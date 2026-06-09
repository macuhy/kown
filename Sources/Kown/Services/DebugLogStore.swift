import Foundation

/// 一条 LLM HTTP 请求 / 返回的调试记录。一个请求一条(多轮工具循环、去参重试各自一条)。
/// 仅用于排查「空响应」之类问题:完整请求体 + 原始返回,点一下复制全文。
struct DebugLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let model: String
    let method: String
    /// 已脱敏的 URL(剥掉 key/x-goog-api-key query),保留 host 以便判断是否走中转。
    let url: String
    /// 美化后的请求体 JSON。API Key 不在请求体里(在 header / Gemini 在 URL query),故安全。
    let requestBody: String
    /// HTTP 状态码;网络层失败时为 nil。
    let httpStatus: Int?
    /// 原始返回:成功时是累积的 SSE 全文;非 2xx 时是错误响应体。
    let responseRaw: String
    let error: String?
    let elapsedMS: Int

    /// URL 的 host,用于列表行展示「host · model」。
    var host: String { URL(string: url)?.host ?? url }

    /// 状态短标:给列表徽章用。
    var statusBadge: String {
        if error != nil { return "网络错误" }
        guard let s = httpStatus else { return "?" }
        if !(200..<300).contains(s) { return "HTTP \(s)" }
        return isLikelyEmpty ? "空" : "200"
    }

    /// 粗判「200 但没有任何内容增量」——本次要抓的现象。provider 无关的启发式。
    var isLikelyEmpty: Bool {
        guard error == nil, let s = httpStatus, (200..<300).contains(s) else { return false }
        let markers = ["text_delta", "\"content\"", "input_json_delta", "functionCall",
                       "tool_use", "reasoning_content", "\"delta\"", "\"parts\""]
        let lower = responseRaw
        return !markers.contains { lower.contains($0) }
    }

    var summary: String {
        if let error { return "网络错误:\(error.prefix(80))" }
        let code = httpStatus.map(String.init) ?? "?"
        var s = "HTTP \(code) · 返回 \(responseRaw.count) 字符 · \(elapsedMS)ms"
        if isLikelyEmpty { s += " · ⚠ 疑似空响应(无任何内容增量)" }
        return s
    }

    /// 复制用的完整文本。
    var fullText: String {
        var lines: [String] = []
        lines.append("===== Kown 调试日志 =====")
        lines.append("时间: \(Self.fmt.string(from: timestamp))")
        lines.append("模型: \(model)")
        lines.append("请求: \(method) \(url)")
        lines.append("HTTP: \(httpStatus.map(String.init) ?? "(网络层失败)")")
        if let error { lines.append("错误: \(error)") }
        lines.append("摘要: \(summary)")
        lines.append("")
        lines.append("----- 请求体 -----")
        lines.append(requestBody)
        lines.append("")
        lines.append("----- 原始返回 -----")
        lines.append(responseRaw.isEmpty ? "(空)" : responseRaw)
        return lines.joined(separator: "\n")
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}

/// 调试日志总线。默认关;开关在「设置 ▸ 调试日志」。
/// 内存环形缓冲(最近 50 条),**不落盘** —— 请求体含对话原文,避免同步进 iCloud / 泄露。
@Observable
@MainActor
final class DebugLogStore {
    static let shared = DebugLogStore()

    nonisolated static let enabledKey = "kown.debugLog.enabled.v1"
    private static let maxEntries = 50

    private(set) var entries: [DebugLogEntry] = []

    private init() {}

    /// 后台廉价判断,client 在录前先看这个,关时零开销。仿 AnthropicClient.claudeThinkingEnabled。
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    func clear() { entries.removeAll() }

    func append(_ entry: DebugLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    /// 从 client(后台线程)调用:同步把请求体序列化 + 脱敏 URL + 组装条目,再跳主线程入库。
    nonisolated static func record(model: String,
                                   method: String,
                                   url: String,
                                   body: [String: Any],
                                   status: Int?,
                                   responseRaw: String,
                                   error: String?,
                                   startedAt: Date) {
        let pretty: String
        if let data = try? JSONSerialization.data(withJSONObject: body,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            pretty = s
        } else {
            pretty = "\(body)"
        }
        let entry = DebugLogEntry(
            timestamp: Date(),
            model: model,
            method: method,
            url: redactURL(url),
            requestBody: pretty,
            httpStatus: status,
            responseRaw: responseRaw,
            error: error,
            elapsedMS: Int(Date().timeIntervalSince(startedAt) * 1000)
        )
        Task { @MainActor in shared.append(entry) }
    }

    /// 剥掉 URL 里的 API Key query(Gemini 把 key 放在 `?key=`;有的代理用 `x-goog-api-key`)。
    nonisolated static func redactURL(_ raw: String) -> String {
        guard var comps = URLComponents(string: raw), let items = comps.queryItems else { return raw }
        let secret: Set<String> = ["key", "x-goog-api-key", "api_key", "apikey"]
        comps.queryItems = items.map { item in
            secret.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "***")
                : item
        }
        return comps.string ?? raw
    }
}
