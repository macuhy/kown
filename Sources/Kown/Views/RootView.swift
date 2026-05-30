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
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        conversationsButton
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        settingsButton
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        newConversationButton
                    }
                }
        }
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
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showConversations = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
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
        }
        .help("厂商配置")
    }

    private var conversationsButton: some View {
        Button {
            showConversations = true
        } label: {
            Image(systemName: "sidebar.left")
        }
        .help("会话列表")
    }

    private var newConversationButton: some View {
        Button {
            viewModel.newConversation(mode: viewModel.activeMode)
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .help("新建会话")
    }
}
