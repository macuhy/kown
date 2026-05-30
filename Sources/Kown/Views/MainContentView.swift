import SwiftUI

struct MainContentView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showSystemPromptDrawer = false
    @FocusState private var inputFocused: Bool
    @Binding var showSettings: Bool

    var body: some View {
        ZStack {
            MainWorkspaceBackdrop(mode: viewModel.currentMode)
            VStack(spacing: 0) {
                #if os(iOS)
                mobileModeBar
                #endif
                workspacePathBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(iOS)
                mobileComposerDock
                #else
                ActiveProviderBar(viewModel: viewModel)
                InputBarView(
                    viewModel: viewModel,
                    showSystemPromptDrawer: $showSystemPromptDrawer,
                    inputFocused: $inputFocused
                )
                #endif
            }
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
            .contentMargins(.bottom, 10, for: .scrollContent)
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
                    let lImages = showLive ? viewModel.liveTurnImages : []
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
                                liveImages: lImages,
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
                                liveImages: lImages,
                                livePanel: viewModel.providersForCurrentSend().panel
                            )
                        case .compare:
                            CompareTurnsView(
                                viewModel: viewModel,
                                conversation: conv ?? Conversation(),
                                liveStates: lStates,
                                liveChairState: lChair,
                                livePrompt: lPrompt,
                                liveImages: lImages,
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
                                liveImages: lImages,
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
                .contentMargins(.bottom, 14, for: .scrollContent)
                #endif
            }
        }
    }

    /// Workspace 路径条 — 设置了 working folder 时在会话顶端显示完整路径。
    /// 点击在 Finder 里展开;✕ 解除 workspace。
    @ViewBuilder
    private var workspacePathBar: some View {
        if let path = viewModel.currentWorkspaceDisplayPath {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text("Workspace")
                        .font(.caption2.weight(.black))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                #if os(macOS)
                Button {
                    let url = URL(fileURLWithPath: path)
                    Platform.revealInExplorer(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .help("在 Finder 里打开")
                #endif
                Button {
                    viewModel.clearWorkspace()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.04), in: Circle())
                }
                .buttonStyle(.plain)
                .help("移除 workspace")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.10), Color.clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            #if os(iOS)
            .padding(.vertical, 6)
            #else
            .padding(.vertical, 8)
            #endif
            .background {
                Rectangle().fill(.thinMaterial)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            }
        }
    }

    #if os(iOS)
    private var mobileModeBar: some View {
        HStack(spacing: 8) {
            ModeTabsView(viewModel: viewModel)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        modeTint.opacity(0.08),
                        Color.orange.opacity(viewModel.currentMode == .debate ? 0.05 : 0.02),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }

    private var mobileComposerDock: some View {
        VStack(spacing: 0) {
            ActiveProviderBar(viewModel: viewModel)
            InputBarView(
                viewModel: viewModel,
                showSystemPromptDrawer: $showSystemPromptDrawer,
                inputFocused: $inputFocused
            )
        }
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [modeTint.opacity(0.10), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }

    private var modeTint: Color {
        switch viewModel.currentMode {
        case .council: return Color(red: 0.10, green: 0.66, blue: 0.56)
        case .direct:  return Color(red: 0.16, green: 0.48, blue: 0.94)
        case .compare: return Color(red: 0.91, green: 0.55, blue: 0.20)
        case .debate:  return Color(red: 0.88, green: 0.35, blue: 0.22)
        }
    }
    #endif
}

private struct MainWorkspaceBackdrop: View {
    let mode: ConversationMode

    var body: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [tint.opacity(0.16), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 560
            )
            RadialGradient(
                colors: [Color.orange.opacity(mode == .debate ? 0.16 : 0.10), Color.clear],
                center: .bottomTrailing,
                startRadius: 80,
                endRadius: 620
            )
            LinearGradient(
                colors: [Color.white.opacity(0.035), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var tint: Color {
        switch mode {
        case .council: return Color(red: 0.10, green: 0.66, blue: 0.56)
        case .direct:  return Color(red: 0.16, green: 0.48, blue: 0.94)
        case .compare: return Color(red: 0.91, green: 0.55, blue: 0.20)
        case .debate:  return Color(red: 0.88, green: 0.35, blue: 0.22)
        }
    }
}
