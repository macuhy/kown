import SwiftUI

struct RootView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showSettings = false
    @State private var showConversations = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        desktopBody
        #endif
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
                        settingsButton
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
    }

    private var iOSNavigationIdentity: some View {
        HStack(spacing: 9) {
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
                    .foregroundStyle(iOSModeTint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 190, alignment: .leading)
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
                .frame(width: 34, height: 34)
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                #endif
        }
        #if os(iOS)
        .buttonStyle(.plain)
        #endif
        .help("厂商配置")
    }

    private var conversationsButton: some View {
        Button {
            showConversations = true
        } label: {
            Image(systemName: "sidebar.left")
                #if os(iOS)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                #endif
        }
        #if os(iOS)
        .buttonStyle(.plain)
        #endif
        .help("会话列表")
    }

    private var newConversationButton: some View {
        Button {
            viewModel.newConversation(mode: viewModel.activeMode)
        } label: {
            Image(systemName: "square.and.pencil")
                #if os(iOS)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    LinearGradient(
                        colors: [iOSModeTint.opacity(0.98), iOSModeTint.opacity(0.72)],
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
    private var iOSModeTint: Color {
        switch viewModel.currentMode {
        case .council: return Color(red: 0.10, green: 0.66, blue: 0.56)
        case .direct:  return Color(red: 0.16, green: 0.48, blue: 0.94)
        case .compare: return Color(red: 0.91, green: 0.55, blue: 0.20)
        case .debate:  return Color(red: 0.88, green: 0.35, blue: 0.22)
        }
    }
    #endif
}
