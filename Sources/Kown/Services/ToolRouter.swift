import Foundation

/// 中央工具定义 + 执行入口。所有 provider 客户端共用同一份 tool schema。
enum ToolCatalog {
    static let webSearch = LLMTool(
        name: "web_search",
        description: """
        Search the public web with Firecrawl and return up-to-date results \
        (title, URL, snippet). Use this whenever the user asks about recent events, \
        current data, prices, news, or anything that may have changed since your \
        training cutoff. Prefer English queries for global topics, Chinese for \
        中文-specific topics.
        """,
        parameters: ToolParameters(
            properties: [
                "query": ToolParameterSchema(
                    type: "string",
                    description: "The search query in the most appropriate language."
                ),
                "limit": ToolParameterSchema(
                    type: "integer",
                    description: "Max results to return (1-100, but 5-15 usually suffices). Omit to use the user's configured default."
                )
            ],
            required: ["query"]
        )
    )

    /// 当前启用的工具集合。
    static func enabledTools(forSession session: WebSearchSession?) -> [LLMTool] {
        guard session != nil else { return [] }
        return [webSearch]
    }
}

/// 一次用户发送中,Firecrawl 的配置快照(避免每次工具调用重复读 Keychain)。
struct WebSearchSession: Sendable {
    let config: WebSearchConfig
    let apiKey: String

    /// 工厂方法 — 返回 nil 表示当前没法搜索(用户没开关,或没填 key)。
    @MainActor
    static func makeIfReady(userToggle: Bool) -> WebSearchSession? {
        guard userToggle else { return nil }
        let cfg = WebSearchConfigStore.load()
        guard cfg.enabled else { return nil }
        guard let key = try? WebSearchKey.load(), !key.isEmpty else { return nil }
        return WebSearchSession(config: cfg, apiKey: key)
    }
}

/// 执行模型发出的 ToolCall。线程安全,无可变状态。
struct ToolRouter: Sendable {
    let session: WebSearchSession

    /// 从一次 web_search 的 `ToolResult` 里把命中来源解析成 `[SourceRef]`,用于结构化留痕。
    /// 由于 `ToolRouter` 是无状态值类型(每次工具调用都新建),来源不在实例里累积,
    /// 而是由调用方(AgentRunner / AppViewModel)在拿到 `ToolResult` 后调此静态方法收集,
    /// 再写回对应 `Turn.sources`。解析的是 `runWebSearch` 自己产出的 JSON,字段保持一致。
    /// 失败 / 非 web_search / 错误结果一律返回空数组,绝不抛错。
    static func sources(from result: ToolResult) -> [SourceRef] {
        guard result.name == ToolCatalog.webSearch.name, !result.isError else { return [] }
        guard let data = result.content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var refs: [SourceRef] = []
        for item in results {
            guard let url = item["url"] as? String, !url.isEmpty, !seen.contains(url) else { continue }
            seen.insert(url)
            let title = (item["title"] as? String) ?? url
            let snippet = (item["snippet"] as? String) ?? ""
            refs.append(SourceRef(title: title, url: url, snippet: snippet))
        }
        return refs
    }

    func execute(_ call: ToolCall) async -> ToolResult {
        switch call.name {
        case ToolCatalog.webSearch.name:
            return await runWebSearch(call)
        default:
            return ToolResult(
                callID: call.id,
                name: call.name,
                content: #"{"error":"unknown tool"}"#,
                summary: "⚠ 未知工具: \(call.name)",
                isError: true
            )
        }
    }

    private func runWebSearch(_ call: ToolCall) async -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let query = (args["query"] as? String) ?? ""
        let limit = (args["limit"] as? Int) ?? session.config.resultLimit
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ToolResult(
                callID: call.id,
                name: call.name,
                content: #"{"error":"empty query"}"#,
                summary: "⚠ 搜索参数为空",
                isError: true
            )
        }

        let client = FirecrawlClient(baseURL: session.config.baseURL, apiKey: session.apiKey)
        do {
            let hits = try await client.search(query: trimmed, limit: limit)
            let payload: [String: Any] = [
                "query": trimmed,
                "results": hits.map { hit in
                    [
                        "title": hit.title,
                        "url": hit.url,
                        "snippet": hit.description
                    ] as [String: Any]
                }
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return ToolResult(
                callID: call.id,
                name: call.name,
                content: json,
                summary: "✓ 找到 \(hits.count) 条结果",
                isError: false
            )
        } catch {
            let msg = error.localizedDescription
            let payload = [
                "error": msg
            ]
            let data = try? JSONSerialization.data(withJSONObject: payload)
            let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"error":"unknown"}"#
            return ToolResult(
                callID: call.id,
                name: call.name,
                content: json,
                summary: "⚠ 搜索失败: \(msg)",
                isError: true
            )
        }
    }
}
