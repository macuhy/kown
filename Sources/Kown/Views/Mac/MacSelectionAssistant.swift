#if os(macOS)
import SwiftUI
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import UserNotifications

/// 划词助手(macOS 专用):全局热键 ⌃⌥L 在任意 app 里弹出迷你命令面板。
///
/// - 经 Accessibility API 读取前台 app 当前选中的文本(读不到再退回「模拟 ⌘C」,
///   最后兜底用剪贴板);无辅助功能权限时引导授权,并降级为只处理剪贴板文本。
/// - 面板提供 纠错 / 润色 / 翻译 三个内置动作 + 提示词库里**无变量**的自定义模板;
///   用小模型(优先 chair)流式生成,结果可一键复制,或写回剪贴板后模拟 ⌘V 原地替换。
@MainActor
final class MacSelectionAssistant {
    static let shared = MacSelectionAssistant()
    private init() {}

    private weak var viewModel: AppViewModel?
    private var hotKey: GlobalHotKey?
    private var panel: NSPanel?
    private var state: SelectionAssistantState?
    /// 唤起面板时的前台 app —— 「替换原文」要把它再激活回来再粘贴。
    private var sourceApp: NSRunningApplication?

    /// 注册全局热键 ⌃⌥L(id=2,跟 MacQuickAsk 的 ⌃⌥K id=1 区分)。
    func registerHotKey(viewModel: AppViewModel) {
        self.viewModel = viewModel
        guard hotKey == nil else { return }
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_L),
                              modifiers: UInt32(controlKey | optionKey),
                              id: 2) {
            Task { @MainActor in
                MacSelectionAssistant.shared.toggle()
            }
        }
    }

    // MARK: - 面板开关

    private func toggle() {
        if let panel, panel.isVisible {
            closePanel()
            return
        }
        // 先记下前台 app(此刻还没被面板抢焦点),替换原文时要激活回去。
        sourceApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            let text = await captureSelection()
            presentPanel(text: text)
        }
    }

    func closePanel() {
        state?.cancel()
        panel?.orderOut(nil)
        panel = nil
        state = nil
    }

    // MARK: - 读取选中文本

    /// 三级降级:AX 选中文本 → 模拟 ⌘C → 剪贴板现有文字。
    private func captureSelection() async -> String {
        if AXIsProcessTrusted() {
            if let s = axSelectedText(), !s.isEmpty { return s }
            if let s = await selectionViaCopy(), !s.isEmpty { return s }
        }
        return (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从系统焦点元素读 kAXSelectedText(最快、不动剪贴板;部分 app 不支持)。
    private func axSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextAttribute as CFString,
                                            &selectedRef) == .success,
              let text = selectedRef as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// AX 读不到时模拟 ⌘C 抓选区,抓完恢复用户原剪贴板。
    private func selectionViaCopy() async -> String? {
        let pb = NSPasteboard.general
        let savedText = pb.string(forType: .string)
        let savedCount = pb.changeCount
        postKeystroke(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        // 等目标 app 把选区写进剪贴板(最多 ~0.5s)。
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(50))
            if pb.changeCount != savedCount { break }
        }
        guard pb.changeCount != savedCount else { return nil }
        let captured = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 恢复用户原来的剪贴板内容,别让一次划词把人家复制的东西冲掉。
        pb.clearContents()
        if let savedText { pb.setString(savedText, forType: .string) }
        return captured
    }

    /// 模拟一次带修饰键的按键(需要辅助功能权限)。
    private func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - 弹面板

    private func presentPanel(text: String) {
        closePanel()
        guard let vm = viewModel else { return }

        let state = SelectionAssistantState(sourceText: text, sourceApp: sourceApp)
        self.state = state

        let root = SelectionAssistantView(
            state: state,
            viewModel: vm,
            onClose: { [weak self] in self?.closePanel() },
            onReplace: { [weak self] result in self?.replaceSelection(with: result) }
        )
        let host = NSHostingController(rootView: root)
        let panel = NSPanel(contentViewController: host)
        // 非激活面板:弹出时不把前台 app 的焦点抢走,点按钮才接收事件。
        panel.styleMask = [.titled, .closable, .nonactivatingPanel, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        // 贴着鼠标位置弹出,并夹回可见屏幕内。
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - 12)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let size = host.view.fittingSize
            origin.x = min(origin.x, screen.visibleFrame.maxX - size.width - 8)
            origin.y = max(origin.y, screen.visibleFrame.minY + size.height + 8)
        }
        panel.setFrameTopLeftPoint(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
    }

    // MARK: - 替换原文 / 授权

    /// 结果写进剪贴板;有辅助功能权限就激活原 app 模拟 ⌘V 原地替换,
    /// 没有权限则降级为「已复制 + 系统通知提示手动粘贴」。
    private func replaceSelection(with result: String) {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trimmed, forType: .string)

        guard AXIsProcessTrusted(), let app = sourceApp else {
            closePanel()
            notify(title: "结果已复制",
                   body: "未授权辅助功能,无法原地替换;请回到原 app 手动粘贴(⌘V)。")
            return
        }
        closePanel()
        app.activate(options: [])
        Task { @MainActor in
            // 等原 app 重新拿到焦点再粘贴,太快会贴进虚空。
            try? await Task.sleep(for: .milliseconds(200))
            self.postKeystroke(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        }
    }

    /// 弹系统的「辅助功能」授权引导(系统设置 ▸ 隐私与安全性 ▸ 辅助功能)。
    /// 注:`kAXTrustedCheckOptionPrompt` 是非并发安全的全局 var(Swift 6 严格并发下不能直接引用),
    /// 这里用它的字面值 "AXTrustedCheckOptionPrompt"。
    static func requestAccessibilityPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func notify(title: String, body: String) {
        SchedulerService.shared.ensureNotificationPermission()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }
}

// MARK: - 面板状态(流式生成)

/// 划词面板的运行状态:选中文本 + 当前动作的流式结果。
/// 模型选择沿用菜单栏剪贴板动作的策略:优先 chair,其次第一家 enabled 非 CLI provider。
@MainActor
@Observable
final class SelectionAssistantState {
    /// 唤起面板那一刻抓到的选中文本(可能为空 —— 没选中也没剪贴板)。
    let sourceText: String
    /// 唤起面板时的前台 app(「回复聊天」要截它的窗口做 OCR)。
    private let sourceApp: NSRunningApplication?
    /// 是否已授权辅助功能(决定能否「原地替换」)。
    let axTrusted: Bool
    /// 提示词库里无变量的自定义模板(变量模板需要填参,迷你面板放不下,不收)。
    let customTemplates: [PromptTemplate]

    private(set) var runningTitle: String?
    private(set) var result = ""
    private(set) var errorText: String?
    private(set) var providerName = ""
    /// 思考型模型正在输出思考、正文还没来(占位文案显示「思考中…」)。
    private(set) var isThinking = false

    /// 用户指定的生成模型(nil = 自动:主席优先)。跨次唤起持久化。
    private(set) var chosenProviderID: UUID?
    private(set) var chosenModel: String?

    private static let providerKey = "kown.selectionAssistant.provider.v1"
    private static let modelKey = "kown.selectionAssistant.model.v1"

    var isRunning: Bool { runningTitle != nil }
    var hasOutput: Bool { !result.isEmpty || errorText != nil }

    private var task: Task<Void, Never>?

    init(sourceText: String, sourceApp: NSRunningApplication? = nil) {
        self.sourceText = sourceText
        self.sourceApp = sourceApp
        self.axTrusted = AXIsProcessTrusted()
        let d = UserDefaults.standard
        self.chosenProviderID = d.string(forKey: Self.providerKey).flatMap(UUID.init(uuidString:))
        self.chosenModel = d.string(forKey: Self.modelKey).flatMap { $0.isEmpty ? nil : $0 }
        self.customTemplates = Array(
            PromptLibraryStore().templates
                .filter { $0.variableNames.isEmpty }
                .prefix(4)
        )
    }

    /// 跑一个动作:把拼好的指令丢给所选模型流式生成。
    func run(title: String, prompt: String, viewModel: AppViewModel) {
        task?.cancel()
        guard let cfg = resolvedConfig(from: viewModel) else {
            errorText = "没有可用的模型,先到设置里启用一个(CLI 除外)。"
            return
        }
        runningTitle = title
        result = ""
        errorText = nil
        providerName = cfg.displayName

        task = Task { [weak self] in
            guard let self else { return }
            var collected = ""
            var sawReasoning = false
            do {
                let apiKey = (try? KeychainStore.load(id: cfg.id)) ?? ""
                let client = ProviderRegistry.client(for: cfg.kind)
                // maxTokens 给足:思考型模型(豆包/DeepSeek thinking)的思考也计入输出上限,
                // 2048 会被思考吃光导致正文为空。
                let options = ChatOptions(systemPrompt: nil, temperature: 0.3, maxTokens: 8192)
                for try await chunk in client.stream(prompt: prompt, options: options,
                                                     config: cfg, apiKey: apiKey) {
                    if Task.isCancelled { break }
                    switch chunk {
                    case .text(let t):
                        collected += t
                        self.result = collected
                    case .reasoning:
                        // 思考过程不上屏,但置位标记:占位文案变「思考中…」,
                        // 跑完没正文时也能给出明确的原因提示而不是空白框。
                        sawReasoning = true
                        self.isThinking = self.result.isEmpty
                    default:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.errorText = error.localizedDescription
                }
            }
            self.isThinking = false
            self.runningTitle = nil
            // 流式正常结束但一个正文字都没有:把原因说清楚,别留空白框。
            if !Task.isCancelled, self.errorText == nil,
               collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.errorText = sawReasoning
                    ? "模型只输出了思考过程,没有正文。换个非思考模型(右上角可选)或再试一次。"
                    : "模型没有返回内容,稍后再试,或换个模型(右上角可选)。"
            }
        }
    }

    /// 「回复聊天」:截取唤起面板时的前台窗口 → 系统 OCR 识别聊天记录
    /// (右侧气泡=我,左侧=对方)→ 以「我」的身份拟回复。不依赖选中文本。
    func runChatReply(viewModel: AppViewModel) {
        guard let app = sourceApp else {
            errorText = "没记到来源窗口 —— 切到聊天 app 再按一次 ⌃⌥L。"
            return
        }
        task?.cancel()
        runningTitle = "回复聊天"
        result = ""
        errorText = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let messages = try await ChatWindowReader.readChat(of: app)
                // 只带最近 30 条,聊天截图一屏也就这个量级,防超长。
                let transcript = OCRService.chatTranscript(Array(messages.suffix(30)))
                let prompt = """
                下面是从聊天窗口识别出的最近对话(「我」是用户本人,气泡在右侧;\
                「对方」是聊天对象,气泡在左侧),按时间从早到晚排列。OCR 可能有少量错字,按语境理解:

                \(transcript)

                以「我」的身份,针对对方最新的发言拟一条自然、得体的回复;\
                延续我此前的语气与称呼习惯,长度贴合对话节奏(日常闲聊就短,正事可以长)。\
                只输出回复正文,不要解释、不要加引号或前后缀。
                """
                self.runningTitle = nil
                self.run(title: "回复聊天", prompt: prompt, viewModel: viewModel)
            } catch {
                self.runningTitle = nil
                self.errorText = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        runningTitle = nil
    }

    /// 记住用户指定的模型(providerID = nil 表示回到自动)。
    func setChoice(providerID: UUID?, model: String?) {
        chosenProviderID = providerID
        chosenModel = model
        let d = UserDefaults.standard
        if let providerID {
            d.set(providerID.uuidString, forKey: Self.providerKey)
            d.set(model ?? "", forKey: Self.modelKey)
        } else {
            d.removeObject(forKey: Self.providerKey)
            d.removeObject(forKey: Self.modelKey)
        }
    }

    /// 本次生成实际会用的配置:用户指定优先(provider 失效则自动回退),否则 主席 > 第一家。
    func resolvedConfig(from viewModel: AppViewModel) -> ProviderConfig? {
        if let id = chosenProviderID,
           var cfg = viewModel.providers.first(where: { $0.id == id && $0.enabled && !$0.kind.isCLI }) {
            if let model = chosenModel, !model.isEmpty { cfg.model = model }
            return cfg
        }
        return smallModel(from: viewModel)
    }

    private func smallModel(from viewModel: AppViewModel) -> ProviderConfig? {
        if let chair = viewModel.chairProvider, !chair.kind.isCLI { return chair }
        return viewModel.providers.first { $0.enabled && !$0.kind.isCLI }
    }
}

// MARK: - 面板视图

/// 迷你命令面板:原文预览 + 动作按钮 + 流式结果(复制 / 替换原文)。
struct SelectionAssistantView: View {
    @Bindable var state: SelectionAssistantState
    let viewModel: AppViewModel
    let onClose: () -> Void
    let onReplace: (String) -> Void

    /// 一个面板动作:标题 + 图标 + 由选中文本拼出完整指令。
    private struct PanelAction: Identifiable {
        let id: String
        let title: String
        let icon: String
        let prompt: (String) -> String
    }

    /// 内置三件套:纠错 / 润色 / 翻译(翻译复用剪贴板动作的指令)。
    private var builtinActions: [PanelAction] {
        [
            PanelAction(id: "proofread", title: "纠错", icon: "text.badge.checkmark") { text in
                """
                修正下面文本中的错别字、标点和语法错误,保持原意、语气与原语言不变。
                只输出修正后的全文,不要解释、不要加前后缀。

                待修正文本:
                \(text)
                """
            },
            PanelAction(id: "polish", title: "润色", icon: "wand.and.stars") { text in
                """
                润色下面的文本,让表达更通顺、自然、得体,保持原意与原语言不变。
                只输出润色后的全文,不要解释、不要加前后缀。

                待润色文本:
                \(text)
                """
            },
            PanelAction(id: "translate", title: "翻译", icon: "character.book.closed") { text in
                ClipboardAction.translate.prompt(for: text)
            }
        ]
    }

    /// 提示词库无变量模板 → 自定义动作(正文 + 选中文本)。
    private var customActions: [PanelAction] {
        state.customTemplates.map { tpl in
            PanelAction(id: tpl.id.uuidString, title: tpl.title, icon: "text.badge.plus") { text in
                tpl.body + "\n\n待处理文本:\n" + text
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if state.sourceText.isEmpty {
                Text("没有读到选中文本。选中一段文字再按 ⌃⌥L 可用 纠错/润色/翻译;「回复聊天」不需要选中,直接识别当前窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(state.sourceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.platformControlBackground.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            actionButtons

            if state.isRunning || state.hasOutput {
                resultArea
            }
        }
        .padding(14)
        .padding(.top, 8) // 给隐藏标题栏的关闭按钮留点呼吸空间
        .frame(width: 400)
        .background(.regularMaterial)
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.and.square.on.square.dashed")
                .foregroundStyle(.tint)
            Text("划词助手")
                .font(.subheadline.weight(.bold))
            Spacer()
            modelMenu
            if !state.axTrusted {
                Button {
                    MacSelectionAssistant.requestAccessibilityPermission()
                } label: {
                    Label("去授权辅助功能", systemImage: "lock.shield")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("授权后才能读取任意 app 的选区,并支持「替换原文」")
            }
        }
    }

    // MARK: - 模型选择

    /// 生成模型菜单:自动(主席优先)/ 各启用厂商 → 模型列表。选择持久化,下次唤起还在。
    private var modelMenu: some View {
        Menu {
            Button {
                state.setChoice(providerID: nil, model: nil)
            } label: {
                if state.chosenProviderID == nil { Label("自动(主席优先)", systemImage: "checkmark") }
                else { Text("自动(主席优先)") }
            }
            Divider()
            ForEach(candidateProviders) { cfg in
                let union = uniqueOrdered([cfg.model] + ProviderModelCatalog.knownModels(for: cfg))
                if union.count <= 1 {
                    modelChoiceButton(cfg: cfg, model: cfg.model, fullLabel: true)
                } else {
                    Menu(cfg.displayName) {
                        ForEach(union, id: \.self) { model in
                            modelChoiceButton(cfg: cfg, model: model, fullLabel: false)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                    .font(.caption2.weight(.bold))
                Text(currentModelLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140)
            }
            .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择划词助手用哪个模型生成;「自动」= 主席优先,其次第一家启用的")
    }

    private func modelChoiceButton(cfg: ProviderConfig, model: String, fullLabel: Bool) -> some View {
        let selected = state.chosenProviderID == cfg.id
            && (state.chosenModel ?? cfg.model) == model
        let title = fullLabel ? "\(cfg.displayName)(\(model))" : model
        return Button {
            // 选的是 provider 当前模型时不存 model 覆盖,跟随 provider 设置变化。
            state.setChoice(providerID: cfg.id, model: model == cfg.model ? nil : model)
        } label: {
            if selected { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }

    private var candidateProviders: [ProviderConfig] {
        viewModel.providers.filter { $0.enabled && !$0.kind.isCLI }
    }

    private var currentModelLabel: String {
        guard let cfg = state.resolvedConfig(from: viewModel) else { return "无可用模型" }
        return state.chosenProviderID == nil ? "自动 · \(cfg.displayName)" : cfg.model
    }

    private func uniqueOrdered(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(builtinActions) { action in
                    actionButton(action)
                }
            }
            // 回复聊天:截当前窗口 OCR 识别对话(右=我,左=对方),不依赖选中文本。
            Button {
                state.runChatReply(viewModel: viewModel)
            } label: {
                Label("回复聊天(识别当前窗口)", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(state.isRunning)
            .help("截取聊天窗口截图,用系统 OCR 识别最近对话后以你的口吻拟回复;需要「屏幕录制」权限")
            if !customActions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(customActions) { action in
                            actionButton(action)
                        }
                    }
                }
            }
        }
    }

    private func actionButton(_ action: PanelAction) -> some View {
        Button {
            // 太长截断,迷你面板的轻动作别打爆上下文。
            let maxChars = 8000
            let text = state.sourceText.count > maxChars
                ? String(state.sourceText.prefix(maxChars)) + "…(已截断)"
                : state.sourceText
            state.run(title: action.title, prompt: action.prompt(text), viewModel: viewModel)
        } label: {
            Label(action.title, systemImage: action.icon)
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(state.isRunning || state.sourceText.isEmpty)
    }

    @ViewBuilder
    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = state.errorText {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                ScrollView {
                    Text(state.result.isEmpty && state.isRunning
                         ? (state.isThinking ? "思考中…" : "生成中…")
                         : state.result)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .foregroundStyle(state.result.isEmpty ? .secondary : .primary)
                }
                .frame(maxHeight: 200)

                HStack {
                    if !state.providerName.isEmpty {
                        Text("由 \(state.providerName) 生成")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Platform.copyText(state.result.trimmingCharacters(in: .whitespacesAndNewlines))
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(resultBlank)

                    Button {
                        onReplace(state.result)
                    } label: {
                        Label(state.axTrusted ? "替换原文" : "复制并关闭", systemImage: "arrow.uturn.backward.square")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(resultBlank)
                    .help(state.axTrusted
                          ? "把结果写回剪贴板,回到原 app 模拟 ⌘V 原地替换"
                          : "未授权辅助功能:结果进剪贴板,请手动粘贴")
                }
            }
        }
        .padding(8)
        .background(Color.platformControlBackground,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var resultBlank: Bool {
        state.isRunning || state.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
#endif
