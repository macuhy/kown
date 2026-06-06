import SwiftUI

/// Tournament(擂台 / 淘汰赛)模式:所有启用的模型先各自回答(种子),
/// 再由裁判用单淘汰赛两两对决,逐轮裁定胜者晋级,直到决出最终冠军。
/// 结构 / 样式对齐 `DebateTurnsView` / `CompareTurnsView`。
struct TournamentTurnsView: View {
    @Bindable var viewModel: AppViewModel
    let conversation: Conversation
    let liveStates: [UUID: ResponseState]
    let liveTournamentRounds: [TournamentRound]
    let livePrompt: String?
    var liveImages: [TurnImage] = []
    let isRunning: Bool
    let livePanel: [ProviderConfig]
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

    // MARK: - 历史 turn

    private func historicalTurn(_ turn: Turn) -> some View {
        let isCollapsed = collapsedTurns.contains(turn.id)
        let rounds = (turn.tournamentRounds ?? []).sorted { $0.index < $1.index }
        return ModeTurnCard(
            title: "Tournament",
            subtitle: isCollapsed ? TurnFold.preview(turn) : "\(turn.orderedPanelConfigs.count) 位选手 · \(max(rounds.count, 1)) 轮淘汰赛",
            icon: "trophy",
            tint: tournamentTint,
            collapsed: isCollapsed,
            onToggleCollapse: { TurnFold.toggle(turn.id, in: &collapsedTurns) }
        ) {
            PromptBubble(prompt: turn.prompt, timestamp: turn.timestamp, images: turn.images ?? [],
                         onFork: { viewModel.forkConversation(fromTurnID: turn.id) },
                         onEdit: onEditTurn.map { f in { f(turn.id) } },
                         onFollowUp: onFollowUpTurn.map { f in { f(turn.id) } },
                         onExportReport: onExportTurn.map { f in { f(turn.id) } },
                         onShareImage: onShareTurn.map { f in { f(turn.id) } })

            // 冠军横幅(最终冠军 = 最后一轮唯一对决的胜者)。
            if let champ = champion(rounds: rounds, snapshot: turn.providerSnapshot) {
                championBanner(champ)
            }

            // 种子回答(各家对原问题的回答)。
            seedHeader
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
                        reasoning: turn.reasoningByProvider?[key],
                        tokenUsage: turn.tokenUsage?[key],
                        sources: turn.sourcesByProvider?[key] ?? []
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            // 对决赛程。
            ForEach(rounds) { round in
                roundBracket(round, snapshot: turn.providerSnapshot)
            }
            if let writes = turn.appliedWrites, !writes.isEmpty {
                AppliedWritesStrip(writes: writes, onUndo: { viewModel.undoWrite(turnID: turn.id, write: $0) })
            }
            TurnSourcesStrip(turn: turn)
        }
    }

    // MARK: - 直播 turn

    private func liveTurn(prompt: String) -> some View {
        ModeTurnCard(
            title: "Tournament",
            subtitle: liveTournamentRounds.isEmpty ? "选手正在各自作答" : "裁判正在裁定对决",
            icon: "trophy",
            tint: tournamentTint,
            isLive: isRunning
        ) {
            PromptBubble(prompt: prompt, timestamp: Date(), images: liveImages)

            seedHeader
            if !liveStates.isEmpty {
                panelStack(count: livePanel.count) {
                    ForEach(livePanel) { cfg in
                        if let state = liveStates[cfg.id] {
                            ResponseColumnView(config: cfg, state: state)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }

            ForEach(liveTournamentRounds.sorted { $0.index < $1.index }) { round in
                roundBracket(round, snapshot: liveSnapshot)
            }
        }
    }

    // MARK: - 赛程渲染

    private func roundBracket(_ round: TournamentRound, snapshot: [String: ProviderConfig]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            roundHeader(index: round.index, title: round.title)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(round.matches) { match in
                    matchCard(match, snapshot: snapshot)
                }
            }
        }
        .padding(12)
        .background(roundBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tournamentTint.opacity(0.13), lineWidth: 1)
        }
    }

    private func matchCard(_ match: TournamentRound.Match, snapshot: [String: ProviderConfig]) -> some View {
        let aWon = match.winnerProviderID == match.aProviderID
        let bWon = match.bProviderID != nil && match.winnerProviderID == match.bProviderID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                contenderChip(providerID: match.aProviderID, snapshot: snapshot, won: aWon)
                Text("VS")
                    .font(.system(.caption2, design: .monospaced).weight(.heavy))
                    .foregroundStyle(.secondary)
                if let bID = match.bProviderID {
                    contenderChip(providerID: bID, snapshot: snapshot, won: bWon)
                } else {
                    Text("轮空")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.platformControlBackground.opacity(0.4), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            if let err = match.error, !err.isEmpty {
                Text("裁判调用失败:\(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !match.rationale.isEmpty {
                Text(match.rationale)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.26),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tournamentTint.opacity(0.10), lineWidth: 1)
        }
    }

    private func contenderChip(providerID: String, snapshot: [String: ProviderConfig], won: Bool) -> some View {
        let name = snapshot[providerID].map { PromptBuilders.providerLabel($0) } ?? "选手"
        return HStack(spacing: 6) {
            if won {
                Image(systemName: "crown.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(championGold)
            }
            Text(name)
                .font(.caption.weight(won ? .bold : .semibold))
                .lineLimit(1)
                .foregroundStyle(won ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background((won ? championGold.opacity(0.15) : Color.platformControlBackground.opacity(0.4)), in: Capsule())
        .overlay {
            Capsule().strokeBorder((won ? championGold : Color.primary).opacity(won ? 0.4 : 0.08), lineWidth: 1)
        }
    }

    private func championBanner(_ cfg: ProviderConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trophy.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(championGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("冠军")
                    .font(.caption2.weight(.black))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Text(PromptBuilders.providerLabel(cfg))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [championGold.opacity(0.18), Color.clear],
                                         startPoint: .leading, endPoint: .trailing))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(championGold.opacity(0.35), lineWidth: 1)
        }
    }

    private var seedHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.3.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(tournamentTint)
            Text("种子回答")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
            Spacer()
        }
    }

    private func roundHeader(index: Int, title: String) -> some View {
        HStack(spacing: 8) {
            Text("ROUND \(index)")
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(tournamentTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tournamentTint.opacity(0.12), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(tournamentTint.opacity(0.20), lineWidth: 1)
                }
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.bold))
            Spacer()
        }
    }

    @ViewBuilder
    private func panelStack<Content: View>(count: Int, @ViewBuilder content: () -> Content) -> some View {
        if stacksVertically {
            VStack(alignment: .leading, spacing: 14) { content() }
        } else {
            AdaptivePanelGrid(count: count) { content() }
        }
    }

    private var roundBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.platformControlBackground.opacity(0.26))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tournamentTint.opacity(0.06), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    // MARK: - 工具

    /// 冠军 = 最后一轮(决赛)唯一对决的胜者。
    private func champion(rounds: [TournamentRound], snapshot: [String: ProviderConfig]) -> ProviderConfig? {
        guard let last = rounds.max(by: { $0.index < $1.index }),
              let winner = last.matches.last?.winnerProviderID else { return nil }
        return snapshot[winner]
    }

    private var liveSnapshot: [String: ProviderConfig] {
        Dictionary(uniqueKeysWithValues: livePanel.map { ($0.id.uuidString, $0) })
    }

    private var tournamentTint: Color {
        Color(red: 0.85, green: 0.62, blue: 0.13)
    }

    private var championGold: Color {
        Color(red: 0.90, green: 0.68, blue: 0.15)
    }
}
