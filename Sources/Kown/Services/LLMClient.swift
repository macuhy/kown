import Foundation

struct ChatOptions: Sendable {
    var systemPrompt: String?
    var temperature: Double?
    var maxTokens: Int?

    static let `default` = ChatOptions()
}

protocol LLMClient: Sendable {
    func stream(prompt: String,
                options: ChatOptions,
                config: ProviderConfig,
                apiKey: String) -> AsyncThrowingStream<String, Error>
}

enum LLMError: Error, LocalizedError {
    case badURL(String)
    case httpError(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let u): return "URL 无效: \(u)"
        case .httpError(let s, let b):
            let preview = b.count > 200 ? String(b.prefix(200)) + "…" : b
            return "HTTP \(s): \(preview)"
        case .decoding(let m): return "解码失败: \(m)"
        }
    }
}

/// 拼 baseURL 与 path,处理结尾斜杠
func joinURL(_ base: String, _ path: String) -> String {
    let b = base.hasSuffix("/") ? String(base.dropLast()) : base
    let p = path.hasPrefix("/") ? path : "/" + path
    return b + p
}
