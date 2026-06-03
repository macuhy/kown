import Foundation

enum ConversationMode: String, Codable, CaseIterable, Sendable {
    case council
    case direct
    case compare
    case debate

    var displayName: String {
        switch self {
        case .council: return "Council"
        case .direct:  return "Direct"
        case .compare: return "Compare"
        case .debate:  return "Debate"
        }
    }

    var symbol: String {
        switch self {
        case .council: return "person.3.fill"
        case .direct:  return "bubble.left.fill"
        case .compare: return "rectangle.split.2x1.fill"
        case .debate:  return "quote.bubble.fill"
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .council: return "Start a New Council"
        case .direct:  return "Start a Direct Chat"
        case .compare: return "Compare Two Models"
        case .debate:  return "Start a Model Debate"
        }
    }

    var emptyStateSubtitle: String {
        switch self {
        case .council: return "Ask a question below to gather insights from multiple AI models"
        case .direct:  return "Have a focused conversation with one model"
        case .compare: return "Send the same question to two models and compare answers side-by-side"
        case .debate:  return "Let enabled models argue, rebut each other, then produce a moderated conclusion"
        }
    }
}

/// Debate 模式中的一轮发言。一个 Turn 可以包含多轮 DebateRound。
struct DebateRound: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var index: Int
    var title: String
    /// providerID(uuidString) → 本轮发言
    var responses: [String: String]
    /// providerID(uuidString) → 本轮错误
    var errors: [String: String]
    /// 本轮参与者顺序
    var panelOrder: [String]

    init(id: UUID = UUID(),
         index: Int,
         title: String,
         responses: [String: String] = [:],
         errors: [String: String] = [:],
         panelOrder: [String] = []) {
        self.id = id
        self.index = index
        self.title = title
        self.responses = responses
        self.errors = errors
        self.panelOrder = panelOrder
    }
}

/// 一轮问答里用户附带的图片引用。**只存元数据**(文件名 + mime + 尺寸),
/// 真正的字节单独存成文件(见 `ConversationImageStore`),放在同步目录里随 iCloud 同步。
/// 这样会话 JSON 不会被 base64 撑爆(否则一张 8MB 图 → JSON ~11MB,高频存盘很费)。
struct TurnImage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// 同步图片目录下的文件名,如 `<uuid>.jpg`。
    let fileName: String
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int

    init(id: UUID = UUID(), fileName: String, mimeType: String, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// 一轮里某个 provider 的 token 用量(用于成本角标)。key 为 providerID(uuidString)。
struct TurnTokenUsage: Codable, Hashable, Sendable {
    var input: Int
    var output: Int
    /// 命中提示缓存的输入 token 数(input 已含缓存)。旧存档无此键 → 容错为 0。
    var cachedInput: Int

    init(input: Int, output: Int, cachedInput: Int = 0) {
        self.input = input
        self.output = output
        self.cachedInput = cachedInput
    }

    // 旧 JSON 缺 cachedInput 时,合成 Decodable 会抛 keyNotFound → 整轮/会话解码失败丢数据。
    // 故自定义 init(from:) 用 decodeIfPresent 容错。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        self.output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        self.cachedInput = try c.decodeIfPresent(Int.self, forKey: .cachedInput) ?? 0
    }
}

/// Council 投票结果:由 chair 对各家答案按维度打分(0-10),外加一句总评。
struct CouncilVote: Codable, Hashable, Sendable {
    struct Score: Codable, Hashable, Sendable {
        var accuracy: Int       // 准确性
        var completeness: Int   // 完整性
        var actionability: Int  // 可执行性
        var clarity: Int        // 清晰度
        var total: Int { accuracy + completeness + actionability + clarity }
    }
    /// providerID(uuidString) → 分数
    var scores: [String: Score]
    /// 一句话总评 / 评审理由
    var rationale: String
}

/// 一轮问答：用户的 prompt + 各模型最终文本 + 可选的 Chair 综合
struct Turn: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    var prompt: String
    var systemPrompt: String
    /// providerID(uuidString) → 最终文本
    var responses: [String: String]
    /// providerID(uuidString) → 错误信息
    var errors: [String: String]
    /// Chair providerID(uuidString)，nil 表示这轮无主席
    var chairProviderID: String?
    /// Chair 综合后的文本
    var chairSummary: String?
    /// Chair 调用失败时的错误信息
    var chairError: String?
    /// Summary(总结员) providerID — Council 模式中跑在 chair 之后的中立汇总
    var summaryProviderID: String?
    /// Summary 文本
    var summaryText: String?
    /// Summary 失败错误
    var summaryError: String?
    /// 历史回看用的 provider 完整快照（即使原 provider 后来被删/改也能还原显示）
    var providerSnapshot: [String: ProviderConfig]
    /// panel 的顺序（providerID uuidString），用于按发送顺序渲染
    var panelOrder: [String]
    /// Debate 模式下的多轮辩论记录。旧会话没有该字段,所以保持 optional 兼容旧 JSON。
    var debateRounds: [DebateRound]?
    /// 本轮被 model 提议 + 自动 apply 到 workspace 的文件改动(从 `kown:write` 代码块解析出)。
    /// 仅当 Conversation 设置了 workspaceBookmark 时才会有内容。
    var appliedWrites: [AppliedWrite]?
    /// 用户本轮附带的图片(引用,字节单独存盘)。旧会话没有该字段,保持 optional 兼容旧 JSON。
    var images: [TurnImage]?
    /// 本轮 web_search 命中的引用来源(结构化留痕)。旧会话没有该字段,保持 optional 兼容旧 JSON。
    var sources: [SourceRef]?
    /// 各 provider(panel + chair + summary)本轮的「思考过程」文本,key = providerID(uuidString)。
    /// 旧会话没有,保持 optional 兼容旧 JSON。
    var reasoningByProvider: [String: String]?
    /// 各 provider(panel + chair + summary)本轮的 token 用量,key = providerID(uuidString)。
    /// 旧会话没有,保持 optional 兼容旧 JSON。
    var tokenUsage: [String: TurnTokenUsage]?
    /// Council 投票结果(仅 Council 模式且开启投票时有)。旧会话没有,保持 optional。
    var councilVotes: CouncilVote?
    /// 各 panel provider 各自 web_search 命中的来源,key = providerID(uuidString)。
    /// 旧会话没有,保持 optional;与全轮合并的 `sources` 并存。
    var sourcesByProvider: [String: [SourceRef]]?
    /// 本轮由图像生成产出的图片(引用,字节单独存盘)。旧会话没有,保持 optional。
    var generatedImages: [TurnImage]?

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         prompt: String,
         systemPrompt: String,
         responses: [String: String] = [:],
         errors: [String: String] = [:],
         chairProviderID: String? = nil,
         chairSummary: String? = nil,
         chairError: String? = nil,
         summaryProviderID: String? = nil,
         summaryText: String? = nil,
         summaryError: String? = nil,
         providerSnapshot: [String: ProviderConfig] = [:],
         panelOrder: [String] = [],
         debateRounds: [DebateRound]? = nil,
         appliedWrites: [AppliedWrite]? = nil,
         images: [TurnImage]? = nil,
         sources: [SourceRef]? = nil,
         reasoningByProvider: [String: String]? = nil,
         tokenUsage: [String: TurnTokenUsage]? = nil,
         councilVotes: CouncilVote? = nil,
         sourcesByProvider: [String: [SourceRef]]? = nil,
         generatedImages: [TurnImage]? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.responses = responses
        self.errors = errors
        self.chairProviderID = chairProviderID
        self.chairSummary = chairSummary
        self.chairError = chairError
        self.summaryProviderID = summaryProviderID
        self.summaryText = summaryText
        self.summaryError = summaryError
        self.providerSnapshot = providerSnapshot
        self.panelOrder = panelOrder
        self.debateRounds = debateRounds
        self.appliedWrites = appliedWrites
        self.images = images
        self.sources = sources
        self.reasoningByProvider = reasoningByProvider
        self.tokenUsage = tokenUsage
        self.councilVotes = councilVotes
        self.sourcesByProvider = sourcesByProvider
        self.generatedImages = generatedImages
    }

    // 兼容旧 JSON(缺新字段时 sources 等以 decodeIfPresent 解码,默认 nil),不破坏现有存档/同步。
    enum CodingKeys: String, CodingKey {
        case id, timestamp, prompt, systemPrompt, responses, errors
        case chairProviderID, chairSummary, chairError
        case summaryProviderID, summaryText, summaryError
        case providerSnapshot, panelOrder, debateRounds, appliedWrites, images, sources
        case reasoningByProvider, tokenUsage, councilVotes, sourcesByProvider
        case generatedImages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.prompt = try c.decode(String.self, forKey: .prompt)
        self.systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        self.responses = try c.decodeIfPresent([String: String].self, forKey: .responses) ?? [:]
        self.errors = try c.decodeIfPresent([String: String].self, forKey: .errors) ?? [:]
        self.chairProviderID = try c.decodeIfPresent(String.self, forKey: .chairProviderID)
        self.chairSummary = try c.decodeIfPresent(String.self, forKey: .chairSummary)
        self.chairError = try c.decodeIfPresent(String.self, forKey: .chairError)
        self.summaryProviderID = try c.decodeIfPresent(String.self, forKey: .summaryProviderID)
        self.summaryText = try c.decodeIfPresent(String.self, forKey: .summaryText)
        self.summaryError = try c.decodeIfPresent(String.self, forKey: .summaryError)
        self.providerSnapshot = try c.decodeIfPresent([String: ProviderConfig].self, forKey: .providerSnapshot) ?? [:]
        self.panelOrder = try c.decodeIfPresent([String].self, forKey: .panelOrder) ?? []
        self.debateRounds = try c.decodeIfPresent([DebateRound].self, forKey: .debateRounds)
        self.appliedWrites = try c.decodeIfPresent([AppliedWrite].self, forKey: .appliedWrites)
        self.images = try c.decodeIfPresent([TurnImage].self, forKey: .images)
        self.sources = try c.decodeIfPresent([SourceRef].self, forKey: .sources)
        self.reasoningByProvider = try c.decodeIfPresent([String: String].self, forKey: .reasoningByProvider)
        self.tokenUsage = try c.decodeIfPresent([String: TurnTokenUsage].self, forKey: .tokenUsage)
        self.councilVotes = try c.decodeIfPresent(CouncilVote.self, forKey: .councilVotes)
        self.sourcesByProvider = try c.decodeIfPresent([String: [SourceRef]].self, forKey: .sourcesByProvider)
        self.generatedImages = try c.decodeIfPresent([TurnImage].self, forKey: .generatedImages)
    }

    /// 取顺序化的 panel 配置（按发送顺序，Chair 不在内）
    var orderedPanelConfigs: [ProviderConfig] {
        panelOrder.compactMap { providerSnapshot[$0] }
    }

    /// 取 Chair 配置（如有）
    var chairConfig: ProviderConfig? {
        guard let id = chairProviderID else { return nil }
        return providerSnapshot[id]
    }

    /// 取 Summary 配置(如有)
    var summaryConfig: ProviderConfig? {
        guard let id = summaryProviderID else { return nil }
        return providerSnapshot[id]
    }
}

/// 一条 web_search 命中的引用来源(结构化留痕),随 Turn 一起存盘/同步,并在回答下方展示。
struct SourceRef: Identifiable, Codable, Hashable, Sendable {
    /// 以 url 作稳定标识(同一回合内来源 url 已去重)。
    var id: String { url }
    /// 来源标题
    var title: String
    /// 来源链接
    var url: String
    /// 摘要片段
    var snippet: String

    init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

struct Conversation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var mode: ConversationMode
    var createdAt: Date
    var updatedAt: Date
    /// 软删除时间戳。非 nil = 在回收站(可恢复);超过 30 天启动时自动永久清理。
    var deletedAt: Date?
    var turns: [Turn]
    /// 滚动摘要 — 由 `ConversationSummarizer` 维护,发送时注入到 prompt 头部。
    var contextSummary: String?
    /// 摘要已覆盖的 turn 数量(turns[0..<summarizedThroughTurnCount] 都已并入 summary)。
    var summarizedThroughTurnCount: Int
    /// 本会话锁定的 provider ID 集合(Direct 1 个 / Compare 2 个),空=回退到 first N enabled。
    /// Council 模式忽略此字段(用全部 enabled)。
    /// 已被 `activeModelChoices` 取代,仅保留向后兼容用。
    var activeProviderIDs: [UUID]
    /// 本会话锁定的 (provider, model) 组合 — 比 `activeProviderIDs` 更细,允许同一个
    /// provider 配置用不同 model 来发(例如同时对比 deepseek-v4-flash vs deepseek-v4-pro)。
    var activeModelChoices: [ProviderModelChoice]
    /// Working folder 的 security-scoped bookmark。macOS 设置后,发送时把目录内容注入 prompt,
    /// model 输出 ```kown:write 块会自动应用到该目录(仅限目录内,路径必须相对)。
    var workspaceBookmark: Data?
    /// Working folder 的显示路径(仅 UI 展示,实际写入用 bookmark 解析后的 URL)。
    var workspaceDisplayPath: String?
    /// 本会话的系统提示覆盖。非 nil 且非空时取代全局 `AppViewModel.systemPrompt`;nil/空则回退全局。
    var systemPrompt: String?
    /// 置顶 — 侧栏排序时优先于普通会话。
    var pinned: Bool
    /// 标签 — 侧栏可按标签过滤分组。
    var tags: [String]
    /// 绑定的知识库资料夹 ID — 发送时按问题本地检索片段注入上下文。nil = 未绑定。
    var knowledgeFolderID: UUID?
    /// 所属会话文件夹 ID(侧栏分组用)。nil = 未分组。
    var folderID: UUID?

    init(id: UUID = UUID(),
         title: String = "New Conversation",
         mode: ConversationMode = .council,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         deletedAt: Date? = nil,
         turns: [Turn] = [],
         contextSummary: String? = nil,
         summarizedThroughTurnCount: Int = 0,
         activeProviderIDs: [UUID] = [],
         activeModelChoices: [ProviderModelChoice] = [],
         workspaceBookmark: Data? = nil,
         workspaceDisplayPath: String? = nil,
         systemPrompt: String? = nil,
         pinned: Bool = false,
         tags: [String] = [],
         knowledgeFolderID: UUID? = nil,
         folderID: UUID? = nil) {
        self.id = id
        self.title = title
        self.mode = mode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.turns = turns
        self.contextSummary = contextSummary
        self.summarizedThroughTurnCount = summarizedThroughTurnCount
        self.activeProviderIDs = activeProviderIDs
        self.activeModelChoices = activeModelChoices
        self.workspaceBookmark = workspaceBookmark
        self.workspaceDisplayPath = workspaceDisplayPath
        self.systemPrompt = systemPrompt
        self.pinned = pinned
        self.tags = tags
        self.knowledgeFolderID = knowledgeFolderID
        self.folderID = folderID
    }

    // 兼容旧 JSON(缺新字段)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.mode = try c.decode(ConversationMode.self, forKey: .mode)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.turns = try c.decode([Turn].self, forKey: .turns)
        self.contextSummary = try c.decodeIfPresent(String.self, forKey: .contextSummary)
        self.summarizedThroughTurnCount = try c.decodeIfPresent(Int.self, forKey: .summarizedThroughTurnCount) ?? 0
        self.activeProviderIDs = try c.decodeIfPresent([UUID].self, forKey: .activeProviderIDs) ?? []
        self.activeModelChoices = try c.decodeIfPresent([ProviderModelChoice].self, forKey: .activeModelChoices) ?? []
        self.workspaceBookmark = try c.decodeIfPresent(Data.self, forKey: .workspaceBookmark)
        self.workspaceDisplayPath = try c.decodeIfPresent(String.self, forKey: .workspaceDisplayPath)
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.knowledgeFolderID = try c.decodeIfPresent(UUID.self, forKey: .knowledgeFolderID)
        self.folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
    }

    var lastPromptPreview: String {
        turns.last?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// 侧栏会话分组「文件夹」。会话通过 `Conversation.folderID` 归属。
struct ConversationFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// 文件夹列表持久化:`syncedDataDir/conversation-folders.json`(随 iCloud 同步)。
@MainActor
enum ConversationFolderStore {
    private static var url: URL {
        Platform.syncedDataDir.appendingPathComponent("conversation-folders.json")
    }
    static func load() -> [ConversationFolder] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ConversationFolder].self, from: data) else { return [] }
        return list
    }
    static func save(_ folders: [ConversationFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 一条已应用到 workspace 文件夹的写入记录。
/// 由 model 输出 ```kown:write 代码块 触发,自动 apply 后归档到 Turn 里。
struct AppliedWrite: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// 相对 workspace 根的路径(永远不带 `/` 开头,永远不能 `..` 出根)
    var relativePath: String
    /// 写入类型
    var action: Action
    /// 是否成功落盘
    var success: Bool
    /// 失败时的错误信息
    var error: String?
    /// 旧内容(create 时为 nil;update 时为覆盖前的全文,可用于 Undo / diff)。
    /// 大文件(>200KB)只存前 200KB 截断,后续 Undo 提示用户。
    var oldContent: String?
    /// 新内容(写入磁盘的全文)— UI 用它展示
    var newContent: String
    /// 是否已被用户撤销(撤销后还原 oldContent / 删除新建文件)。旧存档无该字段 → optional。
    var reverted: Bool?

    enum Action: String, Codable, Sendable {
        case create     // 文件原本不存在
        case update     // 覆盖了已有文件
        case skipped    // 路径不合法 / 后缀禁写 / 体积超限,没落盘
    }

    init(id: UUID = UUID(),
         relativePath: String,
         action: Action,
         success: Bool,
         error: String? = nil,
         oldContent: String? = nil,
         newContent: String,
         reverted: Bool? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.action = action
        self.success = success
        self.error = error
        self.oldContent = oldContent
        self.newContent = newContent
        self.reverted = reverted
    }
}
