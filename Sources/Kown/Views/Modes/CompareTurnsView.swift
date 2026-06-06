import SwiftUI

/// Compare 模式:每个 turn = 用户问题 + 2 列回答并排 + 可选的裁判结论。
/// iPhone compact 宽度下两列改成垂直堆叠,避免固定高度 pager 裁切长回答。
struct CompareTurnsView: View {
    @Bindable var viewModel: AppViewModel
    let conversation: Conversation
    let liveStates: [UUID: ResponseState]
    let liveChairState: ResponseState?
    let livePrompt: String?
    var liveImages: [TurnImage] = []
    let livePanel: [ProviderConfig]
    let liveChair: ProviderConfig?
    /// 历史 turn 的「编辑并重发」动作(由父视图注入,打开编辑 sheet)。
    var onEditTurn: ((UUID) -> Void)? = nil
    /// 历史 turn 的追问 / 导出报告动作(由父视图注入)。
    var onFollowUpTurn: ((UUID) -> Void)? = nil
    var onExportTurn: ((UUID) -> Void)? = nil
    var onShareTurn: ((UUID) -> Void)? = nil

    @State private var collapsedTurns: Set<UUID> = []
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
                historicalTurn(turn)
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
            title: "Compare",
            subtitle: isCollapsed ? TurnFold.preview(turn) : "双模型并排对照，Judge 给出结论",
            icon: "rectangle.split.2x1.fill",
            tint: compareTint,
            collapsed: isCollapsed,
            onToggleCollapse: { TurnFold.toggle(turn.id, in: &collapsedTurns) }
        ) {
            PromptBubble(prompt: turn.prompt, timestamp: turn.timestamp, images: turn.images ?? [],
                         onFork: { viewModel.forkConversation(fromTurnID: turn.id) },
                         onEdit: onEditTurn.map { f in { f(turn.id) } },
                         onFollowUp: onFollowUpTurn.map { f in { f(turn.id) } },
                         onExportReport: onExportTurn.map { f in { f(turn.id) } },
                         onShareImage: onShareTurn.map { f in { f(turn.id) } })
            comparePanels(count: min(2, turn.orderedPanelConfigs.count)) {
                ForEach(Array(turn.orderedPanelConfigs.prefix(2))) { cfg in
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
                        sources: turn.sourcesByProvider?[key] ?? []
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            compareVerdictSection(turn)
            if let judge = turn.chairConfig {
                ChairSummaryCard(
                    config: judge,
                    text: turn.chairSummary,
                    error: turn.chairError,
                    liveText: nil,
                    isStreaming: false,
                    role: .judge,
                    onRetry: turn.chairError != nil ? {
                        viewModel.retryChair(turnID: turn.id, target: .chair)
                    } : nil,
                    isRetrying: viewModel.isRetryingChair(turnID: turn.id, target: .chair),
                    reasoning: turn.reasoningByProvider?[judge.id.uuidString],
                    tokenUsage: turn.tokenUsage?[judge.id.uuidString],
                    sources: turn.sources ?? [],
                    regenerateProviders: viewModel.regenerateCandidates,
                    onRegenerate: { viewModel.regenerateChairWithModel(turnID: turn.id, target: .chair, newProviderID: $0) }
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
            title: "Compare",
            subtitle: "\(min(livePanel.count, 2)) 个回答正在对照生成",
            icon: "rectangle.split.2x1.fill",
            tint: compareTint,
            isLive: true
        ) {
            PromptBubble(prompt: prompt, timestamp: Date(), images: liveImages)
            comparePanels(count: min(2, livePanel.count)) {
                ForEach(Array(livePanel.prefix(2))) { cfg in
                    if let state = liveStates[cfg.id] {
                        ResponseColumnView(config: cfg, state: state)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            if let judge = liveChair, let judgeState = liveChairState {
                ChairSummaryCard(
                    config: judge,
                    text: nil,
                    error: judgeErrorMessage(judgeState),
                    liveText: judgeState.text,
                    isStreaming: isJudgeStreaming(judgeState),
                    role: .judge,
                    reasoning: judgeState.reasoning
                )
            }
        }
    }

    /// iPhone 用 VStack;其他按可用宽度自动换列。
    @ViewBuilder
    private func comparePanels<Content: View>(count: Int, @ViewBuilder content: () -> Content) -> some View {
        if stacksVertically {
            VStack(alignment: .leading, spacing: 14) { content() }
        } else {
            AdaptivePanelGrid(minColumnWidth: 520, count: count) { content() }
        }
    }

    // MARK: - 裁判评判(verdict badge + 「让裁判评判」按钮)

    /// 已有判定 → 显示胜者徽章 + 理由;否则(两家回答都齐了)→ 显示「让裁判评判」按钮。
    @ViewBuilder
    private func compareVerdictSection(_ turn: Turn) -> some View {
        if let verdict = turn.compareVerdict {
            verdictBadge(turn: turn, verdict: verdict)
        } else if canJudge(turn) {
            judgeButton(turn: turn)
        }
    }

    /// 是否具备评判条件:取前两列、两家都有非空回答。
    private func canJudge(_ turn: Turn) -> Bool {
        let panel = Array(turn.orderedPanelConfigs.prefix(2))
        guard panel.count == 2 else { return false }
        return panel.allSatisfy { cfg in
            !(turn.responses[cfg.id.uuidString] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func judgeButton(turn: Turn) -> some View {
        let judging = viewModel.isJudgingCompare(turnID: turn.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                viewModel.judgeCompare(turnID: turn.id)
            } label: {
                HStack(spacing: 7) {
                    if judging {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "scalemass.fill")
                    }
                    Text(judging ? "裁判评判中…" : "让裁判评判")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(compareTint.opacity(0.12), in: Capsule())
                .foregroundStyle(compareTint)
                .overlay { Capsule().strokeBorder(compareTint.opacity(0.28), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(judging)

            if let err = viewModel.judgeCompareErrors[turn.id] {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verdictBadge(turn: Turn, verdict: CompareVerdict) -> some View {
        let winner = turn.providerSnapshot[verdict.winnerProviderID]
        let winnerName = winner?.displayName ?? "未知模型"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "trophy.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(verdictTint)
                Text("裁判判定")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(winnerName)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(verdictTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(verdictTint.opacity(0.14), in: Capsule())
                    .lineLimit(1).truncationMode(.middle)
                Text("胜")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if !verdict.rationale.isEmpty {
                Text(verdict.rationale)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(verdictTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(verdictTint.opacity(0.22), lineWidth: 1)
        }
    }

    private var verdictTint: Color {
        Color(red: 0.85, green: 0.60, blue: 0.14)
    }

    private var compareTint: Color {
        Color(red: 0.83, green: 0.38, blue: 0.18)
    }

    private func isJudgeStreaming(_ state: ResponseState) -> Bool {
        if case .streaming = state.phase { return true }
        return false
    }

    private func judgeErrorMessage(_ state: ResponseState) -> String? {
        if case .failed(let msg) = state.phase { return msg }
        return nil
    }
}
