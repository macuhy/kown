import Foundation
import Observation

@Observable
@MainActor
final class AppViewModel {
    // MARK: - 持久化的数据
    var providers: [ProviderConfig]
    var conversations: [Conversation]
    var webSearchConfig: WebSearchConfig

    // MARK: - UI 选择 / 输入
    var selectedConversationID: UUID?
    /// 没选会话时新建会话使用的默认模式
    var activeMode: ConversationMode = .council
    var prompt: String = ""
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

    // MARK: - 内部
    private static let systemPromptKey = "kown.systemPrompt.v1"
    private static let webSearchToggleKey = "kown.webSearch.toggle.v1"
    private static let alwaysEnableWebSearchKey = "kown.webSearch.alwaysOn.v1"
    private static let debateRoundsKey = "kown.debate.rounds.v1"
    private var runningTask: Task<Void, Never>?
    private var summarizingTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Init

    init() {
        // 启动时异步清一次旧 log 文件(保留最近 14 天),后台 queue 跑,毫秒级
        ResponseLogger.rotateOldLogsIfNeeded()
        self.providers = ProviderConfigStore.load()
        self.conversations = ConversationStore.loadAll()
        self.webSearchConfig = WebSearchConfigStore.load()
        self.systemPrompt = UserDefaults.standard.string(forKey: Self.systemPromptKey) ?? ""
        let storedAlwaysOn = UserDefaults.standard.bool(forKey: Self.alwaysEnableWebSearchKey)
        self.alwaysEnableWebSearch = storedAlwaysOn
        // 启动时若"默认联网"开着,强制把 webSearch 状态拉成 on;否则恢复上次状态
        let storedToggle = UserDefaults.standard.bool(forKey: Self.webSearchToggleKey)
        self.webSearchEnabledForNextSend = storedAlwaysOn ? true : storedToggle
        let storedRounds = UserDefaults.standard.integer(forKey: Self.debateRoundsKey)
        self.debateRoundsForNextSend = storedRounds == 0 ? 2 : max(1, min(4, storedRounds))

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
        let conv = Conversation(mode: mode)
        conversations.insert(conv, at: 0)
        selectedConversationID = conv.id
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

    func selectConversation(_ id: UUID) {
        // 不打断后台运行的请求 — 它绑定的还是原会话 ID(send() 闭包里 captured),
        // 结束后会正确把 turn 写回 `conversations[原 idx]`。当前选中切换只影响 UI 显示。
        selectedConversationID = id
        applyAlwaysEnableWebSearchIfNeeded()
        if let conv = conversations.first(where: { $0.id == id }) {
            activeMode = conv.mode
        }
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

    func deleteConversation(_ id: UUID) {
        let title = conversations.first(where: { $0.id == id })?.title ?? ""
        conversations.removeAll { $0.id == id }
        ConversationStore.delete(id)
        ResponseLogger.deleteDirectory(title: title, conversationID: id.uuidString)
        if selectedConversationID == id {
            selectedConversationID = nil
            liveStates.removeAll()
            liveChairState = nil
            liveSummaryState = nil
            liveDebateRounds.removeAll()
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
        let f = try AttachmentLoader.loadFile(at: url)
        attachments.append(.file(f))
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

    func send() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let (panel, chair) = providersForCurrentSend()
        guard !panel.isEmpty else { return }

        // 没有当前会话就新建
        if selectedConversationID == nil {
            newConversation(mode: activeMode)
        }
        guard let convIdx = conversations.firstIndex(where: { $0.id == selectedConversationID }) else { return }

        runningTask?.cancel()
        isRunning = true
        runningConvID = conversations[convIdx].id

        // iOS:申请通知权限(首次)+ 拿后台 token + 启动无声音频保活(切到后台仍能跑网络)
        BackgroundCompanion.shared.ensureNotificationPermission()
        BackgroundAudioKeepalive.shared.start()
        BackgroundCompanion.shared.beginIfNeeded { [weak self] in
            // 系统给的后台时间到了 — 取消流并让 UI 显示"被系统挂起"
            guard let self else { return }
            for state in self.liveStates.values where self.isStreaming(state) {
                state.fail("iOS 后台时间已到,流被系统挂起 — 切回前台重发可继续")
            }
            self.liveChairState.map { if self.isStreaming($0) { $0.fail("已挂起") } }
            self.liveSummaryState.map { if self.isStreaming($0) { $0.fail("已挂起") } }
            self.runningTask?.cancel()
            self.runningTask = nil
            self.isRunning = false
            self.runningConvID = nil
            BackgroundAudioKeepalive.shared.stop()
        }

        // 把文件附件文本拼到 prompt 前面；图片走 options.images
        let fileBlocks = attachments.compactMap { att -> String? in
            if case .file(let f) = att {
                return "<attached file=\"\(f.name)\">\n\(f.content)\n</attached>"
            }
            return nil
        }
        let imagePayloads = attachments.compactMap { att -> Attachment.ImagePayload? in
            if case .image(let i) = att { return i }
            return nil
        }
        let composedPrompt: String
        if fileBlocks.isEmpty {
            composedPrompt = trimmed
        } else {
            composedPrompt = fileBlocks.joined(separator: "\n\n") + "\n\n" + trimmed
        }

        let promptSnapshot = composedPrompt
        // Workspace 上下文(若设置了 Working Folder):扫所有文件,打包成 XML 块,前置到 system prompt。
        // Model 看到后可以在响应里输出 ```kown:write 块,我们 post-parse 自动应用。
        let workspaceURLForSend = currentWorkspaceURL
        let workspaceContext: String? = workspaceURLForSend.flatMap {
            WorkspaceManager.buildContext(workspaceURL: $0)
        }
        let sysSnapshot: String = {
            let base = systemPrompt
            guard let ws = workspaceContext else { return base }
            if base.isEmpty { return ws }
            return ws + "\n\n" + base
        }()
        let roundDate = Date()
        let roundID = String(UUID().uuidString.prefix(8))
        let imageSnapshot = imagePayloads
        // 上下文摘要 + 最近原文多轮:摘要进 system prompt;原文进真正的 messages[user/assistant]
        let contextSummarySnapshot = ConversationSummarizer.summaryForNextSend(conversations[convIdx])
        let priorTurnsSnapshot = ConversationSummarizer.priorTurnsForReplay(conversations[convIdx])
        // 工具调用 session(用户开 🌐 + Firecrawl 已配置时才非 nil)
        let toolSessionSnapshot = WebSearchSession.makeIfReady(userToggle: webSearchEnabledForNextSend)
        let toolsSnapshot: [LLMTool] = ToolCatalog.enabledTools(forSession: toolSessionSnapshot)
        let modeSnapshot = currentMode
        let debateRoundsSnapshot = debateRoundsForNextSend

        // 初始化 live 状态
        liveStates.removeAll()
        liveChairState = nil
        liveSummaryState = nil
        liveDebateRounds.removeAll()
        liveTurnPrompt = promptSnapshot
        for cfg in panel {
            let s = ResponseState(id: cfg.id)
            s.reset()
            liveStates[cfg.id] = s
        }
        if let chair {
            let s = ResponseState(id: chair.id)
            // Chair 先空着,等 panel 完成再 reset
            liveChairState = s
        }
        // Summary 只在 Council 模式跑;一并预创建占位 state
        let summarySnapshot = (modeSnapshot == .council) ? summaryProvider : nil
        if let s = summarySnapshot {
            let st = ResponseState(id: s.id)
            liveSummaryState = st
        }

        // 清空 prompt 输入框 + 附件(🌐 状态保留,跨发送/跨重启持久化)
        prompt = ""
        attachments = []

        // 如果会话标题还是默认的，用首问截断作标题
        if conversations[convIdx].title == "New Conversation" || conversations[convIdx].title.isEmpty {
            conversations[convIdx].title = String(promptSnapshot.prefix(30))
        }

        let convID = conversations[convIdx].id

        runningTask = Task { [weak self] in
            guard let self else { return }

            var responses: [String: String] = [:]
            var errors: [String: String] = [:]
            var snapshot: [String: ProviderConfig] = [:]
            for cfg in panel {
                snapshot[cfg.id.uuidString] = cfg
            }
            if let chair {
                snapshot[chair.id.uuidString] = chair
            }
            let panelOrder = panel.map { $0.id.uuidString }

            let convTitleSnapshot = conversations[convIdx].title
            let convIDString = convID.uuidString
            let modeAtSend = modeSnapshot

            // 1) 跑 panel。Debate 模式跑 N 轮(用户配置,1-4);其他模式只跑一轮。
            //    N=1 仅立论;N>=2 立论 + (N-1) 轮反驳/修正。
            //    panel<=1 时反驳轮没有意义,自动降级为 1 轮。
            var debateRounds: [DebateRound]? = nil
            if modeAtSend == .debate {
                let totalRounds = panel.count > 1
                    ? max(1, min(4, debateRoundsSnapshot))
                    : 1
                var rounds: [DebateRound] = []

                roundLoop: for roundIndex in 1...totalRounds {
                    if Task.isCancelled { break }
                    if roundIndex > 1 {
                        // 前一轮全部失败/空时,后续轮无意义,提前停。
                        let hasContent = rounds.last?.responses.values.contains(where: {
                            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }) ?? false
                        if !hasContent { break roundLoop }
                    }

                    let title = Self.debateRoundTitle(round: roundIndex, total: totalRounds)
                    let prompts = Dictionary(uniqueKeysWithValues: panel.map { cfg -> (UUID, String) in
                        let p: String
                        if roundIndex == 1 {
                            p = Self.buildDebateOpeningPrompt(
                                originalPrompt: promptSnapshot,
                                panel: panel,
                                speaker: cfg,
                                totalRounds: totalRounds
                            )
                        } else {
                            p = Self.buildDebateRebuttalPrompt(
                                originalPrompt: promptSnapshot,
                                panel: panel,
                                completedRounds: rounds,
                                speaker: cfg,
                                totalRounds: totalRounds
                            )
                        }
                        return (cfg.id, p)
                    })

                    let result = await self.runPanelRound(
                        panel: panel,
                        prompts: prompts,
                        defaultPrompt: promptSnapshot,
                        systemPrompt: sysSnapshot,
                        roundDate: roundDate,
                        roundID: "\(roundID)-debate-r\(roundIndex)",
                        images: imageSnapshot,
                        contextSummary: contextSummarySnapshot,
                        priorTurns: priorTurnsSnapshot,
                        tools: toolsSnapshot,
                        toolSession: toolSessionSnapshot,
                        conversationTitle: convTitleSnapshot,
                        conversationID: convIDString
                    )
                    responses = result.responses
                    errors = result.errors
                    let round = DebateRound(
                        index: roundIndex,
                        title: title,
                        responses: result.responses,
                        errors: result.errors,
                        panelOrder: panelOrder
                    )
                    rounds.append(round)
                    self.liveDebateRounds = rounds
                }

                debateRounds = rounds
            } else {
                let panelResult = await self.runPanelRound(
                    panel: panel,
                    prompts: [:],
                    defaultPrompt: promptSnapshot,
                    systemPrompt: sysSnapshot,
                    roundDate: roundDate,
                    roundID: roundID,
                    images: imageSnapshot,
                    contextSummary: contextSummarySnapshot,
                    priorTurns: priorTurnsSnapshot,
                    tools: toolsSnapshot,
                    toolSession: toolSessionSnapshot,
                    conversationTitle: convTitleSnapshot,
                    conversationID: convIDString
                )
                responses = panelResult.responses
                errors = panelResult.errors
            }

            // 2) 如果有 Chair,跑综合 / 裁判 / 主持总结
            var chairSummary: String? = nil
            var chairError: String? = nil
            if let chair, modeAtSend == .council || modeAtSend == .compare || modeAtSend == .debate {
                let nonEmpty = responses.filter { !$0.value.isEmpty }
                if !nonEmpty.isEmpty {
                    self.liveStates.removeAll()
                    self.liveChairState?.reset()
                    let synthesisPrompt: String
                    switch modeAtSend {
                    case .compare:
                        synthesisPrompt = Self.buildJudgePrompt(
                            originalPrompt: promptSnapshot,
                            panel: panel, responses: responses, errors: errors
                        )
                    case .debate:
                        synthesisPrompt = Self.buildDebateModeratorPrompt(
                            originalPrompt: promptSnapshot,
                            panel: panel,
                            rounds: debateRounds ?? [],
                            finalResponses: responses,
                            finalErrors: errors
                        )
                    default:
                        synthesisPrompt = Self.buildChairPrompt(
                            originalPrompt: promptSnapshot,
                            panel: panel, responses: responses, errors: errors
                        )
                    }
                    let result = await self.runOne(
                        config: chair, prompt: synthesisPrompt,
                        systemPrompt: sysSnapshot,
                        roundDate: roundDate, roundID: roundID + "-chair",
                        target: .chair,
                        images: [],
                        contextSummary: contextSummarySnapshot,
                        priorTurns: priorTurnsSnapshot,
                        tools: [],
                        toolSession: nil,
                        conversationTitle: convTitleSnapshot,
                        conversationID: convIDString
                    )
                    chairSummary = result.1
                    chairError = result.2
                }
            }

            // 2.5) Summary(总结员) — 只在 Council 模式跑;跑在 chair 之后,可以看到 chair 的产出
            var summaryText: String? = nil
            var summaryError: String? = nil
            if let summary = summarySnapshot, modeAtSend == .council {
                let nonEmpty = responses.filter { !$0.value.isEmpty }
                if !nonEmpty.isEmpty {
                    self.liveSummaryState?.reset()
                    let aggPrompt = Self.buildSummaryPrompt(
                        originalPrompt: promptSnapshot,
                        panel: panel, responses: responses, errors: errors,
                        chairSummary: chairSummary
                    )
                    let result = await self.runOne(
                        config: summary, prompt: aggPrompt,
                        systemPrompt: sysSnapshot,
                        roundDate: roundDate, roundID: roundID + "-summary",
                        target: .summary,
                        images: [],
                        contextSummary: contextSummarySnapshot,
                        priorTurns: priorTurnsSnapshot,
                        tools: [],
                        toolSession: nil,
                        conversationTitle: convTitleSnapshot,
                        conversationID: convIDString
                    )
                    summaryText = result.1
                    summaryError = result.2
                }
            }

            // 2.7) Workspace 写文件:扫所有 provider 响应(包括 chair / summary 文本)里
            //      的 ```kown:write 代码块,逐个 apply 到 workspace 文件夹。
            //      默认 auto-apply,UI 里展示结果。仅当 send 时 workspaceURLForSend 存在才跑。
            var appliedWrites: [AppliedWrite]? = nil
            if let workspaceURL = workspaceURLForSend {
                var allTexts: [String] = []
                allTexts.append(contentsOf: responses.values)
                if let cs = chairSummary { allTexts.append(cs) }
                if let st = summaryText { allTexts.append(st) }
                var pendings: [PendingWrite] = []
                for t in allTexts {
                    pendings.append(contentsOf: WorkspaceManager.parseProposedWrites(t))
                }
                // 去重(同路径重复时取最后一个 — model 最后输出的认为是最终版本)
                var seen: [String: PendingWrite] = [:]
                for p in pendings { seen[p.relativePath] = p }
                let applied = seen.values.map { WorkspaceManager.apply($0, workspaceURL: workspaceURL) }
                if !applied.isEmpty {
                    appliedWrites = applied
                } else {
                    // workspace 设置了但 model 没输出 kown:write 块 —
                    // 检查响应里是否含其他 fenced code(说明 model 想写但用错了格式),
                    // 把这个情况做成一条 .skipped 提示,让 UI 显示出来
                    let hasOtherCodeFence = allTexts.contains { $0.contains("```") }
                    if hasOtherCodeFence {
                        appliedWrites = [AppliedWrite(
                            relativePath: "(无)",
                            action: .skipped,
                            success: false,
                            error: "Model 输出了代码块,但都不是 kown:write 格式。提醒它用 kown:write 代码块改文件,或者直接复制内容到目标文件。",
                            newContent: ""
                        )]
                    }
                }
            }

            // 3) 落盘
            if let idx = self.conversations.firstIndex(where: { $0.id == convID }) {
                if let summary = summarySnapshot {
                    snapshot[summary.id.uuidString] = summary
                }
                let turn = Turn(
                    timestamp: roundDate,
                    prompt: promptSnapshot,
                    systemPrompt: sysSnapshot,
                    responses: responses,
                    errors: errors,
                    chairProviderID: chair?.id.uuidString,
                    chairSummary: chairSummary,
                    chairError: chairError,
                    summaryProviderID: summarySnapshot?.id.uuidString,
                    summaryText: summaryText,
                    summaryError: summaryError,
                    providerSnapshot: snapshot,
                    panelOrder: panelOrder,
                    debateRounds: debateRounds,
                    appliedWrites: appliedWrites
                )
                self.conversations[idx].turns.append(turn)
                self.conversations[idx].updatedAt = Date()
                ConversationStore.save(self.conversations[idx])
                // 把会话顶到列表最前
                let moved = self.conversations.remove(at: idx)
                self.conversations.insert(moved, at: 0)

                // 触发增量摘要(后台跑,不阻塞 UI)
                self.scheduleSummarization(for: convID)
            }

            // 完成 — 停无声音频 + 释放后台 token + 后台时通知用户
            BackgroundAudioKeepalive.shared.stop()
            BackgroundCompanion.shared.end()
            let notifyBody = Self.notificationPreview(
                summaryText: summaryText,
                chairSummary: chairSummary,
                responses: responses,
                panelOrder: panelOrder
            )
            BackgroundCompanion.shared.notifyIfBackgrounded(
                title: "Kown 回答已完成",
                body: notifyBody
            )

            self.liveStates.removeAll()
            self.liveChairState = nil
            self.liveSummaryState = nil
            self.liveDebateRounds.removeAll()
            self.liveTurnPrompt = nil
            self.isRunning = false
            self.runningConvID = nil
        }
    }

    // MARK: - 摘要调度

    private func scheduleSummarization(for convID: UUID) {
        if let running = summarizingTasks[convID], !running.isCancelled { return }
        guard let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        let convSnapshot = conversations[idx]
        // 未总结 turn 累计到阈值才跑(避免每轮都开一次摘要 LLM)
        let remaining = convSnapshot.turns.count - convSnapshot.summarizedThroughTurnCount
        guard remaining >= ConversationSummarizer.triggerThreshold else { return }

        let chair = chairProvider
        let firstEnabled = providers.first(where: { $0.enabled && !$0.kind.isCLI })
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.summarizingTasks.removeValue(forKey: convID) }
            guard let result = await ConversationSummarizer.updatedSummary(
                for: convSnapshot, chair: chair, firstEnabled: firstEnabled
            ) else { return }
            guard let liveIdx = self.conversations.firstIndex(where: { $0.id == convID }) else { return }
            // 只前进 — 防止竞态把新摘要覆盖回旧的
            if result.summarizedThroughTurnCount > self.conversations[liveIdx].summarizedThroughTurnCount {
                self.conversations[liveIdx].contextSummary = result.summary
                self.conversations[liveIdx].summarizedThroughTurnCount = result.summarizedThroughTurnCount
                ConversationStore.save(self.conversations[liveIdx])
            }
        }
        summarizingTasks[convID] = task
    }

    func cancel() {
        runningTask?.cancel()
        runningTask = nil
        isRunning = false
        runningConvID = nil
        BackgroundAudioKeepalive.shared.stop()
        BackgroundCompanion.shared.end()
        for state in liveStates.values where isStreaming(state) {
            state.fail("已取消")
        }
        if let summary = liveSummaryState, isStreaming(summary) {
            summary.fail("已取消")
        }
        if let chair = liveChairState, isStreaming(chair) {
            chair.fail("已取消")
        }
        liveDebateRounds.removeAll()
    }

    private func isStreaming(_ state: ResponseState) -> Bool {
        if case .streaming = state.phase { return true }
        return false
    }

    // MARK: - 单家失败重试(超时恢复)

    /// 正在重试的 (turn, provider[, round]) 组合,UI 据此显示加载态。
    /// 注:同一 provider 在不同 turn / round 可同时重试,所以 key 是复合的。
    var retryingTickets: Set<String> = []

    private static func retryTicket(turnID: UUID, configID: UUID, roundIndex: Int?) -> String {
        if let r = roundIndex { return "\(turnID.uuidString):\(configID.uuidString):r\(r)" }
        return "\(turnID.uuidString):\(configID.uuidString)"
    }

    func isRetrying(turnID: UUID, configID: UUID, roundIndex: Int? = nil) -> Bool {
        retryingTickets.contains(Self.retryTicket(turnID: turnID, configID: configID, roundIndex: roundIndex))
    }

    /// 重跑某个 turn 里一家失败的 provider。roundIndex 仅 Debate 模式使用 — 指定要重跑哪一轮。
    /// 重跑成功后原地 patch turn.responses / turn.errors(或对应 round 的),并落盘。
    /// 主发送进行中时(isRunning)拒绝重试,避免状态机交叉。
    func retryProvider(turnID: UUID, configID: UUID, roundIndex: Int? = nil) {
        guard !isRunning else { return }
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        guard let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }

        let ticket = Self.retryTicket(turnID: turnID, configID: configID, roundIndex: roundIndex)
        guard !retryingTickets.contains(ticket) else { return }

        let turn = conversations[convIdx].turns[turnIdx]
        let key = configID.uuidString
        guard let cfg = turn.providerSnapshot[key] else { return }
        let mode = conversations[convIdx].mode
        let panel = turn.orderedPanelConfigs

        // 用 turn 之前的会话状态重建上下文,确保重试不会拿到"未来"的 turn。
        var historicalConv = conversations[convIdx]
        historicalConv.turns = Array(conversations[convIdx].turns[..<turnIdx])
        let contextSummary = ConversationSummarizer.summaryForNextSend(historicalConv)
        let priorTurns = ConversationSummarizer.priorTurnsForReplay(historicalConv)

        // 组 prompt
        let prompt: String
        switch mode {
        case .direct, .council, .compare:
            prompt = turn.prompt
        case .debate:
            let rounds = turn.debateRounds ?? []
            let targetRound = roundIndex ?? rounds.last?.index ?? 1
            let total = max(1, min(4, rounds.count == 0 ? 2 : rounds.count))
            if targetRound <= 1 {
                prompt = Self.buildDebateOpeningPrompt(
                    originalPrompt: turn.prompt,
                    panel: panel,
                    speaker: cfg,
                    totalRounds: total
                )
            } else {
                let priorRounds = rounds.filter { $0.index < targetRound }
                prompt = Self.buildDebateRebuttalPrompt(
                    originalPrompt: turn.prompt,
                    panel: panel,
                    completedRounds: priorRounds,
                    speaker: cfg,
                    totalRounds: total
                )
            }
        }

        let sysPrompt = turn.systemPrompt
        let convTitle = conversations[convIdx].title
        let convIDString = convID.uuidString
        let roundDate = Date()
        let roundID = "retry-\(String(UUID().uuidString.prefix(8)))"

        retryingTickets.insert(ticket)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.retryingTickets.remove(ticket) }

            var collected = ""
            var failure: String? = nil
            do {
                let apiKey = cfg.kind.isCLI ? "" : (try KeychainStore.load(id: cfg.id))
                let client = ProviderRegistry.client(for: cfg.kind)
                var options = self.optionsFor(config: cfg, systemPromptOverride: sysPrompt)
                options.contextSummary = contextSummary
                options.priorTurns = priorTurns
                // 注:retry 不带 images / tools — 失败的原 turn 已经过初次尝试,简化为干跑文本。
                // 用户若需要带图重跑,可以直接重发整 turn。
                for try await chunk in client.stream(prompt: prompt, options: options, config: cfg, apiKey: apiKey) {
                    switch chunk {
                    case .text(let t): collected += t
                    case .toolEvent: break
                    case .usage(let input, let output):
                        UsageStore.shared.record(
                            providerKind: cfg.kind,
                            model: cfg.model,
                            inputTokens: input,
                            outputTokens: output
                        )
                    }
                }
            } catch is CancellationError {
                failure = "已取消"
            } catch {
                failure = error.localizedDescription
            }

            ResponseLogger.writeAsync(.init(
                roundID: roundID,
                timestamp: roundDate,
                providerName: cfg.displayName,
                providerKind: cfg.kind.rawValue,
                baseURL: cfg.baseURL,
                model: cfg.model,
                prompt: prompt,
                systemPrompt: sysPrompt,
                response: collected,
                elapsedSeconds: nil,
                error: failure,
                conversationTitle: convTitle,
                conversationID: convIDString
            ))

            // 重新定位 turn(过程中会话可能被其他操作变更)
            guard let liveConvIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  let liveTurnIdx = self.conversations[liveConvIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }

            if mode == .debate, let rounds = self.conversations[liveConvIdx].turns[liveTurnIdx].debateRounds {
                let targetRound = roundIndex ?? rounds.last?.index ?? 1
                if let rIdx = rounds.firstIndex(where: { $0.index == targetRound }) {
                    if let failure {
                        self.conversations[liveConvIdx].turns[liveTurnIdx].debateRounds?[rIdx].errors[key] = failure
                        self.conversations[liveConvIdx].turns[liveTurnIdx].debateRounds?[rIdx].responses[key] = collected
                    } else {
                        self.conversations[liveConvIdx].turns[liveTurnIdx].debateRounds?[rIdx].errors.removeValue(forKey: key)
                        self.conversations[liveConvIdx].turns[liveTurnIdx].debateRounds?[rIdx].responses[key] = collected
                    }
                    // turn 顶层 responses/errors 缓存的是最后一轮 — 若 retry 的就是最后一轮,同步刷新
                    let isLastRound = (rounds.max(by: { $0.index < $1.index })?.index ?? 0) == targetRound
                    if isLastRound {
                        if let failure {
                            self.conversations[liveConvIdx].turns[liveTurnIdx].errors[key] = failure
                            self.conversations[liveConvIdx].turns[liveTurnIdx].responses[key] = collected
                        } else {
                            self.conversations[liveConvIdx].turns[liveTurnIdx].errors.removeValue(forKey: key)
                            self.conversations[liveConvIdx].turns[liveTurnIdx].responses[key] = collected
                        }
                    }
                }
            } else {
                if let failure {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].errors[key] = failure
                    self.conversations[liveConvIdx].turns[liveTurnIdx].responses[key] = collected
                } else {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].errors.removeValue(forKey: key)
                    self.conversations[liveConvIdx].turns[liveTurnIdx].responses[key] = collected
                }
            }

            self.conversations[liveConvIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[liveConvIdx])
        }
    }

    enum ChairRetryTarget: String {
        case chair      // Council/Debate/Compare 的综合/裁判/主持(turn.chairSummary)
        case summary    // Council 的总结员(turn.summaryText)
    }

    private static func chairRetryTicket(turnID: UUID, target: ChairRetryTarget) -> String {
        "chair:\(turnID.uuidString):\(target.rawValue)"
    }

    func isRetryingChair(turnID: UUID, target: ChairRetryTarget = .chair) -> Bool {
        retryingTickets.contains(Self.chairRetryTicket(turnID: turnID, target: target))
    }

    /// 重跑 turn 的 Chair / Moderator / Judge / Summary。重跑前会拿现 turn 的 panel 答复重建 prompt,
    /// 因此即使 panel 中有一家失败,只要其他家有内容,chair 重试就能继续。
    func retryChair(turnID: UUID, target: ChairRetryTarget = .chair) {
        guard !isRunning else { return }
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        guard let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }

        let ticket = Self.chairRetryTicket(turnID: turnID, target: target)
        guard !retryingTickets.contains(ticket) else { return }

        let turn = conversations[convIdx].turns[turnIdx]
        let mode = conversations[convIdx].mode

        let targetCfg: ProviderConfig?
        switch target {
        case .chair:
            targetCfg = turn.chairConfig
        case .summary:
            targetCfg = turn.summaryConfig
        }
        guard let cfg = targetCfg else { return }

        let panel = turn.orderedPanelConfigs

        // 用 turn 之前的会话状态重建上下文
        var historicalConv = conversations[convIdx]
        historicalConv.turns = Array(conversations[convIdx].turns[..<turnIdx])
        let contextSummary = ConversationSummarizer.summaryForNextSend(historicalConv)
        let priorTurns = ConversationSummarizer.priorTurnsForReplay(historicalConv)

        // 组 prompt — 与 send() 里的逻辑保持一致
        let prompt: String
        switch target {
        case .chair:
            switch mode {
            case .compare:
                prompt = Self.buildJudgePrompt(
                    originalPrompt: turn.prompt,
                    panel: panel,
                    responses: turn.responses,
                    errors: turn.errors
                )
            case .debate:
                prompt = Self.buildDebateModeratorPrompt(
                    originalPrompt: turn.prompt,
                    panel: panel,
                    rounds: turn.debateRounds ?? [],
                    finalResponses: turn.responses,
                    finalErrors: turn.errors
                )
            default:
                prompt = Self.buildChairPrompt(
                    originalPrompt: turn.prompt,
                    panel: panel,
                    responses: turn.responses,
                    errors: turn.errors
                )
            }
        case .summary:
            prompt = Self.buildSummaryPrompt(
                originalPrompt: turn.prompt,
                panel: panel,
                responses: turn.responses,
                errors: turn.errors,
                chairSummary: turn.chairSummary
            )
        }

        let sysPrompt = turn.systemPrompt
        let convTitle = conversations[convIdx].title
        let convIDString = convID.uuidString
        let roundDate = Date()
        let roundID = "retry-chair-\(String(UUID().uuidString.prefix(8)))"

        retryingTickets.insert(ticket)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.retryingTickets.remove(ticket) }

            var collected = ""
            var failure: String? = nil
            do {
                let apiKey = cfg.kind.isCLI ? "" : (try KeychainStore.load(id: cfg.id))
                let client = ProviderRegistry.client(for: cfg.kind)
                var options = self.optionsFor(config: cfg, systemPromptOverride: sysPrompt)
                options.contextSummary = contextSummary
                options.priorTurns = priorTurns
                for try await chunk in client.stream(prompt: prompt, options: options, config: cfg, apiKey: apiKey) {
                    switch chunk {
                    case .text(let t): collected += t
                    case .toolEvent: break
                    case .usage(let input, let output):
                        UsageStore.shared.record(
                            providerKind: cfg.kind,
                            model: cfg.model,
                            inputTokens: input,
                            outputTokens: output
                        )
                    }
                }
            } catch is CancellationError {
                failure = "已取消"
            } catch {
                failure = error.localizedDescription
            }

            ResponseLogger.writeAsync(.init(
                roundID: roundID,
                timestamp: roundDate,
                providerName: cfg.displayName,
                providerKind: cfg.kind.rawValue,
                baseURL: cfg.baseURL,
                model: cfg.model,
                prompt: prompt,
                systemPrompt: sysPrompt,
                response: collected,
                elapsedSeconds: nil,
                error: failure,
                conversationTitle: convTitle,
                conversationID: convIDString
            ))

            guard let liveConvIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  let liveTurnIdx = self.conversations[liveConvIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }

            switch target {
            case .chair:
                if let failure {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].chairError = failure
                    self.conversations[liveConvIdx].turns[liveTurnIdx].chairSummary = collected.isEmpty ? nil : collected
                } else {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].chairError = nil
                    self.conversations[liveConvIdx].turns[liveTurnIdx].chairSummary = collected
                }
            case .summary:
                if let failure {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].summaryError = failure
                    self.conversations[liveConvIdx].turns[liveTurnIdx].summaryText = collected.isEmpty ? nil : collected
                } else {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].summaryError = nil
                    self.conversations[liveConvIdx].turns[liveTurnIdx].summaryText = collected
                }
            }

            self.conversations[liveConvIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[liveConvIdx])
        }
    }

    private func startLivePanelRound(_ panel: [ProviderConfig]) {
        liveStates.removeAll()
        for cfg in panel {
            let state = ResponseState(id: cfg.id)
            state.reset()
            liveStates[cfg.id] = state
        }
    }

    private func runPanelRound(
        panel: [ProviderConfig],
        prompts: [UUID: String],
        defaultPrompt: String,
        systemPrompt: String,
        roundDate: Date,
        roundID: String,
        images: [Attachment.ImagePayload],
        contextSummary: String?,
        priorTurns: [PriorTurn],
        tools: [LLMTool],
        toolSession: WebSearchSession?,
        conversationTitle: String,
        conversationID: String
    ) async -> (responses: [String: String], errors: [String: String]) {
        startLivePanelRound(panel)

        var responses: [String: String] = [:]
        var errors: [String: String] = [:]
        await withTaskGroup(of: (UUID, String, String?).self) { group in
            for cfg in panel {
                let promptForProvider = prompts[cfg.id] ?? defaultPrompt
                let imagesForProvider = cfg.kind == .openAICompatible ? images : []
                group.addTask { [weak self] in
                    guard let self else { return (cfg.id, "", "释放") }
                    return await self.runOne(
                        config: cfg,
                        prompt: promptForProvider,
                        systemPrompt: systemPrompt,
                        roundDate: roundDate,
                        roundID: roundID,
                        target: .panel,
                        images: imagesForProvider,
                        contextSummary: contextSummary,
                        priorTurns: priorTurns,
                        tools: tools,
                        toolSession: toolSession,
                        conversationTitle: conversationTitle,
                        conversationID: conversationID
                    )
                }
            }
            for await (id, text, err) in group {
                if let err {
                    errors[id.uuidString] = err
                }
                responses[id.uuidString] = text
            }
        }
        return (responses, errors)
    }

    private enum RunTarget { case panel, chair, summary }

    /// 跑一个 provider 的流式；返回 (id, finalText, error?)。
    private func runOne(
        config: ProviderConfig, prompt: String,
        systemPrompt: String, roundDate: Date, roundID: String,
        target: RunTarget,
        images: [Attachment.ImagePayload],
        contextSummary: String?,
        priorTurns: [PriorTurn],
        tools: [LLMTool],
        toolSession: WebSearchSession?,
        conversationTitle: String,
        conversationID: String
    ) async -> (UUID, String, String?) {
        let state: ResponseState
        switch target {
        case .panel:
            guard let s = liveStates[config.id] else { return (config.id, "", "状态丢失") }
            state = s
        case .chair:
            guard let s = liveChairState else { return (config.id, "", "状态丢失") }
            state = s
        case .summary:
            guard let s = liveSummaryState else { return (config.id, "", "状态丢失") }
            state = s
        }
        var failure: String? = nil
        do {
            let key = config.kind.isCLI ? "" : (try KeychainStore.load(id: config.id))
            let client = ProviderRegistry.client(for: config.kind)
            var options = optionsFor(config: config, systemPromptOverride: systemPrompt)
            options.images = images
            options.contextSummary = contextSummary
            options.priorTurns = priorTurns
            options.tools = tools
            options.toolSession = toolSession
            for try await chunk in client.stream(prompt: prompt, options: options, config: config, apiKey: key) {
                if Task.isCancelled { break }
                switch chunk {
                case .text(let t):       state.append(t)
                case .toolEvent(let e):  state.logEvent(e)
                case .usage(let input, let output):
                    // 记一笔到 UsageStore(按天分桶,本地持久化)
                    UsageStore.shared.record(
                        providerKind: config.kind,
                        model: config.model,
                        inputTokens: input,
                        outputTokens: output
                    )
                }
            }
            if Task.isCancelled {
                state.fail("已取消")
                failure = "已取消"
            } else {
                state.finish()
            }
        } catch is CancellationError {
            state.fail("已取消")
            failure = "已取消"
        } catch {
            state.fail(error.localizedDescription)
            failure = error.localizedDescription
        }

        let entry = ResponseLogger.Entry(
            roundID: roundID,
            timestamp: roundDate,
            providerName: config.displayName,
            providerKind: config.kind.rawValue,
            baseURL: config.baseURL,
            model: config.model,
            prompt: prompt,
            systemPrompt: systemPrompt,
            response: state.text,
            elapsedSeconds: state.elapsedSeconds,
            error: failure,
            conversationTitle: conversationTitle,
            conversationID: conversationID
        )
        ResponseLogger.writeAsync(entry)

        return (config.id, state.text, failure)
    }

    private func optionsFor(config: ProviderConfig, systemPromptOverride: String) -> ChatOptions {
        let sys = systemPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatOptions(
            systemPrompt: sys.isEmpty ? nil : sys,
            temperature: config.temperature,
            maxTokens: config.maxTokens
        )
    }

    /// 生成本地通知 body 的预览 — 优先 summary,其次 chair,再次第一个非空 panel 答复。
    private static func notificationPreview(
        summaryText: String?,
        chairSummary: String?,
        responses: [String: String],
        panelOrder: [String]
    ) -> String {
        let candidates: [String?] = [
            summaryText,
            chairSummary,
            panelOrder.compactMap { responses[$0] }.first(where: { !$0.isEmpty })
        ]
        let pick = candidates.compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "已完成,点开查看"
        return String(pick.prefix(120))
    }

    // MARK: - Debate prompt

    private static func buildDebateOpeningPrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        speaker: ProviderConfig,
        totalRounds: Int
    ) -> String {
        var lines: [String] = []
        lines.append("你正在参加一场多模型辩论(共 \(totalRounds) 轮)。你的身份是: \(providerLabel(speaker))。")
        lines.append("其他参与者:")
        for cfg in panel where cfg.id != speaker.id {
            lines.append("- \(providerLabel(cfg))")
        }
        lines.append("")
        lines.append("【辩题 / 用户问题】")
        lines.append(originalPrompt)
        lines.append("")
        lines.append("【第 1 轮:立论】")
        lines.append("请给出你的初始立场,但不要为了反对而反对。目标是逼近正确答案。")
        lines.append("要求:")
        lines.append("1) 先用一句话给结论或倾向。")
        lines.append("2) 给出 3-5 条关键理由 / 证据 / 假设。")
        lines.append("3) 指出你认为最容易被其他模型挑战的薄弱点。")
        lines.append("4) 如果需要其他参与者回应,列出 1-2 个具体追问。")
        lines.append("中文输出,控制在 250-450 字。")
        return lines.joined(separator: "\n")
    }

    /// Debate 模式下每一轮的标题。第 1 轮固定"立论";最后一轮叫"收敛/最终立场";中间叫"反驳 / 修正"。
    private static func debateRoundTitle(round: Int, total: Int) -> String {
        if round == 1 { return "立论" }
        if round == total { return total >= 3 ? "收敛 / 最终立场" : "反驳 / 修正" }
        return "反驳 / 修正 #\(round - 1)"
    }

    private static func buildDebateRebuttalPrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        completedRounds: [DebateRound],
        speaker: ProviderConfig,
        totalRounds: Int
    ) -> String {
        let nextRound = completedRounds.count + 1
        let isFinal = nextRound == totalRounds
        var lines: [String] = []
        lines.append("你正在参加一场多模型辩论(共 \(totalRounds) 轮,当前是第 \(nextRound) 轮)。你的身份是: \(providerLabel(speaker))。")
        lines.append("")
        lines.append("【辩题 / 用户问题】")
        lines.append(originalPrompt)
        lines.append("")
        // 自家立论用一句话摘要带过,只把其他模型的完整发言喂回去 —
        // 避免 self-consistency 把 speaker 锚定在自己的旧立场上。
        let speakerKey = speaker.id.uuidString
        if let mySummary = ownSummary(for: speakerKey, in: completedRounds) {
            lines.append("【你上一轮的核心立场(仅供参考,可被推翻)】")
            lines.append(mySummary)
            lines.append("")
        }
        lines.append("【其他模型的发言】")
        lines.append(renderDebateRounds(
            completedRounds,
            panel: panel,
            maxPerAnswer: 1200,
            excludeSpeakerKey: speakerKey
        ))
        lines.append("")
        if isFinal && totalRounds >= 3 {
            lines.append("【第 \(nextRound) 轮:收敛 / 最终立场】")
            lines.append("这是最后一轮,请尽量收敛分歧、给出你的最终结论。")
            lines.append("要求:")
            lines.append("1) 简述本轮你最认同其他模型的 1-2 点(点名来源模型)。")
            lines.append("2) 指出仍未解决的 1-2 个真分歧,说明为什么没法在这一轮内解决。")
            lines.append("3) 给出你的最终结论,以及你对它的置信度(高/中/低)和适用边界。")
            lines.append("中文输出,控制在 250-450 字。")
        } else {
            lines.append("【第 \(nextRound) 轮:反驳 / 修正】")
            lines.append("请阅读其他模型的立论后发言。")
            lines.append("要求:")
            lines.append("1) 指出你同意的 1-2 点(点名来源模型)。")
            lines.append("2) 反驳或修正至少 1 个你认为有问题的观点,格式: @模型名: 你的 X 我不同意,因为 Y。")
            lines.append("3) 如果你的原立场需要改变,明确说明改变了什么、为什么;如果不改变,说明为什么。")
            lines.append("4) 最后给出你更新后的结论。")
            lines.append("中文输出,控制在 250-450 字。")
        }
        return lines.joined(separator: "\n")
    }

    /// 抽取某 speaker 在已完成轮次里最后一条非空发言的前 N 字,作为反驳轮的"自家立场摘要"。
    private static func ownSummary(for speakerKey: String, in rounds: [DebateRound]) -> String? {
        for round in rounds.sorted(by: { $0.index > $1.index }) {
            if let text = round.responses[speakerKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return shorten(text, max: 240)
            }
        }
        return nil
    }

    private static func buildDebateModeratorPrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        rounds: [DebateRound],
        finalResponses: [String: String],
        finalErrors: [String: String]
    ) -> String {
        var lines: [String] = []
        lines.append("你是这场多模型辩论的主持人兼裁判。请基于辩论全过程做最终归纳,不要再展开新的长篇论证。")
        lines.append("")
        lines.append("【辩题 / 用户问题】")
        lines.append(originalPrompt)
        lines.append("")
        if rounds.isEmpty {
            lines.append("【各模型最终发言】")
            for cfg in panel {
                let key = cfg.id.uuidString
                lines.append("=== \(providerLabel(cfg)) ===")
                if let err = finalErrors[key], !err.isEmpty {
                    lines.append("(调用失败:\(err))")
                } else {
                    lines.append(shorten(finalResponses[key] ?? "(空响应)", max: 1400))
                }
                lines.append("")
            }
        } else {
            lines.append("【辩论记录】")
            lines.append(renderDebateRounds(rounds, panel: panel, maxPerAnswer: 1400))
        }
        lines.append("")
        lines.append("请输出 Markdown,包含:")
        lines.append("**1. 共识**:各方最终基本同意的点(3-5 条)")
        lines.append("**2. 关键分歧**:仍未解决的争议,标注主要模型")
        lines.append("**3. 立场变迁**:对比首轮立论与最终发言,列出哪些模型修正了观点、改了什么、为什么(没有变化的也注明)")
        lines.append("**4. 最强论点**:你认为最有价值的 2-3 个论点及来源")
        lines.append("**5. 最终判断**:给用户一个可执行结论,并说明置信度/风险")
        lines.append("中文输出,控制在 400-750 字。")
        return lines.joined(separator: "\n")
    }

    private static func renderDebateRounds(
        _ rounds: [DebateRound],
        panel: [ProviderConfig],
        maxPerAnswer: Int,
        excludeSpeakerKey: String? = nil
    ) -> String {
        var lines: [String] = []
        let byID = Dictionary(uniqueKeysWithValues: panel.map { ($0.id.uuidString, $0) })
        for round in rounds.sorted(by: { $0.index < $1.index }) {
            lines.append("## 第 \(round.index) 轮: \(round.title)")
            let order = round.panelOrder.isEmpty ? panel.map { $0.id.uuidString } : round.panelOrder
            for key in order where key != excludeSpeakerKey {
                guard let cfg = byID[key] else { continue }
                lines.append("=== \(providerLabel(cfg)) ===")
                if let err = round.errors[key], !err.isEmpty {
                    lines.append("(调用失败:\(err))")
                } else {
                    lines.append(shorten(round.responses[key] ?? "(空响应)", max: maxPerAnswer))
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func providerLabel(_ cfg: ProviderConfig) -> String {
        "\(cfg.displayName) · \(cfg.model)"
    }

    private static func shorten(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max)) + "…"
    }

    // MARK: - Chair 合成 prompt

    private static func buildChairPrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        responses: [String: String],
        errors: [String: String]
    ) -> String {
        var lines: [String] = []
        lines.append("你是这个 council 的主席。其他模型针对同一个问题给出了各自答案，请综合判断。\n")
        lines.append("【问题】")
        lines.append(originalPrompt)
        lines.append("")
        lines.append("【各模型回答】")
        for cfg in panel {
            let key = cfg.id.uuidString
            let label = "\(cfg.displayName) · \(cfg.model)"
            if let err = errors[key], !err.isEmpty {
                lines.append("=== \(label) (调用失败：\(err)) ===")
                lines.append("")
            } else {
                let body = responses[key] ?? ""
                lines.append("=== \(label) ===")
                lines.append(body.isEmpty ? "(空响应)" : body)
                lines.append("")
            }
        }
        lines.append("请用 200-400 字回答：1) 共识与主要分歧；2) 你倾向的结论与理由。中文输出。")
        return lines.joined(separator: "\n")
    }

    /// Council 模式的"总结员" prompt — 中立汇总,不输出立场和倾向。
    /// 如果 chair 已经跑过,把 chair 结论也一并放进材料里(总结可能引用它,但不二次裁断)。
    private static func buildSummaryPrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        responses: [String: String],
        errors: [String: String],
        chairSummary: String?
    ) -> String {
        var lines: [String] = []
        lines.append("你是一个中立的总结员。任务:把以下各家 AI 对同一问题的回答**汇总**,不出立场、不裁断、不二次推理,只做信息提取与去重。")
        lines.append("")
        lines.append("【问题】")
        lines.append(originalPrompt)
        lines.append("")
        lines.append("【各模型回答】")
        for cfg in panel {
            let key = cfg.id.uuidString
            let label = "\(cfg.displayName) · \(cfg.model)"
            if let err = errors[key], !err.isEmpty {
                lines.append("=== \(label) (调用失败:\(err)) ===")
                lines.append("")
            } else {
                let body = responses[key] ?? ""
                lines.append("=== \(label) ===")
                lines.append(body.isEmpty ? "(空响应)" : body)
                lines.append("")
            }
        }
        if let chairSummary, !chairSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("【主席综合(可参考,但不要照搬观点)】")
            lines.append(chairSummary)
            lines.append("")
        }
        lines.append("请输出以下三块,Markdown 格式,总长度 250-450 字:")
        lines.append("")
        lines.append("**共识点**:各家都讲到的关键信息(bullet,3-6 条)")
        lines.append("")
        lines.append("**分歧/独家**:某一家提到、其他家没提到或不同意的点(bullet,标注是哪家)")
        lines.append("")
        lines.append("**事实/数字汇总**:涉及到的数字、日期、专有名词、引用链接等硬信息合并去重(bullet)")
        lines.append("")
        lines.append("不要写自己的判断、推荐、结论。中文输出。")
        return lines.joined(separator: "\n")
    }

    /// Compare 模式的"裁判" prompt — 让模型挑出胜者并说理由,不要综合两家。
    private static func buildJudgePrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        responses: [String: String],
        errors: [String: String]
    ) -> String {
        var lines: [String] = []
        lines.append("你是裁判。两个 AI 针对同一问题给了各自答复,请评判哪个更好,而不是综合两家。")
        lines.append("")
        lines.append("【问题】")
        lines.append(originalPrompt)
        lines.append("")
        lines.append("【两份回答】")
        for (i, cfg) in panel.enumerated() {
            let key = cfg.id.uuidString
            let mark = i == 0 ? "A" : "B"
            let label = "\(mark) — \(cfg.displayName) · \(cfg.model)"
            if let err = errors[key], !err.isEmpty {
                lines.append("=== \(label) (调用失败:\(err)) ===")
                lines.append("")
            } else {
                let body = responses[key] ?? ""
                lines.append("=== \(label) ===")
                lines.append(body.isEmpty ? "(空响应)" : body)
                lines.append("")
            }
        }
        lines.append("请在 200 字以内给出:")
        lines.append("1) 关键分歧点(1-2 条)")
        lines.append("2) 判决:A 更好 / B 更好 / 各有千秋 / 都不行,任选其一")
        lines.append("3) 2-3 句理由,具体到事实/逻辑/可执行性而不是文笔")
        lines.append("中文输出。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 单家测试（Settings 的「测试」按钮调用）

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
