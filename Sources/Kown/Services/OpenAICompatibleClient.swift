import Foundation

struct OpenAICompatibleClient: LLMClient {
    func stream(prompt: String,
                options: ChatOptions,
                config: ProviderConfig,
                apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlString = joinURL(config.baseURL, "/chat/completions")
                    guard let url = URL(string: urlString) else {
                        throw LLMError.badURL(urlString)
                    }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    var messages: [[String: String]] = []
                    if let sys = options.systemPrompt, !sys.isEmpty {
                        messages.append(["role": "system", "content": sys])
                    }
                    messages.append(["role": "user", "content": prompt])

                    var body: [String: Any] = [
                        "model": config.model,
                        "stream": true,
                        "messages": messages
                    ]
                    if let t = options.temperature { body["temperature"] = t }
                    if let m = options.maxTokens { body["max_tokens"] = m }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n" }
                        throw LLMError.httpError(status: http.statusCode, body: body)
                    }

                    let stream = SSELineStream(bytes: bytes)
                    for try await event in stream {
                        let payload = event.data
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let choices = json["choices"] as? [[String: Any]],
                           let first = choices.first,
                           let delta = first["delta"] as? [String: Any],
                           let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
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
