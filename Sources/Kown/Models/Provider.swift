import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAICompatible
    case anthropic
    case gemini
    case cliCommand          // 通过子进程调用本地 CLI 工具

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .anthropic:        return "Anthropic"
        case .gemini:           return "Google Gemini"
        case .cliCommand:       return "命令行 CLI"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic:        return "https://api.anthropic.com/v1"
        case .gemini:           return "https://generativelanguage.googleapis.com/v1beta"
        case .cliCommand:       return ""   // CLI 不用 URL
        }
    }

    var defaultModel: String {
        switch self {
        case .openAICompatible: return "gpt-4o"
        case .anthropic:        return "claude-sonnet-4-6"
        case .gemini:           return "gemini-2.5-pro"
        case .cliCommand:       return "(由 CLI 决定)"
        }
    }

    var defaultCliCommand: String {
        switch self {
        case .cliCommand: return "claude"
        default:          return ""
        }
    }

    var defaultCliArgs: String {
        switch self {
        case .cliCommand: return "-p {prompt}"
        default:          return ""
        }
    }

    var isCLI: Bool { self == .cliCommand }
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

    // CLI-specific (optional, ignored for HTTP kinds)
    var cliCommand: String?
    var cliArgs: String?

    // Council 模式下被指定为主席:做带观点的综合判断(共识/分歧/倾向结论)。
    var isChair: Bool

    /// Council 模式下被指定为总结员:做中立的汇总聚合(各家观点并集/交集/事实汇总,不出判断)。
    /// 与 chair 并存:发送时先跑 panel → chair → summary。
    var isSummary: Bool

    /// OpenAI 兼容下的具体厂商标签(deepseek/glm/kimi/qwen/openai)。
    /// nil = 未指定(可能是自建/未知服务) → model picker 只列硬填的那个 model。
    var vendor: String?

    /// 被指定为「AI 键盘使用的模型」。单选语义(同主席/总结员):整份 providers 里至多一个为 true。
    /// 仅 openAICompatible / anthropic 且填了 key 时键盘才用得上;为空时键盘回退自动挑选。
    var isKeyboardModel: Bool

    init(id: UUID = UUID(),
         displayName: String,
         kind: ProviderKind,
         baseURL: String? = nil,
         model: String? = nil,
         enabled: Bool = false,
         temperature: Double? = nil,
         maxTokens: Int? = nil,
         cliCommand: String? = nil,
         cliArgs: String? = nil,
         isChair: Bool = false,
         isSummary: Bool = false,
         vendor: String? = nil,
         isKeyboardModel: Bool = false) {
        self.id          = id
        self.displayName = displayName
        self.kind        = kind
        self.baseURL     = baseURL ?? kind.defaultBaseURL
        self.model       = model   ?? kind.defaultModel
        self.enabled     = enabled
        self.temperature = temperature
        self.maxTokens   = maxTokens
        self.cliCommand  = cliCommand ?? (kind.isCLI ? kind.defaultCliCommand : nil)
        self.cliArgs     = cliArgs    ?? (kind.isCLI ? kind.defaultCliArgs    : nil)
        self.isChair     = isChair
        self.isSummary   = isSummary
        self.vendor      = vendor
        self.isKeyboardModel = isKeyboardModel
    }

    // 兼容旧 ~/.kown/config.json (缺 isChair / vendor 字段)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id          = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.kind        = try c.decode(ProviderKind.self, forKey: .kind)
        self.baseURL     = try c.decode(String.self, forKey: .baseURL)
        self.model       = try c.decode(String.self, forKey: .model)
        self.enabled     = try c.decode(Bool.self, forKey: .enabled)
        self.temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        self.maxTokens   = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        self.cliCommand  = try c.decodeIfPresent(String.self, forKey: .cliCommand)
        self.cliArgs     = try c.decodeIfPresent(String.self, forKey: .cliArgs)
        self.isChair     = try c.decodeIfPresent(Bool.self, forKey: .isChair) ?? false
        self.isSummary   = try c.decodeIfPresent(Bool.self, forKey: .isSummary) ?? false
        self.vendor      = try c.decodeIfPresent(String.self, forKey: .vendor)
        self.isKeyboardModel = try c.decodeIfPresent(Bool.self, forKey: .isKeyboardModel) ?? false
    }

    static var defaultSeed: [ProviderConfig] {
        [
            ProviderConfig(displayName: "OpenAI GPT-4o",     kind: .openAICompatible, vendor: "openai"),
            ProviderConfig(displayName: "Anthropic Claude",  kind: .anthropic),
            ProviderConfig(displayName: "Google Gemini",     kind: .gemini),
            ProviderPreset.deepseekV4Flash.makeConfig(),
            ProviderPreset.glm45.makeConfig(),
            ProviderPreset.kimi.makeConfig(),
            ProviderConfig(displayName: "Claude Code (CLI)",
                           kind: .cliCommand,
                           cliCommand: "claude",
                           cliArgs: "-p {prompt}"),
            ProviderConfig(displayName: "Gemini CLI",
                           kind: .cliCommand,
                           cliCommand: "gemini",
                           cliArgs: "--skip-trust -y -p {prompt}"),
            ProviderConfig(displayName: "Codex",
                           kind: .cliCommand,
                           cliCommand: "codex",
                           cliArgs: "exec --skip-git-repo-check -o {outfile} {prompt}"),
        ]
    }
}

/// 一键添加的国内厂商预设 — 全部走 OpenAI 兼容协议。
enum ProviderPreset: String, CaseIterable, Identifiable, Sendable {
    case deepseekV4Flash
    case deepseekV4Pro
    case glm45
    case glm45Air
    case kimi
    case kimiK2
    case qwenPlus
    case ollama

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .deepseekV4Flash: return "DeepSeek V4 Flash · 性价比"
        case .deepseekV4Pro:   return "DeepSeek V4 Pro · 思考模式"
        case .glm45:           return "智谱 GLM-4.7 · 旗舰"
        case .glm45Air:        return "智谱 GLM-4.5 Air · 便宜"
        case .kimi:            return "Moonshot Kimi K2.6 · 最新"
        case .kimiK2:          return "Moonshot Kimi K2.5"
        case .qwenPlus:        return "阿里通义 Qwen3.7 Max · 旗舰"
        case .ollama:          return "Ollama · 本地模型(localhost)"
        }
    }

    func makeConfig() -> ProviderConfig {
        switch self {
        case .deepseekV4Flash:
            return ProviderConfig(displayName: "DeepSeek V4 Flash",
                                  kind: .openAICompatible,
                                  baseURL: "https://api.deepseek.com/v1",
                                  model: "deepseek-v4-flash",
                                  vendor: "deepseek")
        case .deepseekV4Pro:
            return ProviderConfig(displayName: "DeepSeek V4 Pro",
                                  kind: .openAICompatible,
                                  baseURL: "https://api.deepseek.com/v1",
                                  model: "deepseek-v4-pro",
                                  vendor: "deepseek")
        case .glm45:
            return ProviderConfig(displayName: "智谱 GLM-4.7",
                                  kind: .openAICompatible,
                                  baseURL: "https://open.bigmodel.cn/api/paas/v4",
                                  model: "glm-4.7",
                                  vendor: "glm")
        case .glm45Air:
            return ProviderConfig(displayName: "智谱 GLM-4.5 Air",
                                  kind: .openAICompatible,
                                  baseURL: "https://open.bigmodel.cn/api/paas/v4",
                                  model: "glm-4.5-air",
                                  vendor: "glm")
        case .kimi:
            return ProviderConfig(displayName: "Moonshot Kimi K2.6",
                                  kind: .openAICompatible,
                                  baseURL: "https://api.moonshot.cn/v1",
                                  model: "kimi-k2.6",
                                  vendor: "kimi")
        case .kimiK2:
            return ProviderConfig(displayName: "Kimi K2.5",
                                  kind: .openAICompatible,
                                  baseURL: "https://api.moonshot.cn/v1",
                                  model: "kimi-k2.5",
                                  vendor: "kimi")
        case .qwenPlus:
            return ProviderConfig(displayName: "通义 Qwen3.7 Max",
                                  kind: .openAICompatible,
                                  baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                                  model: "qwen3.7-max",
                                  vendor: "qwen")
        case .ollama:
            // Ollama 暴露 OpenAI 兼容端点(/v1),无需 key。model 由用户在编辑页选(可自动拉本地列表)。
            return ProviderConfig(displayName: "Ollama",
                                  kind: .openAICompatible,
                                  baseURL: "http://localhost:11434/v1",
                                  model: "llama3.2",
                                  vendor: "ollama")
        }
    }
}

@MainActor
enum ProviderConfigStore {
    private static let legacyUDKey = "kown.providers.v1"

    private static var configURL: URL {
        Platform.syncedDataDir.appendingPathComponent("config.json")
    }

    static func load() -> [ProviderConfig] {
        let raw: [ProviderConfig]
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            raw = decoded
        } else if let legacy = loadLegacy() {
            save(legacy)
            raw = legacy
        } else {
            raw = ProviderConfig.defaultSeed
        }
        return filterUnsupportedOnPlatform(raw)
    }

    static func save(_ providers: [ProviderConfig]) {
        let cleaned = filterUnsupportedOnPlatform(providers)
        guard let data = try? JSONEncoder().encode(cleaned) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    private static func loadLegacy() -> [ProviderConfig]? {
        for suite in [nil, "app.kown"] {
            let ud = suite.flatMap { UserDefaults(suiteName: $0) } ?? UserDefaults.standard
            if let data = ud.data(forKey: legacyUDKey),
               let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
                ud.removeObject(forKey: legacyUDKey)
                return decoded
            }
        }
        return nil
    }

    /// iOS 上 CLI provider 没法运行(沙箱起不了子进程),直接过滤掉,UI 看不到。
    private static func filterUnsupportedOnPlatform(_ list: [ProviderConfig]) -> [ProviderConfig] {
        #if os(macOS)
        return list
        #else
        return list.filter { $0.kind != .cliCommand }
        #endif
    }
}
