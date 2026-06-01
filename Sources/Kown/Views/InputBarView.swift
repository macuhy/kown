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

    /// 发送历史回溯(↑/↓ 调取最近输入)。视图本地持有即可,跨会话靠自身持久化。
    @State private var history = PromptHistoryStore()

    @State private var pickerError: String?
    @State private var showEnhancer = false
    @State private var showPromptLibrary = false
    @State private var showKnowledge = false
    @State private var showURLScrape = false
    @State private var urlDraft = ""
    @State private var scraping = false
    #if os(macOS)
    @State private var showFileImporter = false
    @State private var showImageImporter = false
    /// ⌘V 本地事件监听:抢在字段编辑器前拦截图片/文件粘贴(否则 file-url 会被当文本贴成路径)。
    @State private var pasteMonitor: Any?
    #endif
    #if os(iOS)
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    #endif

    /// 语音听写(STT)。录音中把识别文本接在 dictationBase 后面写入 prompt。
    @ObservedObject private var dictation = SpeechRecognizer.shared
    @State private var dictationBase = ""

    var body: some View {
        VStack(spacing: shellSpacing) {
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
        .padding(.horizontal, shellHorizontalPadding)
        .padding(.vertical, shellVerticalPadding)
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
        .onChange(of: viewModel.focusInputRequest) { _, _ in
            inputFocused = true
        }
        .alert("抓取网页", isPresented: $showURLScrape) {
            TextField("https://…", text: $urlDraft)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            Button("抓取") {
                let u = urlDraft
                scraping = true
                Task {
                    let err = await viewModel.attachScrapedURL(u)
                    await MainActor.run { scraping = false; pickerError = err }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("用 Firecrawl 抓取该网页正文,作为附件并入上下文")
        }
        .sheet(isPresented: $showPromptLibrary) {
            PromptInsertSheet { rendered in
                if viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    viewModel.prompt = rendered
                } else {
                    viewModel.prompt += "\n\n" + rendered
                }
                inputFocused = true
            }
        }
        .sheet(isPresented: $showEnhancer, onDismiss: { viewModel.dismissEnhancer() }) {
            PromptEnhancerSheet(viewModel: viewModel, isPresented: $showEnhancer)
                .frame(minWidth: 640, minHeight: 420)
        }
        .sheet(isPresented: $showKnowledge) {
            KnowledgeView(viewModel: viewModel)
        }
        #if os(macOS)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.plainText, .utf8PlainText, .text, .json, .yaml, .sourceCode, .swiftSource, .pythonScript, .shellScript, .xml, .html, .pdf]
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
        VStack(spacing: 6) {
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
            .padding(.horizontal, promptHorizontalPadding)
            .padding(.vertical, promptVerticalPadding)
            .frame(minHeight: promptMinHeight)
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
            // 拖拽文件/图片到输入框 → 分流成附件(图片走缩略图、其它走文本/PDF)。
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
            .submitLabel(.send)
            .onSubmit { sendIfCan() }
            // 用户改动文本就退出历史浏览态(下次 ↑ 从最新一条重新数起)。
            // 历史回填本身也会改 prompt,这里用 isBrowsing 把回填动作排除掉。
            .onChange(of: viewModel.prompt) { _, _ in
                if !history.isBrowsing { history.resetBrowsing() }
            }
            // ↑ 取更早一条:仅当输入框为空、或正在浏览历史时拦截,避免破坏正常多行编辑的光标上移。
            .onKeyPress(.upArrow) {
                guard inputFocused, canBrowseHistory else { return .ignored }
                if let text = history.older(current: viewModel.prompt) {
                    viewModel.prompt = text
                    return .handled
                }
                return .ignored
            }
            // ↓ 取更晚一条:仅当正在浏览历史时拦截,否则放行给正常多行编辑。
            .onKeyPress(.downArrow) {
                guard inputFocused, history.isBrowsing else { return .ignored }
                if let text = history.newer() {
                    viewModel.prompt = text
                    return .handled
                }
                return .ignored
            }
            #if os(iOS)
            .onTapGesture { inputFocused = true }
            #endif
            #if os(macOS)
            // ⌘V 粘贴图片(位图字节)兜底 — file-url 由下面的 NSEvent monitor 抢在字段编辑器前拦。
            .onPasteCommand(of: ["public.image", "public.png", "public.jpeg", "public.tiff"]) { _ in
                handlePasteImage()
            }
            // 关键:聚焦时装 local keyDown monitor。聚焦的 TextField 字段编辑器会先把 file-url
            // 当文本吃掉 ⌘V(只贴路径、无缩略图),onPasteCommand 根本轮不到 → 这里抢在它前面。
            .onAppear { installPasteMonitor() }
            .onDisappear { removePasteMonitor() }
            #endif
    }

    /// 是否允许 ↑ 进入历史回溯:输入框为空(光标必在首行)或已经在浏览中。
    /// 输入框有内容时不拦截 ↑,让它当作正常的多行光标上移。
    private var canBrowseHistory: Bool {
        history.isBrowsing || viewModel.prompt.isEmpty
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
            iconButton("text.badge.plus", help: "从提示词库插入(可填充 {{变量}})") {
                showPromptLibrary = true
            }
            knowledgeButton
            if viewModel.canEnableWebSearch {
                iconButton(scraping ? "hourglass" : "link.badge.plus", help: "抓取网页正文入上下文") {
                    urlDraft = ""
                    showURLScrape = true
                }
                .disabled(scraping)
            }
            iconButton("wand.and.stars", help: viewModel.prompt.isEmpty ? "先输入问题再增强" : "用 AI 改写问题") {
                viewModel.enhancePrompt()
                showEnhancer = true
            }
            .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            micButton
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
            chipShell(label: f.name, detail: "\(f.byteCount / 1024)KB", id: f.id, color: .blue) {
                chipIconBox("doc.text", color: .blue)
            }
        case .pdf(let p):
            chipShell(label: p.name, detail: "\(p.pageCount) 页", id: p.id, color: .red) {
                chipIconBox("doc.richtext", color: .red)
            }
        case .image(let i):
            // 图片附件:展示真实缩略图(粘贴 / 拖入 / 选取都走这里),不再只显示图标 + 名称。
            chipShell(label: i.name, detail: "\(i.pixelWidth)×\(i.pixelHeight)", id: i.id, color: .purple) {
                AttachmentImageThumb(payload: i)
            }
        }
    }

    /// 文件附件用的彩色图标方块(图片附件改用真实缩略图,见 AttachmentImageThumb)。
    private func chipIconBox(_ icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func chipShell<Leading: View>(
        label: String,
        detail: String,
        id: UUID,
        color: Color,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: 6) {
            leading()
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

    /// 知识库按钮。绑定了资料夹时高亮显示。点开管理 / 绑定 sheet。
    @ViewBuilder
    private var knowledgeButton: some View {
        let bound = viewModel.currentKnowledgeFolder != nil
        Button {
            showKnowledge = true
        } label: {
            Image(systemName: bound ? "books.vertical.fill" : "books.vertical")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(bound ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill((bound ? Color.accentColor : Color.primary).opacity(bound ? 0.12 : 0.055))
                }
                .overlay {
                    Circle().strokeBorder((bound ? Color.accentColor : Color.primary).opacity(bound ? 0.26 : 0.07), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(bound ? "知识库:已绑定「\(viewModel.currentKnowledgeFolder?.name ?? "")」" : "知识库 / 资料夹")
    }

    /// 语音听写按钮。点一下开始录音(首次弹权限),边说边把文字写进输入框;再点停止。
    @ViewBuilder
    private var micButton: some View {
        let recording = dictation.isRecording
        Button {
            if recording {
                dictation.stop()
            } else {
                dictationBase = viewModel.prompt
                dictation.toggle { text in
                    let base = dictationBase.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.prompt = base.isEmpty ? text : base + " " + text
                }
            }
        } label: {
            Image(systemName: recording ? "stop.fill" : "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(recording ? Color.white : .secondary)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(recording ? Color.red : Color.primary.opacity(0.055))
                }
                .overlay {
                    Circle().strokeBorder(recording ? Color.red.opacity(0.5) : Color.primary.opacity(0.07), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(recording ? "停止听写" : "语音听写(中文)")
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

    private var shellSpacing: CGFloat {
        #if os(iOS)
        return 6
        #else
        return 10
        #endif
    }

    private var shellHorizontalPadding: CGFloat {
        #if os(iOS)
        return 12
        #else
        return 16
        #endif
    }

    private var shellVerticalPadding: CGFloat {
        #if os(iOS)
        return 8
        #else
        return 12
        #endif
    }

    private var promptHorizontalPadding: CGFloat {
        #if os(iOS)
        return 13
        #else
        return 16
        #endif
    }

    private var promptVerticalPadding: CGFloat {
        #if os(iOS)
        return 9
        #else
        return 12
        #endif
    }

    private var promptMinHeight: CGFloat {
        #if os(iOS)
        return 42
        #else
        return 48
        #endif
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
            // 发送前把当前文本记进历史(record 内部会去重相邻重复 + 重置浏览游标)。
            history.record(viewModel.prompt)
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

    // MARK: - 附件分流(粘贴 / 拖拽共用,跨平台)

    /// 把若干文件 URL 按扩展名分流成附件:图片 → attachImageNormalized(HEIC 转 JPEG、缩略图);
    /// 其它 → attachFile(文本 / PDF)。粘贴 file-url 与拖拽共用。
    func attachFileURLs(_ urls: [URL]) {
        var attached = false
        for url in urls {
            do {
                if Self.pasteImageExtensions.contains(url.pathExtension.lowercased()) {
                    let data = try Data(contentsOf: url)
                    try viewModel.attachImageNormalized(data, name: url.lastPathComponent)
                } else {
                    try viewModel.attachFile(at: url)
                }
                attached = true
            } catch {
                pickerError = error.localizedDescription
            }
        }
        if attached { pickerError = nil }
    }

    /// 拖拽/粘贴文件时按扩展名识别图片(走缩略图路径)。
    static let pasteImageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]

    /// `.onDrop` 处理:从 NSItemProvider 取 file URL,分流到 attachFileURLs。
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in attachFileURLs([url]) }
            }
        }
        return handled
    }

    // MARK: - 文件/图片选择 (macOS only — iOS 移除附件入口)

    #if os(macOS)
    private func pickFile()  { showFileImporter = true }
    private func pickImage() { showImageImporter = true }

    /// 从 NSPasteboard 拿图片/文件塞进 attachments — 触发条件:用户在输入框聚焦 ⌘V。
    /// 优先位图数据(截图 / 浏览器复制图片):PNG → TIFF→PNG;
    /// 再退到文件引用(从 Finder 复制的图片/文件):按扩展名分流成图片或文件附件。
    private func handlePasteImage() {
        let pb = NSPasteboard.general
        // 1) 剪贴板里就是位图字节(截图 / 浏览器「复制图片」)。
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
        // 2) 剪贴板里是文件引用(从 Finder 复制了图片/文件)。
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            attachFileURLs(urls)
            return
        }
        // 真没图片/文件就给个兜底提示(普通文本粘贴不会进到这里)。
        pickerError = "剪贴板里没有可识别的图片或文件"
    }

    /// 装/卸 ⌘V 本地监听:聚焦输入框时,⌘V 且剪贴板含图片字节或 file-url → 自己处理并吞掉事件
    /// (返回 nil),抢在字段编辑器把 file-url 当文本贴进来之前。普通文本 → 放行,正常粘贴。
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard inputFocused,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            let pb = NSPasteboard.general
            let hasImage = pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil
            let hasFileURL = ((pb.readObjects(forClasses: [NSURL.self],
                              options: [.urlReadingFileURLsOnly: true]) as? [URL])?.isEmpty == false)
            guard hasImage || hasFileURL else { return event }  // 纯文本等 → 放行
            handlePasteImage()
            return nil  // 吞掉,字段编辑器不再把路径当文本贴
        }
    }

    private func removePasteMonitor() {
        if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil }
    }

    private func pastedName(ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "Pasted-\(f.string(from: Date())).\(ext)"
    }
    #endif
}

// MARK: - 附件缩略图

/// 输入区图片附件的缩略图。
/// base64 只解码一次(放进 .task,按 id 缓存),避免每次输入框重绘都解一遍大图。
private struct AttachmentImageThumb: View {
    let payload: Attachment.ImagePayload
    var side: CGFloat = 30

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                // 解码完成前的占位(也兜底解码失败)。
                Rectangle()
                    .fill(Color.purple.opacity(0.12))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.purple)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: payload.id) {
            guard image == nil,
                  let data = Data(base64Encoded: payload.base64) else { return }
            image = ConversationImageView.makeImage(from: data)
        }
    }
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
