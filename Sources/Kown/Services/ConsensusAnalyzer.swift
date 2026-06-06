import Foundation

/// 把一轮里各家(带 provider 名)的回答交给小模型,抽取「共識(各模型一致点)/ 分歧(意见分歧点)」。
/// opt-in:由 UI「分析分歧」按钮触发(成本考量),结果写回 `Turn.consensusAnalysis`。
/// 参照 `ConversationSummarizer`:选 chair > 第一个非 CLI 的 enabled provider,小调用、低温、短输出。
enum ConsensusAnalyzer {
    /// 单家回答送进 prompt 的最大字符数(防止上下文炸开)。
    static let maxAnswerChars = 2000
    /// 输出 token 上限。
    static let maxTokens = 900

    /// provider 名 + 其回答文本(按 panelOrder 顺序)。
    struct NamedAnswer {
        let name: String
        let text: String
    }

    /// 跑差异分析,失败 / 选不到 provider / 回答不足 2 家时返回 nil(分析无意义)。
    @MainActor
    static func analyze(
        question: String,
        answers: [NamedAnswer],
        chair: ProviderConfig?,
        firstEnabled: ProviderConfig?
    ) async -> ConsensusAnalysis? {
        // 只有 >= 2 家有效回答才值得做共識/分歧分析。
        let valid = answers.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard valid.count >= 2 else { return nil }

        // 选 provider:chair 优先,否则第一个非 CLI 的 enabled。
        guard let provider = chair ?? firstEnabled, !provider.kind.isCLI else { return nil }

        let prompt = buildPrompt(question: question, answers: valid)
        do {
            let key = try KeychainStore.load(id: provider.id)
            let client = ProviderRegistry.client(for: provider.kind)
            let options = ChatOptions(
                systemPrompt: "你是一个答案对比分析助手。你会读到同一个问题下多个 AI 模型各自的回答,任务是找出它们的共識(一致结论)与分歧(意见分歧的点)。",
                temperature: 0.2,
                maxTokens: maxTokens
            )
            var collected = ""
            for try await chunk in client.stream(prompt: prompt, options: options, config: provider, apiKey: key) {
                if case .text(let t) = chunk { collected += t }
                if collected.count >= 6000 { break }
            }
            return parse(collected)
        } catch {
            return nil
        }
    }

    // MARK: - Prompt

    private static func buildPrompt(question: String, answers: [NamedAnswer]) -> String {
        var lines: [String] = []
        lines.append("下面是针对同一个问题,多个 AI 模型各自给出的回答。请对比它们,抽取:")
        lines.append("1) 共識:各模型基本一致认同的关键结论 / 要点。")
        lines.append("2) 分歧:模型之间意见分歧的点;**尽量点明是哪个模型、它的不同立场是什么**。")
        lines.append("")
        lines.append("严格按下面的格式输出,中文,每条一行,简短具体,不要编号外的解释:")
        lines.append("共識:")
        lines.append("- <一致点1>")
        lines.append("- <一致点2>")
        lines.append("分歧:")
        lines.append("- <分歧点1(谁怎么不同)>")
        lines.append("- <分歧点2(谁怎么不同)>")
        lines.append("")
        lines.append("若没有共識或没有分歧,对应小节写一行「- 无」。")
        lines.append("")
        lines.append("【问题】")
        lines.append(snippet(question, max: 800))
        lines.append("")
        lines.append("【各模型回答】")
        for a in answers {
            lines.append("=== \(a.name) ===")
            lines.append(snippet(a.text, max: maxAnswerChars))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parse

    /// 解析模型输出的「共識: / 分歧:」两段列表。容错大小写、全/半角冒号、缺一节。
    static func parse(_ raw: String) -> ConsensusAnalysis? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        enum Section { case none, agreement, disagreement }
        var section: Section = .none
        var agreements: [String] = []
        var disagreements: [String] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let header = line.replacingOccurrences(of: " ", with: "")
            if header.hasPrefix("共識") || header.hasPrefix("共识") {
                section = .agreement
                continue
            }
            if header.hasPrefix("分歧") {
                section = .disagreement
                continue
            }
            let item = stripBullet(line)
            guard !item.isEmpty, item != "无", item != "無" else { continue }
            switch section {
            case .agreement: agreements.append(item)
            case .disagreement: disagreements.append(item)
            case .none: break
            }
        }

        guard !agreements.isEmpty || !disagreements.isEmpty else { return nil }
        return ConsensusAnalysis(agreements: agreements, disagreements: disagreements)
    }

    /// 去掉行首的项目符号 / 序号 / 冒号残留。
    private static func stripBullet(_ s: String) -> String {
        var r = s
        // 去掉残留的「共識:」「分歧:」前缀(同一行写法)。
        for prefix in ["共識:", "共识:", "分歧:", "共識:", "共识:", "分歧:"] {
            if r.hasPrefix(prefix) { r.removeFirst(prefix.count) }
        }
        while let f = r.first,
              f == "-" || f == "*" || f == "•" || f == "·" || f == "." || f == "、"
              || f == ")" || f == ")" || f == ":" || f == ":" || (f.isNumber && f.isASCII) || f == " " {
            // 注意:只剥 ASCII 数字作行号。中文数字「一/二/三」在 Swift 里 isNumber 也为真,
            // 若一并剥掉会把「一致点」误伤成「致点」,故加 isASCII 限制。
            r.removeFirst()
        }
        return r.trimmingCharacters(in: .whitespaces)
    }

    private static func snippet(_ text: String, max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }
}
