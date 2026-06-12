import Foundation

/// 一个「技能包」:一段系统提示(可带 `{{变量}}`)+ 它被允许调用的工具白名单 +
/// 用于自动触发匹配的关键词。选中后,`instructions` 注入系统提示,`allowedTools` 并入本次工具集。
struct Skill: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// 展示名,如「提醒助手」。
    var name: String
    /// 一句话说明这个技能干什么(也参与自动触发的语义匹配)。
    var summary: String
    /// 系统提示正文,支持 `{{变量}}` 占位(复用 PromptLibraryStore 的占位逻辑)。
    var instructions: String
    /// 自动触发用的关键词(命中 prompt 即加分)。
    var keywords: [String]
    /// 自动生成的同义触发说法(便宜模型据 name/summary/keywords 扩写,≤15 条)。
    /// 与 `keywords` 同样参与 `SkillRouter` 命中加分,提升口语化触发召回。
    /// 可选字段:旧数据 / 未生成时为空,`decodeIfPresent` 容错。
    var triggerPhrases: [String]
    /// 该技能允许模型调用的工具名(如 "create_reminder"、"web_search")。
    var allowedTools: [String]
    /// 关闭后不参与自动触发,也不能被手动选中。
    var enabled: Bool
    /// 内置预设标记(UI 上不可删除,只能禁用/复制)。
    var isPreset: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         summary: String = "",
         instructions: String,
         keywords: [String] = [],
         triggerPhrases: [String] = [],
         allowedTools: [String] = [],
         enabled: Bool = true,
         isPreset: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.keywords = keywords
        self.triggerPhrases = triggerPhrases
        self.allowedTools = allowedTools
        self.enabled = enabled
        self.isPreset = isPreset
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Codable 容错:新增字段一律 decodeIfPresent(仓库惯例),旧数据缺 triggerPhrases 解空数组。
    enum CodingKeys: String, CodingKey {
        case id, name, summary, instructions, keywords, triggerPhrases, allowedTools, enabled, isPreset, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id             = try c.decode(UUID.self, forKey: .id)
        self.name           = try c.decode(String.self, forKey: .name)
        self.summary        = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.instructions   = try c.decode(String.self, forKey: .instructions)
        self.keywords       = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        self.triggerPhrases = try c.decodeIfPresent([String].self, forKey: .triggerPhrases) ?? []
        self.allowedTools   = try c.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
        self.enabled        = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.isPreset       = try c.decodeIfPresent(Bool.self, forKey: .isPreset) ?? false
        self.createdAt      = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt      = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// 正文里出现的全部 `{{变量}}` 名(去重、保持首次出现顺序)。
    var variableNames: [String] {
        PromptLibraryStore.extractVariables(from: instructions)
    }
}
