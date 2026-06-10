import Foundation

/// 键盘扩展的极简流式客户端:OpenAI 兼容(/chat/completions)+ Anthropic(/messages)。
/// 键盘扩展内存上限很低(~60MB),只用 URLSession 原生 SSE,不依赖主 app 模块。
struct KeyboardChatClient: Sendable {
    let config: KeyboardProviderConfig

    enum ClientError: LocalizedError {
        case badURL
        case http(Int)
        case api(String)
        var errorDescription: String? {
            switch self {
            case .badURL:       return "服务地址无效"
            case .http(let c):  return "请求失败(\(c)),检查模型配置或网络"
            case .api(let msg): return msg
            }
        }
    }

    /// 流式请求,每个增量片段回调一次 `onDelta`。
    func stream(system: String, user: String, onDelta: @Sendable @escaping (String) async -> Void) async throws {
        if config.isAnthropic {
            try await streamAnthropic(system: system, user: user, onDelta: onDelta)
        } else {
            try await streamOpenAI(system: system, user: user, onDelta: onDelta)
        }
    }

    private var trimmedBase: String {
        config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
    }

    // MARK: OpenAI 兼容

    private func streamOpenAI(system: String, user: String, onDelta: @Sendable @escaping (String) async -> Void) async throws {
        guard let url = URL(string: trimmedBase + "/chat/completions") else { throw ClientError.badURL }

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
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // 部分中转把错误塞进 SSE data(不带 event 行),识别出来给用户看,别吞成空响应。
            if let err = obj["error"] {
                throw ClientError.api(Self.errorMessage(from: err))
            }
            guard let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String, !content.isEmpty
            else { continue }
            await onDelta(content)
        }
    }

    // MARK: Anthropic

    private func streamAnthropic(system: String, user: String, onDelta: @Sendable @escaping (String) async -> Void) async throws {
        guard let url = URL(string: trimmedBase + "/messages") else { throw ClientError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 2048,
            "stream": true,
            "system": system,
            "messages": [
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
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            switch type {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                   let text = delta["text"] as? String, !text.isEmpty {
                    await onDelta(text)
                }
            case "error":
                throw ClientError.api(Self.errorMessage(from: obj["error"] ?? "未知错误"))
            case "message_stop":
                return
            default:
                continue
            }
        }
    }

    /// error 字段可能是字符串,也可能是 {message: ...} 对象,都转成可读文案。
    private static func errorMessage(from err: Any) -> String {
        if let s = err as? String { return s }
        if let dict = err as? [String: Any] {
            if let msg = dict["message"] as? String { return msg }
            return String(describing: dict)
        }
        return "请求出错"
    }
}
