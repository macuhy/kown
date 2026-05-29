import Foundation

/// 把 `Conversation` 里未总结的轮次合并到 `contextSummary`,作为后续轮的上下文。
/// 设计要点：
///  - 总结结果只是一段中文段落,不强行结构化
///  - 每次只处理"新增的" turn(`turns[summarizedThroughTurnCount..<turns.count - lookbackKeep]`)
///  - 保留最近 `lookbackKeep` 个 turn 不入摘要(下次 send 时这些原文一起发,让模型看到细节)
///  - 调用方:`AppViewModel` 在每轮发送结束后,如果 unsummarized turn 数 >= 阈值,异步触发
enum ConversationSummarizer {
    /// 保留多少个最近的 turn 不进摘要(它们以原文形式拼到下一轮 prompt)。
    static let lookbackKeep = 1
    /// 触发增量摘要的阈值 — unsummarized turn 数达到该值才跑(避免每轮都调用一次摘要 LLM)。
    static let triggerThreshold = 3
    /// `contextForNextSend` 里 lookback 最多带这么多个原文 turn(防止 summarizer 没追上时上下文炸开)。
    static let maxLookbackForSend = 3

    /// 跑摘要,失败/选不到 provider 时返回 nil。
    @MainActor
    static func updatedSummary(
        for conv: Conversation,
        chair: ProviderConfig?,
        firstEnabled: ProviderConfig?
    ) async -> (summary: String, summarizedThroughTurnCount: Int)? {
        // 选 provider: chair > first enabled
        guard let provider = chair ?? firstEnabled else { return nil }
        // 不能用 CLI 类 provider 跑摘要(没法保证短输出+不交互)
        guard !provider.kind.isCLI else { return nil }

        let total = conv.turns.count
        let alreadyDone = conv.summarizedThroughTurnCount
        // 需要的"打算并入摘要"的范围:从 alreadyDone 到 total - lookbackKeep
        let upperExclusive = max(alreadyDone, total - lookbackKeep)
        guard upperExclusive > alreadyDone else { return nil }
        let newTurns = Array(conv.turns[alreadyDone..<upperExclusive])
        guard !newTurns.isEmpty else { return nil }

        let prompt = buildPrompt(existingSummary: conv.contextSummary, newTurns: newTurns)

        do {
            let key = try KeychainStore.load(id: provider.id)
            let client = ProviderRegistry.client(for: provider.kind)
            let options = ChatOptions(
                systemPrompt: "你是一个对话摘要助手。任务是把对话压缩成简短上下文,供模型在后续轮次中参考。",
                temperature: 0.2,
                maxTokens: 800
            )
            var collected = ""
            for try await chunk in client.stream(
                prompt: prompt, options: options, config: provider, apiKey: key
            ) {
                if case .text(let t) = chunk { collected += t }
                if collected.count >= 2400 { break }
            }
            let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (trimmed, upperExclusive)
        } catch {
            return nil
        }
    }

    /// 当前会话的摘要原文(只含 summary,lookback 走 `priorTurnsForReplay`)。
    static func summaryForNextSend(_ conv: Conversation) -> String? {
        guard let summary = conv.contextSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        return summary
    }

    /// 从最近 N 轮 turn 抽出 (user, assistant) 配对,塞进 ChatOptions.priorTurns,
    /// 客户端用真正的 messages[user/assistant] 多轮形式发给模型 — 关联强度比"塞进单条 prompt"高一档。
    static func priorTurnsForReplay(_ conv: Conversation) -> [PriorTurn] {
        let start = max(0, conv.turns.count - maxLookbackForSend)
        guard start < conv.turns.count else { return [] }
        return conv.turns[start..<conv.turns.count].map { turn in
            PriorTurn(
                userText: snippet(turn.prompt, max: 4000),
                assistantText: snippet(bestAnswer(from: turn), max: 4000)
            )
        }
    }

    // MARK: - Private helpers

    private static func buildPrompt(existingSummary: String?, newTurns: [Turn]) -> String {
        var lines: [String] = []
        lines.append("把下面的对话片段并入既有摘要,输出一份**更新后的**整体摘要。")
        lines.append("规则:")
        lines.append("1) 控制在 200-400 字以内。")
        lines.append("2) 保留事实/数字/名称等关键信息,**不要**编造。")
        lines.append("3) 不要输出 \"摘要:\" 这样的前缀,直接输出正文。")
        lines.append("4) 中文输出。")
        lines.append("")
        if let s = existingSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            lines.append("【已有摘要】")
            lines.append(s)
            lines.append("")
        }
        lines.append("【新增对话】")
        for (i, turn) in newTurns.enumerated() {
            lines.append("--- 第 \(i + 1) 轮 ---")
            lines.append("用户: \(snippet(turn.prompt, max: 600))")
            let answer = bestAnswer(from: turn)
            if !answer.isEmpty {
                lines.append("模型: \(snippet(answer, max: 600))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 选一个最值得入摘要的回答:chair summary > 第一个非空 panel response。
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
