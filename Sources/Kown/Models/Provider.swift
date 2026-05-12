import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAICompatible
    case anthropic
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAICompatible: return "gpt-4o"
        case .anthropic: return "claude-sonnet-4-6"
        case .gemini: return "gemini-2.5-pro"
        }
    }
}

struct ProviderConfig: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var kind: ProviderKind
    var baseURL: String
    var model: String
    var enabled: Bool
    var temperature: Double?
    var maxTokens: Int?

    init(id: UUID = UUID(),
         displayName: String,
         kind: ProviderKind,
         baseURL: String? = nil,
         model: String? = nil,
         enabled: Bool = false,
         temperature: Double? = nil,
         maxTokens: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = model ?? kind.defaultModel
        self.enabled = enabled
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    static var defaultSeed: [ProviderConfig] {
        [
            ProviderConfig(displayName: "OpenAI GPT-4o", kind: .openAICompatible),
            ProviderConfig(displayName: "Anthropic Claude", kind: .anthropic),
            ProviderConfig(displayName: "Google Gemini", kind: .gemini),
            ProviderConfig(displayName: "DeepSeek",
                           kind: .openAICompatible,
                           baseURL: "https://api.deepseek.com/v1",
                           model: "deepseek-chat"),
        ]
    }
}

enum ProviderConfigStore {
    private static let key = "kown.providers.v1"

    static func load() -> [ProviderConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data) else {
            return ProviderConfig.defaultSeed
        }
        return decoded
    }

    static func save(_ providers: [ProviderConfig]) {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
