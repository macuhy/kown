import Foundation

/// 把一轮里各家(带 provider 名)的回答合成一份「最优终稿」:取各家最强论点、补齐遗漏、化解矛盾。
/// opt-in(成本考量):由 Council / Compare 的「合成最优答案」按钮触发,结果写回 `Turn.synthesizedConclusion`。
/// 参照 `SelfReflectionService` / `ConsensusAnalyzer`:选 chair > 第一个非 CLI 的 enabled provider,一次低温调用。
enum SynthesisService {
    /// 单家回答送进 prompt 的最大字符数。
    static let maxAnswerChars = 4000
    /// 输出 token 上限(终稿可能较长)。
    static let maxTokens = 2200

    /// 跑一轮合成。失败 / 选不到 provider / 回答不足 2 家时返回 nil。
    @MainActor
    static func synthesize(
        question: String,
        answers: [ConsensusAnalyzer.NamedAnswer],
        consensus: ConsensusAnalysis?,
        provider: ProviderConfig
    ) async -> (text: String, rationale: String)? {
        guard !provider.kind.isCLI else { return nil }
        let valid = answers.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard valid.count >= 2 else { return nil }

        let prompt = buildPrompt(question: question, answers: valid, consensus: consensus)
        do {
            let key = try KeychainStore.load(id: provider.id)
            let client = ProviderRegistry.client(for: provider.kind)
            let options = ChatOptions(
                systemPrompt: "你是一个答案合成专家。你会读到同一个问题下多个 AI 模型各自的回答,"
                    + "任务是博采众长,合成一份比任何单一回答都更好的最终答案:吸收各家最强的论点与证据,"
                    + "补齐遗漏,化解矛盾(有冲突时取更可信、更有依据的一方),去掉冗余与错误。",
                temperature: 0.3,
                maxTokens: maxTokens
            )
            var collected = ""
            for try await chunk in client.stream(prompt: prompt, options: options, config: provider, apiKey: key) {
                if case .text(let t) = chunk { collected += t }
                if collected.count >= 20000 { break }
            }
            return parse(collected)
        } catch {
            return nil
        }
    }

    private static func buildPrompt(question: String,
                                    answers: [ConsensusAnalyzer.NamedAnswer],
                                    consensus: ConsensusAnalysis?) -> String {
        var lines: [String] = []
        lines.append("下面是一个问题,以及多个 AI 模型各自给出的回答。请合成一份最优终稿。")
        lines.append("")
        lines.append("【问题】")
        lines.append(snippet(question, max: 1500))
        lines.append("")
        for (i, a) in answers.enumerated() {
            lines.append("【回答 \(i + 1) · \(a.name)】")
            lines.append(snippet(a.text, max: maxAnswerChars))
            lines.append("")
        }
        // 已有共識/分歧分析时作为线索注入,帮助合成更准。
        if let consensus {
            let agreements = consensus.agreements.prefix(6)
            let disagreements = consensus.disagreements.prefix(6)
            if !agreements.isEmpty || !disagreements.isEmpty {
                lines.append("【已知的共識与分歧(参考)】")
                if !agreements.isEmpty {
                    lines.append("共識:" + agreements.joined(separator: ";"))
                }
                if !disagreements.isEmpty {
                    lines.append("分歧:" + disagreements.joined(separator: ";"))
                }
                lines.append("")
            }
        }
        lines.append("严格按下面格式输出,中文,两块都要有:")
        lines.append("【合成说明】")
        lines.append("<一两句话说明你的合成策略:采纳了谁的哪些要点、如何处理分歧>")
        lines.append("【最优答案】")
        lines.append("<合成后的完整最终答案,可用 Markdown>")
        return lines.joined(separator: "\n")
    }

    /// 解析「【合成说明】…【最优答案】…」两段。容错:缺标记时把全文当最优答案、说明留空。
    static func parse(_ raw: String) -> (text: String, rationale: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let rationaleMarkers = ["【合成说明】", "【合成說明】", "合成说明:", "合成說明:"]
        let answerMarkers = ["【最优答案】", "【最優答案】", "【最优答案】", "最优答案:", "最終答案:", "最终答案:"]

        func range(of markers: [String]) -> Range<String.Index>? {
            for m in markers { if let r = text.range(of: m) { return r } }
            return nil
        }

        let rationaleR = range(of: rationaleMarkers)
        let answerR = range(of: answerMarkers)

        if let answerR {
            let answer = String(text[answerR.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            var rationale = ""
            if let rationaleR, rationaleR.upperBound <= answerR.lowerBound {
                rationale = String(text[rationaleR.upperBound..<answerR.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !answer.isEmpty else { return nil }
            return (answer, rationale)
        }
        // 没有答案标记 → 整段当最优答案(说明为空)。
        return (text, "")
    }

    private static func snippet(_ text: String, max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }
}
