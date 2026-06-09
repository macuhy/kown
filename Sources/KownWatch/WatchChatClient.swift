import Foundation

/// 表盘端的极简 OpenAI 兼容流式客户端:POST /chat/completions,逐 SSE chunk 回吐 delta。
/// 只支持 OpenAI 兼容厂商(大多数中文厂商都兼容);Anthropic/Gemini 不在此处理。
struct WatchChatClient {
    let config: WatchProviderConfig

    enum ClientError: LocalizedError {
        case badURL
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .badURL:        return "服务地址无效"
            case .http(let c):   return "请求失败(\(c))"
            }
        }
    }

    /// 流式请求。`onDelta` 在每个增量片段到达时回调(async,调用方在其中 hop 回主线程更新 UI)。
    func stream(system: String, user: String, onDelta: @Sendable @escaping (String) async -> Void) async throws {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard let url = URL(string: base + "/chat/completions") else { throw ClientError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String, !content.isEmpty
            else { continue }
            await onDelta(content)
        }
    }
}
