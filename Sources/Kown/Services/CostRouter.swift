import Foundation

/// 任务类别 — 学习型成本路由的聚合维度。与 `QuestionRouter.classify`(难度)同样是
/// 纯启发式、零额外模型调用;难度决定档位,类别决定「在该档位里看哪份战绩」。
enum TaskCategory: String, Codable, CaseIterable, Sendable {
    case qa        // 简单问答
    case writing   // 写作
    case code      // 代码
    case analysis  // 分析

    var label: String {
        switch self {
        case .qa:       return "问答类"
        case .writing:  return "写作类"
        case .code:     return "代码类"
        case .analysis: return "分析类"
        }
    }

    private static let codeMarks = [
        "```", "代码", "函数", "报错", "编译", "脚本", "正则", "重构", "调试", "排查", "接口", "单元测试",
        "bug", "sql", "swift", "python", "javascript", "typescript", "code", "function",
        "compile", "refactor", "debug", "stack trace"
    ]
    private static let analysisMarks = [
        "分析", "对比", "评估", "为什么", "原因", "利弊", "权衡", "方案", "怎么选", "趋势", "推导", "证明",
        "analyze", "compare", "evaluate", "why", "pros and cons", "tradeoff", "derive", "proof"
    ]
    private static let writingMarks = [
        "写一", "写个", "写篇", "写封", "改写", "润色", "翻译", "文案", "标题", "邮件", "周报", "演讲稿",
        "扩写", "缩写", "起草", "write a", "rewrite", "polish", "draft", "essay", "email", "blog"
    ]

    /// 按关键词启发式归类(代码 → 分析 → 写作 → 兜底问答),调用方式对齐 `QuestionRouter.classify`。
    static func classify(_ prompt: String) -> TaskCategory {
        let lower = prompt.lowercased()
        if codeMarks.contains(where: { lower.contains($0) }) { return .code }
        if analysisMarks.contains(where: { lower.contains($0) }) { return .analysis }
        if writingMarks.contains(where: { lower.contains($0) }) { return .writing }
        return .qa
    }
}

/// 学习型成本路由 — 在 `QuestionRouter`(按难度静态选档)之上叠一层数据驱动决策:
/// 复用胜率榜落盘的分类别战绩(Compare 裁判判定时按 `TaskCategory` 细分累计),
/// 在**同难度档位内**优先选「胜率不显著低于最优(差距 <10 个百分点)且单价更低」的模型。
/// 样本不足((模型, 类别) 对不满 `minSamples` 场)时回退到现有静态规则,行为与现状一致。
enum CostRouter {

    /// 一次路由决策。`reason` 非 nil 表示本次是按本地战绩做的学习型决策(中文理由,可直接展示)。
    struct Decision {
        var config: ProviderConfig
        var difficulty: QuestionRouter.Difficulty
        var category: TaskCategory
        var changed: Bool
        var reason: String?
    }

    /// (模型, 类别) 对至少要打满的场次,不够不参与学习(避免小样本噪声)。
    static let minSamples = 5
    /// 「胜率不显著低于最优」的容忍差距(10 个百分点)。
    static let winRateTolerance = 0.10
    /// 省钱级联默认评分阈值:裁判给初答打分低于该值(满分 10)→ 自动旗舰档重答。
    static let defaultCascadeThreshold = 6

    /// 路由入口:难度定档(沿用 QuestionRouter)→ 档内查分类别战绩 → 选「胜率相当且更便宜」。
    /// 学习数据不足时整体回退 `QuestionRouter.route`(reason = nil),保证开关行为不变。
    @MainActor
    static func route(_ config: ProviderConfig, prompt: String) -> Decision {
        let difficulty = QuestionRouter.classify(prompt)
        let category = TaskCategory.classify(prompt)

        // 静态回退闭包:与现有「按难度自动选模型」逐 bit 等价。
        func staticFallback() -> Decision {
            let r = QuestionRouter.route(config, prompt: prompt)
            return Decision(config: r.config, difficulty: r.difficulty, category: category,
                            changed: r.changed, reason: nil)
        }

        let models = ProviderModelCatalog.knownModels(for: config)
        guard models.count > 1 else { return staticFallback() }
        let tierModels = models.filter { ModelTier.heuristic($0) == difficulty.tier }
        guard tierModels.count >= 2 else { return staticFallback() }

        // 档内每个模型查 (模型, 类别) 战绩,样本不足的剔除。
        let store = ModelLeaderboardStore.shared
        var stats: [(model: String, rate: Double, total: Int)] = []
        for m in tierModels {
            let key = ModelLeaderboardStore.key(providerKind: config.kind, model: m)
            if let rec = store.categoryRecord(forModelKey: key, category: category),
               rec.total >= minSamples, rec.wins + rec.losses > 0 {
                stats.append((m, rec.winRate, rec.total))
            }
        }
        // 有效样本不足两家就谈不上「学习挑选」,回退静态规则。
        guard stats.count >= 2, let best = stats.max(by: { $0.rate < $1.rate }) else {
            return staticFallback()
        }

        // 「胜率不显著低于最优」的候选里挑单价最低的(单价 = 输入+输出 每百万 token 美元价之和;
        // 查不到单价的视为最贵,排到最后)。
        let near = stats.filter { best.rate - $0.rate < winRateTolerance }
        func unitPrice(_ model: String) -> Double? {
            ProviderModelCatalog.price(forModel: model, providerKind: config.kind)
                .map { $0.inputPerMTok + $0.outputPerMTok }
        }
        let chosen = near.min(by: {
            (unitPrice($0.model) ?? .greatestFiniteMagnitude) < (unitPrice($1.model) ?? .greatestFiniteMagnitude)
        }) ?? best

        // 可解释理由(中文,一句话,落盘进 Turn.routeNote 给角标展示)。
        let reason: String
        let ratePct = Int((chosen.rate * 100).rounded())
        if chosen.model == best.model {
            reason = "路由:\(category.label) · \(chosen.model) 本地胜率最高(\(ratePct)%,\(chosen.total) 场)"
        } else if let cp = unitPrice(chosen.model), let bp = unitPrice(best.model), bp > cp {
            let savePct = Int(((bp - cp) / bp * 100).rounded())
            reason = "路由:\(category.label) · \(chosen.model) 胜率 \(ratePct)% 与最优相当,单价省约 \(savePct)%"
        } else {
            reason = "路由:\(category.label) · \(chosen.model) 胜率 \(ratePct)% 与最优相当且更便宜"
        }

        guard chosen.model != config.model else {
            return Decision(config: config, difficulty: difficulty, category: category,
                            changed: false, reason: reason)
        }
        var copy = config
        copy.model = chosen.model
        return Decision(config: copy, difficulty: difficulty, category: category,
                        changed: true, reason: reason)
    }

    // MARK: - 省钱级联(实验)

    /// 级联升级计划:发送前算好(裁判 + 旗舰档配置 + 阈值),初答完成后由 runSend 消费。
    struct CascadePlan: Sendable {
        /// 快速打分用的裁判(chair 优先,否则首个 enabled 非 CLI)。
        var judge: ProviderConfig
        /// 旗舰档配置(panel 首家的副本,只换 model;同 id → Keychain key 共用)。
        var flagship: ProviderConfig
        /// 评分阈值,初答低于该分触发旗舰重答。
        var threshold: Int
    }

    /// 级联快速打分:让裁判给「问题 + 回答」打 1-10 的整数分。
    /// 复用 Council 投票打分的裁判调用方式(低温、一次流式调用、usage 记账),失败返回 nil(静默降级,不升级)。
    @MainActor
    static func scoreAnswer(question: String, answer: String, judge: ProviderConfig) async -> Int? {
        guard !judge.kind.isCLI else { return nil }
        let prompt = """
        你是严格的答案质检员。请给下面这条回答的质量打一个 1-10 的整数分\
        (综合考量:是否准确、是否完整回答了问题、是否切题、是否清晰)。
        只输出一行,格式:分数:<n>。不要任何解释。

        【问题】
        \(question.prefix(1200))

        【回答】
        \(answer.prefix(2400))
        """
        let apiKey = (try? KeychainStore.load(id: judge.id)) ?? ""
        let client = ProviderRegistry.client(for: judge.kind)
        var opts = ChatOptions()
        opts.temperature = 0.0
        opts.maxTokens = 24
        var collected = ""
        do {
            for try await chunk in client.stream(prompt: prompt, options: opts, config: judge, apiKey: apiKey) {
                if Task.isCancelled { return nil }
                switch chunk {
                case .text(let t): collected += t
                case .usage(let i, let o, let cached):
                    UsageStore.shared.record(providerKind: judge.kind, model: judge.model,
                                             inputTokens: i, outputTokens: o, cachedTokens: cached)
                default: break
                }
            }
        } catch {
            return nil
        }
        return parseScore(from: collected)
    }

    /// 从裁判输出里解析 1-10 的分数:取首个落在 [1, 10] 的整数(容忍「分数:7」「7/10」「7 分」等格式)。
    static func parseScore(from text: String) -> Int? {
        var digits = ""
        for ch in text {
            if ch.isNumber {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        guard let n = Int(digits), (1...10).contains(n) else { return nil }
        return n
    }
}
