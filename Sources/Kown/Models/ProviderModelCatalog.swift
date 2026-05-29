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
