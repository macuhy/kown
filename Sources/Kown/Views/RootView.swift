import SwiftUI

struct RootView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showSettings = false
    @State private var showConversations = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // [MeetingNotes] 录音/会议转写工具 sheet 开关。
    @State private var showMeetingNotes = false
    // [VoiceJournal] 语音随手记 sheet 开关(跨平台)。
    @State private var showVoiceJournal = false
    #if os(macOS)
    // [ScreenCopilot] 实时屏幕副驾 sheet 开关(macOS 专属)。
    @State private var showScreenCopilot = false
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            iOSBody
            #else
            desktopBody
            #endif
        }
        // 设备码授权:从输入栏发起(设置已关)时用这个全局 sheet 展示验证码。
        // 从设置页发起时,设置本身是 sheet,再叠一个 sheet 会被 macOS 排到设置关闭后才显示 ——
        // 那种情况改由设置页 GitHubConnectionCard 内联展示;这里用 !showSettings 门控避免重复弹出。
        .sheet(item: Binding(
            get: { showSettings ? nil : viewModel.gitHubPendingDeviceCode },
            set: { if $0 == nil { viewModel.cancelGitHubDeviceFlow() } }
        )) { device in
            GitHubDeviceCodeSheet(device: device) {
                viewModel.cancelGitHubDeviceFlow()
            }
        }
    }

    private var desktopBody: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel, onOpenSettings: {
                showSettings = true
            })
        } detail: {
            MainContentView(viewModel: viewModel, showSettings: $showSettings)
                .inspector(isPresented: $viewModel.showArtifactPanel) {
                    ArtifactPreviewPanel(viewModel: viewModel)
                        .inspectorColumnWidth(min: 300, ideal: 420, max: 720)
                }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ModeTabsView(viewModel: viewModel)
                    .frame(maxWidth: 500)
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                settingsButton
            }
            #else
            // [ScreenCopilot] Mac 工具栏入口:实时屏幕副驾。
            ToolbarItem(placement: .primaryAction) {
                screenCopilotButton
            }
            // [VoiceJournal] Mac 工具栏入口:语音随手记。
            ToolbarItem(placement: .primaryAction) {
                voiceJournalButton
            }
            // [MeetingNotes] Mac 工具栏入口:录音/会议转写。
            ToolbarItem(placement: .primaryAction) {
                meetingNotesButton
            }
            ToolbarItem(placement: .primaryAction) {
                artifactToggleButton
            }
            ToolbarItem(placement: .primaryAction) {
                settingsButton
            }
            #endif
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
                #if os(macOS)
                .frame(width: 960, height: 660)
                #endif
        }
        .sheet(isPresented: $viewModel.showCommandPalette) {
            CommandPaletteView(viewModel: viewModel)
        }
        // [MeetingNotes] 录音/会议转写工具。
        .sheet(isPresented: $showMeetingNotes) {
            MeetingNotesView(viewModel: viewModel)
        }
        // [VoiceJournal] 语音随手记(跨平台)。
        .sheet(isPresented: $showVoiceJournal) {
            voiceJournalSheet
        }
        #if os(macOS)
        // [ScreenCopilot] 实时屏幕副驾(macOS 专属)。
        .sheet(isPresented: $showScreenCopilot) {
            screenCopilotSheet
        }
        #endif
        // [生成式 UI] AI 现做交互工具面板(macOS sheet,与 Artifacts inspector 互不抢位)。
        .sheet(isPresented: $viewModel.showGenerativeToolPanel) {
            GenerativeToolPanel(viewModel: viewModel)
                #if os(macOS)
                .frame(width: 540, height: 640)
                #endif
        }
    }

    // [VoiceJournal] 语音随手记 sheet 内容(两端共用主体,平台各自包装)。
    private var voiceJournalSheet: some View {
        NavigationStack {
            ScrollView {
                VoiceJournalView(viewModel: viewModel)
                    .padding(.horizontal, 20).padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("语音随手记")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if SpeechRecognizer.shared.isRecording { SpeechRecognizer.shared.stop() }
                        showVoiceJournal = false
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        #endif
    }

    #if os(macOS)
    // [ScreenCopilot] 实时屏幕副驾 sheet 内容。
    private var screenCopilotSheet: some View {
        NavigationStack {
            ScrollView {
                ScreenCopilotView(viewModel: viewModel)
                    .padding(.horizontal, 20).padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("实时屏幕副驾")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        // 关面板默认停掉看屏(隐私:不留后台偷看)。
                        ScreenCopilotService.shared.stop()
                        showScreenCopilot = false
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 660)
    }
    #endif

    #if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            MainContentView(viewModel: viewModel, showSettings: $showSettings)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        conversationsButton
                    }
                    ToolbarItem(placement: .principal) {
                        iOSNavigationIdentity
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        utilityMenuButton
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        newConversationButton
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .tint(iOSModeTint)
        .sheet(isPresented: $showConversations) {
            NavigationStack {
                SidebarView(
                    viewModel: viewModel,
                    onOpenSettings: {
                        showConversations = false
                        showSettings = true
                    },
                    onSelectConversation: {
                        showConversations = false
                    }
                )
                .navigationTitle("会话")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showConversations = false }
                            .font(.callout.weight(.semibold))
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $viewModel.showCommandPalette) {
            CommandPaletteView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $viewModel.showArtifactPanel) {
            ArtifactPreviewPanel(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        // [生成式 UI] AI 现做交互工具面板(iOS sheet)。
        .sheet(isPresented: $viewModel.showGenerativeToolPanel) {
            GenerativeToolPanel(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        // [MeetingNotes] 录音/会议转写工具(iOS)。
        .sheet(isPresented: $showMeetingNotes) {
            MeetingNotesView(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
    }

    private var iOSNavigationIdentity: some View {
        let tint = viewModel.currentMode.kownTint
        return HStack(spacing: 9) {
            Image("AppIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(iOSConversationTitle)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(viewModel.currentMode.localizedDisplayName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 156, alignment: .leading)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.14), lineWidth: 1)
        }
    }

    private var iOSConversationTitle: String {
        let title = viewModel.selectedConversation?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty || title == "New Conversation" ? "Kown" : title
    }
    #endif

    /// 切换 Artifacts 预览面板。常驻显示(不依赖检测),无 artifact 时面板给空态。
    private var artifactToggleButton: some View {
        Button {
            viewModel.showArtifactPanel.toggle()
        } label: {
            Image(systemName: viewModel.showArtifactPanel ? "rectangle.righthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                #if os(iOS)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                #endif
        }
        .help("Artifacts 预览")
    }

    // [MeetingNotes] 工具栏按钮:打开录音/会议转写工具。
    private var meetingNotesButton: some View {
        Button {
            showMeetingNotes = true
        } label: {
            Image(systemName: "waveform.badge.mic")
                #if os(iOS)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                #endif
        }
        .help("录音 / 会议转写 → AI 纪要")
    }

    // [VoiceJournal] 工具栏按钮:打开语音随手记。
    private var voiceJournalButton: some View {
        Button {
            showVoiceJournal = true
        } label: {
            Image(systemName: "mic.badge.plus")
                #if os(iOS)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                #endif
        }
        .help("语音随手记 → 自动打标归档")
    }

    #if os(macOS)
    // [ScreenCopilot] 工具栏按钮:打开实时屏幕副驾(macOS)。
    private var screenCopilotButton: some View {
        Button {
            showScreenCopilot = true
        } label: {
            Image(systemName: "eye")
        }
        .help("实时屏幕副驾:看屏 + 基于屏幕内容提问")
    }
    #endif

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                #if os(iOS)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(viewModel.currentMode.kownTint.opacity(0.12), lineWidth: 1)
                }
                #endif
        }
        #if os(iOS)
        .buttonStyle(.plain)
        #endif
        .help("设置")
    }

    private var commandPaletteButton: some View {
        Button {
            viewModel.showCommandPalette = true
        } label: {
            Image(systemName: "command")
                #if os(iOS)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(viewModel.currentMode.kownTint.opacity(0.12), lineWidth: 1)
                }
                #endif
        }
        #if os(iOS)
        .buttonStyle(.plain)
        #endif
        .help("命令面板")
    }

    private var conversationsButton: some View {
        Button {
            showConversations = true
        } label: {
            Image(systemName: "sidebar.left")
                #if os(iOS)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(viewModel.currentMode.kownTint.opacity(0.12), lineWidth: 1)
                }
                #endif
        }
        #if os(iOS)
        .buttonStyle(.plain)
        #endif
        .help("会话列表")
    }

    #if os(iOS)
    private var utilityMenuButton: some View {
        Menu {
            Button {
                viewModel.showCommandPalette = true
            } label: {
                Label("命令面板", systemImage: "command")
            }
            Button {
                viewModel.showArtifactPanel = true
            } label: {
                Label("Artifacts 预览", systemImage: "rectangle.righthalf.inset.filled")
            }
            // [MeetingNotes] iOS「更多操作」菜单入口。
            Button {
                showMeetingNotes = true
            } label: {
                Label("会议纪要", systemImage: "waveform.badge.mic")
            }
            // [VoiceJournal] iOS「更多操作」菜单入口。
            Button {
                showVoiceJournal = true
            } label: {
                Label("语音随手记", systemImage: "mic.badge.plus")
            }
            Button {
                showSettings = true
            } label: {
                Label("厂商配置", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(viewModel.currentMode.kownTint.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help("更多操作")
    }
    #endif

    private var newConversationButton: some View {
        Button {
            viewModel.newConversation(mode: viewModel.currentMode)
        } label: {
            Image(systemName: "square.and.pencil")
                #if os(iOS)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(
                        colors: [iOSModeTint.opacity(0.98), viewModel.currentMode.kownSecondaryTint.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                }
                .shadow(color: iOSModeTint.opacity(0.20), radius: 10, x: 0, y: 5)
                #endif
        }
        #if os(iOS)
        .buttonStyle(.plain)
        #endif
        .help("新建会话")
    }

    #if os(iOS)
    private var iOSModeTint: Color { viewModel.currentMode.kownTint }
    #endif
}
