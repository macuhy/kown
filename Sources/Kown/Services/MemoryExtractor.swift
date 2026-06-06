import Foundation

/// 用「小而便宜」的模型,从一个会话里抽取**值得长期保留**的事实 / 偏好 / 决定,写进 `MemoryStore`。
///
/// 与 `ConversationSummarizer` 的区别:summarizer 压缩**本会话**历史供后续轮用;
/// 这里是把跨会话有价值的恒久信息沉淀下来,供**未来其它会话**按相关性回灌。
///
/// 触发策略(调用方 `AppViewModel`):会话达到一定轮数 / 切走时,后台异步跑一次,失败静默降级。
/// 同一会话用 `memoryExtractedThroughTurnCount` 水位避免重复抽取(只看新增轮)。
enum MemoryExtractor {
    /// 会话累计到该轮数才首次抽取(太短的会话没什么可沉淀)。
    static let triggerTurnCount = 2
    /// 距上次抽取又新增这么多轮,才再抽一次(避免每轮都调用小模型)。
    static let incrementalThreshold = 3
    /// 单次抽取最多产出多少条(防止一次塞爆记忆库)。
    static let maxItemsPerRun = 6

    /// 跑一次抽取,返回 (抽出的记忆文本数组, 抽取到的轮次水位)。
    /// 选不到 provider / 失败 / 无可沉淀内容时返回 nil。
    @MainActor
    static func extract(
        for conv: Conversation,
        chair: ProviderConfig?,
        firstEnabled: ProviderConfig?
    ) async -> (memories: [String], extractedThroughTurnCount: Int)? {
        // 选 provider: chair > first enabled(与 summarizer 一致)
        guard let provider = chair ?? firstEnabled else { return nil }
        // CLI 类不适合跑抽取(无法保证短输出 + 非交互)
        guard !provider.kind.isCLI else { return nil }

        let total = conv.turns.count
        let alreadyDone = conv.memoryExtractedThroughTurnCount
        guard total > alreadyDone else { return nil }
        let newTurns = Array(conv.turns[alreadyDone..<total])
        guard !newTurns.isEmpty else { return nil }

        let prompt = buildPrompt(newTurns: newTurns)

        do {
            let key = try KeychainStore.load(id: provider.id)
            let client = ProviderRegistry.client(for: provider.kind)
            let options = ChatOptions(
                systemPrompt: "你是一个长期记忆抽取助手。只抽取跨会话长期有用的恒久信息,严格按格式输出。",
                temperature: 0.1,
                maxTokens: 500
            )
            var collected = ""
            for try await chunk in client.stream(
                prompt: prompt, options: options, config: provider, apiKey: key
            ) {
                if case .text(let t) = chunk { collected += t }
                if collected.count >= 2000 { break }
            }
            let memories = parse(collected)
            // 即便没抽到内容,也要把水位推进,避免下次又对同样的轮次重复调用。
            return (memories, total)
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private static func buildPrompt(newTurns: [Turn]) -> String {
        var lines: [String] = []
        lines.append("从下面的对话里,抽取**值得长期保留、跨会话仍然有用**的信息,作为用户的长期记忆。")
        lines.append("只保留这几类:")
        lines.append("1) 用户的稳定偏好 / 习惯(如:喜欢简洁回答、常用某编程语言、所在时区)。")
        lines.append("2) 关于用户的恒久事实(如:职业、项目名、技术栈、长期目标)。")
        lines.append("3) 明确做出的长期决定 / 约定。")
        lines.append("")
        lines.append("规则:")
        lines.append("- 每条一行,用 `- ` 开头,一句话,中文,尽量短(≤40 字)。")
        lines.append("- **不要**抽取一次性问答、临时上下文、与本对话强绑定的细节。")
        lines.append("- 不确定是否长期有用就**不要**输出。宁缺毋滥。")
        lines.append("- 没有任何值得保留的,就只输出一行:无")
        lines.append("- 最多 \(maxItemsPerRun) 条。不要输出解释或多余文字。")
        lines.append("")
        lines.append("【对话】")
        for (i, turn) in newTurns.enumerated() {
            lines.append("--- 第 \(i + 1) 轮 ---")
            lines.append("用户: \(snippet(turn.prompt, max: 600))")
            let answer = bestAnswer(from: turn)
            if !answer.isEmpty {
                lines.append("模型: \(snippet(answer, max: 400))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 解析模型输出成记忆条目数组:按行拆,剥掉 `- ` / `• ` / 序号前缀,过滤「无」与空行,去重 + 截断。
    static func parse(_ raw: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            // 剥常见列表前缀
            for prefix in ["- ", "* ", "• ", "・ "] {
                if line.hasPrefix(prefix) { line = String(line.dropFirst(prefix.count)); break }
            }
            // 剥 "1. " / "1) " 这类序号
            line = stripLeadingNumber(line)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            // 过滤「无 / 没有 / none」这类空结果
            let lower = line.lowercased()
            if line == "无" || line == "没有" || lower == "none" || lower == "n/a" { continue }
            if line.count > 80 { line = String(line.prefix(80)) }
            let dedupKey = line.lowercased()
            guard seen.insert(dedupKey).inserted else { continue }
            out.append(line)
            if out.count >= maxItemsPerRun { break }
        }
        return out
    }

    private static func stripLeadingNumber(_ s: String) -> String {
        var idx = s.startIndex
        var sawDigit = false
        while idx < s.endIndex, s[idx].isNumber {
            sawDigit = true
            idx = s.index(after: idx)
        }
        guard sawDigit, idx < s.endIndex else { return s }
        let sep = s[idx]
        if sep == "." || sep == ")" || sep == "、" {
            return String(s[s.index(after: idx)...])
        }
        return s
    }

    private static func bestAnswer(from turn: Turn) -> String {
        if let s = turn.chairSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        for key in turn.panelOrder {
            if let text = turn.responses[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return ""
    }

    private static func snippet(_ text: String, max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }
}
