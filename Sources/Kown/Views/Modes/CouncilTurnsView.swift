import SwiftUI

/// Council 模式：每个 turn = 用户问题 + 横向多列回答 + 可选 Chair 综合
struct CouncilTurnsView: View {
    @Bindable var viewModel: AppViewModel
    let conversation: Conversation
    let liveStates: [UUID: ResponseState]
    let liveChairState: ResponseState?
    let liveSummaryState: ResponseState?
    let livePrompt: String?
    let isRunning: Bool
    /// 用于 live turn 推断当前 panel/chair/summary
    let livePanel: [ProviderConfig]
    let liveChair: ProviderConfig?
    let liveSummary: ProviderConfig?

    /// iPhone compact 宽度下 panel 改成垂直堆叠;iPad / Mac 仍并排
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var stacksVertically: Bool {
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
                        isRetrying: viewModel.isRetrying(turnID: turn.id, configID: cfg.id)
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
                    isRetrying: viewModel.isRetryingChair(turnID: turn.id, target: .chair)
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
                    isRetrying: viewModel.isRetryingChair(turnID: turn.id, target: .summary)
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
            panelStack {
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
                    isStreaming: isChairStreaming(chairState)
                )
            }
            if let summary = liveSummary, let summaryState = liveSummaryState {
                ChairSummaryCard(
                    config: summary,
                    text: nil,
                    error: chairErrorMessage(summaryState),
                    liveText: summaryState.text,
                    isStreaming: isChairStreaming(summaryState),
                    role: .summary
                )
            }
        }
    }

    /// 紧凑(iPhone)用 VStack,常规(iPad / Mac)用 HStack。
    @ViewBuilder
    private func panelStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if stacksVertically {
            VStack(alignment: .leading, spacing: 12) { content() }
        } else {
            HStack(alignment: .top, spacing: 12) { content() }
        }
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
