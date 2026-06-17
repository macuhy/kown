import Foundation

/// 深度研究引擎(Direct 模式的「深度研究」子模式)。
///
/// 编排「大纲 → 搜索 → 抓取正文 → 提炼 → 缺口自查 → 再搜索」的多轮循环,最终综合成
/// 带小节结构、引用角标 [n] 与参考文献列表的长报告。设计原则:**最大化复用现有积木**——
/// - 搜索/抓取走 `FirecrawlClient`(与 web_search 工具同一条管线);
/// - 进度以 `ToolStep` 写进 `ResponseState.toolSteps`,由 `AgentStepsView` 按轮渲染成步骤树;
/// - 来源以 `SourceRef` 上报(顺序即引用编号),正文 [n] 角标由 `citationLinkified` 点击直达;
/// - 中途取消复用发送取消机制:引擎跑在 `runningTask` 里,各阶段检查 `Task.isCancelled`。
@MainActor
final class DeepResearchEngine {
    typealias Redactor = (ProviderConfig, inout String, inout ChatOptions) -> PIIRedactor.StreamingRestorer?

    // MARK: - 可调常量

    /// 研究轮数上限(第 1 轮 = 大纲子问题,之后每轮 = 上一轮自查出的缺口)。
    static let maxRounds = 5
    /// 大纲最多拆几个子问题(提示词与解析端共用)。
    static let maxSubQuestions = 6
    /// 每轮缺口自查最多补几个新子问题(防发散)。
    static let maxGapQuestions = 3
    /// 每个子问题最多抓几个来源正文。
    static let sourcesPerSubQuestion = 3
    /// 每次搜索取几条候选结果。
    static let searchLimit = 5
    /// 单个来源正文截断长度(字符),控制提炼调用的 token 开销。
    static let maxScrapeChars = 5000
    /// 全程来源数量封顶(参考文献不至于失控)。
    static let maxTotalSources = 24

    // MARK: - 依赖

    private let provider: ProviderConfig
    private let apiKey: String
    private let web: WebSearchSession
    /// 直播状态:大纲/报告流进 `text`,步骤进 `toolSteps`,token 累加进 usage 字段。
    private let state: ResponseState
    /// 新来源上报(已全局去重、顺序即引用编号),由调用方并入 liveSources / state.sources。
    private let onSources: ([SourceRef]) -> Void
    /// 步骤状态上报,供 AgentRunStore 等长期运行记录同步进度。
    private let onStep: (ToolStep) -> Void
    /// 复用主发送链路的 PII 出站脱敏/流式还原策略。
    private let redactor: Redactor?

    /// 全局编号的来源列表(index + 1 = 引用编号 [n]),与上报给 UI 的顺序严格一致。
    private var sources: [SourceRef] = []
    /// 已访问过的 URL(跨轮去重,避免重复抓同一页)。
    private var visitedURLs: Set<String> = []
    /// 每个子问题提炼出的研究笔记(含 [n] 角标),综合报告的唯一事实来源。
    private var notes: [(question: String, digest: String)] = []

    init(provider: ProviderConfig,
         apiKey: String,
         web: WebSearchSession,
         state: ResponseState,
         onSources: @escaping ([SourceRef]) -> Void,
         onStep: @escaping (ToolStep) -> Void = { _ in },
         redactor: Redactor? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.web = web
        self.state = state
        self.onSources = onSources
        self.onStep = onStep
        self.redactor = redactor
    }

    // MARK: - 主流程

    /// 跑完整个深度研究循环。返回的 error 非 nil 表示失败/取消(报告可能不完整);
    /// 产出的文本已经流式写进 `state.text`(大纲 → 报告 → 参考文献)。
    func run(question: String, systemPrompt: String) async -> (sources: [SourceRef], error: String?) {
        do {
            // 1) 研究大纲:拆 3-6 个子问题,直接展示(MVP 不阻塞等确认)。
            var pending = try await makeOutline(question: question)
            // 2) 逐轮:每个子问题 搜索→抓取→提炼;轮末自查缺口,有缺口且未到上限则续轮。
            var round = 0
            while !pending.isEmpty && round < Self.maxRounds {
                try Task.checkCancellation()
                for sub in pending {
                    try Task.checkCancellation()
                    await research(subQuestion: sub, round: round)
                }
                round += 1
                // 已到最后一轮就不再自查(查了也没机会补)。
                guard round < Self.maxRounds, sources.count < Self.maxTotalSources else { break }
                pending = try await findGaps(question: question, round: round - 1)
            }
            // 3) 综合报告:小节结构 + [n] 角标,流式写进 state.text;参考文献程序化追加保证编号一致。
            try await synthesizeReport(question: question, systemPrompt: systemPrompt, round: max(0, round - 1))
            appendReferences()
            return (sources, nil)
        } catch is CancellationError {
            return (sources, "已取消")
        } catch {
            return (sources, "深度研究失败:\(error.localizedDescription)")
        }
    }

    // MARK: - 阶段一:研究大纲

    /// 让模型把研究问题拆成 3-6 个可检索的子问题,并把大纲直接展示进正文。
    private func makeOutline(question: String) async throws -> [String] {
        let step = beginStep(round: 0, tool: "research_outline", args: String(question.prefix(60)))
        let prompt = """
        你是一名严谨的研究助理。请把下面的研究问题拆解成 \(Self.maxSubQuestions) 个以内(至少 3 个)\
        相互独立、可分别拿去搜索引擎检索的子问题。
        只输出一个 JSON 字符串数组(每个元素是一个子问题),不要输出任何其他文字或代码块标记。

        研究问题:\(question)
        """
        let raw = try await llmText(prompt: prompt, system: nil, temperature: 0.2)
        var subs = Self.parseStringArray(raw)
        if subs.isEmpty {
            // 解析失败兜底:退化为单子问题(原问题本身),研究仍能进行。
            subs = [question]
        }
        subs = Array(subs.prefix(Self.maxSubQuestions))
        finishStep(step, summary: "✓ 已拆解 \(subs.count) 个子问题")
        // 大纲直接展示(随报告一起留在正文里,带编号小节)。
        var outline = "## 研究大纲\n\n"
        for (i, s) in subs.enumerated() { outline += "\(i + 1). \(s)\n" }
        state.append(outline)
        return subs
    }

    // MARK: - 阶段二:单个子问题的 搜索 → 抓取 → 提炼

    /// 对一个子问题完成「搜索 → 选 2-3 个来源抓正文 → 提炼要点(带 [n] 角标)」。
    /// 任一环节失败都不会中断整体研究:失败的步骤标红,继续下一步。
    private func research(subQuestion: String, round: Int) async {
        let client = FirecrawlClient(baseURL: web.config.baseURL, apiKey: web.apiKey)

        // 1) 搜索(步骤名复用 web_search,UI 显示「联网搜索」)。
        let searchStep = beginStep(round: round, tool: "web_search", args: "query: \(String(subQuestion.prefix(60)))")
        let hits: [FirecrawlSearchHit]
        do {
            hits = try await client.search(query: subQuestion, limit: Self.searchLimit)
            finishStep(searchStep, summary: "✓ 找到 \(hits.count) 条结果")
        } catch {
            failStep(searchStep, summary: "⚠ 搜索失败: \(error.localizedDescription)")
            return
        }

        // 2) 选取未访问过的前 N 个来源抓正文;全失败时降级用搜索摘要作材料。
        var materials: [(index: Int, title: String, text: String)] = []
        let fresh = hits.filter { !visitedURLs.contains($0.url) && $0.url.hasPrefix("http") }
        for hit in fresh.prefix(Self.sourcesPerSubQuestion) {
            if Task.isCancelled { return }
            guard sources.count < Self.maxTotalSources else { break }
            visitedURLs.insert(hit.url)
            let scrapeStep = beginStep(round: round, tool: "research_scrape",
                                       args: Self.domain(of: hit.url))
            do {
                let page = try await client.scrape(url: hit.url)
                let text = String(page.markdown.prefix(Self.maxScrapeChars))
                let n = registerSource(SourceRef(title: page.title, url: hit.url, snippet: hit.description))
                materials.append((n, page.title, text))
                finishStep(scrapeStep, summary: "✓ 抓到正文 \(text.count) 字 → 引用 [\(n)]")
            } catch {
                // 抓不到正文(反爬/超时)降级用搜索摘要,引用编号照常分配。
                if !hit.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let n = registerSource(SourceRef(title: hit.title, url: hit.url, snippet: hit.description))
                    materials.append((n, hit.title, hit.description))
                    failStep(scrapeStep, summary: "⚠ 正文抓取失败,降级用搜索摘要 → 引用 [\(n)]")
                } else {
                    failStep(scrapeStep, summary: "⚠ 抓取失败: \(error.localizedDescription)")
                }
            }
        }
        guard !materials.isEmpty else { return }

        // 3) 提炼要点(记录来源编号,综合阶段只看笔记不看原文,控制 token)。
        let digestStep = beginStep(round: round, tool: "research_digest",
                                   args: String(subQuestion.prefix(60)))
        let blocks = materials.map { "[\($0.index)] 【\($0.title)】\n\($0.text)" }
            .joined(separator: "\n\n---\n\n")
        let prompt = """
        你是一名研究助理,正在调查子问题:「\(subQuestion)」
        下面是若干网页材料,每段开头标注了全局引用编号 [n]。请提炼与子问题相关的关键事实、\
        数据与观点,输出中文条目式要点:
        - 每条要点末尾必须用对应编号角标标注来源,如 [3] 或 [3][5];
        - 只保留与研究有关的信息,忽略导航/广告等噪音;尽量保留具体数字、日期与出处;
        - 若材料确实没有有用信息,只输出一行:(本组来源无有效信息)。

        \(blocks)
        """
        do {
            let digest = try await llmText(prompt: prompt, system: nil, temperature: 0.3)
            notes.append((subQuestion, digest))
            finishStep(digestStep, summary: "✓ 提炼出 \(digest.count) 字要点")
        } catch {
            failStep(digestStep, summary: "⚠ 提炼失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 阶段三:缺口自查

    /// 一轮结束后让模型回看笔记找缺口;返回新一批可检索子问题(空 = 信息已足够)。
    private func findGaps(question: String, round: Int) async throws -> [String] {
        guard !notes.isEmpty else { return [] }
        let step = beginStep(round: round, tool: "research_gap", args: "")
        let prompt = """
        原始研究问题:\(question)

        已完成的研究笔记(含来源编号):
        \(notesBlock())

        请自查:要写出一份完整、严谨的研究报告,上述笔记还缺哪些关键信息(未覆盖的方面、\
        矛盾待核实的数据、缺失的对比维度)?
        只输出一个 JSON 字符串数组,每个元素是一个**可直接拿去搜索**的新子问题;\
        最多 \(Self.maxGapQuestions) 个;若信息已足够,输出空数组 []。不要输出任何其他文字。
        """
        let raw = try await llmText(prompt: prompt, system: nil, temperature: 0.2)
        let gaps = Array(Self.parseStringArray(raw).prefix(Self.maxGapQuestions))
        finishStep(step, summary: gaps.isEmpty
            ? "✓ 自查通过,信息已足够"
            : "✓ 发现 \(gaps.count) 个缺口,继续下一轮")
        return gaps
    }

    // MARK: - 阶段四:综合报告 + 参考文献

    /// 把所有研究笔记综合成结构化长报告,流式写进 `state.text`(用户实时看到报告生成)。
    private func synthesizeReport(question: String, systemPrompt: String, round: Int) async throws {
        let step = beginStep(round: round, tool: "research_report", args: "")
        guard !notes.isEmpty else {
            failStep(step, summary: "⚠ 没有可用的研究笔记")
            state.append("\n\n(深度研究未能收集到有效资料,请检查网络搜索配置后重试。)\n")
            return
        }
        let prompt = """
        请基于以下研究笔记,撰写一份结构化的深度研究报告(中文 Markdown):
        - 用 `## ` 小节组织全文(开头一段简短引言、结尾一节结论与展望,中间小节标题自拟、贴合内容);
        - 正文中每个有来源支撑的论断,在句末用笔记里的编号角标标注,如 [2] 或 [2][7],编号必须沿用笔记原编号;
        - 不要编造笔记之外的事实;证据不足之处明确指出「证据有限」;
        - 不要自己写参考文献列表(系统会按编号自动附上);
        - 直接输出报告正文,不要客套开场白。

        原始研究问题:\(question)

        研究笔记:
        \(notesBlock())
        """
        state.append("\n\n---\n\n")
        _ = try await llmText(prompt: prompt,
                              system: systemPrompt.isEmpty ? nil : systemPrompt,
                              temperature: provider.temperature,
                              streamIntoState: true)
        finishStep(step, summary: "✓ 报告完成")
    }

    /// 程序化追加参考文献(编号与 `sources` 顺序严格一致,杜绝模型写错编号)。
    private func appendReferences() {
        guard !sources.isEmpty else { return }
        var refs = "\n\n## 参考文献\n\n"
        for (i, s) in sources.enumerated() {
            let title = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
            refs += "\(i + 1). \(title.isEmpty ? s.url : title) — \(s.url)\n"
        }
        state.append(refs)
    }

    // MARK: - 基础设施

    /// 单次 LLM 调用,收集全文返回;`streamIntoState` 时同步流进 `state.text`(报告阶段用)。
    /// token 用量累加进 state(整次研究的总成本),并记一笔 UsageStore。
    private func llmText(prompt: String,
                         system: String?,
                         temperature: Double?,
                         streamIntoState: Bool = false) async throws -> String {
        let client = ProviderRegistry.client(for: provider.kind)
        var outboundPrompt = prompt
        var options = ChatOptions(systemPrompt: system,
                                  temperature: temperature,
                                  maxTokens: provider.maxTokens)
        let restorer = redactor?(provider, &outboundPrompt, &options)
        var collected = ""
        for try await chunk in client.stream(prompt: outboundPrompt, options: options,
                                             config: provider, apiKey: apiKey) {
            try Task.checkCancellation()
            switch chunk {
            case .text(let t):
                let text = restorer?.push(t) ?? t
                collected += text
                if streamIntoState { state.append(text) }
            case .reasoning(let r):
                // 思考过程只在报告阶段透出(中间小调用的思考混进来会很乱)。
                if streamIntoState { state.appendReasoning(r) }
            case .usage(let input, let output, let cached):
                state.inputTokens += input
                state.outputTokens += output
                state.cachedInputTokens += cached
                UsageStore.shared.record(providerKind: provider.kind, model: provider.model,
                                         inputTokens: input, outputTokens: output, cachedTokens: cached)
            default:
                break
            }
        }
        if let restorer {
            let tail = restorer.flush()
            if !tail.isEmpty {
                collected += tail
                if streamIntoState { state.append(tail) }
            }
        }
        return collected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 登记一个新来源,返回其引用编号 [n](顺序与 UI / 参考文献严格一致)。
    private func registerSource(_ ref: SourceRef) -> Int {
        if let existing = sources.firstIndex(where: { $0.url == ref.url }) {
            return existing + 1
        }
        sources.append(ref)
        onSources([ref])
        return sources.count
    }

    private func notesBlock() -> String {
        notes.map { "### 子问题:\($0.question)\n\($0.digest)" }.joined(separator: "\n\n")
    }

    // MARK: 步骤树(复用 AgentStepsView 的 ToolStep 机制)

    private func beginStep(round: Int, tool: String, args: String) -> ToolStep {
        let step = ToolStep(id: UUID().uuidString, round: round, toolName: tool,
                            argsSummary: args, status: .running)
        publishStep(step)
        return step
    }

    private func finishStep(_ step: ToolStep, summary: String) {
        var s = step
        s.status = .done
        s.resultSummary = summary
        publishStep(s)
    }

    private func failStep(_ step: ToolStep, summary: String) {
        var s = step
        s.status = .error
        s.resultSummary = summary
        publishStep(s)
    }

    private func publishStep(_ step: ToolStep) {
        state.upsertToolStep(step)
        onStep(step)
    }

    /// 宽容解析模型输出的 JSON 字符串数组(容忍 ```json 围栏与前后赘述);失败返回空数组。
    static func parseStringArray(_ raw: String) -> [String] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥掉代码围栏
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 截取第一个 [ … 最后一个 ] 之间的内容(模型偶尔会带一句解释)。
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// URL → 域名(步骤参数摘要展示用)。
    private static func domain(of url: String) -> String {
        guard let host = URL(string: url)?.host else { return String(url.prefix(60)) }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
