import Foundation
import Observation

/// `.kownskill` 包的导入、导出与本地安装列表。
///
/// - 单个包文件:一个 `SkillPackage` JSON 对象,建议扩展名 `.kownskill`。
/// - 本地安装列表:`Application Support/Kown/skill-packages.json`,保存 `[SkillPackage]`。
/// - 内置推荐包不直接写盘,用户点「导入/安装」后才进入 `installedPackages`。
@MainActor
@Observable
final class SkillPackageStore {
    enum StoreError: LocalizedError, Equatable {
        case unsupportedFormatVersion(Int)
        case emptyPackage
        case packageNotFound(UUID)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormatVersion(let version):
                return "不支持的 .kownskill 格式版本: \(version)"
            case .emptyPackage:
                return "技能包至少需要一个提示词"
            case .packageNotFound(let id):
                return "找不到技能包: \(id.uuidString)"
            }
        }
    }

    private(set) var installedPackages: [SkillPackage] = []

    private let storeURL: URL

    init(storeURL: URL? = nil, loadFromDisk: Bool = true) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let fm = FileManager.default
            let base = (try? fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true))
                ?? fm.temporaryDirectory
            let dir = base.appendingPathComponent("Kown", isDirectory: true)
            self.storeURL = dir.appendingPathComponent("skill-packages.json")
        }

        if loadFromDisk {
            load()
        }
    }

    var marketPackages: [SkillPackage] {
        let installedIDs = Set(installedPackages.map(\.id))
        return installedPackages + Self.recommendedPackages.filter { !installedIDs.contains($0.id) }
    }

    var recommendedPackages: [SkillPackage] {
        Self.recommendedPackages
    }

    func package(id: UUID?) -> SkillPackage? {
        guard let id else { return nil }
        return marketPackages.first { $0.id == id }
    }

    func isInstalled(_ package: SkillPackage) -> Bool {
        installedPackages.contains { $0.id == package.id }
    }

    @discardableResult
    func install(_ package: SkillPackage) -> SkillPackage {
        var installed = package
        if installed.source == .local {
            installed.source = .imported
        }

        if let idx = installedPackages.firstIndex(where: { $0.id == installed.id }) {
            installedPackages[idx] = installed
        } else {
            installedPackages.insert(installed, at: 0)
        }
        save()
        return installed
    }

    func remove(_ package: SkillPackage) {
        installedPackages.removeAll { $0.id == package.id }
        save()
    }

    @discardableResult
    func importPackage(from data: Data) throws -> SkillPackage {
        let package = try Self.decodePackage(from: data)
        return install(package)
    }

    @discardableResult
    func importPackage(from url: URL) throws -> SkillPackage {
        let data = try Data(contentsOf: url)
        return try importPackage(from: data)
    }

    func exportData(for package: SkillPackage) throws -> Data {
        guard self.package(id: package.id) != nil else {
            throw StoreError.packageNotFound(package.id)
        }
        return try Self.encode(package)
    }

    func exportData(for id: UUID) throws -> Data {
        guard let package = package(id: id) else {
            throw StoreError.packageNotFound(id)
        }
        return try Self.encode(package)
    }

    func exportPackage(_ package: SkillPackage, to url: URL) throws {
        let data = try exportData(for: package)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? Self.decoder.decode([SkillPackage].self, from: data) else {
            installedPackages = []
            return
        }
        installedPackages = decoded
    }

    func save() {
        guard let data = try? Self.encoder.encode(installedPackages) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    static func encode(_ package: SkillPackage) throws -> Data {
        try validate(package)
        return try encoder.encode(package)
    }

    static func decodePackage(from data: Data) throws -> SkillPackage {
        let package = try decoder.decode(SkillPackage.self, from: data)
        try validate(package)
        return package
    }

    static func suggestedExportFilename(for package: SkillPackage) -> String {
        let safeName = package.displayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safeName.isEmpty ? "skill-package" : safeName
        return "\(base).\(SkillPackage.fileExtension)"
    }

    private static func validate(_ package: SkillPackage) throws {
        guard package.formatVersion <= SkillPackage.currentFormatVersion else {
            throw StoreError.unsupportedFormatVersion(package.formatVersion)
        }
        guard !package.prompts.isEmpty else {
            throw StoreError.emptyPackage
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - 内置推荐包

extension SkillPackageStore {
    static let examplePackage: SkillPackage = {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        return SkillPackage(
            id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            metadata: .init(
                name: "示例技能包-需求澄清助手",
                summary: "把模糊需求整理成目标、用户、边界、风险和待确认问题。",
                author: "Kown",
                version: "1.0.0",
                tags: ["示例", "需求", "PRD", "澄清"],
                minKownVersion: "0.1.0",
                createdAt: epoch,
                updatedAt: epoch
            ),
            prompts: [
                .init(title: "需求澄清系统提示词", template: """
                你是产品需求澄清助手。围绕用户提供的「{{需求描述}}」输出结构化分析:
                1. 用一句话重述目标;
                2. 列出目标用户、核心场景和非目标边界;
                3. 提取已知约束、潜在风险和依赖;
                4. 给出 5 个最应该追问的问题;
                5. 最后整理成可复制到 PRD 的 Markdown 小节。
                不要编造用户没有提供的事实;缺失信息放到「待确认」。
                """)
            ],
            variables: [
                .init(name: "需求描述", summary: "用户原始需求、会议记录或想法草稿")
            ],
            examples: [
                .init(
                    title: "模糊需求澄清",
                    input: "需求描述 = 我想做一个能自动整理客户访谈的功能",
                    output: "输出目标、场景、边界、风险和待确认问题。"
                )
            ],
            requiredToolPermissions: [],
            personaReferences: [
                .init(name: "产品经理", summary: "适合产品规划、需求拆解和 PRD 初稿。")
            ],
            promptChainReferences: [
                .init(name: "澄清 → 拆解 → PRD", summary: "先追问关键缺口,再拆成功能范围。", stepTitles: ["澄清", "拆解", "PRD"])
            ],
            source: .local
        )
    }()

    static let recommendedPackages: [SkillPackage] = {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            SkillPackage(
                id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                metadata: .init(
                    name: "联网研究简报",
                    summary: "先检索最新资料,再输出带来源、风险和下一步建议的研究简报。",
                    author: "Kown",
                    version: "1.0.0",
                    tags: ["研究", "搜索", "简报", "web_search"],
                    minKownVersion: "0.1.0",
                    createdAt: epoch,
                    updatedAt: epoch
                ),
                prompts: [
                    .init(title: "研究简报系统提示词", template: """
                    你是严谨的研究助理。围绕用户主题「{{主题}}」完成研究简报:
                    1. 先调用 web_search 搜索最新且可信的资料;
                    2. 区分事实、推断和不确定信息;
                    3. 输出「结论摘要 / 关键证据 / 分歧与风险 / 下一步建议」;
                    4. 对每条关键结论标注来源序号。
                    """)
                ],
                variables: [
                    .init(name: "主题", summary: "要研究的问题或对象")
                ],
                examples: [
                    .init(title: "市场跟踪", input: "主题 = 2026 年端侧 AI 设备趋势", output: "输出一页研究简报,含来源与风险。")
                ],
                requiredToolPermissions: [
                    .init(toolName: "web_search",
                          displayName: "联网搜索",
                          reason: "检索最新资料并生成可追溯来源。",
                          category: .network,
                          riskLevel: .medium)
                ],
                personaReferences: [
                    .init(name: "研究员", summary: "适合需要证据链和来源标注的研究型 Persona。")
                ],
                promptChainReferences: [
                    .init(name: "检索 → 归纳 → 风险审查", summary: "先收集资料,再综合,最后检查遗漏。", stepTitles: ["检索", "归纳", "风险审查"])
                ],
                source: .builtin
            ),
            SkillPackage(
                id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                metadata: .init(
                    name: "会议行动项整理",
                    summary: "把会议纪要转成负责人、截止时间和后续提醒清单。",
                    author: "Kown",
                    version: "1.0.0",
                    tags: ["会议", "行动项", "提醒", "create_reminder"],
                    minKownVersion: "0.1.0",
                    createdAt: epoch,
                    updatedAt: epoch
                ),
                prompts: [
                    .init(title: "行动项抽取", template: """
                    你负责把会议内容整理成可执行行动项。输入是「{{会议记录}}」。
                    - 提取每个行动项的任务、负责人、截止时间和上下文;
                    - 截止时间明确时,可调用 create_reminder 创建提醒;
                    - 时间不明确时不要臆测,把它列入「需确认」;
                    - 最后输出 Markdown 表格。
                    """)
                ],
                variables: [
                    .init(name: "会议记录", summary: "原始会议转写或人工纪要")
                ],
                examples: [
                    .init(title: "周会纪要", input: "会议记录 = 下周三前 Alice 给出方案...", output: "输出行动项表格,并为明确日期创建提醒。")
                ],
                requiredToolPermissions: [
                    .init(toolName: "create_reminder",
                          displayName: "创建提醒",
                          reason: "为明确截止时间的行动项创建系统提醒。",
                          category: .deviceTool,
                          riskLevel: .medium)
                ],
                personaReferences: [
                    .init(name: "会议秘书", summary: "适合会后整理、追踪承诺和生成行动清单。")
                ],
                promptChainReferences: [
                    .init(name: "纪要 → 行动项 → 提醒", summary: "从原文归纳任务,确认时间后创建提醒。", stepTitles: ["纪要清洗", "行动项抽取", "提醒创建"])
                ],
                source: .builtin
            ),
            SkillPackage(
                id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                metadata: .init(
                    name: "双语润色翻译",
                    summary: "在保留语气的前提下翻译并润色中英文文本。",
                    author: "Kown",
                    version: "1.0.0",
                    tags: ["翻译", "润色", "双语"],
                    minKownVersion: "0.1.0",
                    createdAt: epoch,
                    updatedAt: epoch
                ),
                prompts: [
                    .init(title: "翻译润色", template: """
                    你是专业双语编辑。请把「{{原文}}」翻译成「{{目标语言}}」。
                    要求:
                    - 保留原意和语气,不要增删事实;
                    - 术语采用目标语言里的通行表达;
                    - 如果原文有明显病句,在译文中自然修正;
                    - 只输出译文。
                    """)
                ],
                variables: [
                    .init(name: "原文", summary: "待翻译文本"),
                    .init(name: "目标语言", defaultValue: "英文", isRequired: true)
                ],
                examples: [
                    .init(title: "产品文案", input: "目标语言 = 英文; 原文 = 帮你把碎片知识变成长期资产。", output: "只输出自然英文译文。")
                ],
                requiredToolPermissions: [],
                personaReferences: [
                    .init(name: "翻译官", summary: "适合需要稳定翻译风格的 Persona。")
                ],
                promptChainReferences: [
                    .init(name: "直译 → 润色 → 术语检查", summary: "需要高质量文本时可拆成三步。", stepTitles: ["直译", "润色", "术语检查"])
                ],
                source: .builtin
            )
        ]
    }()
}
