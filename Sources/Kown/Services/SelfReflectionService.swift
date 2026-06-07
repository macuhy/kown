import Foundation

/// 自我反思修订:把「问题 + 已有答案」交给模型,先批评再产出改进版。
/// opt-in(成本考量),由 UI「自我反思」按钮触发,结果写回 `Turn.selfRevision`。
/// 选 chair > 第一个非 CLI 的 enabled provider,中低温、一次调用。
enum SelfReflectionService {
    static let maxAnswerChars = 6000
    static let maxTokens = 2000

    /// 跑一轮自我反思。失败 / 选不到 provider 时返回 nil。
    @MainActor
    static func reflect(
        question: String,
        answer: String,
        provider: ProviderConfig
    ) async -> (critique: String, revised: String)? {
        guard !provider.kind.isCLI else { return nil }
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty else { return nil }

        let prompt = buildPrompt(question: question, answer: trimmedAnswer)
        do {
            let key = try KeychainStore.load(id: provider.id)
            let client = ProviderRegistry.client(for: provider.kind)
            let options = ChatOptions(
                systemPrompt: "你是严谨的审稿人。你会读到一个问题和一份初始答案,任务是先挑出答案的问题(事实错误、遗漏、含糊、逻辑漏洞),再给出一份更好的修订答案。",
                temperature: 0.4,
                maxTokens: maxTokens
            )
            var collected = ""
            for try await chunk in client.stream(prompt: prompt, options: options, config: provider, apiKey: key) {
                if case .text(let t) = chunk { collected += t }
                if collected.count >= 16000 { break }
            }
            return parse(collected)
        } catch {
            return nil
        }
    }

    private static func buildPrompt(question: String, answer: String) -> String {
        var lines: [String] = []
        lines.append("下面是一个问题,以及针对它的一份初始答案。请做两件事:")
        lines.append("1) 批评:指出初始答案的问题——事实错误、关键遗漏、含糊其辞、逻辑漏洞或可改进处(3-6 条,具体)。")
        lines.append("2) 修订:在批评基础上重写一份更准确、更完整、更清晰的答案。")
        lines.append("")
        lines.append("严格按下面格式输出,中文,两块都要有:")
        lines.append("【批评】")
        lines.append("- <问题1>")
        lines.append("- <问题2>")
        lines.append("【修订答案】")
        lines.append("<改进后的完整答案,可用 Markdown>")
        lines.append("")
        lines.append("【问题】")
        lines.append(snippet(question, max: 1500))
        lines.append("")
        lines.append("【初始答案】")
        lines.append(snippet(answer, max: maxAnswerChars))
        return lines.joined(separator: "\n")
    }

    /// 解析「【批评】…【修订答案】…」两段。容错:缺标记时把全文当修订答案、批评留空。
    static func parse(_ raw: String) -> (critique: String, revised: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 找两个标记的位置(容忍全/半角括号)。
        let critiqueMarkers = ["【批评】", "【批評】", "批评:", "批評:"]
        let reviseMarkers = ["【修订答案】", "【修訂答案】", "【修订】", "修订答案:", "修订:"]

        func range(of markers: [String]) -> Range<String.Index>? {
            for m in markers { if let r = text.range(of: m) { return r } }
            return nil
        }

        let critiqueR = range(of: critiqueMarkers)
        let reviseR = range(of: reviseMarkers)

        if let reviseR {
            let revised = String(text[reviseR.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            var critique = ""
            if let critiqueR, critiqueR.upperBound <= reviseR.lowerBound {
                critique = String(text[critiqueR.upperBound..<reviseR.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !revised.isEmpty else { return nil }
            return (critique, revised)
        }
        // 没有修订标记 → 整段当修订答案(批评为空)。
        return ("", text)
    }

    private static func snippet(_ text: String, max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }
}
