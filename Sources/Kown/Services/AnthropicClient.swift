import Foundation

struct AnthropicClient: LLMClient {
    private static let maxToolRounds = 6
    /// 默认 output token 预算 — 32k 在多轮工具循环里太奢侈。
    private static let defaultMaxTokens = 8192
    /// 扩展思考的 token 预算。
    private static let thinkingBudget = 2048
    /// 「Claude 扩展思考」开关(设置 ▸ 性能)。与 PerformanceSettingsView 的 @AppStorage 同 key。
    static var claudeThinkingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "kown.claudeThinking.v1")
    }

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
                    // 在最后一条历史消息上打缓存断点 → 缓存覆盖 system + 全部历史,新问题是未缓存增量。
                    if var last = messages.last, let textContent = last["content"] as? String {
                        last["content"] = [["type": "text", "text": textContent,
                                            "cache_control": ["type": "ephemeral"]]]
                        messages[messages.count - 1] = last
                    }
                    messages.append(Self.makeUserMessage(prompt: prompt, images: options.images))

                    var cumulativeInput = 0
                    var cumulativeOutput = 0
                    var cumulativeCached = 0
                    // 扩展思考:仅在本轮不带工具时开(避免 thinking 块跨工具轮 echo 的复杂度)。
                    let thinkingOn = Self.claudeThinkingEnabled && options.tools.isEmpty

                    // 新版 Claude 模型已弃用 temperature / top_p,带上会报 invalid_request。
                    // 这两个值用 var 持有:一旦某轮因此报错,去掉后重试,并对后续轮次同样省略。
                    var effTemperature = options.temperature
                    var effTopP = options.topP
                    func runStreamOnce(messages: [[String: Any]], tools: [LLMTool],
                                       temperature: Double?, topP: Double?) async throws -> RoundResult {
                        try await Self.streamOnce(
                            url: try Self.makeURL(config: config),
                            apiKey: apiKey,
                            model: config.model,
                            messages: messages,
                            systemPrompt: combineSystem(
                                userSystem: options.systemPrompt,
                                summary: options.contextSummary,
                                includeCurrentTime: options.toolContext != nil
                            ),
                            tools: tools,
                            temperature: temperature,
                            topP: topP,
                            maxTokens: options.maxTokens ?? Self.defaultMaxTokens,
                            thinkingEnabled: thinkingOn,
                            yieldText: { continuation.yield(.text($0)) },
                            yieldReasoning: { continuation.yield(.reasoning($0)) }
                        )
                    }

                    for round in 0..<Self.maxToolRounds {
                        let isLast = round == Self.maxToolRounds - 1
                        if isLast, options.toolContext != nil, !options.tools.isEmpty {
                            messages.append([
                                "role": "user",
                                "content": "工具调用次数已达上限,请基于以上工具结果直接给出完整答案,本轮不要再调用工具。"
                            ])
                        }
                        let toolsForThisRound: [LLMTool] = isLast ? [] : options.tools
                        let result: RoundResult
                        do {
                            result = try await runStreamOnce(messages: messages, tools: toolsForThisRound,
                                                             temperature: effTemperature, topP: effTopP)
                        } catch let e as LLMError where Self.isDeprecatedSamplingParam(e)
                                && (effTemperature != nil || effTopP != nil) {
                            // 模型不接受 temperature / top_p —— 去掉后重试一次(错误在出文前发生,无半截内容)。
                            effTemperature = nil
                            effTopP = nil
                            result = try await runStreamOnce(messages: messages, tools: toolsForThisRound,
                                                             temperature: nil, topP: nil)
                        }

                        cumulativeInput += result.inputTokens
                        cumulativeOutput += result.outputTokens
                        cumulativeCached += result.cachedInputTokens

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

                        guard let ctx = options.toolContext else { break }
                        let router = ToolRouter(context: ctx)
                        var toolResultBlocks: [[String: Any]] = []
                        for call in result.toolCalls {
                            let argsSummary = ToolStep.summarizeArgs(argumentsJSON: call.argumentsJSON)
                            continuation.yield(.toolStep(ToolStep(id: call.id, round: round,
                                toolName: call.name, argsSummary: argsSummary, status: .running)))
                            continuation.yield(.toolEvent(Self.eventLineForCall(call)))
                            let tr = await router.execute(call)
                            continuation.yield(.toolStep(ToolStep(id: call.id, round: round,
                                toolName: call.name, argsSummary: argsSummary,
                                status: tr.isError ? .error : .done, resultSummary: tr.summary)))
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

    /// 命中「该模型已弃用 / 不支持 temperature 或 top_p」类报错 → 调用方去掉采样参数重试。
    /// 兼容直连 Anthropic 与中转代理(代理常把 400 包成 HTTP 200 + JSON 信封,文案里仍含原始 message)。
    private static func isDeprecatedSamplingParam(_ error: LLMError) -> Bool {
        guard case .httpError(_, let body) = error else { return false }
        let b = body.lowercased()
        let mentionsParam = b.contains("temperature") || b.contains("top_p") || b.contains("top-p")
        let mentionsReject = b.contains("deprecated") || b.contains("not supported")
            || b.contains("unsupported") || b.contains("not allowed") || b.contains("does not support")
        return mentionsParam && mentionsReject
    }

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
        /// inputTokens 已归一为「含缓存的 prompt 总数」= input_tokens + cache_read + cache_creation;
        /// cachedInputTokens = cache_read(命中缓存读取)。
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cachedInputTokens: Int = 0
    }

    private static func streamOnce(
        url: URL,
        apiKey: String,
        model: String,
        messages: [[String: Any]],
        systemPrompt: String?,
        tools: [LLMTool],
        temperature: Double?,
        topP: Double?,
        maxTokens: Int,
        thinkingEnabled: Bool = false,
        yieldText: (String) -> Void,
        yieldReasoning: (String) -> Void = { _ in }
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
            // system 作为 block 数组并打缓存断点 → 命中提示缓存(否则 Anthropic 不缓存)。
            body["system"] = [["type": "text", "text": sys, "cache_control": ["type": "ephemeral"]]]
        }
        if thinkingEnabled {
            // 扩展思考:max_tokens 必须 > budget;temperature 必须为 1(故不传 temperature)。
            // 官方约束下也不传 top_p,避免与 thinking 冲突。
            body["thinking"] = ["type": "enabled", "budget_tokens": thinkingBudget]
            body["max_tokens"] = max(maxTokens, thinkingBudget + 1024)
        } else {
            if let temperature { body["temperature"] = temperature }
            if let topP { body["top_p"] = topP }
        }
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

            // Anthropic 在 HTTP 200 的流上以 SSE `event: error` 回报错误(overloaded / invalid_request 等)。
            // 不处理会被 default 静默吞掉 → 整条流空手收尾、不抛异常,上层只看到「没返回内容」。
            if event.event == "error" {
                let err = json["error"] as? [String: Any]
                let type = err?["type"] as? String ?? "error"
                let msg = err?["message"] as? String ?? event.data
                throw LLMError.httpError(status: 200, body: "\(type): \(msg)")
            }

            switch event.event {
            case "message_start":
                // message.usage.input_tokens 是 prompt 用量
                if let msg = json["message"] as? [String: Any],
                   let usage = msg["usage"] as? [String: Any] {
                    let input = usage["input_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                    // 归一:input 含缓存读取 + 缓存写入,缓存比 = cacheRead / input。
                    result.inputTokens = input + cacheRead + cacheCreate
                    result.cachedInputTokens = cacheRead
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
                } else if type == "thinking_delta", let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                    // extended thinking 的思考增量(需在请求侧显式开启 thinking 才会收到)。
                    yieldReasoning(thinking)
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
