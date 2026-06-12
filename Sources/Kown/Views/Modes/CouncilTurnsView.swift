import SwiftUI

/// Council 模式：每个 turn = 用户问题 + 横向多列回答 + 可选 Chair 综合
struct CouncilTurnsView: View {
    @Bindable var viewModel: AppViewModel
    let conversation: Conversation
    let liveStates: [UUID: ResponseState]
    let liveChairState: ResponseState?
    let liveSummaryState: ResponseState?
    let livePrompt: String?
    var liveImages: [TurnImage] = []
    let isRunning: Bool
    /// 用于 live turn 推断当前 panel/chair/summary
    let livePanel: [ProviderConfig]
    let liveChair: ProviderConfig?
    let liveSummary: ProviderConfig?
    /// 历史 turn 的「编辑并重发」动作(由父视图注入,打开编辑 sheet)。
    var onEditTurn: ((UUID) -> Void)? = nil
    /// 历史 turn 的追问 / 导出报告动作(由父视图注入)。
    var onFollowUpTurn: ((UUID) -> Void)? = nil
    var onExportTurn: ((UUID) -> Void)? = nil
    var onShareTurn: ((UUID) -> Void)? = nil

    /// 已折叠的历史轮(整轮收起)。
    @State private var collapsedTurns: Set<UUID> = []
    /// iPhone compact 宽度下 panel 改成垂直堆叠;iPad / Mac 仍并排
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var stacksVertically: Bool {
        #if os(iOS)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }

    private var turnSpacing: CGFloat { stacksVertically ? 16 : 22 }
    private var horizontalPadding: CGFloat { stacksVertically ? 10 : 18 }
    private var verticalPadding: CGFloat { stacksVertically ? 12 : 18 }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: turnSpacing) {
            ForEach(conversation.turns) { turn in
                // 显式稳定身份:切换会话时 conversation 整体替换,靠 turn.id 让 SwiftUI 做增量 diff,避免全量重建。
                historicalTurn(turn)
                    .id(turn.id)
            }
            if let livePrompt {
                liveTurn(prompt: livePrompt)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    private func historicalTurn(_ turn: Turn) -> some View {
        let isCollapsed = collapsedTurns.contains(turn.id)
        return ModeTurnCard(
            title: "Council",
            subtitle: isCollapsed ? TurnFold.preview(turn) : "\(turn.orderedPanelConfigs.count) 位模型成员协作回答",
            icon: "person.3.sequence.fill",
            tint: councilTint,
            collapsed: isCollapsed,
            onToggleCollapse: { TurnFold.toggle(turn.id, in: &collapsedTurns) }
        ) {
            PromptBubble(prompt: turn.prompt, timestamp: turn.timestamp, images: turn.images ?? [],
                         onFork: { viewModel.forkConversation(fromTurnID: turn.id) },
                         onEdit: onEditTurn.map { f in { f(turn.id) } },
                         onFollowUp: onFollowUpTurn.map { f in { f(turn.id) } },
                         onExportReport: onExportTurn.map { f in { f(turn.id) } },
                         onShareImage: onShareTurn.map { f in { f(turn.id) } })
            panelStack(count: turn.orderedPanelConfigs.count) {
                ForEach(turn.orderedPanelConfigs) { cfg in
                    let key = cfg.id.uuidString
                    HistoricalResponseCard(
                        config: cfg,
                        text: turn.responses[key] ?? "",
                        error: turn.errors[key],
                        onRetry: turn.errors[key] != nil ? {
                            viewModel.retryProvider(turnID: turn.id, configID: cfg.id)
                        } : nil,
                        isRetrying: viewModel.isRetrying(turnID: turn.id, configID: cfg.id),
                        regenerateProviders: viewModel.regenerateCandidates,
                        onRegenerate: { viewModel.regenerateWithModel(turnID: turn.id, newProviderID: $0) },
                        reasoning: turn.reasoningByProvider?[key],
                        tokenUsage: turn.tokenUsage?[key],
                        sources: turn.sourcesByProvider?[key] ?? [],
                        knowledgeSources: turn.knowledgeSources ?? []
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if let chair = turn.chairConfig {
                ChairSummaryCard(
                    config: chair,
                    text: turn.chairSummary,
                    error: turn.chairError,
                    liveText: nil,
                    isStreaming: false,
                    onRetry: turn.chairError != nil ? {
                        viewModel.retryChair(turnID: turn.id, target: .chair)
                    } : nil,
                    isRetrying: viewModel.isRetryingChair(turnID: turn.id, target: .chair),
                    reasoning: turn.reasoningByProvider?[chair.id.uuidString],
                    tokenUsage: turn.tokenUsage?[chair.id.uuidString],
                    sources: turn.sources ?? [],
                    knowledgeSources: turn.knowledgeSources ?? [],
                    regenerateProviders: viewModel.regenerateCandidates,
                    onRegenerate: { viewModel.regenerateChairWithModel(turnID: turn.id, target: .chair, newProviderID: $0) }
                )
            }
            if let summary = turn.summaryConfig {
                ChairSummaryCard(
                    config: summary,
                    text: turn.summaryText,
                    error: turn.summaryError,
                    liveText: nil,
                    isStreaming: false,
                    role: .summary,
                    onRetry: turn.summaryError != nil ? {
                        viewModel.retryChair(turnID: turn.id, target: .summary)
                    } : nil,
                    isRetrying: viewModel.isRetryingChair(turnID: turn.id, target: .summary),
                    reasoning: turn.reasoningByProvider?[summary.id.uuidString],
                    tokenUsage: turn.tokenUsage?[summary.id.uuidString],
                    sources: turn.sources ?? [],
                    knowledgeSources: turn.knowledgeSources ?? [],
                    regenerateProviders: viewModel.regenerateCandidates,
                    onRegenerate: { viewModel.regenerateChairWithModel(turnID: turn.id, target: .summary, newProviderID: $0) }
                )
            }
            if let votes = turn.councilVotes, !votes.scores.isEmpty {
                VoteResultsCard(vote: votes, names: voteNames(turn))
            }
            // 合成最优终稿 —— opt-in「合成最优答案」按钮 + 结果卡。≥2 家非空回答才显示。
            if turn.responses.values.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).count >= 2 {
                SynthesisSection(
                    conclusion: turn.synthesizedConclusion,
                    providerName: turn.synthesizedConclusion.flatMap { turn.providerSnapshot[$0.providerID]?.displayName },
                    isSynthesizing: viewModel.isSynthesizing(turnID: turn.id),
                    error: viewModel.synthesisErrors[turn.id],
                    onSynthesize: { viewModel.synthesizeTurn(turnID: turn.id) }
                )
            }
            // 答案差异分析(共識/分歧)—— opt-in「分析分歧」按钮 + 结果面板。
            ConsensusSection(
                analysis: turn.consensusAnalysis,
                isAnalyzing: viewModel.isAnalyzingConsensus(turnID: turn.id),
                error: viewModel.consensusErrors[turn.id],
                onAnalyze: { viewModel.analyzeConsensus(turnID: turn.id) }
            )
            if let writes = turn.appliedWrites, !writes.isEmpty {
                AppliedWritesStrip(writes: writes, onUndo: { viewModel.undoWrite(turnID: turn.id, write: $0) })
            }
            TurnSourcesStrip(turn: turn)
        }
    }

    private func liveTurn(prompt: String) -> some View {
        ModeTurnCard(
            title: "Council",
            subtitle: "\(livePanel.count) 位模型成员正在生成",
            icon: "person.3.sequence.fill",
            tint: councilTint,
            isLive: isRunning
        ) {
            PromptBubble(prompt: prompt, timestamp: Date(), images: liveImages)
            panelStack(count: livePanel.count) {
                ForEach(livePanel) { cfg in
                    if let state = liveStates[cfg.id] {
                        ResponseColumnView(config: cfg, state: state)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            if let chair = liveChair, let chairState = liveChairState {
                ChairSummaryCard(
                    config: chair,
                    text: nil,
                    error: chairErrorMessage(chairState),
                    liveText: chairState.text,
                    isStreaming: isChairStreaming(chairState),
                    reasoning: chairState.reasoning
                )
            }
            if let summary = liveSummary, let summaryState = liveSummaryState {
                ChairSummaryCard(
                    config: summary,
                    text: nil,
                    error: chairErrorMessage(summaryState),
                    liveText: summaryState.text,
                    isStreaming: isChairStreaming(summaryState),
                    role: .summary,
                    reasoning: summaryState.reasoning
                )
            }
        }
    }

    /// 紧凑(iPhone)用 VStack,常规(iPad / Mac)按可用宽度自动换列。
    @ViewBuilder
    private func panelStack<Content: View>(count: Int, @ViewBuilder content: () -> Content) -> some View {
        if stacksVertically {
            VStack(alignment: .leading, spacing: 14) { content() }
        } else {
            AdaptivePanelGrid(count: count) { content() }
        }
    }

    private var councilTint: Color {
        ConversationMode.council.kownTint
    }

    /// providerID → 展示名(供投票卡显示)。
    private func voteNames(_ turn: Turn) -> [String: String] {
        var map: [String: String] = [:]
        for (id, cfg) in turn.providerSnapshot { map[id] = cfg.displayName }
        return map
    }

    private func isChairStreaming(_ state: ResponseState) -> Bool {
        if case .streaming = state.phase { return true }
        return false
    }

    private func chairErrorMessage(_ state: ResponseState) -> String? {
        if case .failed(let msg) = state.phase { return msg }
        return nil
    }
}
