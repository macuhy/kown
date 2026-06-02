import Foundation
import Observation

@Observable
@MainActor
final class AppViewModel {
    // MARK: - 持久化的数据
    var providers: [ProviderConfig]
    var conversations: [Conversation]
    var webSearchConfig: WebSearchConfig
    /// 知识库资料夹(本地 RAG)。
    var knowledgeFolders: [KnowledgeFolder] = []

    // MARK: - UI 选择 / 输入
    var selectedConversationID: UUID?
    /// 没选会话时新建会话使用的默认模式
    var activeMode: ConversationMode = .council
    var prompt: String = ""
    /// 各会话未发送的输入草稿(切走暂存、切回还原)。会话级,内存留存。
    private var drafts: [UUID: String] = [:]
    /// ⌘K 命令面板是否打开(macOS 菜单命令与 RootView sheet 共用此开关)。
    var showCommandPalette = false
    /// 会话内查找条是否显示(⌘F)。
    var showFind = false
    /// 全局热键 / 菜单栏唤起后请求聚焦输入框 —— 每次自增,InputBarView 监听变化即聚焦。
    var focusInputRequest = 0
    /// 自动容错:某 panel provider 失败时自动换另一家 enabled provider 重试一次。默认关。
    var autoFailoverEnabled: Bool {
        didSet { UserDefaults.standard.set(autoFailoverEnabled, forKey: Self.autoFailoverKey) }
    }
    /// Council 模式:chair 之后额外跑一次「投票打分」(多一次 LLM 调用)。默认关。
    var councilVotingEnabled: Bool {
        didSet { UserDefaults.standard.set(councilVotingEnabled, forKey: Self.councilVotingKey) }
    }
    /// Direct 模式:按问题难度在当前 provider 的 vendor 内自动选模型(便宜↔旗舰)。默认关。
    var autoRouteEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRouteEnabled, forKey: Self.autoRouteKey) }
    }
    var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: Self.systemPromptKey) }
    }
    var isRunning: Bool = false
    /// 当前 runningTask 绑定的会话 ID — 用户切换到别的会话时,直播 UI 不展示,但 task 继续跑;
    /// 切换回原会话时,直播又出现。task 结束清空。
    var runningConvID: UUID?
    /// 输入栏 🌐 按钮状态 — 持久化到 UserDefaults,跨发送、跨重启都记得上一次的选择。
    /// 如果用户在某次会话点亮了 🌐,下次启动 app 仍然默认是亮的(只要 Web Search 还配置好)。
    var webSearchEnabledForNextSend: Bool {
        didSet { UserDefaults.standard.set(webSearchEnabledForNextSend, forKey: Self.webSearchToggleKey) }
    }
    /// 用户偏好:**默认开启网络搜索**。开启后,启动 / 新建会话 / 切换会话时,
    /// `webSearchEnabledForNextSend` 自动被设成 true,免去每次手动点亮 🌐。
    /// 用户当次按 🌐 关了之后仅当前会话生效,下次切回来又自动开。
    var alwaysEnableWebSearch: Bool {
        didSet {
            UserDefaults.standard.set(alwaysEnableWebSearch, forKey: Self.alwaysEnableWebSearchKey)
            // 偏好刚开启时,立刻把当前 webSearch 状态拉成 on(只要 canEnable)
            if alwaysEnableWebSearch, canEnableWebSearch {
                webSearchEnabledForNextSend = true
            }
        }
    }
    /// iCloud 同步管理器引用 — UI / Settings 通过 viewModel.iCloudSync 访问状态。
    let iCloudSync = ICloudSync.shared
    /// 标识当前是否在做 iCloud 迁移(开关切换瞬间)。UI 可据此显示进度。
    var iCloudMigrationInFlight: Bool = false

    /// Debate 模式下要跑的总轮数(1 = 仅立论;2 = 立论 + 反驳;3+ = 后续轮继续反驳/修正)。
    /// 范围 [1, 4]。在 InputBar 上可调,持久化到 UserDefaults。
    var debateRoundsForNextSend: Int {
        didSet {
            let clamped = max(1, min(4, debateRoundsForNextSend))
            if clamped != debateRoundsForNextSend {
                debateRoundsForNextSend = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.debateRoundsKey)
        }
    }

    /// 输入区附件（文件 / 图片）
    var attachments: [Attachment] = []
    /// Prompt enhancer 浮层的状态
    var enhancerOriginal: String?
    var enhancerOutput: String = ""
    var enhancerRunning: Bool = false
    var enhancerError: String?
    var enhancerProvider: ProviderConfig?

    // MARK: - 临时（streaming）状态
    /// 本轮正在流式的 provider 回答；turn 完成后写入 conversation.turns 并清空
    var liveStates: [UUID: ResponseState] = [:]
    /// Chair 的临时状态（仅 Council 模式）
    var liveChairState: ResponseState?
    /// Summary(总结员)的临时状态(仅 Council 模式)
    var liveSummaryState: ResponseState?
    /// Debate 模式下已经完成的临时辩论轮次；当前正在流式的轮次仍在 liveStates。
    var liveDebateRounds: [DebateRound] = []
    /// 本轮发出的 prompt（用于 turn 渲染时取最新一行）
    var liveTurnPrompt: String?
    /// 本轮附带的图片（直播期间也展示,等 Turn 落盘后由 turn.images 接管）
    var liveTurnImages: [TurnImage] = []
    /// 本轮 web_search 命中的引用来源(各 provider 经 .sources chunk 上报,按 url 去重),落盘进 Turn.sources。
    var liveSources: [SourceRef] = []
    /// 正在重试的 (turn, provider[, round]) 组合,UI 据此显示加载态。复合 key:同一 provider 在不同
    /// turn / round 可同时重试。(发送编排在 AppViewModel+Send.swift,故此存储属性放主类。)
    var retryingTickets: Set<String> = []

    // MARK: - 内部
    private static let systemPromptKey = "kown.systemPrompt.v1"
    private static let webSearchToggleKey = "kown.webSearch.toggle.v1"
    private static let alwaysEnableWebSearchKey = "kown.webSearch.alwaysOn.v1"
    private static let debateRoundsKey = "kown.debate.rounds.v1"
    private static let autoFailoverKey = "kown.autoFailover.v1"
    private static let councilVotingKey = "kown.councilVoting.v1"
    private static let autoRouteKey = "kown.autoRoute.v1"
    // 发送编排已移到 AppViewModel+Send.swift,以下原 private 状态降为 internal 供其访问。
    var runningTask: Task<Void, Never>?
    var summarizingTasks: [UUID: Task<Void, Never>] = [:]
    /// 正在自动起标题的会话(防重复触发)。
    var autoTitleTasks: Set<UUID> = []

    // MARK: - Init

    init() {
        // 启动时异步清一次旧 log 文件(保留最近 14 天),后台 queue 跑,毫秒级
        ResponseLogger.rotateOldLogsIfNeeded()
        self.providers = ProviderConfigStore.load()
        self.conversations = ConversationStore.loadAll()
        self.webSearchConfig = WebSearchConfigStore.load()
        self.knowledgeFolders = KnowledgeStore.loadAll()
        self.systemPrompt = UserDefaults.standard.string(forKey: Self.systemPromptKey) ?? ""
        let storedAlwaysOn = UserDefaults.standard.bool(forKey: Self.alwaysEnableWebSearchKey)
        self.alwaysEnableWebSearch = storedAlwaysOn
        // 启动时若"默认联网"开着,强制把 webSearch 状态拉成 on;否则恢复上次状态
        let storedToggle = UserDefaults.standard.bool(forKey: Self.webSearchToggleKey)
        self.webSearchEnabledForNextSend = storedAlwaysOn ? true : storedToggle
        let storedRounds = UserDefaults.standard.integer(forKey: Self.debateRoundsKey)
        self.debateRoundsForNextSend = storedRounds == 0 ? 2 : max(1, min(4, storedRounds))
        self.autoFailoverEnabled = UserDefaults.standard.bool(forKey: Self.autoFailoverKey)
        self.councilVotingEnabled = UserDefaults.standard.bool(forKey: Self.councilVotingKey)
        self.autoRouteEnabled = UserDefaults.standard.bool(forKey: Self.autoRouteKey)

        // 清理被删超过 30 天的会话(回收站自动过期)。
        purgeExpiredTrash()

        // iCloud 容器探测是异步后台进行的(ICloudSync.init 里 Task.detached)。
        // 冷启动时 init() 跑 loadAll 那一刻容器可能还没就绪,iPhone 端尤甚。
        // ICloudSync 现在有 `readyForCloudWrite` 闸门(等本地 `.kown` 出现或 10s timeout),
        // 这里等闸门开了再 refresh — 否则 refresh 拿到的 syncedDataDir 还是本地,白跑一次。
        Task { @MainActor [weak self] in
            // 等 iCloud 闸门最多 12s(覆盖 ICloudSync 内部 10s timeout + buffer)
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                guard let self else { return }
                if !self.iCloudSync.isEnabled { break }  // 用户关着同步,不用等
                if self.iCloudSync.readyForCloudWrite { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self else { return }
            if self.iCloudSync.isEnabled, self.iCloudSync.isAvailable, !self.iCloudMigrationInFlight {
                self.refreshFromICloud()
            } else {
                // 没触发 iCloud 同步全套 reload 时,至少把 hasWebSearchKey 重新从 syncedDataDir 读一次,
                // 避免 init 时刻 Container 没就绪导致永久误报 "未设置"。
                self.refreshHasWebSearchKey()
            }
        }

        #if os(macOS)
        // CLI 自动发送(macOS only — iOS 没有终端入口)
        if let cliPrompt = CLIPendingPrompt.consume() {
            self.prompt = cliPrompt
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.send()
            }
        }
        #endif
    }

    // MARK: - 会话管理

    var selectedConversation: Conversation? {
        guard let id = selectedConversationID else { return nil }
        return conversations.first { $0.id == id }
    }

    var currentMode: ConversationMode {
        selectedConversation?.mode ?? activeMode
    }

    func newConversation(mode: ConversationMode) {
        // 不再取消 isRunning 的任务 — task 继续跑在原 conv 上,只是当前 UI 不再展示其直播。
        // 直播 UI 是否显示由 `runningConvID == selectedConversationID` 决定(MainContentView)。
        stashDraft()
        let conv = Conversation(mode: mode)
        conversations.insert(conv, at: 0)
        selectedConversationID = conv.id
        prompt = ""
        activeMode = mode
        ConversationStore.save(conv)
        applyAlwaysEnableWebSearchIfNeeded()
    }

    /// 若用户开启了"默认联网"偏好,且当前 Web Search 配置 + Key 都齐了,
    /// 把 webSearchEnabledForNextSend 强制拉成 true。否则不动用户上次的选择。
    private func applyAlwaysEnableWebSearchIfNeeded() {
        guard alwaysEnableWebSearch, canEnableWebSearch else { return }
        if !webSearchEnabledForNextSend {
            webSearchEnabledForNextSend = true
        }
    }

    /// 从某轮(含)分支出一个新会话:拷贝 turns[0...N] 到新会话,保留模式/模型选择/workspace/会话提示,
    /// 摘要清零重算。新会话顶到最前并选中。图片引用共享同一同步目录文件(image store 仅追加不删,安全)。
    func forkConversation(fromTurnID turnID: UUID) {
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
        let source = conversations[convIdx]
        let keptTurns = Array(source.turns[0...turnIdx])
        let fork = Conversation(
            title: source.title + " (分支)",
            mode: source.mode,
            turns: keptTurns,
            contextSummary: nil,
            summarizedThroughTurnCount: 0,
            activeProviderIDs: source.activeProviderIDs,
            activeModelChoices: source.activeModelChoices,
            workspaceBookmark: source.workspaceBookmark,
            workspaceDisplayPath: source.workspaceDisplayPath,
            systemPrompt: source.systemPrompt
        )
        stashDraft()
        conversations.insert(fork, at: 0)
        selectedConversationID = fork.id
        prompt = ""
        activeMode = fork.mode
        ConversationStore.save(fork)
        applyAlwaysEnableWebSearchIfNeeded()
        // 复制了多轮 → 后台重算摘要(自身按阈值 self-gate)
        scheduleSummarization(for: fork.id)
    }

    /// 单轮报告文本(Markdown)+ 建议文件名 —— 供「导出报告」用。找不到轮返回 nil。
    func turnReport(turnID: UUID) -> (text: String, fileName: String)? {
        guard let conv = selectedConversation,
              let idx = conv.turns.firstIndex(where: { $0.id == turnID }) else { return nil }
        let turn = conv.turns[idx]
        return (
            ConversationExporter.turnReportMarkdown(turn, mode: conv.mode, index: idx),
            ConversationExporter.suggestedTurnReportFileName(turn, conversationTitle: conv.title)
        )
    }

    func selectConversation(_ id: UUID) {
        // 不打断后台运行的请求 — 它绑定的还是原会话 ID(send() 闭包里 captured),
        // 结束后会正确把 turn 写回 `conversations[原 idx]`。当前选中切换只影响 UI 显示。
        stashDraft()
        selectedConversationID = id
        prompt = drafts[id] ?? ""
        applyAlwaysEnableWebSearchIfNeeded()
        if let conv = conversations.first(where: { $0.id == id }) {
            activeMode = conv.mode
        }
    }

    /// 接续生成:让模型接着上一轮回答继续(上下文已随发送回放,故直接发「继续」指令)。
    func continueGenerating() {
        guard !isRunning, let conv = selectedConversation, !conv.turns.isEmpty else { return }
        prompt = "继续"
        send()
    }

    /// 把当前输入暂存为当前会话的草稿(切换/新建前调用)。
    private func stashDraft() {
        guard let old = selectedConversationID else { return }
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { drafts.removeValue(forKey: old) } else { drafts[old] = prompt }
    }

    // MARK: - Working Folder

    /// 当前选中会话的 workspace URL — 每次访问时解析 bookmark(可能 stale,需用户重选)。
    var currentWorkspaceURL: URL? {
        guard let conv = selectedConversation,
              let bm = conv.workspaceBookmark else { return nil }
        guard let resolved = try? WorkspaceManager.resolveBookmark(bm) else { return nil }
        return resolved.url
    }

    /// 当前选中会话的 workspace 显示路径(可能 bookmark 还能解析但 URL 不存在)
    var currentWorkspaceDisplayPath: String? {
        selectedConversation?.workspaceDisplayPath
    }

    func setWorkspace(_ url: URL) {
        guard let convID = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        do {
            let bm = try WorkspaceManager.makeBookmark(for: url)
            conversations[idx].workspaceBookmark = bm
            conversations[idx].workspaceDisplayPath = url.path
            conversations[idx].updatedAt = Date()
            ConversationStore.save(conversations[idx])
        } catch {
            // 失败静默忽略 — UI 上 workspace 还是没设置,用户可以重试
            print("setWorkspace bookmark failed: \(error)")
        }
    }

    func clearWorkspace() {
        guard let convID = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        conversations[idx].workspaceBookmark = nil
        conversations[idx].workspaceDisplayPath = nil
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }

    /// 未删除(主列表)与已删除(回收站)的会话。
    var activeConversations: [Conversation] { conversations.filter { $0.deletedAt == nil } }
    var trashedConversations: [Conversation] { conversations.filter { $0.deletedAt != nil } }

    /// 软删除:移入回收站(可恢复)。bump updatedAt 保证跨 iCloud 同步以本次为准。
    func deleteConversation(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].deletedAt = Date()
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
        drafts.removeValue(forKey: id)
        if selectedConversationID == id {
            selectedConversationID = activeConversations.first?.id
            prompt = selectedConversationID.flatMap { drafts[$0] } ?? ""
            liveStates.removeAll()
            liveChairState = nil
            liveSummaryState = nil
            liveDebateRounds.removeAll()
        }
    }

    /// 从回收站恢复。
    func restoreConversation(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].deletedAt = nil
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }

    /// 永久删除(删文件 + 日志 + 内存),不可恢复。
    func permanentlyDeleteConversation(_ id: UUID) {
        let title = conversations.first(where: { $0.id == id })?.title ?? ""
        conversations.removeAll { $0.id == id }
        ConversationStore.delete(id)
        ResponseLogger.deleteDirectory(title: title, conversationID: id.uuidString)
        drafts.removeValue(forKey: id)
        if selectedConversationID == id {
            selectedConversationID = activeConversations.first?.id
            prompt = selectedConversationID.flatMap { drafts[$0] } ?? ""
            liveStates.removeAll()
            liveChairState = nil
            liveSummaryState = nil
            liveDebateRounds.removeAll()
        }
    }

    /// 清空回收站(永久删除所有已软删的会话)。
    func emptyTrash() {
        for c in trashedConversations { permanentlyDeleteConversation(c.id) }
    }

    /// 启动时清理被删超过 30 天的会话(永久删除)。
    func purgeExpiredTrash() {
        let threshold = Date().addingTimeInterval(-30 * 24 * 3600)
        for c in conversations where (c.deletedAt.map { $0 < threshold } ?? false) {
            permanentlyDeleteConversation(c.id)
        }
    }

    func renameConversation(_ id: UUID, title: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        let oldTitle = conversations[idx].title
        conversations[idx].title = title
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
        ResponseLogger.renameDirectory(oldTitle: oldTitle, newTitle: title, conversationID: id.uuidString)
        // 重命名后顶到最前，保持 updatedAt 顺序
        let moved = conversations.remove(at: idx)
        conversations.insert(moved, at: 0)
    }

    /// 设置(或清空)会话级系统提示。传入 nil/空白即清空,发送时回退全局 systemPrompt。
    func setConversationSystemPrompt(_ id: UUID, prompt: String?) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[idx].systemPrompt = (trimmed?.isEmpty == false) ? trimmed : nil
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }

    /// 取某会话当前的系统提示(用于编辑入口回填)。
    func conversationSystemPrompt(_ id: UUID) -> String {
        conversations.first(where: { $0.id == id })?.systemPrompt ?? ""
    }

    /// 置顶/取消置顶会话(侧栏排序时置顶优先)。
    func togglePinned(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].pinned.toggle()
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }

    /// 设置会话标签(去空白、去空、去重、保序)。
    func setTags(_ id: UUID, tags: [String]) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        var seen = Set<String>()
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        conversations[idx].tags = cleaned
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }

    /// 全部会话出现过的标签(按出现频率降序),用于侧栏过滤 chips。
    var allTags: [String] {
        var count: [String: Int] = [:]
        for c in conversations where c.deletedAt == nil { for t in c.tags { count[t, default: 0] += 1 } }
        return count.keys.sorted { (count[$0] ?? 0, $1) > (count[$1] ?? 0, $0) }
    }

    /// 切换 tab：当前会话空 → 直接改模式；非空 → 新建会话。返回 true 表示进行了切换。
    func switchMode(to mode: ConversationMode) -> Bool {
        if let id = selectedConversationID,
           let idx = conversations.firstIndex(where: { $0.id == id }) {
            if conversations[idx].turns.isEmpty {
                conversations[idx].mode = mode
                activeMode = mode
                ConversationStore.save(conversations[idx])
                return true
            } else {
                // 已有 turns，开新会话
                newConversation(mode: mode)
                return true
            }
        }
        activeMode = mode
        return true
    }

    // MARK: - Provider 管理

    func saveProviders() {
        ProviderConfigStore.save(providers)
    }

    func addProvider(kind: ProviderKind) {
        let cfg = ProviderConfig(displayName: kind.displayName, kind: kind)
        providers.append(cfg)
        saveProviders()
    }

    /// 一键添加国内厂商预设(base URL / model 已填好,只需补 key 启用)。
    func addPreset(_ preset: ProviderPreset) {
        providers.append(preset.makeConfig())
        saveProviders()
    }

    func removeProvider(_ id: UUID) {
        providers.removeAll { $0.id == id }
        KeychainStore.delete(id: id)
        saveProviders()
    }

    // MARK: - 配置 导入/导出

    /// 当前偏好快照(给备份用)
    private var currentPreferences: KownBackup.Preferences {
        KownBackup.Preferences(
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            debateRounds: debateRoundsForNextSend,
            webSearchEnabledForNextSend: webSearchEnabledForNextSend
        )
    }

    /// 导出当前配置为 JSON Data,供 fileExporter 写盘。
    func exportBackup(includeAPIKeys: Bool) throws -> Data {
        try BackupStore.makeBackup(
            providers: providers,
            webSearchConfig: webSearchConfig,
            includeAPIKeys: includeAPIKeys,
            preferences: currentPreferences
        )
    }

    /// 从备份 Data 导入(覆盖 or 合并),完成后 reload 内存。
    @discardableResult
    func importBackup(_ data: Data, mode: BackupImportMode) throws -> (providers: Int, importedKeys: Int) {
        let backup = try BackupStore.parseBackup(data)
        let result = try BackupStore.applyBackup(backup, mode: mode)

        // reload 内存里的状态
        self.providers = ProviderConfigStore.load()
        self.webSearchConfig = WebSearchConfigStore.load()
        if mode == .replace {
            self.systemPrompt = UserDefaults.standard.string(forKey: Self.systemPromptKey) ?? ""
            self.webSearchEnabledForNextSend = UserDefaults.standard.bool(forKey: Self.webSearchToggleKey)
            let stored = UserDefaults.standard.integer(forKey: Self.debateRoundsKey)
            self.debateRoundsForNextSend = stored == 0 ? 2 : max(1, min(4, stored))
        }
        return result
    }

    // MARK: - iCloud 同步切换

    /// 开/关 iCloud 同步。
    ///
    /// **开启**:先把本地已有的会话/Provider/WebSearch 复制到 iCloud 容器(不覆盖云端),
    /// 然后切换 syncedDataDir,reload 内存里的状态。
    /// **关闭**:把云端最新内容拉回本地(覆盖),然后切换 syncedDataDir,reload。
    /// 整个过程会短暂阻塞 UI(加载圈),完成后会话列表会重新出现。
    func setICloudSyncEnabled(_ enabled: Bool) {
        guard enabled != iCloudSync.isEnabled else { return }
        guard !iCloudMigrationInFlight else { return }

        iCloudMigrationInFlight = true
        Task { @MainActor in
            defer { self.iCloudMigrationInFlight = false }

            if enabled {
                _ = await self.iCloudSync.migrateLocalToCloud()
                self.iCloudSync.isEnabled = true
                // 启用后,iPhone 端(或第二台 Mac)的 iCloud 容器里可能已经躺着别处上传的
                // 文件,但还是"占位"状态(只有元数据没字节)。触发下载并等 5 秒,让 reload
                // 能读到完整内容。剩余仍未下完的等下次 refresh 补。
                _ = await self.iCloudSync.triggerDownloadsAndWait(in: Platform.syncedDataDir)
            } else {
                _ = await self.iCloudSync.mirrorCloudToLocal()
                self.iCloudSync.isEnabled = false
            }

            // 切换数据源后,重读三类存储到内存
            self.providers = ProviderConfigStore.load()
            self.webSearchConfig = WebSearchConfigStore.load()
            self.conversations = ConversationStore.loadAll()
            self.refreshHasWebSearchKey()
            // 用量也跟着同步刷新 — 其他设备的 usage-*.json 文件可能刚被 iCloud 拉到本地
            UsageStore.shared.reload()
            // 选中的会话可能在切换后不存在(空目录或不同设备状态),清掉
            if let id = self.selectedConversationID,
               !self.conversations.contains(where: { $0.id == id }) {
                self.selectedConversationID = self.conversations.first?.id
            }
        }
    }

    /// 手动触发 iCloud 同步刷新 — 拉取最新占位文件 + reload。
    /// iPhone 用户切换 iCloud Drive 设置 / 等不到自动同步 / 想立即看到另一端的新会话,点这个。
    func refreshFromICloud() {
        guard iCloudSync.isEnabled, iCloudSync.isAvailable else { return }
        guard !iCloudMigrationInFlight else { return }
        iCloudMigrationInFlight = true
        Task { @MainActor in
            defer { self.iCloudMigrationInFlight = false }
            _ = await self.iCloudSync.triggerDownloadsAndWait(in: Platform.syncedDataDir)
            self.providers = ProviderConfigStore.load()
            self.webSearchConfig = WebSearchConfigStore.load()
            self.conversations = ConversationStore.loadAll()
            // Firecrawl key 存在 apikeys.json 里(随 iCloud 同步),但 UI/canEnableWebSearch 看的是
            // 缓存的 hasWebSearchKey 标志。拉到新 apikeys.json 后必须重算一次,否则另一端填的 key
            // 同步过来了却一直显示「未设置」(firecrawl key「同步失败」的真因)。
            self.refreshHasWebSearchKey()
            // 用量也要 reload — 别的设备的 usage-*.json 可能刚被 iCloud 拉下来。
            // 启动 2s 后会自动走到这里,所以多端用量累加在 app 启动后短延迟就能看到。
            UsageStore.shared.reload()
            if let id = self.selectedConversationID,
               !self.conversations.contains(where: { $0.id == id }) {
                self.selectedConversationID = self.conversations.first?.id
            }
        }
    }

    /// Chair 单选语义：勾上一个自动取消其他。
    func setChair(_ id: UUID, isChair: Bool) {
        for i in providers.indices {
            if providers[i].id == id {
                providers[i].isChair = isChair
            } else if isChair {
                providers[i].isChair = false
            }
        }
        saveProviders()
    }

    var chairProvider: ProviderConfig? {
        providers.first { $0.isChair && $0.enabled }
    }

    /// Summary 单选语义,跟 Chair 一样。一个 provider 同时勾 chair+summary 是允许的(罕见但合法)。
    func setSummary(_ id: UUID, isSummary: Bool) {
        for i in providers.indices {
            if providers[i].id == id {
                providers[i].isSummary = isSummary
            } else if isSummary {
                providers[i].isSummary = false
            }
        }
        saveProviders()
    }

    var summaryProvider: ProviderConfig? {
        providers.first { $0.isSummary && $0.enabled }
    }

    // MARK: - Web Search 配置

    /// 镜像 KeychainStore 状态;Keychain 自身不可观察,通过 setter/clearer / refreshHasWebSearchKey 维持一致。
    /// 注:启动时 init 评估这个值时 iCloud 容器可能还没探测到位,导致从错误路径读 → 误报 false。
    /// 后续在 ICloud 容器到位 / sync 切换 / cold-start refresh 时调 `refreshHasWebSearchKey()` 重算。
    private(set) var hasWebSearchKey: Bool = WebSearchKey.hasKey()

    func saveWebSearchConfig() {
        WebSearchConfigStore.save(webSearchConfig)
    }

    func setWebSearchKey(_ key: String) throws {
        try WebSearchKey.save(key)
        hasWebSearchKey = true
    }

    func clearWebSearchKey() {
        WebSearchKey.delete()
        hasWebSearchKey = false
    }

    /// 重算 `hasWebSearchKey`,从最新 syncedDataDir 读取实际状态。
    /// 在 iCloud 容器探测完成 / refreshFromICloud / setICloudSyncEnabled 之后调用。
    func refreshHasWebSearchKey() {
        hasWebSearchKey = WebSearchKey.hasKey()
    }

    /// 当前能否启用 🌐 — 配置 enabled + 已存 Key。
    var canEnableWebSearch: Bool {
        webSearchConfig.enabled && hasWebSearchKey
    }

    // MARK: - 附件

    func attachFile(at url: URL) throws {
        // PDF 单独抽文本;其它按纯文本读。
        if url.pathExtension.lowercased() == "pdf" {
            try attachPDF(at: url)
            return
        }
        let f = try AttachmentLoader.loadFile(at: url)
        attachments.append(.file(f))
    }

    func attachPDF(at url: URL) throws {
        let p = try AttachmentLoader.loadPDF(at: url)
        attachments.append(.pdf(p))
    }

    /// 抓取一个网页正文(Firecrawl /scrape)作为文件附件并入上下文。返回 nil 成功,否则错误文案。
    /// 需已配置 Web Search(Firecrawl key + baseURL)。
    func attachScrapedURL(_ urlString: String) async -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "请输入链接" }
        let normalized = trimmed.hasPrefix("http") ? trimmed : "https://" + trimmed
        guard canEnableWebSearch, let key = try? WebSearchKey.load(), !key.isEmpty else {
            return "需先在 设置 ▸ Web Search 配置 Firecrawl Key"
        }
        let client = FirecrawlClient(baseURL: webSearchConfig.baseURL, apiKey: key)
        do {
            let result = try await client.scrape(url: normalized)
            var content = result.markdown
            let maxChars = 120 * 1024
            if content.count > maxChars { content = String(content.prefix(maxChars)) + "\n\n…(网页正文过长已截断)" }
            let payload = Attachment.FilePayload(
                id: UUID(),
                name: result.title.isEmpty ? normalized : result.title,
                content: "<source url=\"\(normalized)\">\n\(content)\n</source>",
                byteCount: content.utf8.count,
                url: URL(string: normalized) ?? URL(fileURLWithPath: "/dev/null")
            )
            attachments.append(.file(payload))
            return nil
        } catch {
            return "抓取失败:\(error.localizedDescription)"
        }
    }

    func attachImage(at url: URL) throws {
        let i = try AttachmentLoader.loadImage(at: url)
        attachments.append(.image(i))
    }

    /// 粘贴板 / drop 等来的图片数据直接成附件 — 跟 attachImage(at:) 同一条收件路径。
    func attachImageData(_ data: Data, name: String, mime: String? = nil) throws {
        let i = try AttachmentLoader.loadImage(data: data, name: name, mime: mime)
        attachments.append(.image(i))
    }

    /// iOS 相册 / 任意来源图片 — 自动把 HEIC 等非标准格式转 JPEG(视觉 API 多不收 HEIC)。
    func attachImageNormalized(_ data: Data, name: String) throws {
        let i = try AttachmentLoader.loadImageNormalized(data: data, name: name)
        attachments.append(.image(i))
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// 把本轮要发的图片字节落盘(同步目录),返回轻量引用挂到 Turn —— 实现本机历史展示 + iCloud 同步。
    func persistTurnImages(_ payloads: [Attachment.ImagePayload]) -> [TurnImage] {
        var refs: [TurnImage] = []
        for p in payloads {
            guard let data = Data(base64Encoded: p.base64) else { continue }
            let fileName = "\(UUID().uuidString).\(ConversationImageStore.ext(forMime: p.mimeType))"
            guard ConversationImageStore.save(data, fileName: fileName) else { continue }
            refs.append(TurnImage(fileName: fileName, mimeType: p.mimeType,
                                  pixelWidth: p.pixelWidth, pixelHeight: p.pixelHeight))
        }
        return refs
    }

    /// 当前 panel 是否能用图片（OpenAI 兼容 / Anthropic / Gemini 都支持视觉；CLI 不支持）
    var anyProviderSupportsImage: Bool {
        let (panel, _) = providersForCurrentSend()
        return panel.contains { $0.kind == .openAICompatible || $0.kind == .anthropic || $0.kind == .gemini }
    }

    // MARK: - Prompt Enhancer

    private var enhancerTask: Task<Void, Never>?

    func enhancePrompt() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 选 chair 或第一个 enabled，再不济用 panel 第一个
        let enabled = providers.filter(\.enabled)
        let provider = chairProvider ?? enabled.first
        guard let provider else {
            enhancerError = "没有启用任何 provider，先到配置里启用一个。"
            enhancerOriginal = trimmed
            enhancerOutput = ""
            return
        }

        enhancerOriginal = trimmed
        enhancerOutput = ""
        enhancerError = nil
        enhancerProvider = provider
        enhancerRunning = true

        let meta = """
        请改写下面的问题，使其更清晰、更具体，目标是让大模型更好理解。规则：
        1) 保持原语言（中文/英文按原文）。
        2) 保留原意，不要回答问题、不要加额外信息。
        3) 直接输出改写后的问题，不要任何前后缀、引号、序号或解释。

        原问题：
        \(trimmed)
        """
        let snapshot = provider
        enhancerTask?.cancel()
        enhancerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let key = snapshot.kind.isCLI ? "" : (try KeychainStore.load(id: snapshot.id))
                let client = ProviderRegistry.client(for: snapshot.kind)
                let options = ChatOptions(systemPrompt: nil, temperature: 0.3, maxTokens: 1024)
                var collected = ""
                for try await chunk in client.stream(prompt: meta, options: options, config: snapshot, apiKey: key) {
                    if Task.isCancelled { break }
                    if case .text(let t) = chunk {
                        collected += t
                        self.enhancerOutput = collected
                    }
                }
                if Task.isCancelled {
                    self.enhancerError = "已取消"
                }
            } catch {
                self.enhancerError = error.localizedDescription
            }
            self.enhancerRunning = false
        }
    }

    func cancelEnhancer() {
        enhancerTask?.cancel()
        enhancerTask = nil
        enhancerRunning = false
    }

    func acceptEnhancedPrompt() {
        let trimmed = enhancerOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { prompt = trimmed }
        dismissEnhancer()
    }

    func dismissEnhancer() {
        cancelEnhancer()
        enhancerOriginal = nil
        enhancerOutput = ""
        enhancerError = nil
        enhancerProvider = nil
    }

    // MARK: - 发送

    /// 根据 currentMode 决定调哪些 provider。Council 模式 Chair 也参与 panel,之后再做综合。
    /// Direct / Compare 优先用 `Conversation.activeProviderIDs`(用户选的),没选才回退到 first N enabled。
    func providersForCurrentSend() -> (panel: [ProviderConfig], chair: ProviderConfig?) {
        let enabled = providers.filter(\.enabled)
        switch currentMode {
        case .council:
            // 所有启用的 provider 都给答案;Chair 之后再做一轮综合
            return (enabled, chairProvider)
        case .debate:
            // 所有启用的 provider 都参与辩论;Chair 在最后做主持总结。
            return (enabled, chairProvider)
        case .direct:
            if let chosen = resolvedFromModelChoices(maxCount: 1), !chosen.isEmpty {
                return (chosen, nil)
            }
            if let chosen = chosenFromActive(maxCount: 1), !chosen.isEmpty {
                return (chosen, nil)
            }
            return (Array(enabled.prefix(1)), nil)
        case .compare:
            let panel: [ProviderConfig]
            if let chosen = resolvedFromModelChoices(maxCount: 2), !chosen.isEmpty {
                panel = chosen
            } else if let chosen = chosenFromActive(maxCount: 2), !chosen.isEmpty {
                panel = chosen
            } else {
                panel = Array(enabled.prefix(2))
            }
            // Compare 模式让 chair 当裁判;但不能是被对比的两家之一(避免自评)
            let judge = chairProvider.flatMap { c in
                panel.contains(where: { $0.id == c.id }) ? nil : c
            }
            return (panel, judge)
        }
    }

    /// 从当前会话的 `activeProviderIDs` 解析出真实 ProviderConfig 列表;不存在的 id 自动跳过。
    private func chosenFromActive(maxCount: Int) -> [ProviderConfig]? {
        guard let conv = selectedConversation, !conv.activeProviderIDs.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        let resolved = conv.activeProviderIDs.compactMap { byID[$0] }.filter(\.enabled)
        return Array(resolved.prefix(maxCount))
    }

    /// 从 `activeModelChoices` 解析,会把 provider 的 model 字段临时替换成 choice 里指定的 model。
    private func resolvedFromModelChoices(maxCount: Int) -> [ProviderConfig]? {
        guard let conv = selectedConversation, !conv.activeModelChoices.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        var resolved: [ProviderConfig] = []
        for choice in conv.activeModelChoices {
            guard var p = byID[choice.providerID], p.enabled else { continue }
            p.model = choice.model
            resolved.append(p)
        }
        return Array(resolved.prefix(maxCount))
    }

    // MARK: - Active provider 选择

    /// 设置 Direct 模式的 (provider, model)。没有当前会话会自动开一个。
    func setDirectChoice(providerID: UUID, model: String) {
        if selectedConversationID == nil { newConversation(mode: .direct) }
        guard let convID = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        let choice = ProviderModelChoice(providerID: providerID, model: model)
        conversations[idx].activeModelChoices = [choice]
        conversations[idx].activeProviderIDs = [providerID]
        ConversationStore.save(conversations[idx])
    }

    /// 切换 Compare 模式里某个 (provider, model) 的选中;最多保留 2 个,超过淘汰最早。
    func toggleCompareChoice(providerID: UUID, model: String) {
        if selectedConversationID == nil { newConversation(mode: .compare) }
        guard let convID = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        let choice = ProviderModelChoice(providerID: providerID, model: model)
        var list = conversations[idx].activeModelChoices
        if let pos = list.firstIndex(of: choice) {
            list.remove(at: pos)
        } else {
            list.append(choice)
            if list.count > 2 { list.removeFirst(list.count - 2) }
        }
        conversations[idx].activeModelChoices = list
        conversations[idx].activeProviderIDs = list.map(\.providerID)
        ConversationStore.save(conversations[idx])
    }

    /// 当前会话被显式选中的 (provider, model) 组合。
    var activeModelChoicesForCurrent: [ProviderModelChoice] {
        selectedConversation?.activeModelChoices ?? []
    }

    /// 兼容老的 setter,保留为方便 — 等同 setDirectChoice 使用 provider 的默认 model
    func setDirectProvider(_ id: UUID) {
        guard let p = providers.first(where: { $0.id == id }) else { return }
        setDirectChoice(providerID: id, model: p.model)
    }

    func toggleCompareProvider(_ id: UUID) {
        guard let p = providers.first(where: { $0.id == id }) else { return }
        toggleCompareChoice(providerID: id, model: p.model)
    }

    var activeProviderIDsForCurrent: [UUID] {
        selectedConversation?.activeProviderIDs ?? []
    }

    var canSend: Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return false }
        let (panel, _) = providersForCurrentSend()
        return !panel.isEmpty
    }

    // MARK: - 单家测试（Settings 的「测试」按钮调用）

    /// 拉取本地 Ollama 已安装的模型名(打 `/api/tags`)。失败/未运行返回空数组。
    /// baseURL 形如 `http://localhost:11434/v1` → tags 端点是同主机的 `/api/tags`。
    static func fetchOllamaModels(baseURL: String) async -> [String] {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("/v1") { base = String(base.dropLast(3)) }
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        guard let url = URL(string: base + "/api/tags") else { return [] }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }
        } catch { return [] }
    }

    static func testProvider(config: ProviderConfig, apiKey: String) async throws -> String {
        let client = ProviderRegistry.client(for: config.kind)
        let options = ChatOptions(systemPrompt: nil, temperature: nil, maxTokens: 32)
        var sample = ""
        for try await chunk in client.stream(prompt: "ping", options: options, config: config, apiKey: apiKey) {
            if case .text(let t) = chunk { sample += t }
            if sample.count >= 24 { break }
        }
        return sample.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
