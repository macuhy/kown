import Foundation

/// 一个「Persona(Agent 档案)」:把 系统提示词 + 默认模型 + 默认工具开关 + 绑定的技能/知识库
/// 打包成可一键切换的人格,如「翻译官」「代码审查员」「理财助手」。
/// 与 Skill 的区别:Skill 是单点能力(一段提示 + 工具白名单,可自动触发);
/// Persona 是会话级"整套工作方式"(提示词 + 模型 + 多个技能 + 知识库 + 工具开关),按会话手动选择。
struct Persona: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// 展示名,如「翻译官」。
    var name: String
    /// 图标:emoji(如 "🎭")或 SF Symbol 名(如 "person.text.rectangle")。
    /// 渲染时用 `iconIsSystemSymbol` 区分。
    var icon: String
    /// 一句话说明这个 Persona 是干什么的(列表/菜单里展示)。
    var summary: String
    /// 系统提示词 — 激活时注入到本次发送 system prompt 的最前段。
    var systemPrompt: String
    /// 可选的 provider 覆盖(对应 `ProviderConfig.id`)。非 nil 时,Direct / Translate
    /// 单模型路径会改用该 provider 发送;nil = 跟随会话当前选择。
    var providerID: UUID?
    /// 可选的 model 覆盖(配合 providerID;空/nil 用该 provider 配置的默认 model)。
    var modelOverride: String?
    /// 默认点亮「联网搜索」(仍需在设置里配好 Firecrawl,未配置时静默忽略)。
    var enableWebSearch: Bool
    /// 默认点亮「设备工具」(提醒 / 备忘录)。
    var enableDeviceTools: Bool
    /// 默认点亮「MCP 工具」(连接已挂载且启用的 MCP server)。
    var enableMCP: Bool
    /// 绑定的技能 id 列表(对应 `Skill.id`)— 激活时这些技能的指示与工具白名单一并生效。
    var skillIDs: [UUID]
    /// 绑定的知识库资料夹 id(对应 `KnowledgeFolder.id`)。会话自己绑了资料夹时以会话为准。
    var knowledgeFolderID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         icon: String = "🎭",
         summary: String = "",
         systemPrompt: String,
         providerID: UUID? = nil,
         modelOverride: String? = nil,
         enableWebSearch: Bool = false,
         enableDeviceTools: Bool = false,
         enableMCP: Bool = false,
         skillIDs: [UUID] = [],
         knowledgeFolderID: UUID? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.icon = icon
        self.summary = summary
        self.systemPrompt = systemPrompt
        self.providerID = providerID
        self.modelOverride = modelOverride
        self.enableWebSearch = enableWebSearch
        self.enableDeviceTools = enableDeviceTools
        self.enableMCP = enableMCP
        self.skillIDs = skillIDs
        self.knowledgeFolderID = knowledgeFolderID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `icon` 是 SF Symbol 名(纯 ASCII 字母/数字/点)还是 emoji 文本。
    /// SF Symbol 名永远是小写 ASCII + "."(如 "wand.and.stars"),emoji 必含非 ASCII 标量。
    var iconIsSystemSymbol: Bool {
        !icon.isEmpty && icon.unicodeScalars.allSatisfy { $0.isASCII }
    }

    // 兼容旧 JSON(后续字段演进时 decodeIfPresent 容错)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "🎭"
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        self.providerID = try c.decodeIfPresent(UUID.self, forKey: .providerID)
        self.modelOverride = try c.decodeIfPresent(String.self, forKey: .modelOverride)
        self.enableWebSearch = try c.decodeIfPresent(Bool.self, forKey: .enableWebSearch) ?? false
        self.enableDeviceTools = try c.decodeIfPresent(Bool.self, forKey: .enableDeviceTools) ?? false
        self.enableMCP = try c.decodeIfPresent(Bool.self, forKey: .enableMCP) ?? false
        self.skillIDs = try c.decodeIfPresent([UUID].self, forKey: .skillIDs) ?? []
        self.knowledgeFolderID = try c.decodeIfPresent(UUID.self, forKey: .knowledgeFolderID)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}
