import SwiftUI

/// Compare 模式:每个 turn = 用户问题 + 2 列回答并排 + 可选的裁判结论。
/// iPhone compact 宽度下两列改成 TabView 横向滑动(swipe between models)。
struct CompareTurnsView: View {
    @Bindable var viewModel: AppViewModel
    let conversation: Conversation
    let liveStates: [UUID: ResponseState]
    let liveChairState: ResponseState?
    let livePrompt: String?
    let livePanel: [ProviderConfig]
    let liveChair: ProviderConfig?

    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var pages: Bool {
        #if os(iOS)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(conversation.turns) { turn in
                historicalTurn(turn)
            }
            if let livePrompt {
                liveTurn(prompt: livePrompt)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func historicalTurn(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PromptBubble(prompt: turn.prompt, timestamp: turn.timestamp)
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
        VStack(alignment: .leading, spacing: 12) {
            PromptBubble(prompt: prompt, timestamp: Date())
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
            .frame(minHeight: 420)
            #else
            HStack(alignment: .top, spacing: 12) { content() }
            #endif
        } else {
            HStack(alignment: .top, spacing: 12) { content() }
        }
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
