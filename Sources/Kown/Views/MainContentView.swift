import SwiftUI

struct MainContentView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showSystemPromptDrawer = false
    @FocusState private var inputFocused: Bool
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            mobileModeBar
            #endif
            workspacePathBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ActiveProviderBar(viewModel: viewModel)
            InputBarView(
                viewModel: viewModel,
                showSystemPromptDrawer: $showSystemPromptDrawer,
                inputFocused: $inputFocused
            )
        }
        .navigationTitle(viewModel.selectedConversation?.title ?? "New Conversation")
        .onAppear {
            #if !os(iOS)
            // iOS 上不 auto-focus(避免 NavigationStack push 动画与 @FocusState 抢占),
            // 让用户点输入框自然唤起键盘
            inputFocused = true
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        let conv = viewModel.selectedConversation
        let hasTurns = conv?.turns.isEmpty == false
        let hasLive = viewModel.liveTurnPrompt != nil
        if !hasTurns && !hasLive {
            ScrollView {
                EmptyStateCard(
                    mode: viewModel.currentMode,
                    providers: viewModel.providers,
                    onOpenSettings: { showSettings = true }
                )
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // 当前会话 == 正在跑的会话 时才把直播 state 透给 TurnsView。
                    // 否则用户切到别的会话只看历史,后台任务继续跑(切回原会话自然又看到直播)。
                    let showLive = viewModel.runningConvID == conv?.id
                    let lStates = showLive ? viewModel.liveStates : [:]
                    let lChair = showLive ? viewModel.liveChairState : nil
                    let lSummary = showLive ? viewModel.liveSummaryState : nil
                    let lPrompt = showLive ? viewModel.liveTurnPrompt : nil
                    let lDebateRounds = showLive ? viewModel.liveDebateRounds : []
                    let lIsRunning = showLive && viewModel.isRunning
                    Group {
                        switch viewModel.currentMode {
                        case .council:
                            CouncilTurnsView(
                                viewModel: viewModel,
                                conversation: conv ?? Conversation(),
                                liveStates: lStates,
                                liveChairState: lChair,
                                liveSummaryState: lSummary,
                                livePrompt: lPrompt,
                                isRunning: lIsRunning,
                                livePanel: viewModel.providersForCurrentSend().panel,
                                liveChair: viewModel.chairProvider,
                                liveSummary: viewModel.summaryProvider
                            )
                        case .direct:
                            DirectTurnsView(
                                conversation: conv ?? Conversation(),
                                liveStates: lStates,
                                livePrompt: lPrompt,
                                livePanel: viewModel.providersForCurrentSend().panel
                            )
                        case .compare:
                            CompareTurnsView(
                                viewModel: viewModel,
                                conversation: conv ?? Conversation(),
                                liveStates: lStates,
                                liveChairState: lChair,
                                livePrompt: lPrompt,
                                livePanel: viewModel.providersForCurrentSend().panel,
                                liveChair: viewModel.providersForCurrentSend().chair
                            )
                        case .debate:
                            DebateTurnsView(
                                viewModel: viewModel,
                                conversation: conv ?? Conversation(),
                                liveStates: lStates,
                                liveChairState: lChair,
                                liveDebateRounds: lDebateRounds,
                                livePrompt: lPrompt,
                                isRunning: lIsRunning,
                                livePanel: viewModel.providersForCurrentSend().panel,
                                liveChair: viewModel.chairProvider
                            )
                        }
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .onChange(of: viewModel.liveTurnPrompt) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
            }
        }
    }

    /// Workspace 路径条 — 设置了 working folder 时在会话顶端显示完整路径。
    /// 点击在 Finder 里展开;✕ 解除 workspace。
    @ViewBuilder
    private var workspacePathBar: some View {
        if let path = viewModel.currentWorkspaceDisplayPath {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Workspace")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #if os(macOS)
                Button {
                    let url = URL(fileURLWithPath: path)
                    Platform.revealInExplorer(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("在 Finder 里打开")
                #endif
                Button {
                    viewModel.clearWorkspace()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("移除 workspace")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.08))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.accentColor.opacity(0.20)).frame(height: 1)
            }
        }
    }

    #if os(iOS)
    private var mobileModeBar: some View {
        HStack {
            Spacer(minLength: 0)
            ModeTabsView(viewModel: viewModel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }
    #endif
}
