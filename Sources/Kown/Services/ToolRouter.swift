import Foundation

/// 中央工具定义 + 执行入口。所有 provider 客户端共用同一份 tool schema。
enum ToolCatalog {
    static let webSearch = LLMTool(
        // ⚠️ 不能叫 "web_search":那是 Anthropic 内置服务端工具的保留名。新版 Claude
        // (如 claude-opus-4-7)看到一个「叫 web_search 却不是内置 type」的自定义工具会
        // 卡住并回空消息(无 text、无 tool_use)→ 表现为「(空响应)」。改成带前缀的私有名规避。
        name: "firecrawl_web_search",
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

    static let createEvent = LLMTool(
        name: "create_event",
        description: """
        Add an event to the user's system Calendar (iOS/macOS). Use when the user wants to schedule \
        a meeting, appointment, or block of time. The current local time is given in the system \
        context — convert relative times ("tomorrow 3pm", "next Monday 10am") to an absolute ISO 8601 \
        local datetime for `start`. If no end time is given, the event defaults to 1 hour. Keep the \
        title short and descriptive.
        """,
        parameters: ToolParameters(
            properties: [
                "title": ToolParameterSchema(
                    type: "string",
                    description: "Short title of the event (e.g. '产品评审会', not the whole sentence)."
                ),
                "start": ToolParameterSchema(
                    type: "string",
                    description: "Start datetime in ISO 8601 local time, e.g. 2026-06-07T15:00:00."
                ),
                "end": ToolParameterSchema(
                    type: "string",
                    description: "Optional end datetime in ISO 8601 local time. Omit to default to 1 hour after start."
                ),
                "location": ToolParameterSchema(
                    type: "string",
                    description: "Optional location of the event."
                ),
                "notes": ToolParameterSchema(
                    type: "string",
                    description: "Optional extra details / agenda for the event."
                )
            ],
            required: ["title", "start"]
        )
    )

    static let listEvents = LLMTool(
        name: "list_events",
        description: """
        List the user's upcoming events from the system Calendar (iOS/macOS). Use when the user asks \
        what's on their schedule, what they have coming up, or to check for conflicts before adding an event.
        """,
        parameters: ToolParameters(
            properties: [
                "days": ToolParameterSchema(
                    type: "integer",
                    description: "How many days ahead from now to look (default 7)."
                ),
                "limit": ToolParameterSchema(
                    type: "integer",
                    description: "Max events to return (default 20)."
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

    static let localReadFile = LLMTool(
        name: "local_read_file",
        description: """
        Read a text file inside the user's authorized local folder (macOS only). Paths are relative \
        to that folder. Use this to inspect current content before proposing a change with local_write_file.
        """,
        parameters: ToolParameters(
            properties: [
                "path": ToolParameterSchema(type: "string",
                    description: "Folder-relative file path, e.g. 'notes/todo.md'. No leading slash, no '..'.")
            ],
            required: ["path"]
        )
    )

    static let localListDir = LLMTool(
        name: "local_list_dir",
        description: """
        List entries (files + subfolders) inside the user's authorized local folder (macOS only). \
        Pass an empty path or a relative subfolder path. Use to discover what files exist.
        """,
        parameters: ToolParameters(
            properties: [
                "path": ToolParameterSchema(type: "string",
                    description: "Folder-relative subdirectory, or empty for the root. No '..'.")
            ],
            required: []
        )
    )

    static let localWriteFile = LLMTool(
        name: "local_write_file",
        description: """
        Propose writing / overwriting a text file inside the user's authorized local folder (macOS only). \
        IMPORTANT: this does NOT write immediately — it STAGES the change for the user to review a diff and \
        confirm. Provide the COMPLETE new file content (not a diff). Read the file first with local_read_file \
        when editing an existing file so you edit on top of the real content.
        """,
        parameters: ToolParameters(
            properties: [
                "path": ToolParameterSchema(type: "string",
                    description: "Folder-relative file path, e.g. 'notes/summary.md'. No leading slash, no '..'."),
                "content": ToolParameterSchema(type: "string",
                    description: "The COMPLETE new content of the file (full text, not a diff).")
            ],
            required: ["path", "content"]
        )
    )

    /// 按 context + 技能白名单拼出本次暴露给模型的工具集合。
    /// - webSearch:配置就绪才暴露 `web_search`。
    /// - deviceTools:用户开了「设备工具」总开关时暴露提醒/备忘。
    /// - extraToolNames:当前技能额外点名要的工具(让技能不依赖全局开关即可用其声明的工具)。
    static func enabledTools(webSearch: WebSearchSession?,
                             deviceTools: Bool,
                             extraToolNames: Set<String>,
                             gitHub: Bool = false,
                             fileSystem: Bool = false,
                             mcpTools: [LLMTool] = []) -> [LLMTool] {
        var tools: [LLMTool] = []
        if webSearch != nil { tools.append(ToolCatalog.webSearch) }
        if deviceTools || extraToolNames.contains(ToolCatalog.createReminder.name) { tools.append(ToolCatalog.createReminder) }
        if deviceTools || extraToolNames.contains(ToolCatalog.listReminders.name) { tools.append(ToolCatalog.listReminders) }
        if deviceTools || extraToolNames.contains(ToolCatalog.createEvent.name) { tools.append(ToolCatalog.createEvent) }
        if deviceTools || extraToolNames.contains(ToolCatalog.listEvents.name) { tools.append(ToolCatalog.listEvents) }
        if deviceTools || extraToolNames.contains(ToolCatalog.createNote.name) { tools.append(ToolCatalog.createNote) }
        // 本会话绑定了 GitHub 仓库时,暴露「读文件」工具,让模型改文件前先看现状。
        if gitHub { tools.append(ToolCatalog.githubReadFile) }
        // 本地文件工具(macOS,授权目录已设 + 本次开启时):读 / 列即时,写需用户确认。
        if fileSystem {
            tools.append(ToolCatalog.localReadFile)
            tools.append(ToolCatalog.localListDir)
            tools.append(ToolCatalog.localWriteFile)
        }
        // 外部 MCP server 暴露的工具(已命名空间化),直接追加。
        tools.append(contentsOf: mcpTools)
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
    var webSearch: WebSearchSession? = nil
    /// 本会话绑定的 GitHub 写入目标;非 nil 时 `github_read_file` 工具可用。
    var github: GitHubWriteTarget? = nil
    /// 本地文件工具授权目录的 security-scoped bookmark(macOS);非 nil 时本地文件工具可用。
    var localFileBookmark: Data? = nil
    /// 已连接的 MCP server 会话;非 nil 时其暴露的 `mcp__…` 工具可被调用。
    var mcp: MCPSession? = nil
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
        // MCP 工具(命名空间 mcp__…)路由到对应的 server 连接执行。
        if MCPSession.isMCPTool(call.name) {
            guard let mcp = context.mcp else {
                return Self.errorResult(call, summary: "⚠ MCP 未连接", message: "no mcp session")
            }
            return await mcp.callTool(call)
        }
        switch call.name {
        case ToolCatalog.webSearch.name:
            return await runWebSearch(call)
        case ToolCatalog.createReminder.name:
            return await runCreateReminder(call)
        case ToolCatalog.listReminders.name:
            return await runListReminders(call)
        case ToolCatalog.createEvent.name:
            return await runCreateEvent(call)
        case ToolCatalog.listEvents.name:
            return await runListEvents(call)
        case ToolCatalog.createNote.name:
            return await runCreateNote(call)
        case ToolCatalog.githubReadFile.name:
            return await runGitHubReadFile(call)
        case ToolCatalog.localReadFile.name:
            return await runLocalReadFile(call)
        case ToolCatalog.localListDir.name:
            return await runLocalListDir(call)
        case ToolCatalog.localWriteFile.name:
            return await runLocalWriteFile(call)
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

    // MARK: - create_event

    private func runCreateEvent(_ call: ToolCall) async -> ToolResult {
        #if canImport(EventKit)
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let title = (args["title"] as? String) ?? ""
        let notes = args["notes"] as? String
        let location = args["location"] as? String
        guard let start = (args["start"] as? String).flatMap(Self.parseDate) else {
            return Self.errorResult(call, summary: "⚠ 缺少开始时间", message: "missing or invalid start time")
        }
        let end = (args["end"] as? String).flatMap(Self.parseDate)
        do {
            let r = try await EventKitService.shared.createEvent(
                title: title, notes: notes, start: start, end: end, location: location)
            let payload: [String: Any] = ["success": true, "title": r.title,
                                          "start": (args["start"] as? String) ?? ""]
            return ToolResult(callID: call.id, name: call.name,
                              content: Self.jsonString(payload),
                              summary: "✓ 已添加日程:\(r.title) · \(Self.humanDate(r.start))",
                              isError: false)
        } catch {
            let msg = error.localizedDescription
            return Self.errorResult(call, summary: "⚠ 创建日程失败: \(msg)", message: msg)
        }
        #else
        return Self.errorResult(call, summary: "⚠ 当前平台不支持日历", message: "calendar unsupported on this platform")
        #endif
    }

    // MARK: - list_events

    private func runListEvents(_ call: ToolCall) async -> ToolResult {
        #if canImport(EventKit)
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let days = (args["days"] as? Int) ?? 7
        let limit = (args["limit"] as? Int) ?? 20
        let items = await EventKitService.shared.listEvents(daysAhead: days, limit: limit)
        let payload: [String: Any] = [
            "count": items.count,
            "events": items.map { item -> [String: Any] in
                ["title": item.title,
                 "start": item.start.map(Self.iso) ?? "",
                 "end": item.end.map(Self.iso) ?? "",
                 "location": item.location ?? ""]
            }
        ]
        return ToolResult(callID: call.id, name: call.name,
                          content: Self.jsonString(payload),
                          summary: "✓ 找到 \(items.count) 个日程",
                          isError: false)
        #else
        return Self.errorResult(call, summary: "⚠ 当前平台不支持日历", message: "calendar unsupported on this platform")
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

    // MARK: - 本地文件工具(macOS only)

    private func runLocalReadFile(_ call: ToolCall) async -> ToolResult {
        #if os(macOS)
        guard let data = context.localFileBookmark else {
            return Self.errorResult(call, summary: "⚠ 未授权本地文件目录", message: "no authorized local folder")
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let path = (args["path"] as? String) ?? ""
        return await MainActor.run {
            do {
                let (root, _) = try WorkspaceManager.resolveBookmark(data)
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                let url = try LocalFilesystem.resolved(root: root, rel: path)
                let content = try LocalFilesystem.read(at: url)
                let payload: [String: Any] = ["path": path, "content": content]
                return ToolResult(callID: call.id, name: call.name,
                                  content: Self.jsonString(payload),
                                  summary: "✓ 已读取 \(path)(\(content.count) 字)", isError: false)
            } catch {
                let msg = error.localizedDescription
                return Self.errorResult(call, summary: "⚠ 读取失败: \(msg)", message: msg)
            }
        }
        #else
        return Self.errorResult(call, summary: "⚠ 本地文件工具仅 macOS 支持", message: "local file tools are macOS only")
        #endif
    }

    private func runLocalListDir(_ call: ToolCall) async -> ToolResult {
        #if os(macOS)
        guard let data = context.localFileBookmark else {
            return Self.errorResult(call, summary: "⚠ 未授权本地文件目录", message: "no authorized local folder")
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let path = (args["path"] as? String) ?? ""
        return await MainActor.run {
            do {
                let (root, _) = try WorkspaceManager.resolveBookmark(data)
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                let url = try LocalFilesystem.resolved(root: root, rel: path)
                let entries = try LocalFilesystem.list(at: url)
                let payload: [String: Any] = ["path": path.isEmpty ? "." : path, "entries": entries]
                return ToolResult(callID: call.id, name: call.name,
                                  content: Self.jsonString(payload),
                                  summary: "✓ 列出 \(entries.count) 个条目", isError: false)
            } catch {
                let msg = error.localizedDescription
                return Self.errorResult(call, summary: "⚠ 列目录失败: \(msg)", message: msg)
            }
        }
        #else
        return Self.errorResult(call, summary: "⚠ 本地文件工具仅 macOS 支持", message: "local file tools are macOS only")
        #endif
    }

    private func runLocalWriteFile(_ call: ToolCall) async -> ToolResult {
        #if os(macOS)
        guard let data = context.localFileBookmark else {
            return Self.errorResult(call, summary: "⚠ 未授权本地文件目录", message: "no authorized local folder")
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let path = ((args["path"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
        let newContent = (args["content"] as? String) ?? ""
        return await MainActor.run {
            do {
                let (root, _) = try WorkspaceManager.resolveBookmark(data)
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                // 校验路径 / 后缀(forWrite),不通过直接报错,不暂存。
                let url = try LocalFilesystem.resolved(root: root, rel: path, forWrite: true)
                let old = LocalFilesystem.tryRead(at: url)
                LocalFileToolState.shared.stage(PendingFileWrite(
                    relativePath: path, oldContent: old, newContent: newContent))
                let payload: [String: Any] = ["staged": true, "path": path,
                    "note": "改动已暂存,需用户在界面看 diff 后点「应用」才会写入磁盘。"]
                return ToolResult(callID: call.id, name: call.name,
                                  content: Self.jsonString(payload),
                                  summary: "✓ 已暂存改动 \(path),待确认", isError: false)
            } catch {
                let msg = error.localizedDescription
                return Self.errorResult(call, summary: "⚠ 暂存写入失败: \(msg)", message: msg)
            }
        }
        #else
        return Self.errorResult(call, summary: "⚠ 本地文件工具仅 macOS 支持", message: "local file tools are macOS only")
        #endif
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
