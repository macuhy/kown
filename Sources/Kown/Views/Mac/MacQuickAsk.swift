#if os(macOS)
import SwiftUI
import AppKit
import Carbon.HIToolbox

/// 菜单栏快速提问面板内容。输入即发,自动唤起主窗口看回答。
struct QuickAskView: View {
    @Bindable var viewModel: AppViewModel
    @State private var text = ""
    /// 菜单栏剪贴板动作(翻译/总结/解释)的运行状态。
    @State private var clipboardRunner = ClipboardActionRunner()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("快速提问")
                    .font(.headline)
                Spacer()
                Text(viewModel.activeMode.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            TextField("输入问题,回车发送…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)

            HStack {
                Text("发送后会打开主窗口看回答。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("发送", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()

            ClipboardActionsSection(viewModel: viewModel, runner: clipboardRunner)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.newConversation(mode: viewModel.activeMode)
        viewModel.prompt = trimmed
        viewModel.send()
        text = ""
        MacQuickAsk.activateMainWindow()
    }
}

/// 全局热键 + 主窗口唤起。用 Carbon RegisterEventHotKey(不需要辅助功能权限,零三方依赖)。
@MainActor
enum MacQuickAsk {
    private static var hotKey: GlobalHotKey?

    /// 注册全局热键 ⌃⌥K:唤起 Kown 主窗口并聚焦输入框。
    static func registerHotKey(viewModel: AppViewModel) {
        guard hotKey == nil else { return }
        // keyCode 40 = 'K';modifiers = control + option
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_K),
                              modifiers: UInt32(controlKey | optionKey)) {
            Task { @MainActor in
                activateMainWindow()
                // 触发输入框聚焦(InputBarView 监听该计数器)
                viewModel.focusInputRequest &+= 1
            }
        }
    }

    /// 把主窗口拉到前台并激活 App。
    static func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}

/// Carbon 全局热键的轻封装。
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            me.callback()
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4B574E31), id: 1) // 'KWN1'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
#endif
