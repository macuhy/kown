import Foundation

struct GeminiClient: LLMClient {
    func stream(prompt: String,
                options: ChatOptions,
                config: ProviderConfig,
                apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let path = "/models/\(config.model):streamGenerateContent"
                    var components = URLComponents(string: joinURL(config.baseURL, path))
                    components?.queryItems = [
                        URLQueryItem(name: "alt", value: "sse"),
                        URLQueryItem(name: "key", value: apiKey)
                    ]
                    guard let url = components?.url else {
                        throw LLMError.badURL(joinURL(config.baseURL, path))
                    }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    var body: [String: Any] = [
                        "contents": [
                            [
                                "role": "user",
                                "parts": [["text": prompt]]
                            ]
                        ]
                    ]
                    if let sys = options.systemPrompt, !sys.isEmpty {
                        body["systemInstruction"] = [
                            "parts": [["text": sys]]
                        ]
                    }
                    var gen: [String: Any] = [:]
                    if let t = options.temperature { gen["temperature"] = t }
                    if let m = options.maxTokens { gen["maxOutputTokens"] = m }
                    if !gen.isEmpty { body["generationConfig"] = gen }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n" }
                        throw LLMError.httpError(status: http.statusCode, body: body)
                    }

                    let stream = SSELineStream(bytes: bytes)
                    for try await event in stream {
                        guard let data = event.data.data(using: .utf8) else { continue }
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let candidates = json["candidates"] as? [[String: Any]],
                           let first = candidates.first,
                           let content = first["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]] {
                            for part in parts {
                                if let text = part["text"] as? String, !text.isEmpty {
                                    continuation.yield(text)
                                }
                            }
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
