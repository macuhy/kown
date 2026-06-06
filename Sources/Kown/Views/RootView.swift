import SwiftUI

struct RootView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showSettings = false
    @State private var showConversations = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            #if os(iOS)
            iOSBody
            #else
            desktopBody
            #endif
        }
        // 设备码授权进行中时,全局弹出展示验证码的 sheet(从设置页或输入栏发起都能正常显示)。
        .sheet(item: $viewModel.gitHubPendingDeviceCode) { device in
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
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ModeTabsView(viewModel: viewModel)
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                settingsButton
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                logsButton
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
    }

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
                Text(viewModel.selectedConversation?.title ?? "Kown")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(viewModel.currentMode.displayName)
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
    #endif

    private var logsButton: some View {
        Button {
            Platform.revealInExplorer(ResponseLogger.logsDirectory)
        } label: {
            Image(systemName: "doc.text")
        }
        .help("打开日志目录")
    }

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
        .help("厂商配置")
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
