import Foundation

/// OpenAI 兼容 provider 下的"具体厂商"标签 — 用来索引各家的可用模型清单。
/// `.anthropic` / `.gemini` 由 `ProviderKind` 自带,不在这里。
enum ProviderVendor: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai
    case deepseek
    case glm
    case kimi
    case qwen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai:   return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .glm:      return "智谱 GLM"
        case .kimi:     return "Moonshot Kimi"
        case .qwen:     return "阿里通义 Qwen"
        }
    }

    /// 模型按"通常更想用"的优先顺序排:旗舰 → 廉价 → 旧版兼容。
    /// 2026 H1 现行清单 — 后续厂商发新版本只要更新这里就行。
    var knownModels: [String] {
        switch self {
        case .openai:
            return [
                "gpt-5.5", "gpt-5.5-pro",
                "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano",
                "gpt-5.3", "gpt-5.3-codex",
                "o3", "o3-pro",
                "gpt-image-2", "gpt-image-1-mini",
                "gpt-4o", "gpt-4o-mini"
            ]
        case .deepseek:
            return [
                "deepseek-v4-pro", "deepseek-v4-flash",
                "deepseek-chat", "deepseek-reasoner"   // 老 alias,2026-07-24 前仍可用
            ]
        case .glm:
            return [
                "glm-5.1", "glm-5v-turbo",
                "glm-4.7", "glm-4.6",
                "glm-4.5", "glm-4.5-air",
                "glm-z1", "glm-z1-air",
                "glm-4-plus", "glm-4-air", "glm-4-flash"
            ]
        case .kimi:
            return [
                "kimi-k2.6", "kimi-k2.5",
                "kimi-k2-0905-preview", "kimi-k2-vision-preview",
                "moonshot-v1-128k", "moonshot-v1-32k", "moonshot-v1-8k"
            ]
        case .qwen:
            return [
                "qwen3.7-max", "qwen3.7-plus",
                "qwen3-max", "qwen3-max-2026-01-23",
                "qwen3.5-plus", "qwen3.5-flash",
                "qwen-plus", "qwen-turbo", "qwen-max",
                "qwen3-coder-next", "qwen3-vl-flash"
            ]
        }
    }
}

/// 根据 provider 的 kind 和(可选的) vendor 给出可用模型列表。
/// 完全不读 baseURL — vendor 必须显式设定。
enum ProviderModelCatalog {
    static func knownModels(for config: ProviderConfig) -> [String] {
        switch config.kind {
        case .cliCommand:
            return []
        case .anthropic:
            return [
                "claude-opus-4-7", "claude-opus-4-6",
                "claude-sonnet-4-6", "claude-haiku-4-5"
            ]
        case .gemini:
            return [
                "gemini-3.1-pro", "gemini-3.5-flash",
                "gemini-3-flash", "gemini-3.1-flash-lite",
                "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite"
            ]
        case .openAICompatible:
            return config.vendor.flatMap { ProviderVendor(rawValue: $0)?.knownModels } ?? []
        }
    }
}

/// 对话里被选中的某一个 (provider, model) 组合。
struct ProviderModelChoice: Codable, Hashable, Sendable {
    let providerID: UUID
    let model: String
}

// MARK: - 模型单价表(成本估算用)

/// 一个模型的单价 — 每百万(1M)token 的美元价,分 input / output。
/// 只用于"读侧"估算成本,跟实际账单可能有出入(缓存折扣、批量价、阶梯价都不算)。
struct ModelPrice: Hashable, Sendable {
    /// 输入(prompt)单价,$ / 1M token
    let inputPerMTok: Double
    /// 输出(completion)单价,$ / 1M token
    let outputPerMTok: Double
}

extension ProviderModelCatalog {
    /// 内置单价表,key 是模型 API 名称(跟 usage 记录里存的 model 字符串对齐)。
    /// 价格随官方调整会变动,这里取登记时的公开定价;**查不到的型号一律不写**,
    /// 查询返回 nil → UI 侧标注「未知」、成本不计入。
    ///
    /// 注:本项目模型清单(`knownModels`)是 2026 H1 的命名,部分尚无稳定公开单价;
    /// 能对上公开价的才登记,其余留空,宁缺毋滥。
    static let priceTable: [String: ModelPrice] = [
        // MARK: OpenAI(GPT / o 系列)
        "gpt-4o":        ModelPrice(inputPerMTok: 2.5,  outputPerMTok: 10.0),
        "gpt-4o-mini":   ModelPrice(inputPerMTok: 0.15, outputPerMTok: 0.6),
        "o3":            ModelPrice(inputPerMTok: 2.0,  outputPerMTok: 8.0),
        "o3-pro":        ModelPrice(inputPerMTok: 20.0, outputPerMTok: 80.0),

        // MARK: Anthropic(Claude 系列)
        "claude-opus-4-7":   ModelPrice(inputPerMTok: 15.0, outputPerMTok: 75.0),
        "claude-opus-4-6":   ModelPrice(inputPerMTok: 15.0, outputPerMTok: 75.0),
        "claude-sonnet-4-6": ModelPrice(inputPerMTok: 3.0,  outputPerMTok: 15.0),
        "claude-haiku-4-5":  ModelPrice(inputPerMTok: 1.0,  outputPerMTok: 5.0),

        // MARK: Google(Gemini)
        "gemini-2.5-pro":        ModelPrice(inputPerMTok: 1.25, outputPerMTok: 10.0),
        "gemini-2.5-flash":      ModelPrice(inputPerMTok: 0.3,  outputPerMTok: 2.5),
        "gemini-2.5-flash-lite": ModelPrice(inputPerMTok: 0.1,  outputPerMTok: 0.4),

        // MARK: DeepSeek
        "deepseek-chat":     ModelPrice(inputPerMTok: 0.27, outputPerMTok: 1.1),
        "deepseek-reasoner": ModelPrice(inputPerMTok: 0.55, outputPerMTok: 2.19),

        // MARK: Moonshot Kimi
        "moonshot-v1-8k":   ModelPrice(inputPerMTok: 0.2, outputPerMTok: 0.2),
        "moonshot-v1-32k":  ModelPrice(inputPerMTok: 0.7, outputPerMTok: 0.7),
        "moonshot-v1-128k": ModelPrice(inputPerMTok: 2.0, outputPerMTok: 2.0),

        // MARK: 阿里通义 Qwen
        "qwen-turbo": ModelPrice(inputPerMTok: 0.05, outputPerMTok: 0.2),
        "qwen-plus":  ModelPrice(inputPerMTok: 0.4,  outputPerMTok: 1.2),
        "qwen-max":   ModelPrice(inputPerMTok: 1.6,  outputPerMTok: 6.4),
    ]

    /// 查询某模型的单价。优先精确匹配;再退一步做"去日期后缀"的前缀匹配
    /// (有些记录里存的是带日期的快照名,如 `qwen3-max-2026-01-23`)。
    /// 查不到返回 nil → 视为未知价格,不计入成本。
    /// - Parameters:
    ///   - model: 模型 API 名称(usage 记录里的 model 字段)
    ///   - providerKind: 预留参数 — 当前按 model 名查表,kind 仅用于将来歧义消解。
    static func price(forModel model: String, providerKind: ProviderKind? = nil) -> ModelPrice? {
        // 1) 精确命中
        if let p = priceTable[model] { return p }
        // 2) 前缀匹配:记录名是表 key 的前缀(去掉日期/版本快照后缀)时也算命中
        for (key, price) in priceTable where key.hasPrefix(model) {
            return price
        }
        return nil
    }
}
