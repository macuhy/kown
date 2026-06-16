import Foundation

struct ConnectorHubMCPServerSnapshot: Codable, Hashable, Sendable {
    enum TransportKind: String, Codable, Hashable, Sendable {
        case http
        case stdio
    }

    var name: String
    var enabled: Bool
    var transportKind: TransportKind
    var transportSummary: String
    var createdAt: Date
    var slug: String
}

struct ConnectorHubKnowledgeSnapshot: Codable, Hashable, Sendable {
    var folderCount: Int
    var documentCount: Int
    var characterCount: Int
    var lastUpdatedAt: Date?
}

struct ConnectorHubICloudSnapshot: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var isAvailable: Bool
    var readyForCloudWrite: Bool
    var statusText: String
    var conflictBackupCount: Int
}

enum ConnectorHubCalendarAccess: String, Codable, Hashable, Sendable {
    case fullAccess
    case writeOnly
    case denied
    case restricted
    case notDetermined
    case unknown
    case unsupported
}

struct ConnectorHubRuntimeState: Codable, Hashable, Sendable {
    var githubConnected: Bool

    var webSearchEnabled: Bool
    var webSearchHasKey: Bool
    var webSearchBaseURL: String
    var webSearchResultLimit: Int

    var mcpServers: [ConnectorHubMCPServerSnapshot]
    var knowledge: ConnectorHubKnowledgeSnapshot
    var iCloud: ConnectorHubICloudSnapshot

    var remindersSupported: Bool
    var remindersAuthorized: Bool
    var calendarSupported: Bool
    var calendarAccess: ConnectorHubCalendarAccess

    var notesMode: String
    var localFilesSupported: Bool
    var localFilesAuthorized: Bool
    var localFilesPath: String?
    var codeExecutionSupported: Bool
    var codeExecutionEnabled: Bool

    static let empty = ConnectorHubRuntimeState(
        githubConnected: false,
        webSearchEnabled: false,
        webSearchHasKey: false,
        webSearchBaseURL: "https://api.firecrawl.dev",
        webSearchResultLimit: 5,
        mcpServers: [],
        knowledge: ConnectorHubKnowledgeSnapshot(folderCount: 0, documentCount: 0, characterCount: 0, lastUpdatedAt: nil),
        iCloud: ConnectorHubICloudSnapshot(isEnabled: false, isAvailable: false, readyForCloudWrite: false,
                                           statusText: "iCloud status unknown", conflictBackupCount: 0),
        remindersSupported: false,
        remindersAuthorized: false,
        calendarSupported: false,
        calendarAccess: .unsupported,
        notesMode: "Unavailable",
        localFilesSupported: false,
        localFilesAuthorized: false,
        localFilesPath: nil,
        codeExecutionSupported: false,
        codeExecutionEnabled: false
    )
}

enum ConnectorHubService {
    /// Runtime snapshot that reads existing stores directly, without depending on AppViewModel.
    @MainActor
    static func snapshot(now: Date = Date()) -> ConnectorHubSnapshot {
        makeSnapshot(from: runtimeState(), now: now)
    }

    /// Pure builder used by tests and by future integrations that already own connector state.
    static func makeSnapshot(from state: ConnectorHubRuntimeState, now: Date = Date()) -> ConnectorHubSnapshot {
        ConnectorHubSnapshot(generatedAt: now, connectors: [
            githubConnector(state),
            webConnector(state),
            mcpConnector(state),
            knowledgeConnector(state),
            iCloudConnector(state, now: now),
            calendarRemindersConnector(state, now: now),
            systemToolsConnector(state)
        ])
    }

    @MainActor
    static func runtimeState() -> ConnectorHubRuntimeState {
        let webConfig = WebSearchConfigStore.load()
        let mcpStore = MCPStore()
        let folders = KnowledgeStore.loadAll()
        let iCloudSync = ICloudSync.shared

        return ConnectorHubRuntimeState(
            githubConnected: GitHubAuth.isConnected(),
            webSearchEnabled: webConfig.enabled,
            webSearchHasKey: WebSearchKey.hasKey(),
            webSearchBaseURL: webConfig.baseURL,
            webSearchResultLimit: webConfig.resultLimit,
            mcpServers: mcpStore.servers.map(Self.mcpServerSnapshot),
            knowledge: Self.knowledgeSnapshot(from: folders),
            iCloud: ConnectorHubICloudSnapshot(
                isEnabled: iCloudSync.isEnabled,
                isAvailable: iCloudSync.isAvailable,
                readyForCloudWrite: iCloudSync.readyForCloudWrite,
                statusText: iCloudSync.status.displayText,
                conflictBackupCount: iCloudSync.conflictBackupFileCount()
            ),
            remindersSupported: Self.remindersSupported,
            remindersAuthorized: Self.remindersAuthorized,
            calendarSupported: Self.calendarSupported,
            calendarAccess: Self.calendarAccess,
            notesMode: Self.notesMode,
            localFilesSupported: Self.localFilesSupported,
            localFilesAuthorized: Self.localFilesAuthorized,
            localFilesPath: Self.localFilesPath,
            codeExecutionSupported: true,
            codeExecutionEnabled: CodeExecToolState.shared.isEnabled
        )
    }

    private static func githubConnector(_ state: ConnectorHubRuntimeState) -> ConnectorHubItem {
        let connected = state.githubConnected
        return ConnectorHubItem(
            kind: .github,
            subtitle: connected ? "OAuth token 已保存,可绑定仓库 / 分支" : "未连接账号",
            state: connected ? .connected : .needsSetup,
            health: connected ? .healthy : .needsSetup,
            permissions: [.read, .write],
            details: [
                ConnectorHubDetail(label: "认证", value: connected ? "已连接" : "未连接"),
                ConnectorHubDetail(label: "Scope", value: GitHubAuth.scope),
                ConnectorHubDetail(label: "写入路径", value: "Contents API / 提交")
            ],
            projectDescription: "项目可绑定一个 GitHub 仓库和分支,让回答引用仓库文件现状并生成可提交的改动。",
            agentDescription: "Read repository files before edits and prepare GitHub-backed writes for the selected repo/branch.",
            suggestedActions: connected ? [] : [
                ConnectorHubAction(connector: .github,
                                   title: "连接 GitHub",
                                   detail: "在 GitHub 设置页完成 Device Flow 授权,启用仓库读取和提交。",
                                   priority: .high)
            ]
        )
    }

    private static func webConnector(_ state: ConnectorHubRuntimeState) -> ConnectorHubItem {
        let statePair: (ConnectorHubState, ConnectorHubHealth, String) = {
            switch (state.webSearchEnabled, state.webSearchHasKey) {
            case (true, true): return (.connected, .healthy, "联网搜索已可用")
            case (true, false): return (.needsSetup, .needsSetup, "已开启,但缺少 Firecrawl API Key")
            case (false, true): return (.disabled, .warning, "API Key 已保存,但全局开关关闭")
            case (false, false): return (.needsSetup, .needsSetup, "未配置 Firecrawl")
            }
        }()

        var actions: [ConnectorHubAction] = []
        if !state.webSearchHasKey {
            actions.append(ConnectorHubAction(connector: .web,
                                              title: "填写 Firecrawl API Key",
                                              detail: "Web Search 需要 Key 才会向 Agent 暴露 web_search 工具。",
                                              priority: .high))
        }
        if !state.webSearchEnabled {
            actions.append(ConnectorHubAction(connector: .web,
                                              title: "开启 Web Search",
                                              detail: "开启后,发送时可按需注入实时网页搜索。"))
        }

        return ConnectorHubItem(
            kind: .web,
            subtitle: statePair.2,
            state: statePair.0,
            health: statePair.1,
            permissions: [.read],
            details: [
                ConnectorHubDetail(label: "Base URL", value: state.webSearchBaseURL),
                ConnectorHubDetail(label: "结果数", value: "\(state.webSearchResultLimit)"),
                ConnectorHubDetail(label: "Key", value: state.webSearchHasKey ? "已保存" : "未保存")
            ],
            projectDescription: "项目可声明需要实时资料时使用 Firecrawl 搜索和抓取网页正文。",
            agentDescription: "Use web_search for current facts, news, prices, source discovery, and citation seed results.",
            suggestedActions: actions
        )
    }

    private static func mcpConnector(_ state: ConnectorHubRuntimeState) -> ConnectorHubItem {
        let total = state.mcpServers.count
        let enabled = state.mcpServers.filter(\.enabled).count
        let newest = state.mcpServers.map(\.createdAt).max()
        let httpCount = state.mcpServers.filter { $0.transportKind == .http }.count
        let stdioCount = state.mcpServers.filter { $0.transportKind == .stdio }.count

        let connection: (ConnectorHubState, ConnectorHubHealth, String) = {
            if total == 0 { return (.needsSetup, .needsSetup, "尚未挂载 MCP server") }
            if enabled == 0 { return (.disabled, .warning, "已配置 \(total) 个 server,但都未启用") }
            if enabled < total { return (.partial, .warning, "\(enabled)/\(total) 个 server 已启用") }
            return (.configured, .healthy, "\(enabled) 个 server 已启用")
        }()

        var actions: [ConnectorHubAction] = []
        if total == 0 {
            actions.append(ConnectorHubAction(connector: .mcp,
                                              title: "添加 MCP server",
                                              detail: "配置远程 HTTP/SSE 或本地 stdio server,给 Agent 扩展第三方工具。",
                                              priority: .high))
        } else if enabled == 0 {
            actions.append(ConnectorHubAction(connector: .mcp,
                                              title: "启用至少一个 MCP server",
                                              detail: "只有启用的 server 会在发送时连接并暴露工具。",
                                              priority: .high))
        }
        if enabled > 0 {
            actions.append(ConnectorHubAction(connector: .mcp,
                                              title: "测试 MCP 连接",
                                              detail: "发送前建议测试 tools/list,确认外部工具仍可发现。",
                                              priority: .low))
        }

        return ConnectorHubItem(
            kind: .mcp,
            subtitle: connection.2,
            state: connection.0,
            health: connection.1,
            permissions: [.read, .write, .action],
            lastSyncAt: newest,
            details: [
                ConnectorHubDetail(label: "Server", value: "\(enabled)/\(total) enabled"),
                ConnectorHubDetail(label: "HTTP", value: "\(httpCount)"),
                ConnectorHubDetail(label: "stdio", value: "\(stdioCount)")
            ] + state.mcpServers.prefix(3).map { server in
                ConnectorHubDetail(id: "server.\(server.slug)", label: server.name,
                                   value: server.enabled ? server.transportSummary : "Disabled")
            },
            projectDescription: "项目可选择让 Agent 调用外部 MCP 工具,例如数据库、浏览器、设计工具或内部系统。",
            agentDescription: enabled > 0
                ? "Connect enabled MCP servers and expose namespaced tools like mcp__server__tool during the tool loop."
                : "No MCP tools are currently enabled for agent use.",
            suggestedActions: actions
        )
    }

    private static func knowledgeConnector(_ state: ConnectorHubRuntimeState) -> ConnectorHubItem {
        let knowledge = state.knowledge
        let hasDocs = knowledge.documentCount > 0
        return ConnectorHubItem(
            kind: .knowledgeBase,
            subtitle: hasDocs
                ? "\(knowledge.folderCount) 个资料夹,\(knowledge.documentCount) 篇文档"
                : "暂无可检索文档",
            state: hasDocs ? .connected : .needsSetup,
            health: hasDocs ? .healthy : .needsSetup,
            permissions: [.read, .write],
            lastSyncAt: knowledge.lastUpdatedAt,
            details: [
                ConnectorHubDetail(label: "资料夹", value: "\(knowledge.folderCount)"),
                ConnectorHubDetail(label: "文档", value: "\(knowledge.documentCount)"),
                ConnectorHubDetail(label: "字符", value: Self.compactCount(knowledge.characterCount))
            ],
            projectDescription: "项目可绑定知识库资料夹,本地 RAG 会按问题检索 top-K 片段并注入上下文。",
            agentDescription: "Retrieve local knowledge snippets without network access; use as trusted project memory and source grounding.",
            suggestedActions: hasDocs ? [] : [
                ConnectorHubAction(connector: .knowledgeBase,
                                   title: "导入知识库文档",
                                   detail: "添加文本、PDF、文件夹或网页正文后,项目和 Agent 才能检索本地资料。",
                                   priority: .high)
            ]
        )
    }

    private static func iCloudConnector(_ state: ConnectorHubRuntimeState, now: Date) -> ConnectorHubItem {
        let cloud = state.iCloud
        let connection: (ConnectorHubState, ConnectorHubHealth, String) = {
            if cloud.isEnabled && cloud.isAvailable && cloud.readyForCloudWrite {
                return (.connected, .healthy, cloud.statusText)
            }
            if cloud.isEnabled && cloud.isAvailable && !cloud.readyForCloudWrite {
                return (.partial, .warning, "iCloud 容器可用,正在等待安全写入闸门")
            }
            if cloud.isEnabled && !cloud.isAvailable {
                return (.unavailable, .unavailable, cloud.statusText)
            }
            if !cloud.isEnabled && cloud.isAvailable {
                return (.disabled, .warning, cloud.statusText)
            }
            return (.unavailable, .unavailable, cloud.statusText)
        }()

        var actions: [ConnectorHubAction] = []
        if !cloud.isEnabled {
            actions.append(ConnectorHubAction(connector: .iCloud,
                                              title: "开启 iCloud 同步",
                                              detail: "开启后会话、Provider 配置、Web Search 配置和知识库可跨设备同步。"))
        }
        if !cloud.isAvailable {
            actions.append(ConnectorHubAction(connector: .iCloud,
                                              title: "检查 iCloud 登录和容器权限",
                                              detail: "当前无法访问 Kown 的 iCloud 容器,请确认系统账号和 entitlements。",
                                              priority: cloud.isEnabled ? .high : .normal))
        }
        if cloud.conflictBackupCount > 0 {
            actions.append(ConnectorHubAction(connector: .iCloud,
                                              title: "清理 iCloud 冲突备份",
                                              detail: "检测到 \(cloud.conflictBackupCount) 个已合并的冲突备份文件,可在设置里清理。"))
        }

        return ConnectorHubItem(
            kind: .iCloud,
            subtitle: connection.2,
            state: connection.0,
            health: connection.1,
            permissions: [.read, .write],
            lastSyncAt: cloud.isEnabled && cloud.isAvailable ? now : nil,
            details: [
                ConnectorHubDetail(label: "开关", value: cloud.isEnabled ? "已开启" : "未开启"),
                ConnectorHubDetail(label: "容器", value: cloud.isAvailable ? "可用" : "不可用"),
                ConnectorHubDetail(label: "写入闸门", value: cloud.readyForCloudWrite ? "就绪" : "等待中"),
                ConnectorHubDetail(label: "冲突备份", value: "\(cloud.conflictBackupCount)")
            ],
            projectDescription: "项目资料和配置可经 iCloud Drive 在同一 Apple ID 设备间同步。",
            agentDescription: "Use synced Kown data directories as the shared configuration and knowledge substrate across devices.",
            suggestedActions: actions
        )
    }

    private static func calendarRemindersConnector(_ state: ConnectorHubRuntimeState, now: Date) -> ConnectorHubItem {
        guard state.remindersSupported || state.calendarSupported else {
            return ConnectorHubItem(
                kind: .calendarReminders,
                subtitle: "当前平台不支持 EventKit",
                state: .unavailable,
                health: .unavailable,
                permissions: [.read, .write, .action],
                details: [ConnectorHubDetail(label: "EventKit", value: "Unsupported")],
                projectDescription: "当前平台无法访问系统日历和提醒事项。",
                agentDescription: "Calendar and reminder tools are unavailable on this platform.",
                suggestedActions: []
            )
        }

        let calendarText = Self.calendarAccessLabel(state.calendarAccess)
        let hasReminder = state.remindersAuthorized
        let hasCalendarRead = state.calendarAccess == .fullAccess
        let hasCalendarWrite = state.calendarAccess == .fullAccess || state.calendarAccess == .writeOnly
        let anyAuthorized = hasReminder || hasCalendarWrite
        let fullReady = hasReminder && hasCalendarRead
        let stateAndHealth: (ConnectorHubState, ConnectorHubHealth, String) = {
            if fullReady { return (.connected, .healthy, "提醒和日历完整可用") }
            if anyAuthorized { return (.partial, .warning, "部分系统日程能力可用") }
            return (.needsSetup, .needsSetup, "尚未授权提醒事项或日历")
        }()

        var actions: [ConnectorHubAction] = []
        if !hasReminder {
            actions.append(ConnectorHubAction(connector: .calendarReminders,
                                              title: "授权提醒事项",
                                              detail: "授权后 Agent 可创建提醒并列出未完成待办。",
                                              priority: .high))
        }
        if !hasCalendarRead {
            actions.append(ConnectorHubAction(connector: .calendarReminders,
                                              title: hasCalendarWrite ? "升级完整日历访问" : "授权日历访问",
                                              detail: "完整访问可读取日程、检查冲突并把会议纪要写回事件。",
                                              priority: hasCalendarWrite ? .normal : .high))
        }

        return ConnectorHubItem(
            kind: .calendarReminders,
            subtitle: stateAndHealth.2,
            state: stateAndHealth.0,
            health: stateAndHealth.1,
            permissions: [.read, .write, .action],
            lastSyncAt: anyAuthorized ? now : nil,
            details: [
                ConnectorHubDetail(label: "提醒事项", value: hasReminder ? "已授权" : "未授权"),
                ConnectorHubDetail(label: "日历", value: calendarText),
                ConnectorHubDetail(label: "日历写入", value: hasCalendarWrite ? "可创建事件" : "不可写")
            ],
            projectDescription: "项目/技能可让 Agent 创建提醒、读取日程、创建日历事件或写回会议纪要。",
            agentDescription: "Create reminders, list reminders/events, create calendar events, and use schedule context when authorized.",
            suggestedActions: actions
        )
    }

    private static func systemToolsConnector(_ state: ConnectorHubRuntimeState) -> ConnectorHubItem {
        let local = state.localFilesSupported
            ? (state.localFilesAuthorized ? "已授权" : "未授权")
            : "Unsupported"
        let code = state.codeExecutionSupported
            ? (state.codeExecutionEnabled ? "已开启" : "默认关闭")
            : "Unsupported"
        let hasOptionalTool = state.localFilesAuthorized || state.codeExecutionEnabled

        var actions: [ConnectorHubAction] = []
        if state.localFilesSupported && !state.localFilesAuthorized {
            actions.append(ConnectorHubAction(connector: .systemTools,
                                              title: "授权本地文件夹",
                                              detail: "选择一个目录后,Agent 可读取/列出文本文件;写入仍需你确认 diff。"))
        }
        if state.codeExecutionSupported && !state.codeExecutionEnabled {
            actions.append(ConnectorHubAction(connector: .systemTools,
                                              title: "按需开启代码执行",
                                              detail: "仅在信任的对话中开启 run_code,用于计算、数据处理和脚本验证。",
                                              priority: .low))
        }

        return ConnectorHubItem(
            kind: .systemTools,
            subtitle: hasOptionalTool ? "本机工具已有可用能力" : "备忘录可用,本地文件/代码执行需显式开启",
            state: hasOptionalTool ? .connected : .partial,
            health: hasOptionalTool ? .healthy : .warning,
            permissions: [.read, .write, .action],
            details: [
                ConnectorHubDetail(label: "备忘录", value: state.notesMode),
                ConnectorHubDetail(label: "本地文件", value: local),
                ConnectorHubDetail(label: "授权目录", value: state.localFilesPath ?? "-"),
                ConnectorHubDetail(label: "代码执行", value: code)
            ],
            projectDescription: "系统工具覆盖备忘录、本地文件夹和代码执行等本机能力,适合把 Agent 输出落到用户设备。",
            agentDescription: "Use notes/local-file/code tools when enabled; local writes are staged for user review before disk changes.",
            suggestedActions: actions
        )
    }

    @MainActor
    private static func knowledgeSnapshot(from folders: [KnowledgeFolder]) -> ConnectorHubKnowledgeSnapshot {
        let documents = folders.flatMap(\.docs)
        let newestFolder = folders.map(\.updatedAt).max()
        let newestDoc = documents.map(\.addedAt).max()
        return ConnectorHubKnowledgeSnapshot(
            folderCount: folders.count,
            documentCount: documents.count,
            characterCount: folders.reduce(0) { $0 + $1.totalChars },
            lastUpdatedAt: [newestFolder, newestDoc].compactMap { $0 }.max()
        )
    }

    private static func mcpServerSnapshot(_ server: MCPServerConfig) -> ConnectorHubMCPServerSnapshot {
        ConnectorHubMCPServerSnapshot(
            name: server.name,
            enabled: server.enabled,
            transportKind: server.transport.isHTTP ? .http : .stdio,
            transportSummary: server.transport.summary,
            createdAt: server.createdAt,
            slug: server.slug
        )
    }

    private static func calendarAccessLabel(_ access: ConnectorHubCalendarAccess) -> String {
        switch access {
        case .fullAccess: return "完整访问"
        case .writeOnly: return "仅添加事件"
        case .denied: return "已拒绝"
        case .restricted: return "受限制"
        case .notDetermined: return "未询问"
        case .unknown: return "未知"
        case .unsupported: return "Unsupported"
        }
    }

    private static func compactCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private static var remindersSupported: Bool {
        #if canImport(EventKit)
        return true
        #else
        return false
        #endif
    }

    @MainActor
    private static var remindersAuthorized: Bool {
        #if canImport(EventKit)
        return EventKitService.shared.isAuthorized
        #else
        return false
        #endif
    }

    private static var calendarSupported: Bool {
        #if canImport(EventKit)
        return true
        #else
        return false
        #endif
    }

    @MainActor
    private static var calendarAccess: ConnectorHubCalendarAccess {
        #if canImport(EventKit)
        switch EventKitService.shared.eventAccessState {
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .unknown: return .unknown
        }
        #else
        return .unsupported
        #endif
    }

    private static var notesMode: String {
        #if os(macOS)
        return "macOS 自动化"
        #elseif os(iOS)
        return "复制后打开备忘录"
        #else
        return "Unavailable"
        #endif
    }

    private static var localFilesSupported: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    @MainActor
    private static var localFilesAuthorized: Bool {
        #if os(macOS)
        return LocalFileToolState.shared.isAuthorized
        #else
        return false
        #endif
    }

    @MainActor
    private static var localFilesPath: String? {
        #if os(macOS)
        return LocalFileToolState.shared.displayPath
        #else
        return nil
        #endif
    }
}
