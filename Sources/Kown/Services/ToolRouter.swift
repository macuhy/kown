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

    static let createReminder = LLMTool(
        name: "create_reminder",
        description: """
        Create a reminder in the user's system Reminders app (iOS/macOS). Use when the user \
        wants to be reminded to do something, set a to-do, or has a deadline. The current local \
        time is given in the system context — convert relative times ("tomorrow 9am", "next Monday") \
        to an absolute ISO 8601 local datetime for `due`. Keep the title short and action-oriented.
        """,
        parameters: ToolParameters(
            properties: [
                "title": ToolParameterSchema(
                    type: "string",
                    description: "Short title of the reminder (action-oriented, not the whole sentence)."
                ),
                "due": ToolParameterSchema(
                    type: "string",
                    description: "Optional due datetime in ISO 8601 local time, e.g. 2026-06-07T09:00:00. Omit if no time was given."
                ),
                "notes": ToolParameterSchema(
                    type: "string",
                    description: "Optional extra details / context for the reminder."
                )
            ],
            required: ["title"]
        )
    )

    static let listReminders = LLMTool(
        name: "list_reminders",
        description: """
        List the user's incomplete reminders from the system Reminders app (iOS/macOS). Use when \
        the user asks what they have to do, what's pending, or before adding a duplicate.
        """,
        parameters: ToolParameters(
            properties: [
                "limit": ToolParameterSchema(
                    type: "integer",
                    description: "Max reminders to return (default 20)."
                )
            ],
            required: []
        )
    )

    static let createNote = LLMTool(
        name: "create_note",
        description: """
        Create a note in the user's system Notes app. Use when the user wants to save / jot down \
        content for later. Distill the content into a clear title plus concise body before saving. \
        On iOS there is no public Notes-writing API, so this copies the content and opens Notes for \
        the user to paste — the tool result will say so; relay that to the user honestly.
        """,
        parameters: ToolParameters(
            properties: [
                "title": ToolParameterSchema(
                    type: "string",
                    description: "One-line title summarizing the note."
                ),
                "body": ToolParameterSchema(
                    type: "string",
                    description: "The note body. Keep it concise; use short bullet lines when helpful."
                )
            ],
            required: ["body"]
        )
    )

    static let githubReadFile = LLMTool(
        name: "github_read_file",
        description: """
        Read the current content of a file in the connected GitHub repository (the conversation is \
        bound to a specific repo + branch). Use this BEFORE rewriting an existing file with a \
        ```kown:write``` block, so you edit on top of the real current content instead of guessing \
        and overwriting it. No need to read when creating a brand-new file.
        """,
        parameters: ToolParameters(
            properties: [
                "path": ToolParameterSchema(
                    type: "string",
                    description: "Repo-relative file path, e.g. 'docs/plan.md'. No leading slash."
                )
            ],
            required: ["path"]
        )
    )

    /// 按 context + 技能白名单拼出本次暴露给模型的工具集合。
    /// - webSearch:配置就绪才暴露 `web_search`。
    /// - deviceTools:用户开了「设备工具」总开关时暴露提醒/备忘。
    /// - extraToolNames:当前技能额外点名要的工具(让技能不依赖全局开关即可用其声明的工具)。
    static func enabledTools(webSearch: WebSearchSession?,
                             deviceTools: Bool,
                             extraToolNames: Set<String>,
                             gitHub: Bool = false) -> [LLMTool] {
        var tools: [LLMTool] = []
        if webSearch != nil { tools.append(ToolCatalog.webSearch) }
        if deviceTools || extraToolNames.contains(ToolCatalog.createReminder.name) { tools.append(ToolCatalog.createReminder) }
        if deviceTools || extraToolNames.contains(ToolCatalog.listReminders.name) { tools.append(ToolCatalog.listReminders) }
        if deviceTools || extraToolNames.contains(ToolCatalog.createNote.name) { tools.append(ToolCatalog.createNote) }
        // 本会话绑定了 GitHub 仓库时,暴露「读文件」工具,让模型改文件前先看现状。
        if gitHub { tools.append(ToolCatalog.githubReadFile) }
        return tools
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

/// 一次发送的工具执行上下文。携带工具运行时所需的状态(目前只有 web search 会话需要)。
/// 设备工具(提醒/备忘)执行时走各自的单例 / 系统服务,不需要额外上下文。
/// `nil` 表示本次不带任何工具 —— 客户端据此跳过工具循环、且不注入当前时间。
struct ToolContext: Sendable {
    var webSearch: WebSearchSession?
    /// 本会话绑定的 GitHub 写入目标;非 nil 时 `github_read_file` 工具可用。
    var github: GitHubWriteTarget?
}

/// 执行模型发出的 ToolCall。线程安全,无可变状态。
struct ToolRouter: Sendable {
    let context: ToolContext

    /// 从一次 web_search 的 `ToolResult` 里把命中来源解析成 `[SourceRef]`,用于结构化留痕。
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
        case ToolCatalog.createReminder.name:
            return await runCreateReminder(call)
        case ToolCatalog.listReminders.name:
            return await runListReminders(call)
        case ToolCatalog.createNote.name:
            return await runCreateNote(call)
        case ToolCatalog.githubReadFile.name:
            return await runGitHubReadFile(call)
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

    // MARK: - web_search

    private func runWebSearch(_ call: ToolCall) async -> ToolResult {
        guard let session = context.webSearch else {
            return Self.errorResult(call, summary: "⚠ 联网未配置", message: "web search not configured")
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let query = (args["query"] as? String) ?? ""
        let limit = (args["limit"] as? Int) ?? session.config.resultLimit
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.errorResult(call, summary: "⚠ 搜索参数为空", message: "empty query")
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
            return Self.errorResult(call, summary: "⚠ 搜索失败: \(msg)", message: msg)
        }
    }

    // MARK: - create_reminder

    private func runCreateReminder(_ call: ToolCall) async -> ToolResult {
        #if canImport(EventKit)
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let title = (args["title"] as? String) ?? ""
        let notes = args["notes"] as? String
        let due = (args["due"] as? String).flatMap(Self.parseDate)
        do {
            let r = try await EventKitService.shared.createReminder(title: title, notes: notes, due: due)
            let dueText = r.due.map { " · " + Self.humanDate($0) } ?? ""
            let payload: [String: Any] = ["success": true, "title": r.title,
                                          "due": (args["due"] as? String) ?? ""]
            return ToolResult(callID: call.id, name: call.name,
                              content: Self.jsonString(payload),
                              summary: "✓ 已创建提醒:\(r.title)\(dueText)",
                              isError: false)
        } catch {
            let msg = error.localizedDescription
            return Self.errorResult(call, summary: "⚠ 创建提醒失败: \(msg)", message: msg)
        }
        #else
        return Self.errorResult(call, summary: "⚠ 当前平台不支持提醒", message: "reminders unsupported on this platform")
        #endif
    }

    // MARK: - list_reminders

    private func runListReminders(_ call: ToolCall) async -> ToolResult {
        #if canImport(EventKit)
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let limit = (args["limit"] as? Int) ?? 20
        let items = await EventKitService.shared.listReminders(limit: limit)
        let payload: [String: Any] = [
            "count": items.count,
            "reminders": items.map { item -> [String: Any] in
                ["title": item.title, "due": item.due.map(Self.iso) ?? ""]
            }
        ]
        return ToolResult(callID: call.id, name: call.name,
                          content: Self.jsonString(payload),
                          summary: "✓ 找到 \(items.count) 条待办提醒",
                          isError: false)
        #else
        return Self.errorResult(call, summary: "⚠ 当前平台不支持提醒", message: "reminders unsupported on this platform")
        #endif
    }

    // MARK: - create_note

    private func runCreateNote(_ call: ToolCall) async -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let title = (args["title"] as? String) ?? ""
        let body = (args["body"] as? String) ?? ""
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.errorResult(call, summary: "⚠ 备忘内容为空", message: "empty note body")
        }
        do {
            let r = try await MainActor.run { try NotesService.createNote(title: title, body: body) }
            if r.pastedFallback {
                let payload: [String: Any] = ["success": true, "fallback": "clipboard",
                                              "note": "已把内容复制到剪贴板并打开备忘录,请在备忘录里粘贴保存。"]
                return ToolResult(callID: call.id, name: call.name,
                                  content: Self.jsonString(payload),
                                  summary: "✓ 已复制并打开备忘录(请粘贴)",
                                  isError: false)
            } else {
                let payload: [String: Any] = ["success": true, "title": r.title]
                return ToolResult(callID: call.id, name: call.name,
                                  content: Self.jsonString(payload),
                                  summary: "✓ 已写入备忘录:\(r.title.isEmpty ? "新备忘" : r.title)",
                                  isError: false)
            }
        } catch {
            let msg = error.localizedDescription
            return Self.errorResult(call, summary: "⚠ 写入备忘录失败: \(msg)", message: msg)
        }
    }

    // MARK: - github_read_file

    private func runGitHubReadFile(_ call: ToolCall) async -> ToolResult {
        guard let gh = context.github else {
            return Self.errorResult(call, summary: "⚠ 未连接 GitHub 仓库", message: "no github repo bound")
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let path = ((args["path"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
        guard !path.isEmpty, !path.contains("..") else {
            return Self.errorResult(call, summary: "⚠ 路径为空或非法", message: "empty or invalid path")
        }
        do {
            let file = try await GitHubClient(token: gh.token).getFile(
                owner: gh.owner, repo: gh.repo, path: path, branch: gh.branch)
            guard let content = file.content else {
                let payload: [String: Any] = ["exists": false, "path": path,
                                              "note": "文件在该分支不存在,可视为新建。"]
                return ToolResult(callID: call.id, name: call.name,
                                  content: Self.jsonString(payload),
                                  summary: "✓ \(path) 不存在(新建)",
                                  isError: false)
            }
            let payload: [String: Any] = ["exists": true, "path": path, "content": content]
            return ToolResult(callID: call.id, name: call.name,
                              content: Self.jsonString(payload),
                              summary: "✓ 已读取 \(path)(\(content.count) 字)",
                              isError: false)
        } catch {
            let msg = error.localizedDescription
            return Self.errorResult(call, summary: "⚠ 读取失败: \(msg)", message: msg)
        }
    }

    // MARK: - helpers

    /// 解析模型给的 ISO 8601 时间(带或不带时区都尽量吃下;失败返回 nil)。
    static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        // 无时区的本地时间,如 "2026-06-07T09:00:00" 或 "2026-06-07 09:00"
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }

    /// 机读 ISO 8601 本地时间(给模型看)。
    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    private static func humanDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.timeZone = TimeZone.current
        df.dateFormat = "M 月 d 日 HH:mm"
        return df.string(from: date)
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func errorResult(_ call: ToolCall, summary: String, message: String) -> ToolResult {
        let json = jsonString(["error": message])
        return ToolResult(callID: call.id, name: call.name, content: json, summary: summary, isError: true)
    }
}
