import Foundation

/// Persona(Agent 档案)的持久化与增删改查。
///
/// 存盘沿用 `SkillsStore` / `PromptLibraryStore` 的约定:Application Support 下 App 专属子目录
/// 的一个 JSON 文件,JSONEncoder/JSONDecoder 编解码、日期 `.iso8601`,本地库(不另起 iCloud 容器)。
/// 内置示例只在首启注入一次(seed flag 文件),用户删光也不会被塞回。
@Observable
final class PersonaStore {
    private(set) var personas: [Persona] = []

    private let storeURL: URL
    /// 「已注入过示例 Persona」的标记文件 — 示例可删可改,删了不复活。
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
        self.storeURL = dir.appendingPathComponent("personas.json")
        self.seedFlagURL = dir.appendingPathComponent("personas.seeded")
        load()
        seedPresetsIfNeeded()
    }

    // MARK: - 查询

    func persona(id: UUID?) -> Persona? {
        guard let id else { return nil }
        return personas.first { $0.id == id }
    }

    // MARK: - 内置示例(首启种子,可删改)

    private func seedPresetsIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: seedFlagURL.path) else { return }
        let existingNames = Set(personas.map { $0.name })
        let fresh = Self.presetPersonas.filter { !existingNames.contains($0.name) }
        if !fresh.isEmpty {
            personas.append(contentsOf: fresh)
            save()
        }
        try? Data().write(to: seedFlagURL, options: .atomic)
    }

    // MARK: - 增删改查

    @discardableResult
    func add(_ persona: Persona) -> Persona {
        personas.insert(persona, at: 0)
        save()
        return persona
    }

    func update(_ persona: Persona) {
        guard let idx = personas.firstIndex(where: { $0.id == persona.id }) else { return }
        var updated = persona
        updated.updatedAt = Date()
        personas[idx] = updated
        save()
    }

    func remove(_ persona: Persona) {
        personas.removeAll { $0.id == persona.id }
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([Persona].self, from: data) else { return }
        personas = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(personas) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

// MARK: - 内置示例 Persona

extension PersonaStore {
    /// 稳定 id:同一名字在所有设备上生成同一 UUID(沿用 SkillsStore.presetID 的派生方式)。
    private static func presetID(_ seed: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let scalars = Array("Kown.PersonaPreset.\(seed)".utf8)
        guard !scalars.isEmpty else { return UUID() }
        for (i, b) in scalars.enumerated() {
            bytes[i % 16] = bytes[i % 16] &+ b &+ UInt8((i &* 31) & 0xff)
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// 首启注入的示例 Persona(可删可改)。
    static let presetPersonas: [Persona] = {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            Persona(
                id: presetID("翻译官"),
                name: "翻译官",
                icon: "🌐",
                summary: "精准自然的双向翻译,只输出译文。",
                systemPrompt: """
                你是专业翻译。把用户给出的文本在中英之间互译(或按用户指定的目标语言翻译):
                - 准确传达原意,语气自然地道;
                - 专有名词保留原文或采用通行译法;
                - 保留原文的 Markdown 结构与占位符不动;
                - 只输出译文,不加解释、不加引号。
                """,
                createdAt: epoch, updatedAt: epoch
            ),
            Persona(
                id: presetID("代码审查员"),
                name: "代码审查员",
                icon: "🧐",
                summary: "审 bug、提改进,先列问题再给修复建议。",
                systemPrompt: """
                你是严格但建设性的资深代码审查员。用户给你代码(或 diff)时:
                1. 先扫正确性问题:边界条件、并发、资源泄漏、错误处理、安全隐患,按严重程度排列;
                2. 再提可维护性建议:命名、重复、复杂度、可测性;
                3. 每条问题给出具体修复建议(必要时附改后代码片段);
                4. 没有问题就明说,不要硬凑。
                中文输出,直接、具体,不空泛。
                """,
                createdAt: epoch, updatedAt: epoch
            ),
            Persona(
                id: presetID("研究分析师"),
                name: "研究分析师",
                icon: "📊",
                summary: "先联网检索再综合作答,结论带来源。",
                systemPrompt: """
                你是严谨的研究分析师。回答涉及最新事实、数据、新闻、价格等时效性内容时,
                先用 web_search 检索,再基于检索结果作答,并在正文相应处用 [1][2] 标注来源序号;
                不要凭记忆臆断可验证的信息。结论给出置信度与适用边界。
                """,
                enableWebSearch: true,
                createdAt: epoch, updatedAt: epoch
            ),
        ]
    }()
}
