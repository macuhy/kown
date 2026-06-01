import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
private class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return false
            }
        }
        return true
    }
}
#endif

@main
struct KownApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif
    /// 启动闪屏开关 — 两端通用。
    @State private var showLaunchSplash = true
    @State private var viewModel = AppViewModel()
    /// 更新日志弹窗 — 启动时若 app 版本 > 上次看到版本则自动弹
    @State private var showChangelog = false
    /// 监听 app 前后台切换 — 从 background 切回 .active 时主动从 iCloud 拉一次最新数据,
    /// 否则另一端写入的会话/总结/Chair 输出永远只在 app 启动那一刻被读到。
    @Environment(\.scenePhase) private var scenePhase
    /// 跳过启动时第一次 .active 触发的 refresh — AppViewModel.init 的延迟 task 会兜底,
    /// 否则两个 refresh 同时跑,把 main thread 卡住,UI 启动几秒不响应。
    @State private var hasSeenInitialActive = false

    init() {
        CrashLogger.install()
        #if os(macOS)
        captureCLIPromptIfAny()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView(viewModel: viewModel)
                #if os(macOS)
                    .frame(minWidth: 1100, minHeight: 720)
                #endif

                if showLaunchSplash {
                    LaunchSplashView()
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .task {
                #if os(macOS)
                // 注册全局热键 ⌃⌥K(唤起主窗口 + 聚焦输入框)。
                MacQuickAsk.registerHotKey(viewModel: viewModel)
                // 启动即拉起 Sparkle 更新器(按 SUScheduledCheckInterval 定时检查)。
                _ = UpdaterService.shared
                // 再额外强制一次后台静默检查 —— Sparkle 定时器要等满间隔才查,
                // 这里保证「每次打开 App 都检测」。稍等让启动稳定再查。
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    UpdaterService.shared.checkInBackground()
                }
                #endif
                guard showLaunchSplash else { return }
                try? await Task.sleep(for: .milliseconds(1750))
                withAnimation(.easeInOut(duration: 0.42)) {
                    showLaunchSplash = false
                }
                // 闪屏消失后稍等一下,如果有未看过的更新,弹"What's New"
                try? await Task.sleep(for: .milliseconds(500))
                if ChangelogService.shared.hasUnseenChanges {
                    showChangelog = true
                }
            }
            .sheet(isPresented: $showChangelog) {
                #if os(iOS)
                NavigationStack {
                    ChangelogView(autoOpenedForVersion: ChangelogService.shared.currentVersion)
                }
                #else
                ChangelogView(autoOpenedForVersion: ChangelogService.shared.currentVersion)
                #endif
            }
            #if os(iOS)
            .dynamicTypeSize(.xSmall ... .medium)
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            // app 进入后台 / 失焦时强制刷掉 conversation save 缓冲,
            // 防止节流期内 app 被 SIGKILL 丢最后一波内容
            if newPhase == .background || newPhase == .inactive {
                ConversationStore.flushAll()
            }
            guard newPhase == .active else { return }
            #if os(iOS)
            // 分享扩展 / 快捷指令送来的文字:取出预填到输入框并聚焦。
            if let shared = SharedInbox.takePending() {
                if viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    viewModel.prompt = shared
                } else {
                    viewModel.prompt += "\n\n" + shared
                }
                viewModel.focusInputRequest &+= 1
            }
            #endif
            // 启动第一次 .active 不 refresh — AppViewModel.init 里的延迟 2s task 已经会兜底。
            // 否则两条 refresh 路径同时跑,卡住 MainActor,UI 启动几秒不响应。
            if !hasSeenInitialActive {
                hasSeenInitialActive = true
                return
            }
            if viewModel.iCloudSync.isEnabled,
               viewModel.iCloudSync.isAvailable,
               !viewModel.iCloudMigrationInFlight {
                viewModel.refreshFromICloud()
            }
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") {
                    viewModel.newConversation(mode: viewModel.activeMode)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("命令面板…") {
                    viewModel.showCommandPalette = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            // 「Kown ▸ 检查更新…」(紧跟「关于 Kown」之后)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem()
            }
            // 「对话」菜单 —— 模式切换 + 停止 + 删除当前会话。
            // 这里只调用 AppViewModel 已暴露的 public 接口,不触碰其它文件。
            CommandMenu("对话") {
                // ⌘1~⌘4 切换对话模式。固定顺序与 InputBar 上的 tab 一致:
                // 直接 / 对比 / 议会 / 辩论。switchMode(to:) 自身会处理「空会话原地切 / 非空开新会话」。
                Button("直接问答") { _ = viewModel.switchMode(to: .direct) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("模型对比") { _ = viewModel.switchMode(to: .compare) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("模型议会") { _ = viewModel.switchMode(to: .council) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("模型辩论") { _ = viewModel.switchMode(to: .debate) }
                    .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("会话内查找…") { viewModel.showFind = true }
                    .keyboardShortcut("f", modifiers: .command)

                // ⌘. 停止正在生成的回复(等价于输入栏的「停止」)。
                Button("停止生成") {
                    viewModel.cancel()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!viewModel.isRunning)

                Divider()

                // ⌘⇧⌫ 删除当前选中的会话。
                Button("删除当前会话") {
                    if let id = viewModel.selectedConversationID {
                        viewModel.deleteConversation(id)
                    }
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(viewModel.selectedConversationID == nil)
            }
        }
        #endif

        #if os(macOS)
        // 菜单栏快速提问(点图标弹面板;全局热键 ⌃⌥K 唤起主窗口)。
        MenuBarExtra("Kown", systemImage: "bubble.left.and.bubble.right.fill") {
            QuickAskView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

private struct LaunchSplashView: View {
    @State private var appeared = false

    var body: some View {
        GeometryReader { proxy in
            let markSize = min(proxy.size.width * 0.86, 390)

            ZStack {
                SplashBackdrop(appeared: appeared)

                VStack(spacing: 18) {
                    Spacer(minLength: proxy.size.height * 0.08)

                    Image("LaunchLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: markSize, height: markSize * 0.78)
                        .scaleEffect(appeared ? 1 : 0.88)
                        .opacity(appeared ? 1 : 0)
                        .shadow(color: Color(red: 0.10, green: 0.40, blue: 0.95).opacity(0.16),
                                radius: 22, x: 0, y: 12)

                    VStack(spacing: 8) {
                        Text("Kown")
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .tracking(-1.2)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.04, green: 0.20, blue: 0.40),
                                        Color(red: 0.02, green: 0.48, blue: 0.82)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 10)

                        Text("Model Debate")
                            .font(.caption.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(Color(red: 0.02, green: 0.42, blue: 0.98))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(red: 0.02, green: 0.42, blue: 0.98).opacity(0.10), in: Capsule())
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 10)

                        Text("Let enabled models argue,\nrebut each other, then\nproduce a moderated conclusion.")
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .foregroundStyle(.secondary)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 10)
                    }

                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(index == 0 ? Color.accentColor : Color.secondary.opacity(0.22))
                                .frame(width: 8, height: 8)
                                .scaleEffect(appeared ? 1 : 0.4)
                                .opacity(appeared ? 1 : 0)
                                .animation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.18 + Double(index) * 0.08),
                                           value: appeared)
                        }
                    }
                    .padding(.top, 8)

                    VStack(spacing: 12) {
                        Text("Start a Debate")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.02, green: 0.42, blue: 0.98),
                                        Color(red: 0.06, green: 0.53, blue: 1.0)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .shadow(color: Color(red: 0.04, green: 0.42, blue: 1).opacity(0.22),
                                    radius: 14, x: 0, y: 8)

                        HStack(spacing: 8) {
                            Image(systemName: "person.3.fill")
                                .font(.subheadline.weight(.semibold))
                            Text("Choose Debaters")
                                .font(.headline.weight(.semibold))
                        }
                        .foregroundStyle(Color(red: 0.02, green: 0.42, blue: 0.98))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color(red: 0.02, green: 0.42, blue: 0.98).opacity(0.16), lineWidth: 1)
                        )
                    }
                    .padding(.top, 18)
                    .padding(14)
                    .background(.white.opacity(0.36), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.62), lineWidth: 1)
                    }
                    .shadow(color: Color(red: 0.10, green: 0.32, blue: 0.82).opacity(0.10),
                            radius: 22, x: 0, y: 12)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)

                    HStack(spacing: 6) {
                        Text("Swipe to explore")
                            .font(.footnote.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary.opacity(0.76))
                    .padding(.top, 4)
                    .opacity(appeared ? 1 : 0)

                    Spacer(minLength: proxy.size.height * 0.06)
                }
                .padding(.horizontal, 28)
            }
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.spring(response: 0.8, dampingFraction: 0.84)) {
                    appeared = true
                }
            }
        }
    }
}

private struct SplashBackdrop: View {
    let appeared: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.985, blue: 1.0),
                    .white,
                    Color(red: 1.0, green: 0.94, blue: 0.965)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(red: 0.12, green: 0.48, blue: 0.96).opacity(0.13))
                .frame(width: 360, height: 360)
                .blur(radius: 52)
                .offset(y: appeared ? -86 : -54)

            Circle()
                .fill(Color(red: 0.72, green: 0.45, blue: 1.0).opacity(0.10))
                .frame(width: 310, height: 310)
                .blur(radius: 48)
                .offset(x: 118, y: -156)

            Circle()
                .fill(Color(red: 1.0, green: 0.72, blue: 0.18).opacity(0.11))
                .frame(width: 280, height: 280)
                .blur(radius: 50)
                .offset(x: -130, y: 260)

            Circle()
                .stroke(Color(red: 0.50, green: 0.68, blue: 1.0).opacity(0.14), lineWidth: 1)
                .frame(width: appeared ? 390 : 330, height: appeared ? 390 : 330)
                .scaleEffect(x: 1.15, y: 0.78)
                .offset(y: -42)
                .opacity(appeared ? 1 : 0)
        }
    }
}

#if os(macOS)
/// macOS: 启动时如果 stdin / --prompt 有内容就存进 pending file,让 AppViewModel 启动后自动发送。
private func captureCLIPromptIfAny() {
    let argv = Array(CommandLine.arguments.dropFirst())
    for flag in ["-p", "--prompt"] {
        if let i = argv.firstIndex(of: flag), i + 1 < argv.endIndex {
            CLIPendingPrompt.store(argv[i + 1])
            return
        }
    }
    if isatty(STDIN_FILENO) == 0,
       let data = FileHandle.standardInput.readDataToEndOfFile() as Data?,
       !data.isEmpty,
       let text = String(data: data, encoding: .utf8)?
           .trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
        CLIPendingPrompt.store(text)
    }
}
#endif
