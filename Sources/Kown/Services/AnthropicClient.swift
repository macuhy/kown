import Foundation

struct AnthropicClient: LLMClient {
    private static let maxToolRounds = 6
    /// 默认 output token 预算 — 32k 在多轮工具循环里太奢侈。
    private static let defaultMaxTokens = 8192

    /// 构造当前轮 user 消息。带图片时用 content blocks(图片在前、文本在后,Anthropic 推荐顺序)。
    /// `media_type` 需为 image/jpeg|png|gif|webp(HEIC 在附件加载时已转 JPEG)。
    private static func makeUserMessage(prompt: String, images: [Attachment.ImagePayload]) -> [String: Any] {
        guard !images.isEmpty else {
            return ["role": "user", "content": prompt]
        }
        var content: [[String: Any]] = []
        for img in images {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": img.mimeType,
                    "data": img.base64
                ]
            ])
        }
        content.append(["type": "text", "text": prompt])
        return ["role": "user", "content": content]
    }

    func stream(prompt: String,
                options: ChatOptions,
                config: ProviderConfig,
                apiKey: String) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages: [[String: Any]] = []
                    for turn in options.priorTurns {
                        messages.append(["role": "user", "content": turn.userText])
                        if !turn.assistantText.isEmpty {
                            messages.append(["role": "assistant", "content": turn.assistantText])
                        }
                    }
                    messages.append(Self.makeUserMessage(prompt: prompt, images: options.images))

                    var cumulativeInput = 0
                    var cumulativeOutput = 0

                    for round in 0..<Self.maxToolRounds {
                        let isLast = round == Self.maxToolRounds - 1
                        if isLast, options.toolSession != nil, !options.tools.isEmpty {
                            messages.append([
                                "role": "user",
                                "content": "工具调用次数已达上限,请基于以上工具结果直接给出完整答案,本轮不要再调用工具。"
                            ])
                        }
                        let toolsForThisRound: [LLMTool] = isLast ? [] : options.tools
                        let result = try await Self.streamOnce(
                            url: try Self.makeURL(config: config),
                            apiKey: apiKey,
                            model: config.model,
                            messages: messages,
                            systemPrompt: combineSystem(
                                userSystem: options.systemPrompt,
                                summary: options.contextSummary,
                                includeCurrentTime: options.toolSession != nil
                            ),
                            tools: toolsForThisRound,
                            temperature: options.temperature,
                            maxTokens: options.maxTokens ?? Self.defaultMaxTokens,
                            yieldText: { continuation.yield(.text($0)) }
                        )

                        cumulativeInput += result.inputTokens
                        cumulativeOutput += result.outputTokens

                        if Task.isCancelled { break }

                        if result.toolCalls.isEmpty {
                            break
                        }

                        // assistant 消息: 把 text 块 + tool_use 块完整 echo 回去
                        var assistantBlocks: [[String: Any]] = []
                        if !result.text.isEmpty {
                            assistantBlocks.append(["type": "text", "text": result.text])
                        }
                        for call in result.toolCalls {
                            let argsObj = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) ?? [:]
                            assistantBlocks.append([
                                "type": "tool_use",
                                "id": call.id,
                                "name": call.name,
                                "input": argsObj
                            ])
                        }
                        messages.append([
                            "role": "assistant",
                            "content": assistantBlocks
                        ])

                        guard let session = options.toolSession else { break }
                        let router = ToolRouter(session: session)
                        var toolResultBlocks: [[String: Any]] = []
                        for call in result.toolCalls {
                            continuation.yield(.toolEvent(Self.eventLineForCall(call)))
                            let tr = await router.execute(call)
                            continuation.yield(.toolEvent(tr.summary))
                            let refs = ToolRouter.sources(from: tr)
                            if !refs.isEmpty { continuation.yield(.sources(refs)) }
                            var block: [String: Any] = [
                                "type": "tool_result",
                                "tool_use_id": tr.callID,
                                "content": tr.content
                            ]
                            if tr.isError { block["is_error"] = true }
                            toolResultBlocks.append(block)
                        }
                        messages.append([
                            "role": "user",
                            "content": toolResultBlocks
                        ])
                    }

                    if cumulativeInput > 0 || cumulativeOutput > 0 {
                        continuation.yield(.usage(inputTokens: cumulativeInput,
                                                  outputTokens: cumulativeOutput))
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

    private static func makeURL(config: ProviderConfig) throws -> URL {
        let urlString = joinURL(config.baseURL, "/messages")
        guard let url = URL(string: urlString) else {
            throw LLMError.badURL(urlString)
        }
        return url
    }

    private struct RoundResult {
        var text: String = ""
        var toolCalls: [ToolCall] = []
        /// message_start 给的 input_tokens(prompt) + message_delta 最后的 output_tokens(completion)
        var inputTokens: Int = 0
        var outputTokens: Int = 0
    }

    private static func streamOnce(
        url: URL,
        apiKey: String,
        model: String,
        messages: [[String: Any]],
        systemPrompt: String?,
        tools: [LLMTool],
        temperature: Double?,
        maxTokens: Int,
        yieldText: (String) -> Void
    ) async throws -> RoundResult {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": messages
        ]
        if let sys = systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }
        if let temperature { body["temperature"] = temperature }
        if !tools.isEmpty {
            body["tools"] = tools.map(serializeTool)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errBody = ""
            for try await line in bytes.lines { errBody += line + "\n" }
            throw LLMError.httpError(status: http.statusCode, body: errBody)
        }

        var result = RoundResult()
        /// content_block index → in-progress block data
        var blockType: [Int: String] = [:]
        var blockToolID: [Int: String] = [:]
        var blockToolName: [Int: String] = [:]
        var blockToolArgs: [Int: String] = [:]

        let stream = SSELineStream(bytes: bytes)
        for try await event in stream {
            if event.event == "message_stop" { break }
            guard let data = event.data.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            switch event.event {
            case "message_start":
                // message.usage.input_tokens 是 prompt 用量
                if let msg = json["message"] as? [String: Any],
                   let usage = msg["usage"] as? [String: Any] {
                    if let input = usage["input_tokens"] as? Int { result.inputTokens = input }
                    if let output = usage["output_tokens"] as? Int { result.outputTokens = output }
                }
            case "message_delta":
                // 末段 usage.output_tokens 是累计 completion tokens(覆盖 message_start 的初值)
                if let usage = json["usage"] as? [String: Any],
                   let output = usage["output_tokens"] as? Int {
                    result.outputTokens = output
                }
            case "content_block_start":
                let index = (json["index"] as? Int) ?? 0
                if let block = json["content_block"] as? [String: Any],
                   let type = block["type"] as? String {
                    blockType[index] = type
                    if type == "tool_use" {
                        if let id = block["id"] as? String { blockToolID[index] = id }
                        if let name = block["name"] as? String { blockToolName[index] = name }
                        blockToolArgs[index] = ""
                    }
                }
            case "content_block_delta":
                let index = (json["index"] as? Int) ?? 0
                guard let delta = json["delta"] as? [String: Any],
                      let type = delta["type"] as? String else { continue }
                if type == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                    result.text += text
                    yieldText(text)
                } else if type == "input_json_delta", let partial = delta["partial_json"] as? String {
                    blockToolArgs[index, default: ""] += partial
                }
            case "content_block_stop":
                let index = (json["index"] as? Int) ?? 0
                if blockType[index] == "tool_use",
                   let id = blockToolID[index],
                   let name = blockToolName[index] {
                    let args = blockToolArgs[index] ?? ""
                    result.toolCalls.append(ToolCall(
                        id: id, name: name,
                        argumentsJSON: args.isEmpty ? "{}" : args
                    ))
                }
            default:
                break
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
            "input_schema": [
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
