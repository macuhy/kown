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
    /// 会话分组文件夹(侧栏)。
    var conversationFolders: [ConversationFolder] = []

    // MARK: - UI 选择 / 输入
    var selectedConversationID: UUID?
    /// 没选会话时新建会话使用的默认模式
    var activeMode: ConversationMode = .council
    var prompt: String = "" {
        didSet { refreshPromptDerived() }
    }
    /// 缓存:输入是否「空白」(trim 后为空)。给工具按钮 / canSend 用,
    /// 避免每次按键在多个 render body 里反复 `trimmingCharacters` 扫全串(大文本时这会 N×O(n))。
    private(set) var promptIsBlank = true
    /// 缓存:输入是否「过大」。大文本时输入框从多行 TextField 切到 TextEditor(NSTextView),
    /// 否则 macOS 的 `axis:.vertical` TextField 每次按键都会同步重排全文 → 主线程卡死。
    private(set) var promptIsLarge = false
    /// 切到 TextEditor 的 utf8 字节阈值(`utf8.count` 是 O(1),不会自身拖慢)。
    private let promptLargeThresholdBytes = 2000

    /// prompt 改动后刷新派生缓存。在 `prompt` 的 didSet 里调用。
    private func refreshPromptDerived() {
        // `allSatisfy(\.isWhitespace)` 命中首个非空白字符即短路 → 正常输入 O(1),只有全空白串才扫到底。
        promptIsBlank = prompt.allSatisfy(\.isWhitespace)
        promptIsLarge = prompt.utf8.count > promptLargeThresholdBytes
    }
    /// 各会话未发送的输入草稿(切走暂存、切回还原)。会话级,内存留存。
    private var drafts: [UUID: String] = [:]
    /// 当前轮的「追问建议」(点「追问建议」按需生成);发送/切换会话清空。
    var followUpSuggestions: [String] = []
    /// 正在生成追问建议。
    var suggestingFollowUps = false
    /// 追问建议生成失败时的原因(给用户看;成功或重置时清空)。
    var followUpError: String?
    /// Structured 模式:JSON Schema 发送前校验失败的原因(给用户看;校验通过或重置时清空)。
    var structuredSchemaError: String?
    /// Compare 模式:正在裁判评判的 turnID 集合(独立于 follow-up state,互不影响)。
    var judgingCompareTurnIDs: Set<UUID> = []
    /// Compare 裁判评判失败时的错误信息,key = turnID。
    var judgeCompareErrors: [UUID: String] = [:]
    /// 正在做差异分析(共識/分歧)的 turn 集合 —— UI 据此显示该轮的加载态。
    /// 与 follow-up state 完全独立(不复用 suggestingFollowUps),允许多轮并行。
    var analyzingConsensusTurns: Set<UUID> = []
    /// 差异分析失败时的原因,key = turnID(给用户看;成功或重试时清空)。
    var consensusErrors: [UUID: String] = [:]
    /// 正在做自我反思修订的 turn 集合。
    var revisingTurns: Set<UUID> = []
    /// 自我反思失败原因,key = turnID。
    var revisionErrors: [UUID: String] = [:]
    /// 正在做事实核查的 turn 集合。
    var factCheckingTurns: Set<UUID> = []
    /// 事实核查失败原因,key = turnID。
    var factCheckErrors: [UUID: String] = [:]
    /// 正在做「合成最优终稿」的 turn 集合(Council / Compare)。
    var synthesizingTurns: Set<UUID> = []
    /// 合成失败原因,key = turnID。
    var synthesisErrors: [UUID: String] = [:]
    /// GitHub 集成:是否已连接(token 存在)。连接 / 断开后刷新,驱动 UI 显示。
    var gitHubConnected: Bool = GitHubAuth.isConnected()
    /// 当前用户的 GitHub 仓库列表(选仓库菜单用,首次打开时按需拉取后缓存)。
    var gitHubRepos: [GitHubRepo] = []
    /// 正在拉取仓库列表。
    var gitHubReposLoading = false
    /// 拉取仓库 / 设备码授权失败时的原因(给用户看)。
    var gitHubError: String?
    /// 设备码授权流程中要展示给用户的 code + 链接;非 nil 表示正在等待用户在浏览器授权。
    var gitHubPendingDeviceCode: GitHubDeviceCode?
    /// 正在跑的设备码轮询 Task。取消授权时一并 cancel,避免后台轮询「僵尸」继续(甚至事后翻成已连接)。
    @ObservationIgnored var gitHubFlowTask: Task<Void, Never>?
    /// ⌘K 命令面板是否打开(macOS 菜单命令与 RootView sheet 共用此开关)。
    var showCommandPalette = false
    /// Artifacts 实时预览面板开关(macOS 用 .inspector,iOS 用 sheet)。
    var showArtifactPanel = false
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
    /// 跨会话长期记忆:开启后发送时注入相关长期记忆,并在会话进行中自动抽取。默认关(隐私优先)。
    var memoryInjectionEnabled: Bool {
        didSet { UserDefaults.standard.set(memoryInjectionEnabled, forKey: Self.memoryInjectionKey) }
    }
    /// 跨对话语义召回:开启后发送时自动从历史会话里捞相关片段注入上下文。默认关(隐私优先)。
    var recallEnabled: Bool {
        didSet { UserDefaults.standard.set(recallEnabled, forKey: Self.recallKey) }
    }

    /// Translate 模式目标语言(会话级粘性):读 = 当前会话设定 ?? 全局上次用的默认;空 = 中英智能互译。
    /// 写:同时落全局默认(供新会话沿用)+ 当前会话(粘性)。
    var translateTargetLanguage: String {
        get {
            if let c = conversations.first(where: { $0.id == selectedConversationID }),
               let l = c.translateTargetLanguage { return l }
            return UserDefaults.standard.string(forKey: Self.translateLangKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.translateLangKey)
            if let idx = conversations.firstIndex(where: { $0.id == selectedConversationID }) {
                conversations[idx].translateTargetLanguage = newValue.isEmpty ? nil : newValue
                conversations[idx].updatedAt = Date()
                ConversationStore.save(conversations[idx])
            }
        }
    }

    /// Translate 模式是否润色/改语气(会话级)。无会话时返回 false。
    var translateRewrite: Bool {
        get { conversations.first(where: { $0.id == selectedConversationID })?.translateRewrite ?? false }
        set {
            if let idx = conversations.firstIndex(where: { $0.id == selectedConversationID }) {
                conversations[idx].translateRewrite = newValue
                conversations[idx].updatedAt = Date()
                ConversationStore.save(conversations[idx])
            }
        }
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
    /// 输入栏「设备工具」开关 — 开启后本次发送暴露提醒/备忘录工具给模型。持久化,跨重启记得。
    var deviceToolsEnabledForNextSend: Bool {
        didSet { UserDefaults.standard.set(deviceToolsEnabledForNextSend, forKey: Self.deviceToolsToggleKey) }
    }
    /// 输入栏「本地文件工具」开关(macOS)— 开启 + 已授权目录时,本次发送暴露 读/列/写(暂存)工具。持久化。
    static let fileToolsToggleKey = "kown.fileTools.enabledForNextSend"
    var fileToolsEnabledForNextSend: Bool {
        didSet { UserDefaults.standard.set(fileToolsEnabledForNextSend, forKey: Self.fileToolsToggleKey) }
    }
    /// 是否按输入自动匹配技能(纯启发式,零成本)。默认开;关掉则只用手动绑定的技能。
    var skillAutoTriggerEnabled: Bool {
        didSet { UserDefaults.standard.set(skillAutoTriggerEnabled, forKey: Self.skillAutoTriggerKey) }
    }
    /// 首轮回答后自动给会话推荐标签(一次小模型调用)。默认开;关掉则只能手动打标签。
    var autoTagEnabled: Bool {
        didSet { UserDefaults.standard.set(autoTagEnabled, forKey: Self.autoTagKey) }
    }
    /// 输入栏「MCP」开关 — 开启后本次发送连接已启用的 MCP server,把它们的工具暴露给模型。持久化。
    var mcpEnabledForNextSend: Bool {
        didSet { UserDefaults.standard.set(mcpEnabledForNextSend, forKey: Self.mcpToggleKey) }
    }
    /// 输入栏「深入模式」开关(仅 Direct)— 开启后本次发送走多步 Agent:规划→多轮工具→自检→交付。持久化。
    var deepAgentEnabledForNextSend: Bool {
        didSet { UserDefaults.standard.set(deepAgentEnabledForNextSend, forKey: Self.deepAgentToggleKey) }
    }
    /// 输入栏「深度研究」开关(仅 Direct,需 Web Search 已配置)— 开启后本次发送走深度研究引擎:
    /// 大纲→搜索→抓正文→提炼→缺口自查 多轮循环,产出带 [n] 角标与参考文献的长报告。持久化。
    var deepResearchEnabledForNextSend: Bool {
        didSet { UserDefaults.standard.set(deepResearchEnabledForNextSend, forKey: Self.deepResearchToggleKey) }
    }
    /// 技能库(命名的「系统提示 + 工具白名单」能力包)。
    let skillsStore = SkillsStore()
    /// Persona 库(可切换的 Agent 档案:系统提示 + 默认模型 + 工具/技能/知识库打包)。
    let personaStore = PersonaStore()
    /// 已挂载的 MCP server 配置库。
    let mcpStore = MCPStore()
    /// 最近一次发送被自动触发命中的技能 id(手动绑定时为 nil)。供 UI 显示「本次生效技能」徽标,非持久化。
    var autoTriggeredSkillID: UUID?

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
    /// Tournament 模式下逐轮对决的临时进度(裁判逐场裁定时累积更新,turn 落盘后由 turn.tournamentRounds 接管)。
    var liveTournamentRounds: [TournamentRound] = []
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
    private static let memoryInjectionKey = "kown.memory.injection.v1"
    private static let recallKey = "kown.recall.enabled"
    /// Translate 全局默认语言 key(非 private:AppViewModel+Send 跨文件读取做发送时回退)。
    static let translateLangKey = "kown.translate.lang"
    private static let deviceToolsToggleKey = "kown.deviceTools.toggle.v1"
    private static let mcpToggleKey = "kown.mcp.toggle.v1"
    private static let deepAgentToggleKey = "kown.deepAgent.toggle.v1"
    private static let deepResearchToggleKey = "kown.deepResearch.toggle.v1"
    private static let skillAutoTriggerKey = "kown.skill.autoTrigger.v1"
    private static let autoTagKey = "kown.autoTag.v1"
    // 发送编排已移到 AppViewModel+Send.swift,以下原 private 状态降为 internal 供其访问。
    var runningTask: Task<Void, Never>?
    var summarizingTasks: [UUID: Task<Void, Never>] = [:]
    /// 跨会话长期记忆抽取任务(防同一会话重复抽取),key = convID。
    var memoryExtractionTasks: [UUID: Task<Void, Never>] = [:]
    /// 正在自动起标题的会话(防重复触发)。
    var autoTitleTasks: Set<UUID> = []
    /// 正在自动打标签的会话(防重复触发)。
    var autoTagTasks: Set<UUID> = []

    // MARK: - Init

    init() {
        // 启动时异步清一次旧 log 文件(保留最近 14 天),后台 queue 跑,毫秒级
        ResponseLogger.rotateOldLogsIfNeeded()
        self.providers = ProviderConfigStore.load()
        self.conversations = []   // 冷启动改后台解码(见下方 Task),避免一启动就在主线程解码上百个 JSON
        self.webSearchConfig = WebSearchConfigStore.load()
        self.knowledgeFolders = KnowledgeStore.loadAll()
        self.conversationFolders = ConversationFolderStore.load()
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
        self.memoryInjectionEnabled = UserDefaults.standard.bool(forKey: Self.memoryInjectionKey)
        self.recallEnabled = UserDefaults.standard.bool(forKey: Self.recallKey)
        self.deviceToolsEnabledForNextSend = UserDefaults.standard.bool(forKey: Self.deviceToolsToggleKey)
        self.mcpEnabledForNextSend = UserDefaults.standard.bool(forKey: Self.mcpToggleKey)
        self.deepAgentEnabledForNextSend = UserDefaults.standard.bool(forKey: Self.deepAgentToggleKey)
        self.deepResearchEnabledForNextSend = UserDefaults.standard.bool(forKey: Self.deepResearchToggleKey)
        self.fileToolsEnabledForNextSend = UserDefaults.standard.bool(forKey: Self.fileToolsToggleKey)
        // 自动触发默认开:首次启动 UserDefaults 没有该键时取 true。
        self.skillAutoTriggerEnabled = (UserDefaults.standard.object(forKey: Self.skillAutoTriggerKey) as? Bool) ?? true
        // 自动打标签默认开:首次启动 UserDefaults 没有该键时取 true。
        self.autoTagEnabled = (UserDefaults.standard.object(forKey: Self.autoTagKey) as? Bool) ?? true

        // 冷启动:会话 JSON 解码挪到后台线程(避免一启动就在主线程解码上百个文件 → 白屏/卡顿),
        // 解码完回主线程赋值,再清理过期回收站(purge 依赖已加载的 conversations)。
        // 加载窗口内用户若已新建会话,按 id 去重并入(内存优先),不丢已建会话。
        Task { @MainActor [weak self] in
            let loaded = await ConversationStore.loadAllAsync()
            guard let self else { return }
            if self.conversations.isEmpty {
                self.conversations = loaded
            } else {
                let knownIDs = Set(self.conversations.map(\.id))
                self.conversations.append(contentsOf: loaded.filter { !knownIDs.contains($0.id) })
            }
            self.purgeExpiredTrash()
        }

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

        // 快捷指令(SaveToKnowledgeIntent)在本进程后台直接写 KnowledgeStore 后会广播此通知;
        // 这里重读落盘状态,避免内存旧 knowledgeFolders 在下次 saveKnowledge() 时覆盖掉新文档。
        NotificationCenter.default.addObserver(
            forName: .kownKnowledgeDidChangeExternally, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.knowledgeFolders = KnowledgeStore.loadAll()
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

    func newConversation(mode: ConversationMode, inFolder folderID: UUID? = nil) {
        // 不再取消 isRunning 的任务 — task 继续跑在原 conv 上,只是当前 UI 不再展示其直播。
        // 直播 UI 是否显示由 `runningConvID == selectedConversationID` 决定(MainContentView)。
        stashDraft()
        var conv = Conversation(mode: mode)
        // 项目空间继承:落进项目 + 自动锁定项目默认模型。
        // 系统提示 / 知识库不在这里拷贝 —— 发送时按「会话级显式 > 项目级 > 全局」回退
        // (见 AppViewModel+Send / providersForCurrentSend),项目配置改了,项目内旧会话也即时生效。
        if let folderID, let project = conversationFolders.first(where: { $0.id == folderID }) {
            conv.folderID = project.id
            if let choice = project.defaultModelChoice,
               providers.contains(where: { $0.id == choice.providerID && $0.enabled }) {
                conv.activeModelChoices = [choice]
                conv.activeProviderIDs = [choice.providerID]
            }
        }
        conversations.insert(conv, at: 0)
        selectedConversationID = conv.id
        prompt = ""
        followUpSuggestions = []
        followUpError = nil
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
            systemPrompt: source.systemPrompt,
            parentConversationID: source.id,
            forkedFromTurnID: turnID
        )
        stashDraft()
        conversations.insert(fork, at: 0)
        selectedConversationID = fork.id
        prompt = ""
        followUpSuggestions = []
        followUpError = nil
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
        followUpSuggestions = []
        followUpError = nil
        applyAlwaysEnableWebSearchIfNeeded()
        if let conv = conversations.first(where: { $0.id == id }) {
            activeMode = conv.mode
        }
    }

    /// 全局搜索命中后,跳到某会话并定位到某一轮。
    /// `scrollTarget` 是 MainContentView 的私有 @State,这里通过 `pendingScrollTurnID`
    /// 桥接:切会话后置位,MainContentView 监听到再滚动到对应 turn。
    var pendingScrollTurnID: UUID?
    func selectConversationAndTurn(_ convID: UUID, _ turnID: UUID) {
        selectConversation(convID)
        pendingScrollTurnID = turnID
    }

    // MARK: - 成本预算闸
    /// 本月花费接近/超过预算上限时,send() 置位此项让 UI 弹确认;确认后走 confirmBudgetAndSend()。
    struct BudgetGate: Identifiable { let id = UUID(); let message: String; var isHardLimit: Bool = false }
    var budgetGate: BudgetGate?
    /// 确认「仍要发送」后置 true,让紧接着的 send() 跳过预算闸(发完即复位)。
    var bypassBudgetOnce = false
    /// 「换更强模型重答」置 true,让紧接着的 send() 把 Direct panel[0] 强制路由到旗舰档(发完即复位)。
    var forceFlagshipOnce = false

    /// 自动升级建议开关(建议式)。默认开;在「设置 ▸ 性能」里可关。
    static let escalationSuggestionsKey = "kown.escalation.enabled"
    var escalationSuggestionsEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.escalationSuggestionsKey) as? Bool ?? true
    }

    /// 正在生成图片(用于按钮 loading 态)。
    var isGeneratingImage = false

    /// 图像生成:用当前 Direct provider/model 调 /images/generations,出图作为一轮追加。
    /// 注意:需选用支持出图的 model(如 gpt-image-2 / dall-e-3 / 硅基流动图像模型)。
    func generateImage() {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !isGeneratingImage, !isRunning else { return }
        guard let cfg = providersForCurrentSend().panel.first, !cfg.kind.isCLI else { return }
        if selectedConversationID == nil { newConversation(mode: currentMode) }
        guard let convID = selectedConversationID else { return }
        prompt = ""
        followUpSuggestions = []
        followUpError = nil
        isGeneratingImage = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isGeneratingImage = false }
            let key = cfg.kind.isCLI ? "" : ((try? KeychainStore.load(id: cfg.id)) ?? "")
            let turn: Turn
            do {
                let datas = try await ImageGenerationClient.generate(
                    baseURL: cfg.baseURL, apiKey: key, model: cfg.model, prompt: p)
                var imgs: [TurnImage] = []
                for d in datas {
                    let fileName = "\(UUID().uuidString).png"
                    if ConversationImageStore.save(d, fileName: fileName) {
                        imgs.append(TurnImage(fileName: fileName, mimeType: "image/png",
                                              pixelWidth: 1024, pixelHeight: 1024))
                    }
                }
                turn = Turn(prompt: p, systemPrompt: "",
                            responses: [cfg.id.uuidString: ""],
                            providerSnapshot: [cfg.id.uuidString: cfg],
                            panelOrder: [cfg.id.uuidString],
                            generatedImages: imgs)
            } catch {
                turn = Turn(prompt: p, systemPrompt: "",
                            responses: [:],
                            errors: [cfg.id.uuidString: error.localizedDescription],
                            providerSnapshot: [cfg.id.uuidString: cfg],
                            panelOrder: [cfg.id.uuidString])
            }
            if let idx = self.conversations.firstIndex(where: { $0.id == convID }) {
                self.conversations[idx].turns.append(turn)
                self.conversations[idx].updatedAt = Date()
                ConversationStore.save(self.conversations[idx])
            }
        }
    }

    /// 可用于图像生成对比的 provider(已启用、非 CLI;CLI 不支持 /images/generations)。
    /// 用户在编辑页给某些 provider 选好出图模型即可纳入对比。
    var imageGenComparableProviders: [ProviderConfig] {
        providers.filter { $0.enabled && !$0.kind.isCLI }
    }

    /// 图像生成对比:让多个支持出图的模型用同一 prompt 各自出图,产出一轮按模型分组的对比结果。
    /// 逐个串行调用(出图慢且各家限速不一,串行更稳)。某家失败只记该家错误,不影响其他家。
    /// 至少需要 2 个可用 provider;不足时回退到单模型 `generateImage()`。
    func generateImageComparison() {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !isGeneratingImage, !isRunning else { return }
        let panel = imageGenComparableProviders
        guard panel.count >= 2 else { generateImage(); return }
        if selectedConversationID == nil { newConversation(mode: currentMode) }
        guard let convID = selectedConversationID else { return }
        prompt = ""
        followUpSuggestions = []
        followUpError = nil
        isGeneratingImage = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isGeneratingImage = false }
            var imagesByProvider: [String: [TurnImage]] = [:]
            var errorsByProvider: [String: String] = [:]
            var snapshot: [String: ProviderConfig] = [:]
            var order: [String] = []
            for cfg in panel {
                let pid = cfg.id.uuidString
                snapshot[pid] = cfg
                order.append(pid)
                let key = (try? KeychainStore.load(id: cfg.id)) ?? ""
                do {
                    let datas = try await ImageGenerationClient.generate(
                        baseURL: cfg.baseURL, apiKey: key, model: cfg.model, prompt: p)
                    var imgs: [TurnImage] = []
                    for d in datas {
                        let fileName = "\(UUID().uuidString).png"
                        if ConversationImageStore.save(d, fileName: fileName) {
                            imgs.append(TurnImage(fileName: fileName, mimeType: "image/png",
                                                  pixelWidth: 1024, pixelHeight: 1024))
                        }
                    }
                    if imgs.isEmpty {
                        errorsByProvider[pid] = "未返回图片"
                    } else {
                        imagesByProvider[pid] = imgs
                    }
                } catch {
                    errorsByProvider[pid] = error.localizedDescription
                }
            }
            let turn = Turn(prompt: p, systemPrompt: "",
                            providerSnapshot: snapshot,
                            panelOrder: order,
                            generatedImagesByProvider: imagesByProvider,
                            imageGenErrors: errorsByProvider)
            if let idx = self.conversations.firstIndex(where: { $0.id == convID }) {
                self.conversations[idx].turns.append(turn)
                self.conversations[idx].updatedAt = Date()
                ConversationStore.save(self.conversations[idx])
            }
        }
    }

    // MARK: - Artifact Canvas(独立轻量调用,不进主对话)

    /// 「让 AI 修改这个 artifact」:用当前会话将用的模型做一次**独立**调用,收集纯文本回复。
    /// 不写入会话、不动 liveStates / isRunning — 修改请求与结果都不进主对话流。
    /// CLI provider 跳过(输出不可控,没法保证单代码块)。
    func runArtifactRevision(prompt: String, systemPrompt: String) async throws -> String {
        let candidate = providersForCurrentSend().panel.first(where: { !$0.kind.isCLI })
            ?? providers.first(where: { $0.enabled && !$0.kind.isCLI })
        guard let provider = candidate else { throw ArtifactRevisionError.noProvider }
        let key = try KeychainStore.load(id: provider.id)
        let client = ProviderRegistry.client(for: provider.kind)
        let options = ChatOptions(systemPrompt: systemPrompt, temperature: 0.2)
        var collected = ""
        for try await chunk in client.stream(
            prompt: prompt, options: options, config: provider, apiKey: key
        ) {
            if case .text(let t) = chunk { collected += t }
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ArtifactRevisionError.emptyReply }
        return trimmed
    }

    /// 接续生成:让模型接着上一轮回答继续(上下文已随发送回放,故直接发「继续」指令)。
    func continueGenerating() {
        guard !isRunning, let conv = selectedConversation, !conv.turns.isEmpty else { return }
        prompt = "继续"
        send()
    }

    /// 处理 kown:// 深链:
    /// - `kown://ask?q=问题&mode=direct&send=1`:新建/复用空会话,填入问题(send=1 直接发)。
    /// - `kown://new?mode=council`:新建该模式会话。
    /// - `kown://open?id=<UUID>`:打开指定会话。
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "kown" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = (url.host ?? comps?.host ?? "").lowercased()
        func q(_ name: String) -> String? { comps?.queryItems?.first(where: { $0.name == name })?.value }
        func mode(_ s: String?) -> ConversationMode? {
            switch s?.lowercased() {
            case "direct": return .direct
            case "compare": return .compare
            case "council": return .council
            case "debate": return .debate
            default: return nil
            }
        }
        switch host {
        case "ask":
            let m = mode(q("mode")) ?? activeMode
            if let convID = selectedConversationID,
               let idx = conversations.firstIndex(where: { $0.id == convID }),
               conversations[idx].turns.isEmpty {
                conversations[idx].mode = m
                conversations[idx].updatedAt = Date()
                ConversationStore.save(conversations[idx])
                activeMode = m
            } else {
                newConversation(mode: m)
            }
            prompt = q("q") ?? ""
            let send = (q("send") ?? "").lowercased()
            if send == "1" || send == "true" { self.send() } else { focusInputRequest &+= 1 }
        case "new":
            newConversation(mode: mode(q("mode")) ?? activeMode)
            focusInputRequest &+= 1
        case "open":
            if let idStr = q("id") ?? q("convId"), let uuid = UUID(uuidString: idStr),
               conversations.contains(where: { $0.id == uuid && $0.deletedAt == nil }) {
                selectConversation(uuid)
            }
        default:
            break
        }
    }

    /// 用场景模板开聊:当前会话为空则就地套用(设模式 + 系统提示),否则新建一个。
    func startScenario(mode: ConversationMode, systemPrompt: String) {
        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let convID = selectedConversationID,
           let idx = conversations.firstIndex(where: { $0.id == convID }),
           conversations[idx].turns.isEmpty {
            conversations[idx].mode = mode
            conversations[idx].systemPrompt = sys.isEmpty ? nil : sys
            conversations[idx].updatedAt = Date()
            ConversationStore.save(conversations[idx])
            activeMode = mode
        } else {
            newConversation(mode: mode)
            if let id = selectedConversationID { setConversationSystemPrompt(id, prompt: sys) }
        }
    }

    /// 按需生成 3 条追问建议(基于最近一轮问答),用便宜的小调用。
    func suggestFollowUps() {
        guard !suggestingFollowUps else { return }
        guard !isRunning else {
            followUpError = "正在生成回答(isRunning),等这一轮跑完再点。"
            return
        }
        guard let turn = selectedConversation?.turns.last else {
            followUpError = "当前会话还没有可用的问答轮次。"
            return
        }
        guard let cfg = chairProvider ?? providers.first(where: { $0.enabled && !$0.kind.isCLI }) else {
            followUpError = "没有可用的 API provider:追问建议只能用带 API key 的 provider 生成(CLI 不支持)。到配置里启用一个。"
            return
        }
        let answer = turn.chairSummary ?? turn.summaryText
            ?? turn.responses.values.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        guard !answer.isEmpty else {
            followUpError = "最近一轮还没有可用的回答,无法生成追问。"
            return
        }
        let q = String(turn.prompt.prefix(800))
        let a = String(answer.prefix(1200))
        suggestingFollowUps = true
        followUpSuggestions = []
        followUpError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.suggestingFollowUps = false }
            let apiKey = (try? KeychainStore.load(id: cfg.id)) ?? ""
            let prompt = "基于下面的问答,提出 3 个简短、具体、互不相同的后续追问(中文)。每行一个,不要编号、引号或解释。\n\n问:\(q)\n答:\(a)"
            let options = ChatOptions(systemPrompt: nil, temperature: 0.7, maxTokens: 200)
            var collected = ""
            var reasoningLen = 0
            var chunkCount = 0
            var usageNote = ""
            do {
                let client = ProviderRegistry.client(for: cfg.kind)
                for try await chunk in client.stream(prompt: prompt, options: options, config: cfg, apiKey: apiKey) {
                    chunkCount += 1
                    switch chunk {
                    case .text(let t): collected += t
                    case .reasoning(let r): reasoningLen += r.count
                    case .usage(let i, let o, _): usageNote = " in=\(i) out=\(o)"
                    default: break
                    }
                }
            } catch {
                self.followUpError = "生成失败(\(cfg.displayName)):\(error.localizedDescription)"
                return
            }
            let lines = collected.split(whereSeparator: \.isNewline).map { raw -> String in
                var s = raw.trimmingCharacters(in: .whitespaces)
                while let f = s.first, f == "-" || f == "*" || f == "•" || f == "." || f == "、" || f == ")" || f == ")" || f.isNumber || f == " " {
                    s.removeFirst()
                }
                return s.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            let parsed = Array(lines.prefix(3))
            if parsed.isEmpty {
                self.followUpError = "诊断:text=\(collected.count)字 reasoning=\(reasoningLen)字 chunks=\(chunkCount)\(usageNote) | \(cfg.displayName) thinking=\(AnthropicClient.claudeThinkingEnabled)"
            } else {
                self.followUpSuggestions = parsed
            }
        }
    }

    /// 点某条追问建议 → 直接发送。
    func askFollowUp(_ question: String) {
        followUpSuggestions = []
        followUpError = nil
        prompt = question
        send()
    }

    // MARK: - Compare 裁判评判(opt-in)

    /// 指定 turn 是否正在裁判评判中(UI 转圈用)。
    func isJudgingCompare(turnID: UUID) -> Bool {
        judgingCompareTurnIDs.contains(turnID)
    }

    /// Compare 模式:让裁判模型读两家回答,判出胜者 + 理由,写回 Turn 并记进胜率榜。
    /// opt-in —— 由 Compare 回答完成后用户点「让裁判评判」触发(默认手动,省成本)。
    /// 裁判优先 `chairProvider`,否则第一家 enabled 非 CLI provider(尽量避开参赛两家)。
    /// 结构仿 `suggestFollowUps`,但用独立 state(`judgingCompareTurnIDs` / `judgeCompareErrors`),
    /// 不触碰 follow-up 相关状态。
    func judgeCompare(turnID: UUID) {
        guard !judgingCompareTurnIDs.contains(turnID) else { return }
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
        let turn = conversations[convIdx].turns[turnIdx]

        // 取参赛两家(Compare 取前两列)。
        let panel = Array(turn.orderedPanelConfigs.prefix(2))
        guard panel.count == 2 else {
            judgeCompareErrors[turnID] = "需要两家回答才能评判。"
            return
        }
        let aCfg = panel[0], bCfg = panel[1]
        let aKey = aCfg.id.uuidString, bKey = bCfg.id.uuidString
        let aText = (turn.responses[aKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bText = (turn.responses[bKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !aText.isEmpty, !bText.isEmpty else {
            judgeCompareErrors[turnID] = "有一家回答为空,无法评判。"
            return
        }

        // 裁判:chair 优先;否则第一家 enabled 非 CLI(尽量避开参赛两家,实在没有就允许)。
        let participantIDs: Set<UUID> = [aCfg.id, bCfg.id]
        let preferred = chairProvider.flatMap { c in (c.enabled && !c.kind.isCLI) ? c : nil }
        let judge: ProviderConfig?
        if let p = preferred, !participantIDs.contains(p.id) {
            judge = p
        } else if let neutral = providers.first(where: { $0.enabled && !$0.kind.isCLI && !participantIDs.contains($0.id) }) {
            judge = neutral
        } else {
            judge = preferred ?? providers.first(where: { $0.enabled && !$0.kind.isCLI })
        }
        guard let judgeCfg = judge else {
            judgeCompareErrors[turnID] = "没有可用的 API provider 当裁判(CLI 不支持)。到配置里启用一个。"
            return
        }

        let q = String(turn.prompt.prefix(1200))
        let aName = aCfg.displayName, bName = bCfg.displayName
        let a = String(aText.prefix(2400))
        let b = String(bText.prefix(2400))

        judgingCompareTurnIDs.insert(turnID)
        judgeCompareErrors[turnID] = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.judgingCompareTurnIDs.remove(turnID) }
            let apiKey = (try? KeychainStore.load(id: judgeCfg.id)) ?? ""
            let prompt = PromptBuilders.buildCompareScoringPrompt(
                question: q, aName: aName, aResponse: a, bName: bName, bResponse: b
            )
            let options = ChatOptions(systemPrompt: nil, temperature: 0.2, maxTokens: 500)
            var collected = ""
            do {
                let client = ProviderRegistry.client(for: judgeCfg.kind)
                for try await chunk in client.stream(prompt: prompt, options: options, config: judgeCfg, apiKey: apiKey) {
                    if case .text(let t) = chunk { collected += t }
                }
            } catch {
                self.judgeCompareErrors[turnID] = "评判失败(\(judgeCfg.displayName)):\(error.localizedDescription)"
                return
            }

            // 优先解析带维度打分的 JSON;失败则降级到纯文本「首个 A/B」解析(无分数)。
            let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            let winnerIsA: Bool
            let rationale: String
            var scores: [String: CouncilVote.Score]? = nil
            if let scored = PromptBuilders.parseCompareVerdict(from: trimmed) {
                winnerIsA = scored.winnerIsA
                rationale = scored.rationale.isEmpty ? "裁判未给出理由。" : scored.rationale
                scores = [aKey: scored.scoreA, bKey: scored.scoreB]
            } else if let parsed = Self.parseVerdict(trimmed) {
                winnerIsA = parsed.winnerIsA
                rationale = parsed.rationale.isEmpty ? "裁判未给出理由。" : parsed.rationale
            } else {
                self.judgeCompareErrors[turnID] = "评判结果无法解析(\(judgeCfg.displayName)):\(trimmed.prefix(80))"
                return
            }
            let winnerCfg = winnerIsA ? aCfg : bCfg
            let loserCfg  = winnerIsA ? bCfg : aCfg

            // 写回 Turn(只前进到 live 索引,防竞态)。
            guard let liveConvIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  let liveTurnIdx = self.conversations[liveConvIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
            self.conversations[liveConvIdx].turns[liveTurnIdx].compareVerdict =
                CompareVerdict(winnerProviderID: winnerCfg.id.uuidString, rationale: rationale, scores: scores)
            self.conversations[liveConvIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[liveConvIdx])

            // 记进胜率榜(模型键 = providerKind::model)。
            let winnerKey = ModelLeaderboardStore.key(providerKind: winnerCfg.kind, model: winnerCfg.model)
            let loserKey  = ModelLeaderboardStore.key(providerKind: loserCfg.kind, model: loserCfg.model)
            ModelLeaderboardStore.shared.record(winnerKey: winnerKey, loserKey: loserKey)
        }
    }

    /// 解析裁判输出:取首个独立出现的 A/B 当胜者,其余非空行拼成理由。
    private static func parseVerdict(_ text: String) -> (winnerIsA: Bool, rationale: String)? {
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var winnerIsA: Bool?
        var rationaleLines: [String] = []
        for line in lines where !line.isEmpty {
            if winnerIsA == nil {
                // 去掉常见前缀符号后看首字符是不是 A / B。
                let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "：: 。.-*#`【】[]()() "))
                if let first = cleaned.first {
                    if first == "A" || first == "a" { winnerIsA = true; continue }
                    if first == "B" || first == "b" { winnerIsA = false; continue }
                }
                // 没在首字符命中:退一步扫整行有没有「胜者 A/B」字样。
                if line.contains("A") && !line.contains("B") { winnerIsA = true; continue }
                if line.contains("B") && !line.contains("A") { winnerIsA = false; continue }
            } else {
                rationaleLines.append(line)
            }
        }
        guard let isA = winnerIsA else { return nil }
        return (isA, rationaleLines.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    /// 把当前输入暂存为当前会话的草稿(切换/新建前调用)。
    private func stashDraft() {
        guard let old = selectedConversationID else { return }
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { drafts.removeValue(forKey: old) } else { drafts[old] = prompt }
    }

    // MARK: - Skills(会话绑定)

    /// 当前会话手动绑定的技能(如有)。
    var currentBoundSkill: Skill? {
        skillsStore.skill(id: selectedConversation?.selectedSkillID)
    }

    /// 给当前会话绑定 / 解绑技能(nil = 解绑,回到自动触发)。
    func setSelectedSkill(_ id: UUID?) {
        guard let convID = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        conversations[idx].selectedSkillID = id
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
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
            liveTournamentRounds.removeAll()
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
            liveTournamentRounds.removeAll()
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

    /// 设置某会话的生成参数覆盖(nil = 清除,回退 provider 默认)。
    func setConversationGenerationParams(_ id: UUID, temperature: Double?, topP: Double?, maxTokens: Int?) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].conversationTemperature = temperature
        conversations[idx].conversationTopP = topP
        conversations[idx].conversationMaxTokens = maxTokens
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
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

    // MARK: - 会话文件夹 / 分组

    /// 新建文件夹,返回 id。
    @discardableResult
    func createFolder(name: String) -> UUID? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let folder = ConversationFolder(name: n)
        conversationFolders.append(folder)
        ConversationFolderStore.save(conversationFolders)
        return folder.id
    }

    func renameFolder(_ id: UUID, name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let idx = conversationFolders.firstIndex(where: { $0.id == id }) else { return }
        conversationFolders[idx].name = n
        ConversationFolderStore.save(conversationFolders)
    }

    /// 删除文件夹:其下会话移出(folderID = nil),不删会话。
    func deleteFolder(_ id: UUID) {
        for i in conversations.indices where conversations[i].folderID == id {
            conversations[i].folderID = nil
            conversations[i].updatedAt = Date()
            ConversationStore.save(conversations[i])
        }
        conversationFolders.removeAll { $0.id == id }
        ConversationFolderStore.save(conversationFolders)
    }

    // MARK: - 项目空间(文件夹的上下文配置)

    /// 更新项目空间配置:名称 / 项目级系统提示 / 知识库 / 默认模型 / 图标颜色。
    /// 各字段传 nil 即清除对应项目级设置(name 留空不改名)。
    func updateProjectSettings(_ id: UUID,
                               name: String,
                               systemPrompt: String?,
                               knowledgeFolderID: UUID?,
                               defaultModelChoice: ProviderModelChoice?,
                               icon: String?,
                               color: ProjectColor?) {
        guard let idx = conversationFolders.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { conversationFolders[idx].name = n }
        let prompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        conversationFolders[idx].projectSystemPrompt = (prompt?.isEmpty == false) ? prompt : nil
        conversationFolders[idx].knowledgeFolderID = knowledgeFolderID
        conversationFolders[idx].defaultModelChoice = defaultModelChoice
        conversationFolders[idx].icon = icon
        conversationFolders[idx].color = color
        ConversationFolderStore.save(conversationFolders)
    }

    /// 会话所属的项目空间(文件夹);未分组返回 nil。
    func projectFolder(of conv: Conversation) -> ConversationFolder? {
        guard let fid = conv.folderID else { return nil }
        return conversationFolders.first { $0.id == fid }
    }

    /// 项目绑定的知识库资料夹 —— 项目内会话未自行绑定时的回退(发送时消费)。
    func projectKnowledgeFolder(of conv: Conversation) -> KnowledgeFolder? {
        guard let fid = projectFolder(of: conv)?.knowledgeFolderID else { return nil }
        return knowledgeFolders.first { $0.id == fid }
    }

    /// 把会话移动到某文件夹(nil = 移出到未分组)。
    func setFolder(_ convID: UUID, folderID: UUID?) {
        guard let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        conversations[idx].folderID = folderID
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
        #if os(iOS)
        // 保持 Apple Watch 独立表盘的 provider 配置最新(选最合适的 OpenAI 兼容模型)。
        syncWatchProvider()
        // 键盘扩展开关打开时,同步保持共享配置最新。
        syncKeyboardProvider()
        #endif
    }

    #if os(iOS)
    /// 选一个 OpenAI 兼容、已配 key 的 provider 推送给 Apple Watch(优先当前 Direct 选中的模型)。
    @discardableResult
    func syncWatchProvider() -> Bool {
        let candidates = providers.filter {
            $0.enabled && $0.kind == .openAICompatible && KeychainStore.hasKey(id: $0.id)
        }
        let activeID = providersForCurrentSend().panel.first?.id
        let chosen = candidates.first(where: { $0.id == activeID }) ?? candidates.first
        return WatchProvisioning.sync(provider: chosen)
    }

    /// 设置页「AI 键盘」开关:开 → 写入共享配置;关 → 清除。返回是否成功写入。
    @discardableResult
    func setKeyboardBridgeEnabled(_ on: Bool) -> Bool {
        KeyboardConfigBridge.isEnabled = on
        guard on else {
            KeyboardConfigBridge.clear()
            return false
        }
        return syncKeyboardProvider()
    }

    /// 选一个 OpenAI 兼容 / Anthropic、已配 key 的 provider 写给键盘扩展(优先当前 Direct 选中的模型)。
    @discardableResult
    func syncKeyboardProvider() -> Bool {
        guard KeyboardConfigBridge.isEnabled else { return false }
        let candidates = providers.filter {
            $0.enabled && ($0.kind == .openAICompatible || $0.kind == .anthropic) && KeychainStore.hasKey(id: $0.id)
        }
        // 优先用户在设置里显式「设为键盘模型」的那个;没有(或它已失效)再退回自动挑:当前 Direct 选中 → 第一个候选。
        let activeID = providersForCurrentSend().panel.first?.id
        let chosen = candidates.first(where: { $0.isKeyboardModel })
            ?? candidates.first(where: { $0.id == activeID })
            ?? candidates.first
        return KeyboardConfigBridge.sync(provider: chosen)
    }
    #endif

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
            self.conversationFolders = ConversationFolderStore.load()
            self.refreshHasWebSearchKey()
            // 用量也跟着同步刷新 — 其他设备的 usage-*.json 文件可能刚被 iCloud 拉到本地
            UsageStore.shared.reload()
            // 胜率榜同理 — leaderboard.json 可能刚被 iCloud 拉下来
            ModelLeaderboardStore.shared.reload()
            // 定时任务同理 — scheduled-tasks.json 存在 syncedDataDir,init 时容器没就绪只读到本地空表,
            // 切换数据源后必须重读,否则切到 iCloud 后内存里的任务列表一直是空的。
            SchedulerService.shared.reload()
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
            self.conversationFolders = ConversationFolderStore.load()
            // Firecrawl key 存在 apikeys.json 里(随 iCloud 同步),但 UI/canEnableWebSearch 看的是
            // 缓存的 hasWebSearchKey 标志。拉到新 apikeys.json 后必须重算一次,否则另一端填的 key
            // 同步过来了却一直显示「未设置」(firecrawl key「同步失败」的真因)。
            self.refreshHasWebSearchKey()
            // 用量也要 reload — 别的设备的 usage-*.json 可能刚被 iCloud 拉下来。
            // 启动 2s 后会自动走到这里,所以多端用量累加在 app 启动后短延迟就能看到。
            UsageStore.shared.reload()
            ModelLeaderboardStore.shared.reload()
            // 定时任务列表(scheduled-tasks.json)随 iCloud 同步,但 SchedulerService 只在 init 读一次,
            // 那时容器还没就绪只读到本地空表。iCloud 就绪后必须重读,否则「加了任务退出 app 就没了」
            //(任务其实写进了 iCloud `.kown`,只是从没被重新载入)。
            SchedulerService.shared.reload()
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

    #if os(iOS)
    /// 「AI 键盘使用的模型」单选,语义同 chair/summary。设完立即把选中的 provider 推给键盘扩展。
    func setKeyboardModel(_ id: UUID, _ on: Bool) {
        for i in providers.indices {
            if providers[i].id == id {
                providers[i].isKeyboardModel = on
            } else if on {
                providers[i].isKeyboardModel = false
            }
        }
        saveProviders()
        syncKeyboardProvider()
    }
    #endif

    // MARK: - Web Search 配置

    /// 镜像 KeychainStore 状态;Keychain 自身不可观察,通过 setter/clearer / refreshHasWebSearchKey 维持一致。
    /// 注:启动时 init 评估这个值时 iCloud 容器可能还没探测到位,导致从错误路径读 → 误报 false。
    /// 后续在 ICloud 容器到位 / sync 切换 / cold-start refresh 时调 `refreshHasWebSearchKey()` 重算。
    private(set) var hasWebSearchKey: Bool = WebSearchKey.hasKey()

    func saveWebSearchConfig() {
        WebSearchConfigStore.save(webSearchConfig)
        #if os(iOS)
        syncWatchProvider()   // 联网开关变更后,表盘需拿到最新 Firecrawl 配置
        #endif
    }

    func setWebSearchKey(_ key: String) throws {
        try WebSearchKey.save(key)
        hasWebSearchKey = true
        #if os(iOS)
        syncWatchProvider()
        #endif
    }

    func clearWebSearchKey() {
        WebSearchKey.delete()
        hasWebSearchKey = false
        #if os(iOS)
        syncWatchProvider()
        #endif
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

    /// 一键总结链接:抓取网页正文入上下文,自动填一条总结 prompt 并发送。
    /// 复用 `attachScrapedURL`(同一抓取链路)。抓取失败返回错误文案、不发送。
    /// 若用户已在输入框写了内容,则把它当作针对该网页的具体问题,否则用默认总结指令。
    func summarizeURL(_ urlString: String) async -> String? {
        if let err = await attachScrapedURL(urlString) { return err }
        let userQ = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if userQ.isEmpty {
            prompt = "请阅读上面附带的网页正文,用中文做一份结构化总结:1)一句话主旨;2)关键要点(bullet);3)值得注意的数据/结论。"
        }
        send()
        return nil
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

    // MARK: - Prompt Improver(提示词润色)
    // 注:与 follow-up(suggestFollowUps / followUpError / followUpSuggestions)以及 Prompt Enhancer
    // (enhancePrompt / enhancerOutput…)完全独立——独立 state + 独立方法。本功能在输入栏内联预览,
    // 用小模型把当前输入润色成更清晰、具体、结构化的 prompt,点「采用」即替换输入框。
    /// 润色结果(改写后的 prompt);nil = 没有可展示的结果。
    var promptImprovement: String?
    /// 正在润色(供按钮 loading 态)。
    var improvingPrompt: Bool = false
    /// 润色失败原因(给用户看;成功或重置时清空)。
    var promptImproveError: String?
    private var promptImproveTask: Task<Void, Never>?

    /// 用小模型把当前 `prompt` 润色成更清晰、具体、结构化的提问,结果存进 `promptImprovement`。
    /// 仿 suggestFollowUps 的写法,但独立 state/方法,不碰 follow-up / enhancer。
    func improvePrompt() {
        guard !improvingPrompt else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            promptImproveError = "输入框是空的,先写点东西再润色。"
            return
        }
        guard !isRunning else {
            promptImproveError = "正在生成回答,等这一轮跑完再润色。"
            return
        }
        // chair 优先,否则第一个 enabled 的非 CLI provider(CLI 沙箱差异大,小调用不可靠)。
        guard let cfg = chairProvider ?? providers.first(where: { $0.enabled && !$0.kind.isCLI }) else {
            promptImproveError = "没有可用的 API provider:润色只能用带 API key 的 provider(CLI 不支持)。到配置里启用一个。"
            return
        }
        promptImprovement = nil
        promptImproveError = nil
        improvingPrompt = true
        let original = String(trimmed.prefix(4000))
        let snapshot = cfg
        promptImproveTask?.cancel()
        promptImproveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.improvingPrompt = false }
            let apiKey = snapshot.kind.isCLI ? "" : ((try? KeychainStore.load(id: snapshot.id)) ?? "")
            let meta = """
            请把下面的「原提问」润色成一个更清晰、更具体、结构更好的 prompt,目标是让大模型更准确地理解并作答。规则:
            1) 保持原语言(中文/英文按原文)。
            2) 保留原意,补足隐含的背景、约束和期望输出形式,但不要替用户回答问题、不要编造事实。
            3) 必要时用简短的分点或小标题组织,使要求清楚。
            4) 直接输出润色后的提问本身,不要任何前后缀、引号、解释或「润色后:」之类的标注。

            原提问:
            \(original)
            """
            let options = ChatOptions(systemPrompt: nil, temperature: 0.4, maxTokens: 1200)
            var collected = ""
            do {
                let client = ProviderRegistry.client(for: snapshot.kind)
                for try await chunk in client.stream(prompt: meta, options: options, config: snapshot, apiKey: apiKey) {
                    if Task.isCancelled { return }
                    if case .text(let t) = chunk {
                        collected += t
                        self.promptImprovement = collected
                    }
                }
            } catch {
                if Task.isCancelled { return }
                self.promptImproveError = "润色失败(\(snapshot.displayName)):\(error.localizedDescription)"
                return
            }
            let result = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.isEmpty {
                self.promptImproveError = "润色没有返回内容,换个 provider 或稍后再试。"
            } else {
                self.promptImprovement = result
            }
        }
    }

    /// 采用润色结果:替换输入框文本,清空润色 state。
    func acceptImprovedPrompt() {
        let trimmed = (promptImprovement ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { prompt = trimmed }
        dismissImprovement()
    }

    /// 放弃润色结果:取消进行中的任务并清空 state。
    func dismissImprovement() {
        promptImproveTask?.cancel()
        promptImproveTask = nil
        improvingPrompt = false
        promptImprovement = nil
        promptImproveError = nil
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
        case .tournament:
            // 所有启用的非 CLI provider 作为参赛选手(各自回答);裁判 = chair,没有则取第一个 enabled 非 CLI。
            // CLI provider 沙箱差异大,淘汰赛回答不稳定,排除。
            let players = enabled.filter { !$0.kind.isCLI }
            let judge = chairProvider ?? players.first
            return (players, judge)
        case .direct, .translate:
            // Translate 与 Direct 同样是单模型路径:选一个 provider,无 chair。
            // 优先级:会话显式选择(modelChoices / activeProviderIDs)> 项目默认模型 > 第一个 enabled。
            if let chosen = resolvedFromModelChoices(maxCount: 1), !chosen.isEmpty {
                return (chosen, nil)
            }
            if let chosen = chosenFromActive(maxCount: 1), !chosen.isEmpty {
                return (chosen, nil)
            }
            if let chosen = resolvedFromProjectDefault() {
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
        case .structured:
            // 所有启用的非 CLI provider 都按同一 schema 出结构化结果;无 chair。
            // CLI 沙箱差异大、JSON 可靠性低,排除。
            return (enabled.filter { !$0.kind.isCLI }, nil)
        }
    }

    /// Structured 模式:设置当前会话的 JSON Schema(没有会话则新建一个 structured 会话承载)。
    func setStructuredSchema(_ schema: String) {
        structuredSchemaError = nil
        if let idx = conversations.firstIndex(where: { $0.id == selectedConversationID }) {
            conversations[idx].structuredSchema = schema
            conversations[idx].updatedAt = Date()
            ConversationStore.save(conversations[idx])
        } else {
            var conv = Conversation(mode: .structured)
            conv.structuredSchema = schema
            conversations.insert(conv, at: 0)
            selectedConversationID = conv.id
            activeMode = .structured
            ConversationStore.save(conv)
        }
    }

    /// 从当前会话的 `activeProviderIDs` 解析出真实 ProviderConfig 列表;不存在的 id 自动跳过。
    private func chosenFromActive(maxCount: Int) -> [ProviderConfig]? {
        guard let conv = selectedConversation, !conv.activeProviderIDs.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        let resolved = conv.activeProviderIDs.compactMap { byID[$0] }.filter(\.enabled)
        return Array(resolved.prefix(maxCount))
    }

    /// 项目空间的默认模型兜底:当前会话没有任何显式模型选择、且所属项目配了默认模型时,
    /// 用项目默认 (provider, model) 发送。会话级显式设置永远优先于它(调用方先试前两者)。
    private func resolvedFromProjectDefault() -> [ProviderConfig]? {
        guard let conv = selectedConversation,
              conv.activeModelChoices.isEmpty, conv.activeProviderIDs.isEmpty,
              let choice = projectFolder(of: conv)?.defaultModelChoice,
              var p = providers.first(where: { $0.id == choice.providerID }), p.enabled else { return nil }
        p.model = choice.model
        return [p]
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
        guard !promptIsBlank, !isRunning else { return false }
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
