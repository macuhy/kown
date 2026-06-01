import Foundation

/// 模型档位。用名字启发式判定(比维护一张大表更耐厂商改名)。
enum ModelTier: String, Sendable {
    case budget     // 便宜 / 小模型(mini / flash / lite / air / haiku / turbo / nano)
    case balanced   // 性价比中档
    case flagship   // 旗舰(pro / max / opus / ultra / 高版本号)

    /// 用模型名启发式推断档位。
    static func heuristic(_ model: String) -> ModelTier {
        let m = model.lowercased()
        let budgetMarks = ["mini", "flash", "lite", "air", "haiku", "turbo", "nano", "small", "8k"]
        let flagshipMarks = ["pro", "max", "opus", "ultra", "flagship", "-5.5", "reasoner", "-pro"]
        if budgetMarks.contains(where: { m.contains($0) }) { return .budget }
        if flagshipMarks.contains(where: { m.contains($0) }) { return .flagship }
        return .balanced
    }
}

/// 按问题难度自动选模型(Direct 模式实验功能)。纯启发式,不额外调用模型。
enum QuestionRouter {
    enum Difficulty: String, Sendable {
        case easy, medium, hard
        var tier: ModelTier {
            switch self {
            case .easy:   return .budget
            case .medium: return .balanced
            case .hard:   return .flagship
            }
        }
        var label: String {
            switch self {
            case .easy:   return "简单"
            case .medium: return "中等"
            case .hard:   return "复杂"
            }
        }
    }

    private static let hardKeywords = [
        "证明", "推导", "重构", "分析", "算法", "复杂", "为什么", "设计", "架构", "优化", "调试", "排查",
        "proof", "derive", "refactor", "analyze", "algorithm", "architecture", "optimize", "debug", "explain why"
    ]

    /// 用 prompt 的长度 / 代码块 / 关键词启发式判难度。
    static func classify(_ prompt: String) -> Difficulty {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let hasCode = text.contains("```")
        let long = text.count > 600
        let hasHardKw = hardKeywords.contains { lower.contains($0) }
        if hasCode || long || hasHardKw { return .hard }
        if text.count < 60 { return .easy }
        return .medium
    }

    /// 在 config 所属 vendor 的已知模型里,按难度挑一个档位匹配的 model 名。
    /// 找不到精确档位就按方向兜底(旗舰→第一个,便宜→最后一个,中档→中间)。
    /// 返回 nil 表示该 provider 没有可路由的模型清单(保持原样)。
    static func routedModel(for config: ProviderConfig, difficulty: Difficulty) -> String? {
        let models = ProviderModelCatalog.knownModels(for: config)
        guard models.count > 1 else { return nil }   // 只有 0/1 个候选没必要路由
        let target = difficulty.tier
        if let m = models.first(where: { ModelTier.heuristic($0) == target }) { return m }
        switch target {
        case .flagship: return models.first
        case .budget:   return models.last
        case .balanced: return models[models.count / 2]
        }
    }

    /// 返回一个(可能换了 model 的)config 副本 + 是否真的改了。
    static func route(_ config: ProviderConfig, prompt: String) -> (config: ProviderConfig, difficulty: Difficulty, changed: Bool) {
        let difficulty = classify(prompt)
        guard let model = routedModel(for: config, difficulty: difficulty), model != config.model else {
            return (config, difficulty, false)
        }
        var copy = config
        copy.model = model
        return (copy, difficulty, true)
    }
}
