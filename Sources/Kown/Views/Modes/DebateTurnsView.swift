import SwiftUI

/// Debate 模式：多模型先立论，再读彼此观点做反驳 / 修正，最后由 Chair 做主持总结。
struct DebateTurnsView: View {
    @Bindable var viewModel: AppViewModel
    let conversation: Conversation
    let liveStates: [UUID: ResponseState]
    let liveChairState: ResponseState?
    let liveDebateRounds: [DebateRound]
    let livePrompt: String?
    var liveImages: [TurnImage] = []
    let isRunning: Bool
    let livePanel: [ProviderConfig]
    let liveChair: ProviderConfig?
    /// 历史 turn 的「编辑并重发」动作(由父视图注入,打开编辑 sheet)。
    var onEditTurn: ((UUID) -> Void)? = nil
    /// 历史 turn 的追问 / 导出报告动作(由父视图注入)。
    var onFollowUpTurn: ((UUID) -> Void)? = nil
    var onExportTurn: ((UUID) -> Void)? = nil

    @State private var collapsedTurns: Set<UUID> = []
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var stacksVertically: Bool {
        #if os(iOS)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(conversation.turns) { turn in
                historicalTurn(turn)
            }
            if let livePrompt {
                liveTurn(prompt: livePrompt)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private func historicalTurn(_ turn: Turn) -> some View {
        let isCollapsed = collapsedTurns.contains(turn.id)
        return ModeTurnCard(
            title: "Debate",
            subtitle: isCollapsed ? TurnFold.preview(turn) : "\(max((turn.debateRounds ?? []).count, 1)) 轮立论 / 反驳 / 修正",
            icon: "quote.bubble.fill",
            tint: debateTint,
            collapsed: isCollapsed,
            onToggleCollapse: { TurnFold.toggle(turn.id, in: &collapsedTurns) }
        ) {
            PromptBubble(prompt: turn.prompt, timestamp: turn.timestamp, images: turn.images ?? [],
                         onFork: { viewModel.forkConversation(fromTurnID: turn.id) },
                         onEdit: onEditTurn.map { f in { f(turn.id) } },
                         onFollowUp: onFollowUpTurn.map { f in { f(turn.id) } },
                         onExportReport: onExportTurn.map { f in { f(turn.id) } })

            let rounds = (turn.debateRounds ?? []).sorted { $0.index < $1.index }
            if rounds.isEmpty {
                // 兼容极早期/异常数据：没有 debateRounds 时展示最终 panel 结果。
                panelStack {
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
                            reasoning: turn.reasoningByProvider?[key],
                            tokenUsage: turn.tokenUsage?[key],
                            sources: turn.sourcesByProvider?[key] ?? []
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else {
                ForEach(rounds) { round in
                    historicalRound(round, turn: turn)
                }
            }

            if let moderator = turn.chairConfig {
                ChairSummaryCard(
                    config: moderator,
                    text: turn.chairSummary,
                    error: turn.chairError,
                    liveText: nil,
                    isStreaming: false,
                    role: .moderator,
                    onRetry: turn.chairError != nil ? {
                        viewModel.retryChair(turnID: turn.id, target: .chair)
                    } : nil,
                    isRetrying: viewModel.isRetryingChair(turnID: turn.id, target: .chair),
                    reasoning: turn.reasoningByProvider?[moderator.id.uuidString],
                    tokenUsage: turn.tokenUsage?[moderator.id.uuidString],
                    sources: turn.sources ?? []
                )
            }
            if let writes = turn.appliedWrites, !writes.isEmpty {
                AppliedWritesStrip(writes: writes, onUndo: { viewModel.undoWrite(turnID: turn.id, write: $0) })
            }
            TurnSourcesStrip(turn: turn)
        }
    }

    private func historicalRound(_ round: DebateRound, turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            roundHeader(index: round.index, title: round.title, live: false)
            panelStack {
                ForEach(configs(for: round, snapshot: turn.providerSnapshot, fallbackOrder: turn.panelOrder)) { cfg in
                    let key = cfg.id.uuidString
                    HistoricalResponseCard(
                        config: cfg,
                        text: round.responses[key] ?? "",
                        error: round.errors[key],
                        onRetry: round.errors[key] != nil ? {
                            viewModel.retryProvider(turnID: turn.id, configID: cfg.id, roundIndex: round.index)
                        } : nil,
                        isRetrying: viewModel.isRetrying(turnID: turn.id, configID: cfg.id, roundIndex: round.index)
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(12)
        .background(roundBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(debateTint.opacity(0.13), lineWidth: 1)
        }
    }

    private func liveTurn(prompt: String) -> some View {
        ModeTurnCard(
            title: "Debate",
            subtitle: liveDebateRounds.isEmpty ? "模型正在立论" : "模型正在阅读彼此观点并修正",
            icon: "quote.bubble.fill",
            tint: debateTint,
            isLive: isRunning
        ) {
            PromptBubble(prompt: prompt, timestamp: Date(), images: liveImages)

            ForEach(liveDebateRounds.sorted { $0.index < $1.index }) { round in
                liveCompletedRound(round)
            }

            if !liveStates.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    roundHeader(
                        index: liveDebateRounds.count + 1,
                        title: liveDebateRounds.isEmpty ? "立论" : "反驳 / 修正",
                        live: isRunning
                    )
                    panelStack {
                        ForEach(livePanel) { cfg in
                            if let state = liveStates[cfg.id] {
                                ResponseColumnView(config: cfg, state: state)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                }
                .padding(12)
                .background(roundBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(debateTint.opacity(0.18), lineWidth: 1)
                }
            }

            if let moderator = liveChair, let chairState = liveChairState {
                ChairSummaryCard(
                    config: moderator,
                    text: nil,
                    error: chairErrorMessage(chairState),
                    liveText: chairState.text,
                    isStreaming: isChairStreaming(chairState),
                    role: .moderator,
                    reasoning: chairState.reasoning
                )
            }
        }
    }

    private func liveCompletedRound(_ round: DebateRound) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            roundHeader(index: round.index, title: round.title, live: false)
            panelStack {
                ForEach(configs(for: round, snapshot: liveSnapshot, fallbackOrder: livePanel.map { $0.id.uuidString })) { cfg in
                    let key = cfg.id.uuidString
                    HistoricalResponseCard(
                        config: cfg,
                        text: round.responses[key] ?? "",
                        error: round.errors[key]
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(12)
        .background(roundBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(debateTint.opacity(0.13), lineWidth: 1)
        }
    }

    private func roundHeader(index: Int, title: String, live: Bool) -> some View {
        HStack(spacing: 8) {
            Text("ROUND \(index)")
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(debateTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(debateTint.opacity(0.12), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(debateTint.opacity(0.20), lineWidth: 1)
                }
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.bold))
            if live {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func panelStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if stacksVertically {
            VStack(alignment: .leading, spacing: 14) { content() }
        } else {
            AdaptivePanelGrid { content() }
        }
    }

    private var roundBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.platformControlBackground.opacity(0.26))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [debateTint.opacity(0.06), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var debateTint: Color {
        Color.indigo
    }

    private func configs(
        for round: DebateRound,
        snapshot: [String: ProviderConfig],
        fallbackOrder: [String]
    ) -> [ProviderConfig] {
        let order = round.panelOrder.isEmpty ? fallbackOrder : round.panelOrder
        return order.compactMap { snapshot[$0] }
    }

    private var liveSnapshot: [String: ProviderConfig] {
        Dictionary(uniqueKeysWithValues: livePanel.map { ($0.id.uuidString, $0) })
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
