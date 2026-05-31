import SwiftUI

/// Compare 模式:每个 turn = 用户问题 + 2 列回答并排 + 可选的裁判结论。
/// iPhone compact 宽度下两列改成 TabView 横向滑动(swipe between models)。
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

    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var pages: Bool {
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
        ModeTurnCard(
            title: "Compare",
            subtitle: "双模型并排对照，Judge 给出结论",
            icon: "rectangle.split.2x1.fill",
            tint: compareTint
        ) {
            PromptBubble(prompt: turn.prompt, timestamp: turn.timestamp, images: turn.images ?? [],
                         onFork: { viewModel.forkConversation(fromTurnID: turn.id) },
                         onEdit: onEditTurn.map { f in { f(turn.id) } },
                         onFollowUp: onFollowUpTurn.map { f in { f(turn.id) } },
                         onExportReport: onExportTurn.map { f in { f(turn.id) } })
            comparePanels {
                ForEach(Array(turn.orderedPanelConfigs.prefix(2))) { cfg in
                    let key = cfg.id.uuidString
                    HistoricalResponseCard(
                        config: cfg,
                        text: turn.responses[key] ?? "",
                        error: turn.errors[key],
                        onRetry: turn.errors[key] != nil ? {
                            viewModel.retryProvider(turnID: turn.id, configID: cfg.id)
                        } : nil,
                        isRetrying: viewModel.isRetrying(turnID: turn.id, configID: cfg.id)
                    )
                    .frame(maxWidth: .infinity)
                }
            }
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
                    isRetrying: viewModel.isRetryingChair(turnID: turn.id, target: .chair)
                )
            }
            if let writes = turn.appliedWrites, !writes.isEmpty {
                AppliedWritesStrip(writes: writes)
            }
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
            comparePanels {
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
                    role: .judge
                )
            }
        }
    }

    /// iPhone(pages=true)用 TabView 滑动;其他用 HStack 并排。
    @ViewBuilder
    private func comparePanels<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if pages {
            #if os(iOS)
            TabView {
                content()
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(minHeight: 440)
            #else
            HStack(alignment: .top, spacing: 14) { content() }
            #endif
        } else {
            HStack(alignment: .top, spacing: 14) { content() }
        }
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
