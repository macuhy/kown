import Foundation

enum ConversationMode: String, Codable, CaseIterable, Sendable {
    case council
    case direct
    case compare
    case debate
    case structured
    case tournament
    case translate

    var displayName: String {
        switch self {
        case .council: return "Council"
        case .direct:  return "Direct"
        case .compare: return "Compare"
        case .debate:  return "Debate"
        case .structured: return "Structured"
        case .tournament: return "Tournament"
        case .translate: return "Translate"
        }
    }

    var symbol: String {
        switch self {
        case .council: return "person.3.fill"
        case .direct:  return "bubble.left.fill"
        case .compare: return "rectangle.split.2x1.fill"
        case .debate:  return "quote.bubble.fill"
        case .structured: return "curlybraces"
        case .tournament: return "trophy"
        case .translate: return "globe"
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .council: return "Start a New Council"
        case .direct:  return "Start a Direct Chat"
        case .compare: return "Compare Two Models"
        case .debate:  return "Start a Model Debate"
        case .structured: return "Define a JSON Schema"
        case .tournament: return "Start a Model Tournament"
        case .translate: return "翻译 / 改写"
        }
    }

    var emptyStateSubtitle: String {
        switch self {
        case .council: return "Ask a question below to gather insights from multiple AI models"
        case .direct:  return "Have a focused conversation with one model"
        case .compare: return "Send the same question to two models and compare answers side-by-side"
        case .debate:  return "Let enabled models argue, rebut each other, then produce a moderated conclusion"
        case .structured: return "让所有启用的模型都按你定义的 JSON Schema 返回严格 JSON,自动校验后并排对比各家的结构化结果"
        case .tournament: return "让所有启用的模型先各自回答,再由裁判用单淘汰赛两两对决,逐轮决出最终冠军"
        case .translate: return "把输入的文本翻译成目标语言;开启「润色」则在翻译的同时改善措辞与语气"
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

/// Tournament(擂台 / 淘汰赛)模式中的一轮对决。一个 Turn 包含若干 TournamentRound,
/// 每一轮里有若干两两对决(Match),裁判逐对裁定胜者,胜者晋级下一轮,直到决出冠军。
/// 作法对齐 `DebateRound`:Codable / Hashable / Sendable,key 全用 providerID(uuidString)。
struct TournamentRound: Identifiable, Codable, Hashable, Sendable {
    /// 一场两两对决:裁判读 A、B 两家的回答,给出胜者 + 理由。
    struct Match: Identifiable, Codable, Hashable, Sendable {
        let id: UUID
        /// 选手 A 的 providerID(uuidString)。
        var aProviderID: String
        /// 选手 B 的 providerID(uuidString)。轮空(bye)时为 nil,A 直接晋级。
        var bProviderID: String?
        /// 胜者 providerID(uuidString)。裁判未给出 / 失败时为 nil。
        var winnerProviderID: String?
        /// 裁判给出的判决理由。
        var rationale: String
        /// 裁判调用失败时的错误信息。
        var error: String?

        init(id: UUID = UUID(),
             aProviderID: String,
             bProviderID: String? = nil,
             winnerProviderID: String? = nil,
             rationale: String = "",
             error: String? = nil) {
            self.id = id
            self.aProviderID = aProviderID
            self.bProviderID = bProviderID
            self.winnerProviderID = winnerProviderID
            self.rationale = rationale
            self.error = error
        }
    }

    let id: UUID
    /// 第几轮(1 起)。
    var index: Int
    /// 轮标题(如「四分之一决赛」「半决赛」「决赛」)。
    var title: String
    /// 本轮的对决列表。
    var matches: [Match]

    init(id: UUID = UUID(),
         index: Int,
         title: String,
         matches: [Match] = []) {
        self.id = id
        self.index = index
        self.title = title
        self.matches = matches
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

/// Compare 模式的裁判判定结果:裁判模型读两家回答后给出「胜者 + 理由」。
/// 随 Turn 一起存盘/同步,并在 Compare 回答下方以徽章展示。
struct CompareVerdict: Codable, Hashable, Sendable {
    /// 胜者 providerID(uuidString)。对应 Turn.responses / orderedPanelConfigs 里的某一家。
    var winnerProviderID: String
    /// 判定理由(一句话说明为什么这家更好)。
    var rationale: String
    /// 各家按 4 维度(0-10)的打分:providerID(uuidString) → 分数。
    /// 仅 JSON 评分模式有;旧裁判(只给胜者)为空。复用 `CouncilVote.Score` 的四维定义。
    var scores: [String: CouncilVote.Score]?

    init(winnerProviderID: String, rationale: String, scores: [String: CouncilVote.Score]? = nil) {
        self.winnerProviderID = winnerProviderID
        self.rationale = rationale
        self.scores = scores
    }
}

/// 各家答案差异分析:共識(各模型一致点)/ 分歧(意见分歧点)。
/// 由小模型抽取(`ConsensusAnalyzer`),opt-in「分析分歧」按钮触发,随 Turn 存盘/同步。
struct ConsensusAnalysis: Codable, Hashable, Sendable {
    /// 各模型一致认同的要点。
    var agreements: [String]
    /// 意见分歧点(尽量带「哪个模型怎么不同」)。
    var disagreements: [String]

    init(agreements: [String] = [], disagreements: [String] = []) {
        self.agreements = agreements
        self.disagreements = disagreements
    }
}

/// 多家回答合成的「最优终稿」(Council / Compare 的「合成最优答案」按钮触发)。
struct SynthesizedConclusion: Codable, Hashable, Sendable {
    /// 合成后的最优答案正文(Markdown)。
    var text: String
    /// 执行合成的 provider id(uuidString)。
    var providerID: String
    /// 一两句合成说明:采纳了谁的哪些要点、如何处理分歧。
    var rationale: String

    init(text: String, providerID: String, rationale: String = "") {
        self.text = text
        self.providerID = providerID
        self.rationale = rationale
    }
}

/// 自我反思修订:让模型回看自己的答案,先批评再产出改进版。opt-in「自我反思」按钮触发。
struct SelfRevision: Codable, Hashable, Sendable {
    /// 对原答案的批评 / 发现的问题(bullet 文本)。
    var critique: String
    /// 修订后的改进答案(Markdown)。
    var revised: String
    /// 执行反思的 provider providerID(uuidString),展示「由谁修订」。
    var providerID: String

    init(critique: String, revised: String, providerID: String) {
        self.critique = critique
        self.revised = revised
        self.providerID = providerID
    }
}

/// 事实核查结果:抽取答案里的关键论断,用 web_search 反查后逐条标注。opt-in「事实核查」按钮触发。
struct FactCheckResult: Codable, Hashable, Sendable {
    /// 一条被核查的论断。
    struct Claim: Codable, Hashable, Sendable, Identifiable {
        var id: String { claim }
        /// 论断原文(从答案中提炼)。
        var claim: String
        /// 判定:`verified`(已验证)/ `doubtful`(存疑)/ `unverifiable`(无法核实)。
        var verdict: String
        /// 一句话说明判定依据。
        var note: String
        /// 支撑 / 反驳该论断的来源。
        var sources: [SourceRef]

        init(claim: String, verdict: String, note: String, sources: [SourceRef] = []) {
            self.claim = claim
            self.verdict = verdict
            self.note = note
            self.sources = sources
        }
    }
    /// 逐条核查结果。
    var claims: [Claim]
    /// 执行核查的 provider providerID(uuidString)。
    var providerID: String

    init(claims: [Claim], providerID: String) {
        self.claims = claims
        self.providerID = providerID
    }
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
    /// Tournament(擂台 / 淘汰赛)模式下的逐轮对决记录。旧会话没有该字段,保持 optional 兼容旧 JSON。
    var tournamentRounds: [TournamentRound]?
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
    /// 单模型出图时用这个;多模型对比出图时各家图片改放 `generatedImagesByProvider`。
    var generatedImages: [TurnImage]?
    /// Compare 模式裁判判定结果(胜者 + 理由)。仅 Compare 模式且点过「让裁判评判」时有。
    /// 旧会话没有,保持 optional 兼容旧 JSON。
    var compareVerdict: CompareVerdict?
    /// 各家答案差异分析(共識 / 分歧),opt-in「分析分歧」按钮触发后写入。旧会话没有,保持 optional。
    var consensusAnalysis: ConsensusAnalysis?
    /// 图像生成对比:providerID(uuidString) → 该模型产出的图片。旧会话没有,保持 optional。
    /// 各家用哪个 model 出图、按什么顺序展示,沿用 `providerSnapshot` / `panelOrder`。
    var generatedImagesByProvider: [String: [TurnImage]]?
    /// 图像生成对比里各家失败原因:providerID(uuidString) → 错误文案。旧会话没有,保持 optional。
    var imageGenErrors: [String: String]?
    /// 自我反思修订结果(opt-in「自我反思」按钮触发)。旧会话没有,保持 optional。
    var selfRevision: SelfRevision?
    /// 事实核查结果(opt-in「事实核查」按钮触发)。旧会话没有,保持 optional。
    var factCheck: FactCheckResult?
    /// 本轮注入的知识库片段(带来源元数据),用于「句级溯源」:答案里的 `[n]` 角标
    /// 映射到第 n 条,点开弹出原文。RAG 每次 send 检索一次、跨 provider 共享,故 turn 级即可。
    /// 旧会话没有,保持 optional。
    var knowledgeSources: [KnowledgeSourceRef]?
    /// 自动升级建议(建议式):答完后本地启发式检测到「低置信 / 回避」时给出,UI 在答卡下方
    /// 非侵入地提示「换更强模型 / 转 Council 重答」。默认仅建议,绝不自动重跑。旧会话没有,保持 optional。
    var escalationSuggestion: EscalationSuggestion?
    /// 主答案(panel 首家)的工具调用步骤树。深入模式 / 任意带工具的回答都会留痕,
    /// 刷新会话后仍能在答卡上方看到 Agent 做了哪些步骤。旧会话没有,保持 optional。
    var toolSteps: [ToolStep]?
    /// 多家回答合成的最优终稿(Council / Compare 的「合成最优答案」按钮触发)。旧会话没有,保持 optional。
    var synthesizedConclusion: SynthesizedConclusion?
    /// 学习型成本路由的中文理由(如「路由:代码类 · xx 胜率相当,单价省约 80%」)。
    /// 仅 Direct + 自动选模型且按本地战绩做了学习型决策时有。旧会话没有,保持 optional。
    var routeNote: String?
    /// 省钱级联(实验)的自动升级结果:初答评分低于阈值后旗舰档重答的留痕,
    /// UI 在初答下方再放一张「已自动升级」卡。旧会话没有,保持 optional。
    var autoEscalation: AutoEscalation?

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
         tournamentRounds: [TournamentRound]? = nil,
         appliedWrites: [AppliedWrite]? = nil,
         images: [TurnImage]? = nil,
         sources: [SourceRef]? = nil,
         reasoningByProvider: [String: String]? = nil,
         tokenUsage: [String: TurnTokenUsage]? = nil,
         councilVotes: CouncilVote? = nil,
         sourcesByProvider: [String: [SourceRef]]? = nil,
         generatedImages: [TurnImage]? = nil,
         compareVerdict: CompareVerdict? = nil,
         consensusAnalysis: ConsensusAnalysis? = nil,
         generatedImagesByProvider: [String: [TurnImage]]? = nil,
         imageGenErrors: [String: String]? = nil,
         selfRevision: SelfRevision? = nil,
         factCheck: FactCheckResult? = nil,
         knowledgeSources: [KnowledgeSourceRef]? = nil,
         escalationSuggestion: EscalationSuggestion? = nil,
         toolSteps: [ToolStep]? = nil,
         synthesizedConclusion: SynthesizedConclusion? = nil,
         routeNote: String? = nil,
         autoEscalation: AutoEscalation? = nil) {
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
        self.tournamentRounds = tournamentRounds
        self.appliedWrites = appliedWrites
        self.images = images
        self.sources = sources
        self.reasoningByProvider = reasoningByProvider
        self.tokenUsage = tokenUsage
        self.councilVotes = councilVotes
        self.sourcesByProvider = sourcesByProvider
        self.generatedImages = generatedImages
        self.compareVerdict = compareVerdict
        self.consensusAnalysis = consensusAnalysis
        self.generatedImagesByProvider = generatedImagesByProvider
        self.imageGenErrors = imageGenErrors
        self.selfRevision = selfRevision
        self.factCheck = factCheck
        self.knowledgeSources = knowledgeSources
        self.escalationSuggestion = escalationSuggestion
        self.toolSteps = toolSteps
        self.synthesizedConclusion = synthesizedConclusion
        self.routeNote = routeNote
        self.autoEscalation = autoEscalation
    }

    // 兼容旧 JSON(缺新字段时 sources 等以 decodeIfPresent 解码,默认 nil),不破坏现有存档/同步。
    enum CodingKeys: String, CodingKey {
        case id, timestamp, prompt, systemPrompt, responses, errors
        case chairProviderID, chairSummary, chairError
        case summaryProviderID, summaryText, summaryError
        case providerSnapshot, panelOrder, debateRounds, tournamentRounds, appliedWrites, images, sources
        case reasoningByProvider, tokenUsage, councilVotes, sourcesByProvider
        case generatedImages, compareVerdict, consensusAnalysis, generatedImagesByProvider, imageGenErrors
        case selfRevision, factCheck, knowledgeSources, escalationSuggestion
        case toolSteps, synthesizedConclusion
        case routeNote, autoEscalation
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
        self.tournamentRounds = try c.decodeIfPresent([TournamentRound].self, forKey: .tournamentRounds)
        self.appliedWrites = try c.decodeIfPresent([AppliedWrite].self, forKey: .appliedWrites)
        self.images = try c.decodeIfPresent([TurnImage].self, forKey: .images)
        self.sources = try c.decodeIfPresent([SourceRef].self, forKey: .sources)
        self.reasoningByProvider = try c.decodeIfPresent([String: String].self, forKey: .reasoningByProvider)
        self.tokenUsage = try c.decodeIfPresent([String: TurnTokenUsage].self, forKey: .tokenUsage)
        self.councilVotes = try c.decodeIfPresent(CouncilVote.self, forKey: .councilVotes)
        self.sourcesByProvider = try c.decodeIfPresent([String: [SourceRef]].self, forKey: .sourcesByProvider)
        self.generatedImages = try c.decodeIfPresent([TurnImage].self, forKey: .generatedImages)
        self.compareVerdict = try c.decodeIfPresent(CompareVerdict.self, forKey: .compareVerdict)
        self.consensusAnalysis = try c.decodeIfPresent(ConsensusAnalysis.self, forKey: .consensusAnalysis)
        self.generatedImagesByProvider = try c.decodeIfPresent([String: [TurnImage]].self, forKey: .generatedImagesByProvider)
        self.imageGenErrors = try c.decodeIfPresent([String: String].self, forKey: .imageGenErrors)
        self.selfRevision = try c.decodeIfPresent(SelfRevision.self, forKey: .selfRevision)
        self.factCheck = try c.decodeIfPresent(FactCheckResult.self, forKey: .factCheck)
        self.knowledgeSources = try c.decodeIfPresent([KnowledgeSourceRef].self, forKey: .knowledgeSources)
        self.escalationSuggestion = try c.decodeIfPresent(EscalationSuggestion.self, forKey: .escalationSuggestion)
        self.toolSteps = try c.decodeIfPresent([ToolStep].self, forKey: .toolSteps)
        self.synthesizedConclusion = try c.decodeIfPresent(SynthesizedConclusion.self, forKey: .synthesizedConclusion)
        self.routeNote = try c.decodeIfPresent(String.self, forKey: .routeNote)
        self.autoEscalation = try c.decodeIfPresent(AutoEscalation.self, forKey: .autoEscalation)
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

/// 一条知识库引用来源(句级溯源):答案里的 `[n]` 角标映射到 `index == n` 的这条,
/// 点开底部弹层展示 `docName` 文档里被引用的 `excerpt` 原文。随 Turn 一起存盘/同步。
struct KnowledgeSourceRef: Identifiable, Codable, Hashable, Sendable {
    /// 引用编号(同一回合内唯一,等于注入 prompt 时该片段前的 `[n]`)。
    var index: Int
    var id: Int { index }
    /// 来源文档 ID(回溯到 KnowledgeDoc)。
    var docId: UUID
    /// 来源文档名(展示用)。
    var docName: String
    /// 被引用的片段原文。
    var excerpt: String
    /// 命中片段所在页码(大文档分块入库才有)。optional + 默认 nil,旧存档解码不受影响。
    var page: Int?

    init(index: Int, docId: UUID, docName: String, excerpt: String, page: Int? = nil) {
        self.index = index
        self.docId = docId
        self.docName = docName
        self.excerpt = excerpt
        self.page = page
    }
}

/// 省钱级联(实验)的自动升级留痕:Direct 初答(便宜档)被裁判打了低分后,
/// 自动用旗舰档重答的结果。初答原样保留在 `Turn.responses`,本结构只承载升级答与评分上下文,
/// UI 据此在初答下方放一张「已自动升级」卡。随 Turn 落盘/同步。
struct AutoEscalation: Codable, Hashable, Sendable {
    /// 裁判给初答的分(1-10)。
    var score: Int
    /// 触发升级的阈值(初答分 < threshold 才会有本结构)。
    var threshold: Int
    /// 初答用的模型(便宜档)。
    var fromModel: String
    /// 升级重答用的模型(旗舰档)。
    var toModel: String
    /// 升级所用 provider kind 的 rawValue(成本角标按单价表算钱用)。
    var providerKind: String
    /// 升级答全文。
    var text: String
    /// 升级重答失败时的错误(此时 text 可能为空/半截)。
    var error: String?
    /// 升级答的 token 用量(成本角标用)。
    var tokenUsage: TurnTokenUsage?

    init(score: Int, threshold: Int, fromModel: String, toModel: String,
         providerKind: String, text: String, error: String? = nil, tokenUsage: TurnTokenUsage? = nil) {
        self.score = score
        self.threshold = threshold
        self.fromModel = fromModel
        self.toModel = toModel
        self.providerKind = providerKind
        self.text = text
        self.error = error
        self.tokenUsage = tokenUsage
    }
}

/// 自动升级建议(建议式):答完后本地启发式给出的「这条回答也许值得用更强的方式再来一次」提示。
/// 只承载理由文案;具体重答动作(换更强模型 / 转 Council)由 UI 两个按钮触发,绝不自动执行。
struct EscalationSuggestion: Codable, Hashable, Sendable {
    /// 给用户看的一句理由,如「回答中出现多处不确定措辞」。
    var reason: String

    init(reason: String) {
        self.reason = reason
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
    /// 跨会话长期记忆已抽取到的 turn 水位(turns[0..<memoryExtractedThroughTurnCount] 已被 `MemoryExtractor` 处理过)。
    /// 与 `summarizedThroughTurnCount` 是两套独立水位:前者沉淀进 `MemoryStore`,后者维护本会话滚动摘要。
    var memoryExtractedThroughTurnCount: Int = 0
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
    /// 本会话的生成参数覆盖。非 nil 时取代 provider 上的同名设置;nil 回退 provider/全局默认。
    var conversationTemperature: Double?
    var conversationTopP: Double?
    var conversationMaxTokens: Int?
    /// 置顶 — 侧栏排序时优先于普通会话。
    var pinned: Bool
    /// 标签 — 侧栏可按标签过滤分组。
    var tags: [String]
    /// 绑定的知识库资料夹 ID — 发送时按问题本地检索片段注入上下文。nil = 未绑定。
    var knowledgeFolderID: UUID?
    /// 所属会话文件夹 ID(侧栏分组用)。nil = 未分组。
    var folderID: UUID?
    /// Structured 模式下本会话使用的 JSON Schema(纯文本)。各模型被要求严格按此 schema 返回 JSON。
    /// 旧会话/非 structured 模式为 nil,保持 optional 兼容旧 JSON。
    var structuredSchema: String?
    /// 手动绑定到本会话的技能 id。非 nil 时该技能恒定生效(覆盖自动触发)。nil = 不绑定。
    var selectedSkillID: UUID?
    /// 本会话激活的 Persona(Agent 档案)id。非 nil 时发送注入其系统提示/技能/工具/模型覆盖。nil = 不启用。
    var personaID: UUID?
    /// 本会话绑定的 GitHub 仓库 "owner/repo"。非 nil 时,model 输出的 ```kown:write 块会提交到该仓库
    /// (而非本地 workspace),提交结果以 AppliedWrite 形式归档进 Turn 并在聊天里显示 diff 行数。
    var gitHubRepo: String?
    /// 提交到的分支。nil 回退到仓库默认分支(选仓库时填入)。
    var gitHubBranch: String?
    /// Translate 模式:本会话的目标语言(如「English」「日本語」「简体中文」)。nil = 用全局默认。
    var translateTargetLanguage: String?
    /// Translate 模式:是否在翻译同时润色/改善语气。默认 false(纯翻译)。
    var translateRewrite: Bool = false
    /// 分支血缘:本会话从哪个会话 fork 来(nil = 非分支)。用于侧栏显示血缘 + 兄弟分支快速切换。
    var parentConversationID: UUID?
    /// 分支血缘:从父会话的哪一轮分叉(配合 parentConversationID)。
    var forkedFromTurnID: UUID?

    init(id: UUID = UUID(),
         title: String = "New Conversation",
         mode: ConversationMode = .council,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         deletedAt: Date? = nil,
         turns: [Turn] = [],
         contextSummary: String? = nil,
         summarizedThroughTurnCount: Int = 0,
         memoryExtractedThroughTurnCount: Int = 0,
         activeProviderIDs: [UUID] = [],
         activeModelChoices: [ProviderModelChoice] = [],
         workspaceBookmark: Data? = nil,
         workspaceDisplayPath: String? = nil,
         systemPrompt: String? = nil,
         conversationTemperature: Double? = nil,
         conversationTopP: Double? = nil,
         conversationMaxTokens: Int? = nil,
         pinned: Bool = false,
         tags: [String] = [],
         knowledgeFolderID: UUID? = nil,
         folderID: UUID? = nil,
         structuredSchema: String? = nil,
         selectedSkillID: UUID? = nil,
         personaID: UUID? = nil,
         gitHubRepo: String? = nil,
         gitHubBranch: String? = nil,
         translateTargetLanguage: String? = nil,
         translateRewrite: Bool = false,
         parentConversationID: UUID? = nil,
         forkedFromTurnID: UUID? = nil) {
        self.id = id
        self.title = title
        self.mode = mode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.turns = turns
        self.contextSummary = contextSummary
        self.summarizedThroughTurnCount = summarizedThroughTurnCount
        self.memoryExtractedThroughTurnCount = memoryExtractedThroughTurnCount
        self.activeProviderIDs = activeProviderIDs
        self.activeModelChoices = activeModelChoices
        self.workspaceBookmark = workspaceBookmark
        self.workspaceDisplayPath = workspaceDisplayPath
        self.systemPrompt = systemPrompt
        self.conversationTemperature = conversationTemperature
        self.conversationTopP = conversationTopP
        self.conversationMaxTokens = conversationMaxTokens
        self.pinned = pinned
        self.tags = tags
        self.knowledgeFolderID = knowledgeFolderID
        self.folderID = folderID
        self.structuredSchema = structuredSchema
        self.selectedSkillID = selectedSkillID
        self.personaID = personaID
        self.gitHubRepo = gitHubRepo
        self.gitHubBranch = gitHubBranch
        self.translateTargetLanguage = translateTargetLanguage
        self.translateRewrite = translateRewrite
        self.parentConversationID = parentConversationID
        self.forkedFromTurnID = forkedFromTurnID
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
        self.memoryExtractedThroughTurnCount = try c.decodeIfPresent(Int.self, forKey: .memoryExtractedThroughTurnCount) ?? 0
        self.activeProviderIDs = try c.decodeIfPresent([UUID].self, forKey: .activeProviderIDs) ?? []
        self.activeModelChoices = try c.decodeIfPresent([ProviderModelChoice].self, forKey: .activeModelChoices) ?? []
        self.workspaceBookmark = try c.decodeIfPresent(Data.self, forKey: .workspaceBookmark)
        self.workspaceDisplayPath = try c.decodeIfPresent(String.self, forKey: .workspaceDisplayPath)
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.conversationTemperature = try c.decodeIfPresent(Double.self, forKey: .conversationTemperature)
        self.conversationTopP = try c.decodeIfPresent(Double.self, forKey: .conversationTopP)
        self.conversationMaxTokens = try c.decodeIfPresent(Int.self, forKey: .conversationMaxTokens)
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.knowledgeFolderID = try c.decodeIfPresent(UUID.self, forKey: .knowledgeFolderID)
        self.folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        self.structuredSchema = try c.decodeIfPresent(String.self, forKey: .structuredSchema)
        self.selectedSkillID = try c.decodeIfPresent(UUID.self, forKey: .selectedSkillID)
        self.personaID = try c.decodeIfPresent(UUID.self, forKey: .personaID)
        self.gitHubRepo = try c.decodeIfPresent(String.self, forKey: .gitHubRepo)
        self.gitHubBranch = try c.decodeIfPresent(String.self, forKey: .gitHubBranch)
        self.translateTargetLanguage = try c.decodeIfPresent(String.self, forKey: .translateTargetLanguage)
        self.translateRewrite = try c.decodeIfPresent(Bool.self, forKey: .translateRewrite) ?? false
        self.parentConversationID = try c.decodeIfPresent(UUID.self, forKey: .parentConversationID)
        self.forkedFromTurnID = try c.decodeIfPresent(UUID.self, forKey: .forkedFromTurnID)
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
    /// 写入目标是 GitHub 提交时,commit 的网页地址(本地 workspace 写入为 nil)。旧存档无该字段 → optional。
    var remoteURL: String?

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
         reverted: Bool? = nil,
         remoteURL: String? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.action = action
        self.success = success
        self.error = error
        self.oldContent = oldContent
        self.newContent = newContent
        self.reverted = reverted
        self.remoteURL = remoteURL
    }
}
