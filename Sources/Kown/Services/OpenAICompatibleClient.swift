import Foundation

struct OpenAICompatibleClient: LLMClient {
    /// 一次 tool-use 循环里允许的最大轮数。最后一轮强制无工具,且追加一条用户提示让模型 wrap up。
    private static let maxToolRounds = 6

    func stream(prompt: String,
                options: ChatOptions,
                config: ProviderConfig,
                apiKey: String) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages: [[String: Any]] = []
                    if let sys = combineSystem(
                        userSystem: options.systemPrompt,
                        summary: options.contextSummary,
                        includeCurrentTime: options.toolContext != nil
                    ) {
                        messages.append(["role": "system", "content": sys])
                    }
                    // 真正的多轮历史(user / assistant 交替)。
                    // 关键:assistant 为空的轮(失败/未作答)必须整轮跳过 —— 否则会出现连续两条
                    // user 消息,DeepSeek 等严格要求 user/assistant 交替的 API 会直接 400。
                    // 「继续生成」要回放整段历史,最易踩中。
                    for turn in options.priorTurns where !turn.assistantText.isEmpty {
                        messages.append(["role": "user", "content": turn.userText])
                        messages.append(["role": "assistant", "content": turn.assistantText])
                    }
                    messages.append(Self.makeUserMessage(prompt: prompt, images: options.images))

                    var cumulativeInput = 0
                    var cumulativeOutput = 0
                    var cumulativeCached = 0

                    for round in 0..<Self.maxToolRounds {
                        let isLast = round == Self.maxToolRounds - 1
                        if isLast, options.toolContext != nil, !options.tools.isEmpty {
                            // 多 tool 轮已耗尽 — 提示模型停止调用,以现有信息作答
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
                            tools: toolsForThisRound,
                            temperature: options.temperature,
                            topP: options.topP,
                            maxTokens: options.maxTokens,
                            yieldText: { continuation.yield(.text($0)) },
                            yieldReasoning: { continuation.yield(.reasoning($0)) }
                        )

                        // 累计 token 用量(tool use loop 里每轮都是独立计费的 API call)
                        cumulativeInput += result.inputTokens
                        cumulativeOutput += result.outputTokens
                        cumulativeCached += result.cachedTokens

                        if Task.isCancelled { break }

                        if result.toolCalls.isEmpty {
                            break
                        }

                        // 把 assistant 消息(可能含文本+tool_calls+reasoning_content)塞回去
                        // DeepSeek thinking 模式必须 echo reasoning_content,否则下一轮 400
                        var assistantMsg: [String: Any] = ["role": "assistant"]
                        assistantMsg["content"] = result.text.isEmpty ? NSNull() : result.text
                        if !result.reasoningContent.isEmpty {
                            assistantMsg["reasoning_content"] = result.reasoningContent
                        }
                        assistantMsg["tool_calls"] = result.toolCalls.map { call -> [String: Any] in
                            [
                                "id": call.id,
                                "type": "function",
                                "function": [
                                    "name": call.name,
                                    "arguments": call.argumentsJSON
                                ]
                            ]
                        }
                        messages.append(assistantMsg)

                        // 执行每个工具,并把结果作为 role=tool 的消息追加
                        guard let ctx = options.toolContext else { break }
                        let router = ToolRouter(context: ctx)
                        for call in result.toolCalls {
                            let argsSummary = ToolStep.summarizeArgs(argumentsJSON: call.argumentsJSON)
                            continuation.yield(.toolStep(ToolStep(id: call.id, round: round,
                                toolName: call.name, argsSummary: argsSummary, status: .running)))
                            continuation.yield(.toolEvent(Self.eventLineForCall(call)))
                            let toolResult = await router.execute(call)
                            continuation.yield(.toolStep(ToolStep(id: call.id, round: round,
                                toolName: call.name, argsSummary: argsSummary,
                                status: toolResult.isError ? .error : .done, resultSummary: toolResult.summary)))
                            continuation.yield(.toolEvent(toolResult.summary))
                            let refs = ToolRouter.sources(from: toolResult)
                            if !refs.isEmpty { continuation.yield(.sources(refs)) }
                            messages.append([
                                "role": "tool",
                                "tool_call_id": toolResult.callID,
                                "content": toolResult.content
                            ])
                        }
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

    private static func makeURL(config: ProviderConfig) throws -> URL {
        let urlString = joinURL(config.baseURL, "/chat/completions")
        guard let url = URL(string: urlString) else {
            throw LLMError.badURL(urlString)
        }
        return url
    }

    private static func makeUserMessage(prompt: String, images: [Attachment.ImagePayload]) -> [String: Any] {
        if images.isEmpty {
            return ["role": "user", "content": prompt]
        }
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for img in images {
            content.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(img.mimeType);base64,\(img.base64)"
                ]
            ])
        }
        return ["role": "user", "content": content]
    }

    private struct RoundResult {
        var text: String = ""
        /// DeepSeek V4-Pro thinking mode 等会单独返回 reasoning_content;
        /// 这种模型要求下轮 assistant message 必须把它原样带回去,否则 400。
        var reasoningContent: String = ""
        var toolCalls: [ToolCall] = []
        /// 末尾 usage chunk 里的 prompt / completion tokens(若 server 没回则为 0)。
        /// prompt_tokens 本就含缓存;cachedTokens = 命中缓存的部分。
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cachedTokens: Int = 0
    }

    /// 跑一次 /chat/completions 流式请求。返回收集到的文本和(可能为空的)工具调用列表。
    private static func streamOnce(
        url: URL,
        apiKey: String,
        model: String,
        messages: [[String: Any]],
        tools: [LLMTool],
        temperature: Double?,
        topP: Double?,
        maxTokens: Int?,
        yieldText: (String) -> Void,
        yieldReasoning: (String) -> Void = { _ in }
    ) async throws -> RoundResult {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            // 请求 server 在末尾发一个独立 chunk 带 usage(prompt/completion tokens),
            // OpenAI 兼容的厂家(deepseek/qwen/moonshot/zhipu/glm/openrouter 等)大多支持。
            // 不支持的厂家会忽略这个字段,我们 fallback 到 inputTokens=0。
            "stream_options": ["include_usage": true],
            "messages": messages
        ]
        if let temperature { body["temperature"] = temperature }
        if let topP { body["top_p"] = topP }
        if let maxTokens { body["max_tokens"] = maxTokens }
        if !tools.isEmpty {
            body["tools"] = tools.map(serializeTool)
            body["tool_choice"] = "auto"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errBody = ""
            for try await line in bytes.lines { errBody += line + "\n" }
            throw LLMError.httpError(status: http.statusCode, body: errBody)
        }

        var result = RoundResult()
        /// index → partial tool_call data
        var pendingCalls: [Int: (id: String, name: String, arguments: String)] = [:]

        let stream = SSELineStream(bytes: bytes)
        for try await event in stream {
            let payload = event.data
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // OpenAI 末尾会发一个独立 chunk:choices=[] + usage=...,提取 token 用量
            if let usage = json["usage"] as? [String: Any] {
                if let prompt = usage["prompt_tokens"] as? Int { result.inputTokens = prompt }
                if let completion = usage["completion_tokens"] as? Int { result.outputTokens = completion }
                // 缓存命中:OpenAI 用 prompt_tokens_details.cached_tokens;DeepSeek 用 prompt_cache_hit_tokens。
                if let details = usage["prompt_tokens_details"] as? [String: Any],
                   let cached = details["cached_tokens"] as? Int {
                    result.cachedTokens = cached
                } else if let hit = usage["prompt_cache_hit_tokens"] as? Int {
                    result.cachedTokens = hit
                }
            }
            guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else { continue }

            if let delta = first["delta"] as? [String: Any] {
                if let content = delta["content"] as? String, !content.isEmpty {
                    result.text += content
                    yieldText(content)
                }
                if let rc = delta["reasoning_content"] as? String, !rc.isEmpty {
                    result.reasoningContent += rc
                    yieldReasoning(rc)
                }
                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        let index = (tc["index"] as? Int) ?? 0
                        var existing = pendingCalls[index] ?? (id: "", name: "", arguments: "")
                        if let id = tc["id"] as? String, !id.isEmpty { existing.id = id }
                        if let fn = tc["function"] as? [String: Any] {
                            if let name = fn["name"] as? String, !name.isEmpty {
                                existing.name = name
                            }
                            if let args = fn["arguments"] as? String, !args.isEmpty {
                                existing.arguments += args
                            }
                        }
                        pendingCalls[index] = existing
                    }
                }
            }
        }

        // 把 pending 整理成 ToolCall(按 index 排序)
        for index in pendingCalls.keys.sorted() {
            let p = pendingCalls[index]!
            guard !p.name.isEmpty else { continue }
            let id = p.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : p.id
            let args = p.arguments.isEmpty ? "{}" : p.arguments
            result.toolCalls.append(ToolCall(id: id, name: p.name, argumentsJSON: args))
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
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": tool.parameters.required
                ]
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
