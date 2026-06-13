import Foundation

/// 接力流水线(Mixture-of-Agents):跨厂商**串行**精炼 —— 模型 A 起草 → 换厂商模型 B 批判改写 →
/// 模型 C 润色定稿。每站可指定不同模型。opt-in(三次串行调用,成本高),由 Direct 模式「接力精炼」触发。
///
/// 实现复用 `ChainRunner` 的占位符替换与单步流式思路(`{{input}}` / `{{prev}}`),但产出一份
/// 可落盘的 `RelayResult`(供答卡静态展示各阶段),不进入实时工作流面板。
/// 每站失败即中断、保留已完成阶段(绝不变砖),用量记进 `UsageStore`。
enum RelayService {
    /// 一站的配置:类型 + 标题 + 指令模板(支持 `{{input}}` / `{{prev}}` 占位符) + 指定模型(可选)。
    struct StageSpec: Sendable {
        let kind: String           // draft / critique / polish
        let title: String
        let instruction: String
        /// 指定 (provider, model);nil = 自动挑一个「尽量与上一站不同厂商」的 enabled 非 CLI provider。
        var choice: ProviderModelChoice?
    }

    /// 单段送进 prompt 的上一站产出最大字符数(防上下文炸开)。
    static let maxPrevChars = 8000
    /// 单站输出 token 上限。
    static let maxTokens = 2400

    /// 默认三段流水线:起草 → 批判改写 → 润色定稿。`existingDraft` 非空时第一站直接采用它作初稿
    /// (省一次调用,接着让 B/C 精炼);为空则让 A 现起草。
    static func defaultStages(existingDraft: String) -> [StageSpec] {
        let hasDraft = !existingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let draftInstruction = hasDraft
            ? "下面是针对该问题的一份初稿。原样保留其核心内容作为起草结果(无需改写),便于后续接力精炼。\n\n【问题】\n{{input}}\n\n【初稿】\n\(snippet(existingDraft, max: maxPrevChars))"
            : "请针对下面的问题写一份扎实、完整的初稿答案(可用 Markdown)。\n\n【问题】\n{{input}}"
        return [
            StageSpec(
                kind: "draft", title: "起草",
                instruction: draftInstruction),
            StageSpec(
                kind: "critique", title: "批判改写",
                instruction: """
                你是另一个厂商的资深审稿模型。下面是一个问题和一份初稿。请先在心里找出初稿的问题\
                (事实错误、遗漏、含糊、逻辑漏洞、缺乏依据),再直接给出一份**更准确、更完整、更有依据**的改写稿。
                只输出改写后的完整答案(Markdown),不要单独罗列批评。

                【问题】
                {{input}}

                【初稿】
                {{prev}}
                """),
            StageSpec(
                kind: "polish", title: "润色定稿",
                instruction: """
                下面是一个问题和一份已经过改写的答案。请在不改变事实与结论的前提下做最后润色:\
                理顺结构、统一术语、删冗去重、让表达更清晰流畅。输出润色后的完整定稿(Markdown)。

                【问题】
                {{input}}

                【待润色答案】
                {{prev}}
                """)
        ]
    }

    /// 跑整条流水线。`providers` 取 AppViewModel 当前 provider 列表(用于自动挑选与解析指定模型)。
    /// 返回各阶段记录;一站都没成功(连起草都失败)时返回 nil。
    @MainActor
    static func run(
        question: String,
        stages: [StageSpec],
        providers: [ProviderConfig]
    ) async -> RelayResult? {
        let trimmedQ = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQ.isEmpty, !stages.isEmpty else { return nil }

        // 可用的 enabled 非 CLI provider(自动挑选池)。
        let pool = providers.filter { $0.enabled && !$0.kind.isCLI }
        guard !pool.isEmpty else { return nil }

        var out: [RelayResult.Stage] = []
        var prev = ""
        var lastKind: ProviderKind? = nil
        var anySuccess = false

        for spec in stages {
            // 解析本站用哪个 provider:指定优先;否则挑一个「厂商不同于上一站」的,挑不到就用池首个。
            let cfg = resolveConfig(spec: spec, pool: pool, avoidKind: lastKind)
            guard let cfg else {
                out.append(.init(kind: spec.kind, title: spec.title, providerID: "",
                                 modelLabel: "无可用模型", text: "", error: "没有可用模型"))
                break
            }
            let label = "\(cfg.displayName) · \(cfg.model)"
            let prompt = ChainRunner.fill(spec.instruction, input: trimmedQ, prev: prev)

            let (text, error) = await runStage(config: cfg, prompt: prompt)
            out.append(.init(kind: spec.kind, title: spec.title, providerID: cfg.id.uuidString,
                             modelLabel: label, text: text, error: error))
            // 失败且无产出 → 中断,保留已完成阶段(后续站没有可接的 {{prev}} 也没意义)。
            if error != nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
            anySuccess = true
            prev = text
            lastKind = cfg.kind
        }

        guard anySuccess else { return nil }
        return RelayResult(stages: out)
    }

    /// 挑本站的 ProviderConfig:指定 choice 优先(覆写 model);否则在 pool 里优先选厂商 != avoidKind 的,
    /// 没有就退回 pool 首个(单 provider 场景下三站会落到同一家,仍可跑)。
    private static func resolveConfig(
        spec: StageSpec, pool: [ProviderConfig], avoidKind: ProviderKind?
    ) -> ProviderConfig? {
        if let choice = spec.choice,
           var cfg = pool.first(where: { $0.id == choice.providerID }) {
            cfg.model = choice.model
            return cfg
        }
        if let avoidKind, let diff = pool.first(where: { $0.kind != avoidKind }) {
            return diff
        }
        return pool.first
    }

    /// 跑单站流式,收满文本;usage 记进 UsageStore。返回(文本, 错误)。
    @MainActor
    private static func runStage(config: ProviderConfig, prompt: String) async -> (text: String, error: String?) {
        var collected = ""
        do {
            let apiKey = config.kind.needsAPIKey ? (try KeychainStore.load(id: config.id)) : ""
            let client = ProviderRegistry.client(for: config.kind)
            let options = ChatOptions(systemPrompt: nil,
                                      temperature: config.temperature,
                                      maxTokens: config.maxTokens ?? maxTokens)
            for try await chunk in client.stream(prompt: prompt, options: options, config: config, apiKey: apiKey) {
                if Task.isCancelled { return (collected, "已取消") }
                switch chunk {
                case .text(let t):
                    collected += t
                case .usage(let input, let output, let cached):
                    UsageStore.shared.record(providerKind: config.kind, model: config.model,
                                             inputTokens: input, outputTokens: output, cachedTokens: cached)
                default:
                    break
                }
            }
            return (collected, nil)
        } catch is CancellationError {
            return (collected, "已取消")
        } catch {
            return (collected, error.localizedDescription)
        }
    }

    private static func snippet(_ text: String, max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }
}
