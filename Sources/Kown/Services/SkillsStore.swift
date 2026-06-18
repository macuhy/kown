import Foundation

/// 技能库的持久化与增删改查。
///
/// 存盘沿用 `PromptLibraryStore` 的约定:Application Support 下 App 专属子目录的一个 JSON 文件,
/// JSONEncoder/JSONDecoder 编解码、日期 `.iso8601`。和 Prompt 库一样属本地库(不另起 iCloud 容器)。
@MainActor
@Observable
final class SkillsStore {
    private(set) var skills: [Skill] = []

    private let storeURL: URL
    /// 「已注入过内置技能」的标记文件——预设只首启注入一次,用户删光也不会被塞回。
    private let seedFlagURL: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Kown", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("skills.json")
        self.seedFlagURL = dir.appendingPathComponent("skills.seeded")
        load()
        seedPresetsIfNeeded()
    }

    // MARK: - 查询

    /// 已启用的技能(自动触发 / 手动选择都只看这些)。
    var enabledSkills: [Skill] { skills.filter { $0.enabled } }

    func skill(id: UUID?) -> Skill? {
        guard let id else { return nil }
        return skills.first { $0.id == id }
    }

    // MARK: - 内置预设

    private func seedPresetsIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: seedFlagURL.path) else { return }
        let existingNames = Set(skills.map { $0.name })
        let fresh = Self.presetSkills.filter { !existingNames.contains($0.name) }
        if !fresh.isEmpty {
            skills.append(contentsOf: fresh)
            save()
        }
        try? Data().write(to: seedFlagURL, options: .atomic)
    }

    // MARK: - 增删改查

    @discardableResult
    func add(_ skill: Skill) -> Skill {
        skills.insert(skill, at: 0)
        save()
        scheduleTriggerPhraseSynthesis(for: skill)
        return skill
    }

    @discardableResult
    func upsert(_ skill: Skill) -> Skill {
        guard let idx = skills.firstIndex(where: { $0.id == skill.id }) else {
            return add(skill)
        }
        let old = skills[idx]
        var updated = skill
        updated.createdAt = old.createdAt
        updated.updatedAt = Date()
        skills[idx] = updated
        save()
        if old.name != updated.name || old.summary != updated.summary
            || old.keywords != updated.keywords || old.instructions != updated.instructions {
            scheduleTriggerPhraseSynthesis(for: updated)
        }
        return updated
    }

    func update(_ skill: Skill) {
        guard let idx = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        let old = skills[idx]
        var updated = skill
        updated.updatedAt = Date()
        skills[idx] = updated
        save()
        // 只有触发匹配相关字段变了才值得重算同义触发说法(避免每次小编辑都打模型)。
        if old.name != updated.name || old.summary != updated.summary
            || old.keywords != updated.keywords || old.instructions != updated.instructions {
            scheduleTriggerPhraseSynthesis(for: updated)
        }
    }

    /// 后台用便宜模型为技能生成 ≤15 条同义触发说法,完成后写回该技能的 `triggerPhrases`。
    /// 无可用 provider / 超时 / 失败 → 静默保持原样(保存永不因此变慢或失败)。
    /// 直接改数组、不走 `update()`,避免触发递归再生成。
    private func scheduleTriggerPhraseSynthesis(for skill: Skill) {
        guard !isRunningUnderXCTest else { return }
        let snapshot = skill
        Task { [weak self] in
            // synthesize 是 nonisolated async,自动跳出主线程跑模型调用,不卡 UI。
            guard let phrases = await SkillTriggerSynthesizer.synthesize(for: snapshot) else { return }
            guard let self else { return }
            // 期间技能可能被改/删:按 id 重新定位,且确认触发相关字段未变(否则这批已过期)。
            guard let idx = self.skills.firstIndex(where: { $0.id == snapshot.id }) else { return }
            let cur = self.skills[idx]
            guard cur.name == snapshot.name, cur.summary == snapshot.summary,
                  cur.keywords == snapshot.keywords, cur.instructions == snapshot.instructions else { return }
            guard cur.triggerPhrases != phrases else { return }
            self.skills[idx].triggerPhrases = phrases
            self.save()
        }
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[idx].enabled = enabled
        skills[idx].updatedAt = Date()
        save()
    }

    /// 删除技能。预设不可删除(只能禁用),静默忽略。
    func remove(_ skill: Skill) {
        guard let existing = skills.first(where: { $0.id == skill.id }), !existing.isPreset else { return }
        skills.removeAll { $0.id == skill.id }
        save()
    }

    /// 渲染技能正文里的 `{{变量}}`(复用 Prompt 库的占位逻辑)。
    func render(_ skill: Skill, values: [String: String]) -> String {
        var result = skill.instructions
        for name in PromptLibraryStore.extractVariables(from: skill.instructions) {
            guard let value = values[name] else { continue }
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return result
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([Skill].self, from: data) else { return }
        skills = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(skills) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

// MARK: - 内置预设技能

extension SkillsStore {
    private static func presetID(_ seed: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let scalars = Array("Kown.SkillPreset.\(seed)".utf8)
        guard !scalars.isEmpty else { return UUID() }
        for (i, b) in scalars.enumerated() {
            bytes[i % 16] = bytes[i % 16] &+ b &+ UInt8((i &* 31) & 0xff)
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func preset(_ name: String, summary: String, instructions: String,
                               keywords: [String], allowedTools: [String]) -> Skill {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        return Skill(id: presetID(name), name: name, summary: summary,
                     instructions: instructions, keywords: keywords,
                     allowedTools: allowedTools, enabled: true, isPreset: true,
                     createdAt: epoch, updatedAt: epoch)
    }

    /// 首启注入的内置技能。覆盖「提醒 / 备忘 / 联网研究 / 翻译」几个高频场景。
    static let presetSkills: [Skill] = [
        preset(
            "提醒助手",
            summary: "把用户口语里的待办转成系统「提醒事项」,自动算好相对时间。",
            instructions: """
            你是用户的提醒助理。当用户表达「记得做某事 / 到点提醒我 / 别忘了」这类意图时,\
            调用 create_reminder 工具创建一条提醒。
            - 标题简洁明确(动宾结构),不要把整句口语原样塞进标题。
            - 如果用户给了时间(含「明天 / 下周一 / 晚上 8 点」等相对时间),换算成 ISO 8601 \
            本地时间填进 due 参数;系统提示里已给出当前时间,以它为基准换算。
            - 时间不明确就先简短追问,别瞎猜。
            创建成功后用一句话向用户确认。
            """,
            keywords: ["提醒", "记得", "别忘", "到点", "叫我", "闹钟", "deadline", "截止", "remind", "reminder", "待办", "todo"],
            allowedTools: ["create_reminder", "list_reminders"]
        ),
        preset(
            "备忘记录",
            summary: "把要点整理后存进系统「备忘录」。",
            instructions: """
            你帮用户把内容整理成一条结构清晰的备忘。当用户说「记一下 / 存到备忘录 / 帮我记笔记」时,\
            先把内容精炼成「标题 + 要点」,再调用 create_note 工具写入。
            - 标题一行概括主题。
            - 正文用简短分条,保留关键信息。
            创建后用一句话确认(若处于需要用户粘贴的降级场景,按工具回执如实告知)。
            """,
            keywords: ["备忘", "记一下", "记笔记", "笔记", "记录", "存一下", "note"],
            allowedTools: ["create_note"]
        ),
        preset(
            "研究助手",
            summary: "先联网检索再综合作答,给出带来源的结论。",
            instructions: """
            你是严谨的研究助手。回答涉及最新事实、数据、新闻、价格等可能变化的信息时,\
            先调用 web_search 检索,再基于检索结果作答,并在正文相应处用 [1][2] 标注来源序号。\
            不要凭记忆臆断时效性内容。
            """,
            keywords: ["查", "搜", "最新", "新闻", "价格", "行情", "research", "search", "近况"],
            allowedTools: ["web_search"]
        ),
        preset(
            "翻译官",
            summary: "精准、自然的双向翻译,只输出译文。",
            instructions: """
            你是专业翻译。把用户给出的文本在中英之间互译(或按用户指定的目标语言翻译):
            - 准确传达原意,语气自然地道;
            - 专有名词保留原文或采用通行译法;
            - 只输出译文,不加解释、不加引号。
            """,
            keywords: ["翻译", "translate", "译成", "英译", "中译"],
            allowedTools: []
        ),
    ]
}
