import Foundation

/// `.kownskill` 的顶层 JSON 模型。
///
/// MVP 约定:一个 `.kownskill` 文件就是一个 pretty-printed JSON 对象,由
/// `SkillPackageStore.encode(_:)` / `SkillPackageStore.decodePackage(from:)` 读写。
/// 包内只保存声明式信息,真正安装到技能库、Persona 或 PromptChain 的集成由上层调用方决定。
struct SkillPackage: Identifiable, Codable, Hashable, Sendable {
    static let currentFormatVersion = 1
    static let fileExtension = "kownskill"

    var formatVersion: Int
    var id: UUID
    var metadata: Metadata
    /// 多段提示词模板。最常见是一个 `.system` prompt,复杂包可补 `.developer` / `.user` 示例模板。
    var prompts: [Prompt]
    /// UI 收集变量时展示的 schema,与 prompts 内的 `{{变量名}}` 对应。
    var variables: [Variable]
    /// 市场详情页展示的输入/输出示例。
    var examples: [Example]
    /// 技能运行前需要用户确认或开启的工具权限。
    var requiredToolPermissions: [RequiredToolPermission]
    /// 可选 Persona 引用:用于提示上层「这个包建议绑定到哪些 Agent 档案」。
    var personaReferences: [PersonaReference]
    /// 可选 PromptChain 引用:用于提示上层「这个包建议配合哪些工作流」。
    var promptChainReferences: [PromptChainReference]
    var source: Source

    init(formatVersion: Int = Self.currentFormatVersion,
         id: UUID = UUID(),
         metadata: Metadata,
         prompts: [Prompt],
         variables: [Variable] = [],
         examples: [Example] = [],
         requiredToolPermissions: [RequiredToolPermission] = [],
         personaReferences: [PersonaReference] = [],
         promptChainReferences: [PromptChainReference] = [],
         source: Source = .local) {
        self.formatVersion = formatVersion
        self.id = id
        self.metadata = metadata
        self.prompts = prompts
        self.variables = variables
        self.examples = examples
        self.requiredToolPermissions = requiredToolPermissions
        self.personaReferences = personaReferences
        self.promptChainReferences = promptChainReferences
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, id, metadata, prompts, variables, examples, requiredToolPermissions
        case personaReferences, promptChainReferences, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.metadata = try c.decode(Metadata.self, forKey: .metadata)
        self.prompts = try c.decodeIfPresent([Prompt].self, forKey: .prompts) ?? []
        self.variables = try c.decodeIfPresent([Variable].self, forKey: .variables) ?? []
        self.examples = try c.decodeIfPresent([Example].self, forKey: .examples) ?? []
        self.requiredToolPermissions = try c.decodeIfPresent([RequiredToolPermission].self, forKey: .requiredToolPermissions) ?? []
        self.personaReferences = try c.decodeIfPresent([PersonaReference].self, forKey: .personaReferences) ?? []
        self.promptChainReferences = try c.decodeIfPresent([PromptChainReference].self, forKey: .promptChainReferences) ?? []
        self.source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .local
    }

    var displayName: String {
        metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名技能包" : metadata.name
    }

    var primaryPrompt: Prompt? {
        prompts.first { $0.role == .system } ?? prompts.first
    }

    var promptText: String {
        prompts.map { prompt in
            if prompts.count == 1 { return prompt.template }
            return "[\(prompt.role.rawValue)] \(prompt.title)\n\(prompt.template)"
        }
        .joined(separator: "\n\n")
    }

    var variableNames: [String] {
        variables.map(\.name)
    }

    var requiredToolNames: [String] {
        requiredToolPermissions.map(\.toolName)
    }

    /// MVP 安装桥:把一个包压平成现有 `Skill` 模型,供主代理后续接到技能库。
    func makeSkill(enabled: Bool = true, isPreset: Bool = false) -> Skill {
        Skill(id: id,
              name: displayName,
              summary: metadata.summary,
              instructions: promptText,
              keywords: metadata.tags,
              allowedTools: requiredToolNames,
              enabled: enabled,
              isPreset: isPreset,
              createdAt: metadata.createdAt,
              updatedAt: metadata.updatedAt)
    }
}

extension SkillPackage {
    struct Metadata: Codable, Hashable, Sendable {
        var name: String
        var summary: String
        var author: String
        var version: String
        var tags: [String]
        var homepageURL: URL?
        var minKownVersion: String?
        var createdAt: Date
        var updatedAt: Date

        init(name: String,
             summary: String = "",
             author: String = "Kown",
             version: String = "1.0.0",
             tags: [String] = [],
             homepageURL: URL? = nil,
             minKownVersion: String? = nil,
             createdAt: Date = Date(),
             updatedAt: Date = Date()) {
            self.name = name
            self.summary = summary
            self.author = author
            self.version = version
            self.tags = tags
            self.homepageURL = homepageURL
            self.minKownVersion = minKownVersion
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        enum CodingKeys: String, CodingKey {
            case name, summary, author, version, tags, homepageURL, minKownVersion, createdAt, updatedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            self.author = try c.decodeIfPresent(String.self, forKey: .author) ?? "Kown"
            self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
            self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            self.homepageURL = try c.decodeIfPresent(URL.self, forKey: .homepageURL)
            self.minKownVersion = try c.decodeIfPresent(String.self, forKey: .minKownVersion)
            self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        }
    }

    struct Prompt: Identifiable, Codable, Hashable, Sendable {
        var id: UUID
        var title: String
        var role: Role
        var template: String

        init(id: UUID = UUID(), title: String = "系统提示词", role: Role = .system, template: String) {
            self.id = id
            self.title = title
            self.role = role
            self.template = template
        }

        enum CodingKeys: String, CodingKey {
            case id, title, role, template
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? "系统提示词"
            self.role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .system
            self.template = try c.decode(String.self, forKey: .template)
        }
    }

    enum Role: String, Codable, CaseIterable, Hashable, Sendable {
        case system
        case developer
        case user
        case assistant
    }

    struct Variable: Identifiable, Codable, Hashable, Sendable {
        var id: String { name }
        var name: String
        var label: String
        var summary: String
        var defaultValue: String
        var isRequired: Bool

        init(name: String,
             label: String? = nil,
             summary: String = "",
             defaultValue: String = "",
             isRequired: Bool = true) {
            self.name = name
            self.label = label ?? name
            self.summary = summary
            self.defaultValue = defaultValue
            self.isRequired = isRequired
        }

        enum CodingKeys: String, CodingKey {
            case name, label, summary, defaultValue, isRequired
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? name
            self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            self.defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
            self.isRequired = try c.decodeIfPresent(Bool.self, forKey: .isRequired) ?? true
        }
    }

    struct Example: Identifiable, Codable, Hashable, Sendable {
        var id: UUID
        var title: String
        var input: String
        var output: String

        init(id: UUID = UUID(), title: String, input: String, output: String = "") {
            self.id = id
            self.title = title
            self.input = input
            self.output = output
        }

        enum CodingKeys: String, CodingKey {
            case id, title, input, output
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? "示例"
            self.input = try c.decodeIfPresent(String.self, forKey: .input) ?? ""
            self.output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        }
    }

    struct RequiredToolPermission: Identifiable, Codable, Hashable, Sendable {
        var id: String { toolName }
        var toolName: String
        var displayName: String
        var reason: String
        var category: PermissionCategory
        var riskLevel: RiskLevel
        var isRequired: Bool

        init(toolName: String,
             displayName: String? = nil,
             reason: String = "",
             category: PermissionCategory = .other,
             riskLevel: RiskLevel = .medium,
             isRequired: Bool = true) {
            self.toolName = toolName
            self.displayName = displayName ?? toolName
            self.reason = reason
            self.category = category
            self.riskLevel = riskLevel
            self.isRequired = isRequired
        }

        enum CodingKeys: String, CodingKey {
            case toolName, displayName, reason, category, riskLevel, isRequired
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.toolName = try c.decode(String.self, forKey: .toolName)
            self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? toolName
            self.reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
            self.category = try c.decodeIfPresent(PermissionCategory.self, forKey: .category) ?? .other
            self.riskLevel = try c.decodeIfPresent(RiskLevel.self, forKey: .riskLevel) ?? .medium
            self.isRequired = try c.decodeIfPresent(Bool.self, forKey: .isRequired) ?? true
        }
    }

    enum PermissionCategory: String, Codable, CaseIterable, Hashable, Sendable {
        case network
        case deviceTool
        case localFile
        case mcp
        case generation
        case other
    }

    enum RiskLevel: String, Codable, CaseIterable, Hashable, Sendable {
        case low
        case medium
        case high
    }

    struct PersonaReference: Identifiable, Codable, Hashable, Sendable {
        var id: String { explicitID?.uuidString ?? name }
        var explicitID: UUID?
        var name: String
        var summary: String
        var systemPromptHint: String?

        init(id: UUID? = nil, name: String, summary: String = "", systemPromptHint: String? = nil) {
            self.explicitID = id
            self.name = name
            self.summary = summary
            self.systemPromptHint = systemPromptHint
        }

        enum CodingKeys: String, CodingKey {
            case explicitID = "id"
            case name, summary, systemPromptHint
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.explicitID = try c.decodeIfPresent(UUID.self, forKey: .explicitID)
            self.name = try c.decode(String.self, forKey: .name)
            self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            self.systemPromptHint = try c.decodeIfPresent(String.self, forKey: .systemPromptHint)
        }
    }

    struct PromptChainReference: Identifiable, Codable, Hashable, Sendable {
        var id: String { explicitID?.uuidString ?? name }
        var explicitID: UUID?
        var name: String
        var summary: String
        var stepTitles: [String]

        init(id: UUID? = nil, name: String, summary: String = "", stepTitles: [String] = []) {
            self.explicitID = id
            self.name = name
            self.summary = summary
            self.stepTitles = stepTitles
        }

        enum CodingKeys: String, CodingKey {
            case explicitID = "id"
            case name, summary, stepTitles
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.explicitID = try c.decodeIfPresent(UUID.self, forKey: .explicitID)
            self.name = try c.decode(String.self, forKey: .name)
            self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            self.stepTitles = try c.decodeIfPresent([String].self, forKey: .stepTitles) ?? []
        }
    }

    enum Source: String, Codable, CaseIterable, Hashable, Sendable {
        case builtin
        case imported
        case local
    }
}
