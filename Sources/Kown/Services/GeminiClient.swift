import Foundation

struct GeminiClient: LLMClient {
    private static let maxToolRounds = 6

    /// 构造当前轮 user content。带图片时 parts 里加 `inline_data`(base64),文本 part 在后。
    private static func makeUserContent(prompt: String, images: [Attachment.ImagePayload]) -> [String: Any] {
        var parts: [[String: Any]] = []
        for img in images {
            parts.append([
                "inline_data": [
                    "mime_type": img.mimeType,
                    "data": img.base64
                ]
            ])
        }
        parts.append(["text": prompt])
        return ["role": "user", "parts": parts]
    }

    func stream(prompt: String,
                options: ChatOptions,
                config: ProviderConfig,
                apiKey: String) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var contents: [[String: Any]] = []
                    for turn in options.priorTurns {
                        contents.append([
                            "role": "user",
                            "parts": [["text": turn.userText]]
                        ])
                        if !turn.assistantText.isEmpty {
                            contents.append([
                                "role": "model",
                                "parts": [["text": turn.assistantText]]
                            ])
                        }
                    }
                    contents.append(Self.makeUserContent(prompt: prompt, images: options.images))

                    var cumulativeInput = 0
                    var cumulativeOutput = 0
                    var cumulativeCached = 0

                    for round in 0..<Self.maxToolRounds {
                        let isLast = round == Self.maxToolRounds - 1
                        if isLast, options.toolSession != nil, !options.tools.isEmpty {
                            contents.append([
                                "role": "user",
                                "parts": [["text": "工具调用次数已达上限,请基于以上工具结果直接给出完整答案,本轮不要再调用工具。"]]
                            ])
                        }
                        let toolsForThisRound: [LLMTool] = isLast ? [] : options.tools

                        let result = try await Self.streamOnce(
                            baseURL: config.baseURL,
                            model: config.model,
                            apiKey: apiKey,
                            contents: contents,
                            systemPrompt: combineSystem(
                                userSystem: options.systemPrompt,
                                summary: options.contextSummary,
                                includeCurrentTime: options.toolSession != nil
                            ),
                            tools: toolsForThisRound,
                            temperature: options.temperature,
                            topP: options.topP,
                            maxTokens: options.maxTokens,
                            yieldText: { continuation.yield(.text($0)) },
                            yieldReasoning: { continuation.yield(.reasoning($0)) }
                        )

                        cumulativeInput += result.inputTokens
                        cumulativeOutput += result.outputTokens
                        cumulativeCached += result.cachedTokens

                        if Task.isCancelled { break }

                        if result.toolCalls.isEmpty {
                            break
                        }

                        // Echo assistant turn(包含 text + functionCall parts)
                        // **关键**:Gemini 2.5+ 思考模型在 functionCall part 上挂 `thoughtSignature`,
                        // 下一轮回传时必须把它原样带上,否则 400 "Function call is missing a thought_signature"。
                        var assistantParts: [[String: Any]] = []
                        if !result.text.isEmpty {
                            var textPart: [String: Any] = ["text": result.text]
                            if let sig = result.standaloneThoughtSignature {
                                textPart["thoughtSignature"] = sig
                            }
                            assistantParts.append(textPart)
                        }
                        for (idx, call) in result.toolCalls.enumerated() {
                            let argsObj = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) ?? [:]
                            var part: [String: Any] = [
                                "functionCall": [
                                    "name": call.name,
                                    "args": argsObj
                                ]
                            ]
                            if idx < result.toolCallSignatures.count,
                               let sig = result.toolCallSignatures[idx] {
                                part["thoughtSignature"] = sig
                            }
                            assistantParts.append(part)
                        }
                        contents.append([
                            "role": "model",
                            "parts": assistantParts
                        ])

                        guard let session = options.toolSession else { break }
                        let router = ToolRouter(session: session)
                        var functionResponseParts: [[String: Any]] = []
                        for call in result.toolCalls {
                            continuation.yield(.toolEvent(Self.eventLineForCall(call)))
                            let tr = await router.execute(call)
                            continuation.yield(.toolEvent(tr.summary))
                            let refs = ToolRouter.sources(from: tr)
                            if !refs.isEmpty { continuation.yield(.sources(refs)) }
                            let contentObj: Any = (try? JSONSerialization.jsonObject(with: Data(tr.content.utf8))) ?? ["raw": tr.content]
                            functionResponseParts.append([
                                "functionResponse": [
                                    "name": tr.name,
                                    "response": ["content": contentObj]
                                ]
                            ])
                        }
                        contents.append([
                            "role": "function",
                            "parts": functionResponseParts
                        ])
                    }

                    if cumulativeInput > 0 || cumulativeOutput > 0 {
                        continuation.yield(.usage(inputTokens: cumulativeInput,
                                                  outputTokens: cumulativeOutput,
                                                  cachedInputTokens: cumulativeCached))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private struct RoundResult {
        var text: String = ""
        var toolCalls: [ToolCall] = []
        /// 每个 functionCall 对应的 `thoughtSignature`(如果模型给了的话)。
        /// Gemini 2.5+ 思考模型在 functionCall part 里附 thoughtSignature,
        /// 下一轮 echo assistant turn 时**必须**原样回传,否则 400 "missing thought_signature"。
        /// 跟 `toolCalls` 同序号,nil 表示这一次没拿到 signature。
        var toolCallSignatures: [String?] = []
        /// 模型纯思考部分的 thoughtSignature(text part 上的、无 functionCall)。
        /// 没 tool 但有 thinking 的 round 用得到。echo 时附在 text part 上。
        var standaloneThoughtSignature: String?
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        /// promptTokenCount 本就含缓存;cachedTokens = cachedContentTokenCount。
        var cachedTokens: Int = 0
    }

    private static func streamOnce(
        baseURL: String,
        model: String,
        apiKey: String,
        contents: [[String: Any]],
        systemPrompt: String?,
        tools: [LLMTool],
        temperature: Double?,
        topP: Double?,
        maxTokens: Int?,
        yieldText: (String) -> Void,
        yieldReasoning: (String) -> Void = { _ in }
    ) async throws -> RoundResult {
        // 走 SSE 流式 `streamGenerateContent?alt=sse`,字一段段实时显。
        // CRLF 解析问题已经在 SSELineStream 修了(0.6.6),thoughtSignature 也带回去了(0.6.7)。
        let path = "/models/\(model):streamGenerateContent"
        var components = URLComponents(string: joinURL(baseURL, path))
        components?.queryItems = [
            URLQueryItem(name: "alt", value: "sse"),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components?.url else {
            throw LLMError.badURL(joinURL(baseURL, path))
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var body: [String: Any] = ["contents": contents]
        if let sys = systemPrompt, !sys.isEmpty {
            body["systemInstruction"] = ["parts": [["text": sys]]]
        }
        var gen: [String: Any] = [:]
        if let temperature { gen["temperature"] = temperature }
        if let topP { gen["topP"] = topP }
        if let maxTokens { gen["maxOutputTokens"] = maxTokens }
        if !gen.isEmpty { body["generationConfig"] = gen }
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": tools.map(serializeTool)]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errBody = ""
            for try await line in bytes.lines { errBody += line + "\n" }
            throw LLMError.httpError(status: http.statusCode, body: errBody)
        }

        var result = RoundResult()
        let stream = SSELineStream(bytes: bytes)
        for try await event in stream {
            guard let data = event.data.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // 每个 chunk 可能都带 usageMetadata,以最后一次为准(累计值)
            if let usage = json["usageMetadata"] as? [String: Any] {
                if let pt = usage["promptTokenCount"] as? Int { result.inputTokens = pt }
                if let ct = usage["candidatesTokenCount"] as? Int { result.outputTokens = ct }
                if let cached = usage["cachedContentTokenCount"] as? Int { result.cachedTokens = cached }
            }
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }

            for part in parts {
                let signature = part["thoughtSignature"] as? String
                let isThought = (part["thought"] as? Bool) ?? false
                if let text = part["text"] as? String, !text.isEmpty {
                    if isThought {
                        // thought summary(需 generationConfig.thinkingConfig.includeThoughts 才会收到):
                        // 走思考流,不计入正文。
                        yieldReasoning(text)
                    } else {
                        result.text += text
                        yieldText(text)
                    }
                }
                if let call = part["functionCall"] as? [String: Any],
                   let name = call["name"] as? String {
                    let args = call["args"] as? [String: Any] ?? [:]
                    let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
                    let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                    result.toolCalls.append(ToolCall(
                        id: "call_\(UUID().uuidString.prefix(8))",
                        name: name,
                        argumentsJSON: argsJSON
                    ))
                    // 跟 toolCalls 数组同步追加(可能是 nil)
                    result.toolCallSignatures.append(signature)
                } else if let signature, result.standaloneThoughtSignature == nil {
                    // 纯思考 part(text 可能为空 + thoughtSignature)。记一份给 text echo 用。
                    result.standaloneThoughtSignature = signature
                }
            }
        }
        return result
    }

    private static func serializeTool(_ tool: LLMTool) -> [String: Any] {
        var properties: [String: Any] = [:]
        for (name, schema) in tool.parameters.properties {
            properties[name] = [
                "type": schema.type,
                "description": schema.description
            ]
        }
        return [
            "name": tool.name,
            "description": tool.description,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": tool.parameters.required
            ]
        ]
    }

    private static func eventLineForCall(_ call: ToolCall) -> String {
        let data = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        if call.name == ToolCatalog.webSearch.name, let q = data["query"] as? String, !q.isEmpty {
            return "🔍 搜索: \(q)"
        }
        return "🔧 调用工具: \(call.name)"
    }
}
