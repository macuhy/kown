import Foundation

struct AnthropicClient: LLMClient {
    func stream(prompt: String,
                options: ChatOptions,
                config: ProviderConfig,
                apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlString = joinURL(config.baseURL, "/messages")
                    guard let url = URL(string: urlString) else {
                        throw LLMError.badURL(urlString)
                    }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    var body: [String: Any] = [
                        "model": config.model,
                        "max_tokens": options.maxTokens ?? 4096,
                        "stream": true,
                        "messages": [
                            ["role": "user", "content": prompt]
                        ]
                    ]
                    if let sys = options.systemPrompt, !sys.isEmpty {
                        body["system"] = sys
                    }
                    if let t = options.temperature { body["temperature"] = t }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n" }
                        throw LLMError.httpError(status: http.statusCode, body: body)
                    }

                    let stream = SSELineStream(bytes: bytes)
                    for try await event in stream {
                        // Anthropic SSE: event 字段是事件名,data 是 JSON
                        if event.event == "message_stop" { break }
                        guard event.event == "content_block_delta" else { continue }
                        guard let data = event.data.data(using: .utf8) else { continue }
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let delta = json["delta"] as? [String: Any],
                           let type = delta["type"] as? String,
                           type == "text_delta",
                           let text = delta["text"] as? String, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
