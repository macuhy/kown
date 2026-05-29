import Foundation

/// 多轮历史中的一条消息(用 user/assistant 显式分角色,模型才会按"对话"对待,
/// 而不是把它当作 prompt 里的一段背景文字)。
struct PriorTurn: Sendable, Hashable {
    let userText: String
    let assistantText: String
}

struct ChatOptions: Sendable {
    var systemPrompt: String?
    var temperature: Double?
    var maxTokens: Int?
    /// 图片附件（仅部分 provider 支持；其他 provider 会忽略）
    var images: [Attachment.ImagePayload] = []
    /// 滚动摘要 — 把过早的历史压缩成一段,放进 system prompt。
    var contextSummary: String? = nil
    /// 最近若干轮原文(以 user/assistant pair 形式注入 messages 数组),保留细节。
    var priorTurns: [PriorTurn] = []
    /// 暴露给模型的工具集 + 执行入口。nil 表示本次不带工具。
    /// 客户端通过 `toolSession` 在工具被调用时本地执行并回灌结果。
    var tools: [LLMTool] = []
    var toolSession: WebSearchSession? = nil

    static let `default` = ChatOptions()
}

protocol LLMClient: Sendable {
    /// 流式响应：客户端可能多次发请求(tool-use loop),返回的事件流交错 text 与 toolEvent。
    func stream(prompt: String,
                options: ChatOptions,
                config: ProviderConfig,
                apiKey: String) -> AsyncThrowingStream<LLMStreamChunk, Error>
}

enum LLMError: Error, LocalizedError {
    case badURL(String)
    case httpError(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let u): return "URL 无效: \(u)"
        case .httpError(let s, let b):
            // 4000 字符 — Google 完整 error.details 数组 + Anthropic safety reasons 都能装下。
            // UI 端有复制按钮,长一点没关系,保留完整 debug 信息。
            let preview = b.count > 4000 ? String(b.prefix(4000)) + "…" : b
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

/// 把 systemPrompt 和 contextSummary 合成最终 system 段。
/// `includeCurrentTime` 为 true 时在最前面注入当前日期/星期/时区
/// — 当前只在 🌐 web search 启用时这么干,因为搜来的结果天然带时效性。
/// 摘要单独成块,带 [对话回顾] 标签,提示模型这是"以前的事"。
func combineSystem(userSystem: String?, summary: String?, includeCurrentTime: Bool = false) -> String? {
    let sys = (userSystem ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let sum = (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var parts: [String] = []
    if includeCurrentTime { parts.append(currentTimeContextLine()) }
    if !sys.isEmpty { parts.append(sys) }
    if !sum.isEmpty {
        parts.append("""
        [对话回顾 — 这是当前会话之前的内容,请记住并基于它继续与用户对话]
        \(sum)
        """)
    }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
}

/// 生成"现在是 …"的一行,塞进 system / CLI prompt 头部。
/// 用系统本地时区,中文星期名;附 ISO 形式给模型一个稳定锚点。
func currentTimeContextLine() -> String {
    let now = Date()
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
    isoFormatter.timeZone = TimeZone.current

    let zh = DateFormatter()
    zh.locale = Locale(identifier: "zh_CN")
    zh.timeZone = TimeZone.current
    zh.dateFormat = "yyyy 年 M 月 d 日 EEEE HH:mm"

    let iso = isoFormatter.string(from: now)
    let human = zh.string(from: now)
    let tz = TimeZone.current.identifier
    return "[当前时间] \(human) (\(tz),ISO \(iso))。回答涉及今天 / 现在 / 最近等相对时间时请以此为准。"
}

/// CLI 等没法发 messages[] 的客户端,用这个把多轮 + 摘要 + 当前问题平铺成单段 prompt。
func flattenPromptForCLI(prompt: String, summary: String?, priorTurns: [PriorTurn], includeCurrentTime: Bool = false) -> String {
    let sum = (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var lines: [String] = []
    if includeCurrentTime {
        lines.append(currentTimeContextLine())
        lines.append("")
    }
    if !sum.isEmpty {
        lines.append("<对话回顾>")
        lines.append(sum)
        lines.append("</对话回顾>")
        lines.append("")
    }
    for (i, turn) in priorTurns.enumerated() {
        lines.append("<历史第\(i+1)轮>")
        lines.append("用户: \(turn.userText)")
        if !turn.assistantText.isEmpty {
            lines.append("助手: \(turn.assistantText)")
        }
        lines.append("</历史第\(i+1)轮>")
        lines.append("")
    }
    lines.append("<当前问题>")
    lines.append(prompt)
    lines.append("</当前问题>")
    return lines.joined(separator: "\n")
}
