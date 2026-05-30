import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import PhotosUI
#endif

struct InputBarView: View {
    @Bindable var viewModel: AppViewModel
    @Binding var showSystemPromptDrawer: Bool
    @FocusState.Binding var inputFocused: Bool

    @State private var pickerError: String?
    @State private var showEnhancer = false
    #if os(macOS)
    @State private var showFileImporter = false
    @State private var showImageImporter = false
    #endif
    #if os(iOS)
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    #endif

    var body: some View {
        VStack(spacing: 10) {
            if showSystemPromptDrawer {
                systemPromptEditor
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !viewModel.attachments.isEmpty {
                attachmentsRow
            }
            if let err = pickerError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
                    }
            }
            barRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(.thinMaterial)
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.07), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
        .sheet(isPresented: $showEnhancer, onDismiss: { viewModel.dismissEnhancer() }) {
            PromptEnhancerSheet(viewModel: viewModel, isPresented: $showEnhancer)
                .frame(minWidth: 640, minHeight: 420)
        }
        #if os(macOS)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.plainText, .utf8PlainText, .text, .json, .yaml, .sourceCode, .swiftSource, .pythonScript, .shellScript, .xml, .html]
        ) { result in
            handlePicked(result, isImage: false)
        }
        .fileImporter(
            isPresented: $showImageImporter,
            allowedContentTypes: [.image]
        ) { result in
            handlePicked(result, isImage: true)
        }
        #endif
        #if os(iOS)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                defer { photoItem = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        pickerError = "读取图片失败"
                        return
                    }
                    try viewModel.attachImageNormalized(data, name: "photo")
                    pickerError = nil
                } catch {
                    pickerError = error.localizedDescription
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private func handlePicked(_ result: Result<URL, Error>, isImage: Bool) {
        switch result {
        case .success(let url):
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                if isImage { try viewModel.attachImage(at: url) }
                else       { try viewModel.attachFile(at: url) }
                pickerError = nil
            } catch {
                pickerError = error.localizedDescription
            }
        case .failure(let err):
            pickerError = err.localizedDescription
        }
    }
    #endif

    @ViewBuilder
    private var barRow: some View {
        #if os(iOS)
        VStack(spacing: 10) {
            promptField
            HStack(spacing: 8) {
                toolButtons
                Spacer(minLength: 8)
                sendButton
            }
        }
        #else
        HStack(spacing: 10) {
            promptField
            toolButtons
            sendButton
        }
        #endif
    }

    private var promptField: some View {
        TextField(placeholder, text: $viewModel.prompt, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...5)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.platformTextBackground.opacity(0.78))
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    inputFocused ? Color.accentColor.opacity(0.10) : Color.white.opacity(0.035),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        inputFocused ? Color.accentColor.opacity(0.48) : Color.primary.opacity(0.10),
                        lineWidth: inputFocused ? 1.5 : 1
                    )
            }
            .shadow(color: inputFocused ? Color.accentColor.opacity(0.12) : Color.clear, radius: 16, x: 0, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .focused($inputFocused)
            .submitLabel(.send)
            .onSubmit { sendIfCan() }
            #if os(iOS)
            .onTapGesture { inputFocused = true }
            #endif
            #if os(macOS)
            // ⌘V 粘贴图片直接成附件 — 普通文本粘贴让 TextField 自己处理(不消费这条 paste)
            .onPasteCommand(of: ["public.image", "public.png", "public.jpeg", "public.tiff"]) { _ in
                handlePasteImage()
            }
            #endif
    }

    private var toolButtons: some View {
        HStack(spacing: 4) {
            iconButton("slider.horizontal.3", help: "System Prompt") {
                withAnimation(.easeInOut(duration: 0.18)) { showSystemPromptDrawer.toggle() }
            }
            #if os(macOS)
            iconButton("photo", help: viewModel.anyProviderSupportsImage
                               ? "附加图片（OpenAI 兼容 / Anthropic / Gemini 支持视觉）"
                               : "附加图片（当前面板里没有支持视觉的 provider，发送时会忽略）") { pickImage() }
            #endif
            #if os(iOS)
            iconButton("photo", help: "从相册添加图片") { showPhotoPicker = true }
            #endif
            webSearchToggle
            if viewModel.currentMode == .debate {
                debateRoundsPicker
            }
            iconButton("wand.and.stars", help: viewModel.prompt.isEmpty ? "先输入问题再增强" : "用 AI 改写问题") {
                viewModel.enhancePrompt()
                showEnhancer = true
            }
            .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #if os(macOS)
            workspaceButton
            #endif
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    #if os(macOS)
    /// 工作目录按钮 — 未设置时打开文件夹选择器;已设置时显示路径 chip + 关闭按钮
    @ViewBuilder
    private var workspaceButton: some View {
        if let displayPath = viewModel.currentWorkspaceDisplayPath {
            HStack(spacing: 4) {
                Button {
                    pickWorkspace()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text((displayPath as NSString).lastPathComponent)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.26), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Workspace: \(displayPath)\n点击切换文件夹")

                Button {
                    viewModel.clearWorkspace()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, height: 30)
                }
                .buttonStyle(.plain)
                .help("移除 workspace")
            }
        } else {
            iconButton("folder", help: "选 workspace 文件夹 — model 会看到内容,可写回") {
                pickWorkspace()
            }
        }
    }

    private func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选定为 Workspace"
        panel.message = "选一个文件夹作为本会话的 workspace。model 看到里面的内容,可写文件;只能写本目录内。"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.setWorkspace(url)
        }
    }
    #endif

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.attachments) { att in
                    attachmentChip(att)
                }
            }
            .padding(.vertical, 1)
        }
    }

    @ViewBuilder
    private func attachmentChip(_ att: Attachment) -> some View {
        switch att {
        case .file(let f):
            chipShell(icon: "doc.text", label: f.name, detail: "\(f.byteCount / 1024)KB", id: f.id, color: .blue)
        case .image(let i):
            chipShell(icon: "photo", label: i.name, detail: "\(i.pixelWidth)×\(i.pixelHeight)", id: i.id, color: .purple)
        }
    }

    private func chipShell(icon: String, label: String, detail: String, id: UUID, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button {
                viewModel.removeAttachment(id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.24), lineWidth: 1))
    }

    private var placeholder: String {
        switch viewModel.currentMode {
        case .council: return "Ask the council..."
        case .direct:  return "Send a message..."
        case .compare: return "Ask both models..."
        case .debate:  return "Start a debate..."
        }
    }

    private var debateRoundsPicker: some View {
        let menu = Menu {
            ForEach(1...4, id: \.self) { n in
                Button {
                    viewModel.debateRoundsForNextSend = n
                } label: {
                    if n == viewModel.debateRoundsForNextSend {
                        Label(roundsLabel(n), systemImage: "checkmark")
                    } else {
                        Text(roundsLabel(n))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .bold))
                Text("\(viewModel.debateRoundsForNextSend)轮")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.22), lineWidth: 1))
        }
        .menuIndicator(.hidden)
        .fixedSize()

        #if os(macOS)
        return menu
            .menuStyle(.borderlessButton)
            .help("Debate 轮数(1=仅立论, 2=+反驳, 3-4=多轮收敛)")
        #else
        return menu
        #endif
    }

    private func roundsLabel(_ n: Int) -> String {
        switch n {
        case 1: return "1 轮 · 仅立论"
        case 2: return "2 轮 · 立论 + 反驳"
        case 3: return "3 轮 · +一轮反驳后收敛"
        case 4: return "4 轮 · 两轮反驳后收敛"
        default: return "\(n) 轮"
        }
    }

    @ViewBuilder
    private var webSearchToggle: some View {
        let canEnable = viewModel.canEnableWebSearch
        let isOn = canEnable && viewModel.webSearchEnabledForNextSend
        Button {
            if canEnable {
                viewModel.webSearchEnabledForNextSend.toggle()
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isOn ? Color.white : .secondary)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(
                        isOn
                            ? LinearGradient(
                                colors: [Color.blue, Color.cyan.opacity(0.82)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [
                                    Color.primary.opacity(canEnable ? 0.06 : 0.025),
                                    Color.primary.opacity(canEnable ? 0.035 : 0.015)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                }
                .overlay {
                    Circle().strokeBorder(isOn ? Color.white.opacity(0.24) : Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!canEnable)
        .opacity(canEnable ? 1 : 0.45)
        .help(canEnable
              ? (isOn ? "下一条消息会带 web_search 工具(再按关闭)" : "本次发送启用 Firecrawl web_search")
              : "请先到 设置 → Web Search 启用并填好 API Key")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(Color.primary.opacity(0.055))
                }
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 当前选中的会话是否就是后台正在跑的那个 — 决定停止按钮的行为/显示。
    /// 用户切到别的会话时,这里 = false,按钮回到普通"发送"语义,不会误取消另一会话的请求。
    private var isViewingRunningConv: Bool {
        viewModel.isRunning && viewModel.runningConvID == viewModel.selectedConversationID
    }

    private var sendButton: some View {
        let isEnabled = viewModel.canSend || isViewingRunningConv
        let tint = isViewingRunningConv ? Color.red : Color.accentColor
        return Button {
            sendIfCan()
        } label: {
            ZStack {
                Circle()
                    .fill(
                        isEnabled
                            ? LinearGradient(
                                colors: [tint, tint.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [Color.secondary.opacity(0.26), Color.secondary.opacity(0.18)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                    .frame(width: 38, height: 38)
                    .shadow(color: isEnabled ? tint.opacity(0.22) : Color.clear, radius: 12, x: 0, y: 6)
                if isViewingRunningConv {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!viewModel.canSend && !isViewingRunningConv)
        .help(isViewingRunningConv ? "停止生成" : "⌘↩ 发送")
    }

    private func sendIfCan() {
        if isViewingRunningConv {
            viewModel.cancel()
        } else if viewModel.canSend {
            viewModel.send()
        }
    }

    private var systemPromptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.alignleft")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.teal)
                    .frame(width: 28, height: 28)
                    .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("SYSTEM PROMPT")
                    .font(.caption.weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                if !viewModel.systemPrompt.isEmpty {
                    Button("清空") { viewModel.systemPrompt = "" }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            TextEditor(text: $viewModel.systemPrompt)
                .scrollContentBackground(.hidden)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 130)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.platformTextBackground.opacity(0.66))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.teal.opacity(0.25), lineWidth: 1)
                )

            if viewModel.systemPrompt.isEmpty {
                Text("例如：你是一个严谨的产品顾问，先给结论，再列风险。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.18), lineWidth: 1)
        }
    }

    // MARK: - 文件/图片选择 (macOS only — iOS 移除附件入口)

    #if os(macOS)
    private func pickFile()  { showFileImporter = true }
    private func pickImage() { showImageImporter = true }

    /// 从 NSPasteboard 拿图片数据塞进 attachments — 触发条件:用户在输入框聚焦 ⌘V。
    /// 优先 PNG;退而求其次 TIFF → 转 PNG。
    private func handlePasteImage() {
        let pb = NSPasteboard.general
        if let pngData = pb.data(forType: .png),
           (try? viewModel.attachImageData(pngData, name: pastedName(ext: "png"), mime: "image/png")) != nil {
            pickerError = nil
            return
        }
        if let tiff = pb.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]),
           (try? viewModel.attachImageData(png, name: pastedName(ext: "png"), mime: "image/png")) != nil {
            pickerError = nil
            return
        }
        // 真没图片就当 NSPasteboard 让 TextField 自己处理普通文本(本回调已被消费,但 SwiftUI
        // 通常会同时把粘贴文本写进 TextField — 如果没,用户体感上"复制纯文本时按一下"应该会贴。
        // 这里给个温和的错误提示作为兜底。
        pickerError = "剪贴板里没有可识别的图片数据"
    }

    private func pastedName(ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "Pasted-\(f.string(from: Date())).\(ext)"
    }
    #endif
}

// MARK: - Prompt Enhancer Sheet

private struct PromptEnhancerSheet: View {
    @Bindable var viewModel: AppViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                column(title: "原问题", text: viewModel.enhancerOriginal ?? "")
                Divider()
                column(title: "改写后", text: viewModel.enhancerOutput,
                       streaming: viewModel.enhancerRunning,
                       error: viewModel.enhancerError)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.purple)
            Text("Prompt Enhancer")
                .font(.headline)
            if let p = viewModel.enhancerProvider {
                Text("· \(p.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.enhancerRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func column(title: String, text: String, streaming: Bool = false, error: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            ScrollView {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text.isEmpty && streaming ? "..." : text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            Button("取消") {
                viewModel.cancelEnhancer()
                isPresented = false
            }
            .keyboardShortcut(.escape, modifiers: [])
            Spacer()
            if viewModel.enhancerRunning {
                Button("停止") { viewModel.cancelEnhancer() }
            }
            Button("用这个改写") {
                viewModel.acceptEnhancedPrompt()
                isPresented = false
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.enhancerOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.enhancerRunning)
        }
        .padding(16)
    }
}
