import Foundation

/// 一条命名的 Prompt 模板。正文里用 `{{变量}}` 占位符,渲染时按名字替换。
struct PromptTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         title: String,
         body: String,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 正文里出现的全部 `{{变量}}` 名(去重、保持首次出现顺序)。
    var variableNames: [String] {
        PromptLibraryStore.extractVariables(from: body)
    }
}

/// Prompt 库 / 模板的持久化与增删改查。
///
/// 存盘沿用其它 Service(ConversationStore / UsageStore)的约定:
/// 写到 Application Support 下 App 专属子目录里的一个 JSON 文件,JSONEncoder/JSONDecoder 编解码,
/// 日期用 `.iso8601`。不另起 iCloud 容器路径。
@Observable
final class PromptLibraryStore {
    private(set) var templates: [PromptTemplate] = []

    /// App 在 Application Support 下的专属子目录(与其它本地存盘同一处)。
    private let storeURL: URL

    /// 「已注入过内置模板」的标记文件。内置预设只在首次启动注入一次;
    /// 用户之后删光模板也不会被重新塞回去(避免「删了又冒出来」)。
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
        self.storeURL = dir.appendingPathComponent("prompt_library.json")
        self.seedFlagURL = dir.appendingPathComponent("prompt_library.seeded")
        load()
        seedPresetsIfNeeded()
    }

    // MARK: - 内置预设

    /// 首次启动注入一批内置模板。判定:标记文件不存在时才注入,且注入后写下标记;
    /// 注入完不再重复(用户删除/改名都会保留,不会被覆盖)。
    private func seedPresetsIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: seedFlagURL.path) else { return }

        // 已有同名模板就跳过对应预设,避免和用户既有模板撞名。
        let existingTitles = Set(templates.map { $0.title })
        let fresh = Self.presetTemplates.filter { !existingTitles.contains($0.title) }
        if !fresh.isEmpty {
            // 预设排在用户已有模板之后(用户自建的更靠前)。
            templates.append(contentsOf: fresh)
            save()
        }
        // 不管这次有没有真注入,都打标记:代表「内置预设已处理过」。
        try? Data().write(to: seedFlagURL, options: .atomic)
    }

    // MARK: - 增删改查

    /// 新建一条模板,返回新建对象(已落盘)。
    @discardableResult
    func add(title: String, body: String) -> PromptTemplate {
        let template = PromptTemplate(title: title, body: body)
        templates.insert(template, at: 0)
        save()
        return template
    }

    /// 更新一条已存在的模板(按 id 匹配),刷新 updatedAt。
    func update(_ template: PromptTemplate) {
        guard let idx = templates.firstIndex(where: { $0.id == template.id }) else { return }
        var updated = template
        updated.updatedAt = Date()
        templates[idx] = updated
        save()
    }

    /// 删除指定模板。
    func remove(_ template: PromptTemplate) {
        templates.removeAll { $0.id == template.id }
        save()
    }

    /// 删除指定下标(列表里 onDelete 用)。
    func remove(atOffsets offsets: IndexSet) {
        templates.remove(atOffsets: offsets)
        save()
    }

    // MARK: - 渲染

    /// 把模板正文里的 `{{变量}}` 用 values 填充。未提供的变量保留原样占位符。
    func render(_ template: PromptTemplate, values: [String: String]) -> String {
        render(template: template.body, values: values)
    }

    /// 把任意带 `{{变量}}` 的文本用 values 填充。未提供的变量保留原样占位符。
    func render(template body: String, values: [String: String]) -> String {
        var result = body
        for name in Self.extractVariables(from: body) {
            guard let value = values[name] else { continue }
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return result
    }

    /// 从文本里抽出全部 `{{变量}}` 名(去重、保持首次出现顺序、去掉首尾空白)。
    static func extractVariables(from body: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{\\s*([^{}]+?)\\s*\\}\\}") else {
            return []
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var seen = Set<String>()
        var names: [String] = []
        regex.enumerateMatches(in: body, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: body) else { return }
            let name = String(body[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(name) else { return }
            seen.insert(name)
            names.append(name)
        }
        return names
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([PromptTemplate].self, from: data) else { return }
        templates = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(templates) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

// MARK: - 内置预设模板

extension PromptLibraryStore {
    /// 用稳定字符串派生一个确定性 UUID,保证同一条预设跨启动/跨设备 id 一致。
    private static func presetID(_ seed: String) -> UUID {
        // 取 seed 的稳定哈希填满 16 字节,组成 UUID(只为去重稳定,不要求符合 RFC 版本位)。
        var bytes = [UInt8](repeating: 0, count: 16)
        let scalars = Array("Kown.PromptPreset.\(seed)".utf8)
        guard !scalars.isEmpty else { return UUID() }
        for (i, b) in scalars.enumerated() {
            bytes[i % 16] = bytes[i % 16] &+ b &+ UInt8((i &* 31) & 0xff)
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func preset(_ title: String, _ body: String) -> PromptTemplate {
        // 固定一个早期 createdAt,让预设排序稳定、且明显早于用户后建的模板。
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        return PromptTemplate(id: presetID(title), title: title, body: body,
                              createdAt: epoch, updatedAt: epoch)
    }

    /// 首次启动注入的内置模板。覆盖写作、办公、编程、学习决策等常用场景,
    /// 正文统一用 `{{变量}}` 占位,渲染时填充。
    static let presetTemplates: [PromptTemplate] = [
        // —— 写作 / 内容 ——
        preset("文章摘要", """
        请阅读下面的内容,用中文提炼一份摘要。
        要求:
        1. 先用一句话概括核心观点;
        2. 再用 {{要点数量}} 条要点列出关键信息,每条不超过 30 字;
        3. 保留原文中的关键数据与结论,不要加入原文没有的内容。

        【原文】
        {{原文内容}}
        """),

        preset("多语言翻译", """
        请把下面的文本翻译成{{目标语言}}。
        要求:
        1. 准确传达原意,语气保持{{语气风格}}(如正式 / 口语 / 营销);
        2. 专有名词、品牌名保留原文或采用通行译法;
        3. 只输出译文,不要解释。

        【原文】
        {{原文}}
        """),

        preset("文章润色与校对", """
        请对下面这段中文进行校对和润色。
        目标读者:{{目标读者}}
        期望风格:{{期望风格}}(如简洁专业 / 亲切口语 / 学术严谨)
        要求:
        1. 修正错别字、语病和标点问题;
        2. 在不改变原意的前提下让表达更流畅、更有条理;
        3. 输出顺序:先给「润色后的全文」,再用要点列出「主要修改点」。

        【原文】
        {{原文}}
        """),

        preset("邮件草拟", """
        请帮我写一封中文邮件。
        收件人:{{收件人}}
        目的:{{邮件目的}}
        关键信息:{{要点}}
        期望语气:{{语气}}(如礼貌正式 / 简洁直接 / 热情友好)
        要求:包含合适的称呼、正文与结尾署名,条理清晰,长度适中。
        署名用:{{我的名字}}
        """),

        preset("会议纪要整理", """
        请把下面这段零散的会议记录整理成规范的会议纪要。
        会议主题:{{会议主题}}
        输出包含以下板块:
        1. 会议概况(主题、参与人、时间——缺失则留空)
        2. 讨论要点(分条)
        3. 形成的决议
        4. 待办事项(任务 / 负责人 / 截止时间 的表格)

        【原始记录】
        {{原始记录}}
        """),

        preset("社交媒体文案", """
        请为「{{产品或主题}}」写一条发布在{{平台}}的中文文案。
        目标人群:{{目标人群}}
        想传达的核心卖点:{{核心卖点}}
        要求:
        1. 风格{{风格}}(如轻松活泼 / 专业干货 / 走心故事);
        2. 给出 3 个不同角度的版本供挑选;
        3. 每版末尾配 3~5 个相关话题标签。
        """),

        preset("小红书种草文案", """
        请以小红书博主的口吻,为「{{产品}}」写一篇种草笔记。
        使用场景:{{使用场景}}
        最打动人的卖点:{{核心卖点}}
        要求:
        1. 取一个有点击欲的标题(可带 emoji);
        2. 正文真实、有细节、像真人分享,分段清晰;
        3. 结尾给出 5~8 个相关话题标签。
        """),

        // —— 编程 / 技术 ——
        preset("代码审查", """
        请作为资深工程师审查下面这段 {{编程语言}} 代码。
        关注点:正确性、边界条件、性能、可读性、安全隐患。
        要求:
        1. 按「问题 → 影响 → 建议改法」列出具体问题,标注严重程度(高/中/低);
        2. 给出关键问题的修改示例;
        3. 最后用一两句话总体评价。

        【代码】
        ```
        {{代码}}
        ```
        """),

        preset("重构建议", """
        请审视下面这段 {{编程语言}} 代码,给出重构建议。
        重构目标:{{重构目标}}(如提升可读性 / 降低复杂度 / 便于测试 / 提升性能)
        要求:
        1. 指出当前设计的问题与坏味道;
        2. 给出重构方案与理由,保持原有行为不变;
        3. 提供重构后的关键代码片段。

        【代码】
        ```
        {{代码}}
        ```
        """),

        preset("Bug 排查", """
        我遇到了一个问题,请帮我定位原因。
        技术栈 / 环境:{{技术栈}}
        期望行为:{{期望行为}}
        实际行为:{{实际行为}}
        报错信息:
        ```
        {{报错信息}}
        ```
        相关代码:
        ```
        {{相关代码}}
        ```
        请按「最可能的原因 → 验证方法 → 修复方案」分层给出排查思路,并说明判断依据。
        """),

        preset("SQL 生成", """
        请根据需求写一条 {{数据库类型}} 的 SQL 查询。
        表结构说明:
        {{表结构}}
        查询需求:{{查询需求}}
        要求:
        1. 只输出可直接执行的 SQL;
        2. 在 SQL 下方用注释简要说明思路与用到的索引建议;
        3. 注意性能,避免不必要的全表扫描。
        """),

        preset("正则表达式生成", """
        请帮我写一个正则表达式。
        目标:匹配 {{匹配目标}}
        需要匹配的示例:{{应匹配示例}}
        不应匹配的示例:{{不应匹配示例}}
        使用环境:{{使用环境}}(如 JavaScript / Python / PCRE)
        要求:给出正则、逐段解释含义,并附一个使用示例。
        """),

        preset("Git 提交信息", """
        请根据下面的改动内容,生成一条符合 Conventional Commits 规范的中文提交信息。
        改动类型倾向:{{类型}}(如 feat / fix / refactor / docs / chore)
        要求:
        1. 首行格式 `类型(作用域): 简短描述`,不超过 50 字;
        2. 必要时空一行后补充正文,说明做了什么、为什么;
        3. 只输出提交信息本身。

        【改动说明】
        {{改动说明}}
        """),

        preset("技术文档撰写", """
        请为「{{主题}}」撰写一份面向{{目标读者}}的技术文档。
        要点 / 已知信息:{{已知信息}}
        文档应包含:
        1. 概述(它是什么、解决什么问题)
        2. 核心概念 / 架构
        3. 使用步骤或示例
        4. 常见问题 / 注意事项
        语言力求准确、简洁、有示例。
        """),

        preset("代码解释", """
        请逐步解释下面这段 {{编程语言}} 代码的作用。
        读者水平:{{读者水平}}(如初学者 / 有经验)
        要求:
        1. 先一句话说明整体功能;
        2. 再按逻辑分段解释关键部分;
        3. 指出其中值得注意的技巧或潜在坑。

        【代码】
        ```
        {{代码}}
        ```
        """),

        preset("单元测试生成", """
        请为下面这段 {{编程语言}} 代码编写单元测试。
        测试框架:{{测试框架}}
        要求:
        1. 覆盖正常路径、边界条件和异常情况;
        2. 每个用例命名清晰、断言明确;
        3. 必要时说明还需补充哪些难以覆盖的场景。

        【被测代码】
        ```
        {{代码}}
        ```
        """),

        // —— 学习 / 决策 / 思考 ——
        preset("学习计划制定", """
        我想学习「{{学习目标}}」。
        当前基础:{{当前基础}}
        每周可投入时间:{{每周时间}}
        期望达成时间:{{期望周期}}
        请制定一份循序渐进的学习计划:
        1. 分阶段列出学习内容与里程碑;
        2. 每阶段推荐资源与练习项目;
        3. 给出检验是否掌握的标准。
        """),

        preset("概念通俗解释", """
        请把「{{概念}}」解释给{{对象}}听(如小学生 / 没有背景的成年人)。
        要求:
        1. 用一个贴近生活的比喻打底;
        2. 避免术语,必须用时先解释;
        3. 最后用一句话总结它的本质。
        """),

        preset("面试准备", """
        我在准备「{{岗位}}」的面试。
        我的背景:{{个人背景}}
        请帮我准备:
        1. 列出该岗位高频考察的 {{题目数量}} 个问题(技术 + 行为);
        2. 针对其中关键问题给出回答思路与要点;
        3. 提示常见的加分项与避坑点。
        """),

        preset("利弊分析", """
        我正在考虑:{{决策内容}}。
        背景与约束:{{背景约束}}
        我看重的因素:{{看重因素}}
        请帮我做一份理性的利弊分析:
        1. 分别列出主要的「利」与「弊」;
        2. 评估每一点的影响程度;
        3. 给出一个有理由的倾向性建议,并说明在什么情况下应改变选择。
        """),

        preset("决策矩阵", """
        请帮我用决策矩阵从多个选项中做选择。
        待选项:{{候选选项}}
        评估维度:{{评估维度}}(如成本、收益、风险、时间)
        各维度的相对重要性:{{权重说明}}
        要求:
        1. 用表格给每个选项在各维度打分(1~5)并按权重加权;
        2. 算出总分并排序;
        3. 给出结论和需要注意的风险点。
        """),

        preset("头脑风暴", """
        请围绕「{{主题}}」帮我做头脑风暴。
        背景 / 目标:{{背景目标}}
        约束条件:{{约束条件}}
        要求:
        1. 给出至少 {{点子数量}} 个有差异的点子,从常规到大胆都要有;
        2. 每个点子配一句话说明亮点和落地难点;
        3. 最后挑出最值得先尝试的 3 个并说明理由。
        """),

        preset("费曼式追问讲解", """
        请用费曼学习法帮我真正搞懂「{{主题}}」。
        我目前的理解:{{我的理解}}
        请:
        1. 指出我的理解里不准确或缺失的地方;
        2. 用最简单的语言重新讲清楚,配一个例子;
        3. 提 3 个能检验我是否真懂的问题。
        """),

        preset("周报总结", """
        请根据下面的零散记录,帮我整理成一份条理清晰的中文周报。
        岗位 / 项目:{{岗位项目}}
        输出包含:
        1. 本周完成(分条,突出成果与数据)
        2. 进行中 / 遇到的问题
        3. 下周计划
        语气专业、简洁,适合发给上级。

        【本周记录】
        {{本周记录}}
        """),
    ]
}
