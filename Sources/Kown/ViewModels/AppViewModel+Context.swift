import Foundation

// 上下文管理:输入栏「上下文用量条」的估算 + 「压缩早期历史」「全新上下文」两个手动动作。
// 注入点全部收敛在 ConversationSummarizer.summaryForNextSend / priorTurnsForReplay
// (send / edit / retry 共用),这里只负责改写 Conversation 上的字段并落盘。
extension AppViewModel {

    // MARK: - 用量估算

    /// 当前会话「下次发送」的上下文用量估算(给输入栏的用量条)。
    /// 估算口径与真实发送对齐:系统提示 + 摘要(滚动/压缩,截断后为 nil)+ 最近轮原文 + 当前输入。
    /// 没选会话 / 没可用 provider 时返回 nil(用量条隐藏)。
    var contextUsageForCurrentSend: ContextWindowEstimator.Usage? {
        guard let conv = selectedConversation else { return nil }
        let panel = providersForCurrentSend().panel
        guard !panel.isEmpty else { return nil }
        let convPrompt = conv.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSystem = (convPrompt?.isEmpty == false) ? convPrompt! : systemPrompt
        return ContextWindowEstimator.usage(
            systemPrompt: effectiveSystem,
            contextSummary: ConversationSummarizer.summaryForNextSend(conv),
            priorTurns: ConversationSummarizer.priorTurnsForReplay(conv),
            draftPrompt: prompt,
            models: panel.map(\.model)
        )
    }

    // MARK: - 压缩早期历史

    /// 当前会话是否够长,可以做「压缩早期历史」(至少要有 1 轮能进摘要)。
    var canCompressContext: Bool {
        guard let conv = selectedConversation else { return false }
        return conv.turns.count > ConversationSummarizer.compressionKeepRecent
    }

    /// 「压缩早期历史」:把前 N 轮(保留最近 `compressionKeepRecent` 轮原样)用当前模型总结成摘要。
    /// 此后发送时早期轮替换为摘要;原文在 UI 里保留可见,只是不再随请求发送。
    func compressEarlyHistory() {
        guard !isCompressingContext else { return }
        guard let convID = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        let convSnapshot = conversations[idx]
        guard convSnapshot.turns.count > ConversationSummarizer.compressionKeepRecent else {
            contextCompressionError = "轮次还不多,暂时不需要压缩(最近 \(ConversationSummarizer.compressionKeepRecent) 轮始终保留原文)。"
            return
        }
        // 「用当前模型总结」:取本次发送会用到的第一家非 CLI provider;退而求其次用任一启用的。
        guard let provider = providersForCurrentSend().panel.first(where: { !$0.kind.isCLI })
                ?? providers.first(where: { $0.enabled && !$0.kind.isCLI }) else {
            contextCompressionError = "没有可用的 API provider:压缩需要带 API key 的 provider(CLI 不支持)。"
            return
        }
        contextCompressionError = nil
        isCompressingContext = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCompressingContext = false }
            guard let result = await ConversationSummarizer.compressEarlyHistory(
                for: convSnapshot, provider: provider
            ) else {
                self.contextCompressionError = "压缩失败:\(provider.displayName) 未返回有效摘要,稍后再试。"
                return
            }
            guard let liveIdx = self.conversations.firstIndex(where: { $0.id == convID }) else { return }
            // 压缩期间用户可能编辑历史删了轮:水位夹紧到当前轮数,避免越界。
            self.conversations[liveIdx].compressedContextSummary = result.summary
            self.conversations[liveIdx].compressedThroughTurnCount = min(
                result.compressedThroughTurnCount,
                self.conversations[liveIdx].turns.count
            )
            self.conversations[liveIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[liveIdx])
        }
    }

    /// 清除压缩摘要,恢复按原文发送(滚动摘要机制不受影响)。
    func clearCompressedContext() {
        guard let idx = conversations.firstIndex(where: { $0.id == selectedConversationID }) else { return }
        guard conversations[idx].compressedContextSummary != nil
                || conversations[idx].compressedThroughTurnCount > 0 else { return }
        conversations[idx].compressedContextSummary = nil
        conversations[idx].compressedThroughTurnCount = 0
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }

    // MARK: - 全新上下文(截断)

    /// 当前会话是否已设截断点(且截断点还有效 — 指向的轮仍存在)。
    var hasContextCutoff: Bool {
        guard let conv = selectedConversation else { return false }
        return ConversationSummarizer.cutoffIndex(conv) != nil
    }

    /// 「从下一轮开始全新上下文」:把截断点记在当前最后一轮上,
    /// 此后发送只携带截断点之后的轮;UI 在截断处显示分隔线,可撤销。
    func setContextCutoff() {
        guard let idx = conversations.firstIndex(where: { $0.id == selectedConversationID }),
              let last = conversations[idx].turns.last else { return }
        guard conversations[idx].contextCutoffTurnID != last.id else { return }
        conversations[idx].contextCutoffTurnID = last.id
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }

    /// 撤销截断,恢复携带完整上下文。
    func clearContextCutoff() {
        guard let idx = conversations.firstIndex(where: { $0.id == selectedConversationID }),
              conversations[idx].contextCutoffTurnID != nil else { return }
        conversations[idx].contextCutoffTurnID = nil
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }
}
