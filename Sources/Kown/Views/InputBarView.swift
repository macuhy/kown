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
    @State private var showVoice = false
    #if os(macOS)
    @State private var showFileImporter = false
    @State private var showImageImporter = false
    /// ⌘V 本地事件监听:抢在字段编辑器前拦截图片/文件粘贴(否则 file-url 会被当文本贴成路径)。
    @State private var pasteMonitor: Any?
    #endif
    #if os(iOS)
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    /// OCR 扫描:从相册选图后跑 Vision 文字识别,把抽取的文字追加进输入框。
    @State private var showOCRPicker = false
    @State private var ocrItem: PhotosPickerItem?
    @State private var ocrRunning = false
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
            #if os(iOS)
            if hasIOSContextChips && !iOSKeyboardCompact {
                iOSContextChips
            }
            #endif
            promptImprovePreview
            barRow
        }
        .padding(.horizontal, shellHorizontalPadding)
        .padding(.vertical, shellVerticalPadding)
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(.thinMaterial)
                LinearGradient(
                    colors: [viewModel.currentMode.kownTint.opacity(0.08), viewModel.currentMode.kownSecondaryTint.opacity(0.035), Color.clear],
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
            Button("抓取并总结") {
                let u = urlDraft
                scraping = true
                Task {
                    let err = await viewModel.summarizeURL(u)
                    await MainActor.run { scraping = false; pickerError = err }
                }
            }
            Button("仅抓取入上下文") {
                let u = urlDraft
                scraping = true
                Task {
                    let err = await viewModel.attachScrapedURL(u)
                    await MainActor.run { scraping = false; pickerError = err }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("用 Firecrawl 抓取该网页正文。「抓取并总结」会直接发问并生成总结;「仅抓取」只作为附件并入上下文。")
        }
        .sheet(isPresented: $showPromptLibrary) {
            PromptInsertSheet { rendered in
                if viewModel.promptIsBlank {
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
        #if os(iOS)
        .fullScreenCover(isPresented: $showVoice) {
            VoiceConversationView(viewModel: viewModel)
        }
        #else
        .sheet(isPresented: $showVoice) {
            VoiceConversationView(viewModel: viewModel)
        }
        #endif
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
        // OCR 扫描:选图 → Vision 识别 → 抽取文字追加到输入框(不入附件)。
        .photosPicker(isPresented: $showOCRPicker, selection: $ocrItem, matching: .images)
        .onChange(of: ocrItem) { _, item in
            guard let item else { return }
            ocrRunning = true
            Task {
                defer { ocrItem = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        await MainActor.run {
                            ocrRunning = false
                            pickerError = "读取图片失败"
                        }
                        return
                    }
                    let text = try await OCRService.recognizeText(in: image)
                    await MainActor.run {
                        appendOCRText(text)
                        ocrRunning = false
                        pickerError = nil
                        inputFocused = true
                    }
                } catch {
                    await MainActor.run {
                        ocrRunning = false
                        pickerError = error.localizedDescription
                    }
                }
            }
        }
        #endif
    }

    #if os(iOS)
    /// 把 OCR 抽取的文字追加进 prompt:空则直接填,非空则换行接在后面。
    private func appendOCRText(_ text: String) {
        if viewModel.promptIsBlank {
            viewModel.prompt = text
        } else {
            viewModel.prompt += "\n\n" + text
        }
    }
    #endif

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
        if iOSKeyboardCompact {
            HStack(alignment: .bottom, spacing: 7) {
                iOSCompactToolsMenu
                promptField
                    .layoutPriority(1)
                micButton
                sendButton
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            VStack(spacing: 6) {
                promptField
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        toolButtons
                            .padding(.vertical, 1)
                    }
                    sendButton
                }
            }
        }
        #else
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                promptField
                    .frame(minWidth: 260)
                toolButtons
                sendButton
            }
            VStack(spacing: 8) {
                promptField
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        toolButtons
                            .padding(.vertical, 1)
                    }
                    sendButton
                }
            }
        }
        #endif
    }

    private var promptField: some View {
        // 普通长度走多行 TextField;超过阈值(viewModel.promptIsLarge)切到 TextEditor(NSTextView)。
        // macOS 的 axis:.vertical TextField 在大文本下每次按键都同步重排全文 → 卡死主线程;
        // TextEditor 有真正的文本系统,长文本远比多行 TextField 抗造。
        Group {
            if viewModel.promptIsLarge {
                decoratedPromptEditor(
                    TextEditor(text: $viewModel.prompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(maxHeight: largePromptMaxHeight)   // 超过就内部滚动,不再无限长高
                )
            } else {
                decoratedPromptEditor(
                    // 注意:title 必须是空常量。给多行 TextField(axis:.vertical) 传非空 placeholder,
                    // 在 macOS 聚焦态下会触发 setPlaceholderString → _restartEditingWithTextView →
                    // endEditing → textDidEndEditing → 再布局 的重入死循环(整核 100% CPU)。
                    // 占位文字改用 SwiftUI Text 叠层手动渲染,绕开 AppKit 的占位路径。
                    TextField("", text: $viewModel.prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1...promptMaxLines)
                )
                .submitLabel(.send)
                .onSubmit { sendIfCan() }
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
            }
        }
        .focused($inputFocused)
        // 拖拽文件/图片到输入框 → 分流成附件(图片走缩略图、其它走文本/PDF)。
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
        // 用户改动文本就退出历史浏览态(下次 ↑ 从最新一条重新数起)。
        // 历史回填本身也会改 prompt,这里用 isBrowsing 把回填动作排除掉。
        .onChange(of: viewModel.prompt) { _, _ in
            if !history.isBrowsing { history.resetBrowsing() }
        }
        #if os(iOS)
        .onTapGesture { inputFocused = true }
        #endif
        #if os(macOS)
        // ⌘V 粘贴图片(位图字节)兜底 — file-url 由下面的 NSEvent monitor 抢在字段编辑器前拦。
        .onPasteCommand(of: ["public.image", "public.png", "public.jpeg", "public.tiff"]) { _ in
            handlePasteImage()
        }
        // 关键:聚焦时装 local keyDown monitor。聚焦的字段编辑器会先把 file-url
        // 当文本吃掉 ⌘V(只贴路径、无缩略图),onPasteCommand 根本轮不到 → 这里抢在它前面。
        .onAppear { installPasteMonitor() }
        .onDisappear { removePasteMonitor() }
        #endif
    }

    /// 输入框外观装饰(占位 / 内边距 / 背景 / 边框 / 阴影),compact(TextField)与 large(TextEditor)共用。
    private func decoratedPromptEditor<Editor: View>(_ editor: Editor) -> some View {
        let tint = viewModel.currentMode.kownTint
        return editor
            .overlay(alignment: .topLeading) {
                if viewModel.prompt.isEmpty {   // large 模式不会为空,占位只对 compact 生效
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, promptHorizontalPadding)
            .padding(.vertical, promptVerticalPadding)
            .frame(minHeight: promptMinHeight)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: promptCornerRadius, style: .continuous)
                        .fill(Color.platformTextBackground.opacity(0.78))
                    RoundedRectangle(cornerRadius: promptCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    inputFocused ? tint.opacity(0.11) : Color.white.opacity(0.035),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: promptCornerRadius, style: .continuous)
                    .strokeBorder(
                        inputFocused ? tint.opacity(0.48) : Color.primary.opacity(0.10),
                        lineWidth: inputFocused ? 1.5 : 1
                    )
            }
            .shadow(color: inputFocused ? tint.opacity(0.13) : Color.clear, radius: 16, x: 0, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: promptCornerRadius, style: .continuous))
    }

    /// 是否允许 ↑ 进入历史回溯:输入框为空(光标必在首行)或已经在浏览中。
    /// 输入框有内容时不拦截 ↑,让它当作正常的多行光标上移。
    private var canBrowseHistory: Bool {
        history.isBrowsing || viewModel.prompt.isEmpty
    }

    @ViewBuilder
    private var toolButtons: some View {
        #if os(iOS)
        iOSToolButtons
        #else
        macToolButtons
        #endif
    }

    #if os(macOS)
    private var macToolButtons: some View {
        toolButtonCluster {
            iconButton("slider.horizontal.3", help: "System Prompt") {
                withAnimation(.easeInOut(duration: 0.18)) { showSystemPromptDrawer.toggle() }
            }
            iconButton("photo", help: viewModel.anyProviderSupportsImage
                               ? "附加图片（OpenAI 兼容 / Anthropic / Gemini 支持视觉）"
                               : "附加图片（当前面板里没有支持视觉的 provider，发送时会忽略）") { pickImage() }
            webSearchToggle
            deviceToolsToggle
            skillPicker
            if viewModel.currentMode == .debate {
                debateRoundsPicker
            }
            iconButton("text.badge.plus", help: "从提示词库插入(可填充 {{变量}})") {
                showPromptLibrary = true
            }
            knowledgeButton
            GitHubRepoButton(viewModel: viewModel, tint: viewModel.currentMode.kownTint)
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
            .disabled(viewModel.promptIsBlank)
            promptImproveButton
            micButton
            voiceButton
            if viewModel.currentMode == .direct {
                iconButton(viewModel.isGeneratingImage ? "hourglass" : "photo.badge.plus",
                           help: "生成图片(用当前模型,需选支持出图的模型)") {
                    viewModel.generateImage()
                }
                .disabled(viewModel.isGeneratingImage || viewModel.promptIsBlank)
                if viewModel.imageGenComparableProviders.count >= 2 {
                    iconButton(viewModel.isGeneratingImage ? "hourglass" : "photo.stack",
                               help: "图像生成对比(所有启用模型用同一描述各出一张并排比较,需各自选好出图模型)") {
                        viewModel.generateImageComparison()
                    }
                    .disabled(viewModel.isGeneratingImage || viewModel.promptIsBlank)
                }
            }
            workspaceButton
        }
    }
    #endif

    #if os(iOS)
    private var iOSToolButtons: some View {
        toolButtonCluster {
            iconButton("photo", help: "从相册添加图片") { showPhotoPicker = true }
            iconButton(ocrRunning ? "hourglass" : "doc.viewfinder",
                       help: ocrRunning ? "正在识别文字" : "扫描图片文字 OCR") {
                showOCRPicker = true
            }
            .disabled(ocrRunning)
            if viewModel.canEnableWebSearch {
                webSearchToggle
            }
            if viewModel.currentMode == .debate {
                debateRoundsPicker
            }
            micButton
            voiceButton
            moreToolsMenu
        }
    }

    /// 键盘弹起时只保留一个紧凑入口,把次要动作收进菜单,避免工具栏挤占对话内容。
    private var iOSCompactToolsMenu: some View {
        let tint = viewModel.currentMode.kownTint
        let active = hasIOSContextChips ||
            (viewModel.canEnableWebSearch && viewModel.webSearchEnabledForNextSend) ||
            (viewModel.currentMode == .debate && viewModel.debateRoundsForNextSend > 1)
        return Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("添加图片", systemImage: "photo")
            }
            Button {
                showOCRPicker = true
            } label: {
                Label(ocrRunning ? "正在识别文字" : "扫描图片文字", systemImage: ocrRunning ? "hourglass" : "doc.viewfinder")
            }
            .disabled(ocrRunning)
            if viewModel.canEnableWebSearch {
                Button {
                    viewModel.webSearchEnabledForNextSend.toggle()
                } label: {
                    Label(viewModel.webSearchEnabledForNextSend ? "关闭网页搜索" : "开启网页搜索",
                          systemImage: viewModel.webSearchEnabledForNextSend ? "checkmark.circle" : "globe")
                }
            }
            if viewModel.currentMode == .debate {
                Menu {
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
                    Label("Debate 轮数", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Divider()
            iOSMoreToolsMenuContent
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(active ? tint : .secondary)
                    .frame(width: toolButtonSize, height: toolButtonSize)
                    .background((active ? tint : Color.primary).opacity(active ? 0.13 : 0.055), in: Circle())
                    .overlay {
                        Circle().strokeBorder((active ? tint : Color.primary).opacity(active ? 0.28 : 0.07), lineWidth: 1)
                    }
                if active {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Color.platformWindowBackground, lineWidth: 1.5))
                        .offset(x: -1, y: 1)
                }
            }
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(active ? "更多工具,有已启用上下文" : "更多工具")
    }

    private var moreToolsMenu: some View {
        Menu {
            iOSMoreToolsMenuContent
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                Text("更多")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: toolButtonSize)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("更多工具")
    }

    @ViewBuilder
    private var iOSMoreToolsMenuContent: some View {
        let promptEmpty = viewModel.promptIsBlank
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showSystemPromptDrawer.toggle() }
        } label: {
            Label("System Prompt", systemImage: "slider.horizontal.3")
        }
        Button {
            showPromptLibrary = true
        } label: {
            Label("提示词库", systemImage: "text.badge.plus")
        }
        Button {
            showKnowledge = true
        } label: {
            Label("知识库", systemImage: "books.vertical")
        }
        Divider()
        Button {
            viewModel.deviceToolsEnabledForNextSend.toggle()
        } label: {
            Label(viewModel.deviceToolsEnabledForNextSend ? "关闭设备工具" : "启用设备工具",
                  systemImage: viewModel.deviceToolsEnabledForNextSend ? "checkmark.circle" : "wrench.and.screwdriver.fill")
        }
        iOSSkillBindingMenu
        iOSGitHubMenu
        if !viewModel.canEnableWebSearch {
            Label("网页搜索未配置", systemImage: "globe.badge.exclamationmark")
        }
        if viewModel.canEnableWebSearch {
            Button {
                urlDraft = ""
                showURLScrape = true
            } label: {
                Label(scraping ? "正在抓取网页" : "抓取网页正文",
                      systemImage: scraping ? "hourglass" : "link.badge.plus")
            }
            .disabled(scraping)
        }
        Divider()
        Button {
            showVoice = true
        } label: {
            Label("语音对话", systemImage: "waveform")
        }
        Button {
            viewModel.enhancePrompt()
            showEnhancer = true
        } label: {
            Label("AI 改写问题", systemImage: "wand.and.stars")
        }
        .disabled(promptEmpty)
        Button {
            viewModel.improvePrompt()
        } label: {
            Label(viewModel.improvingPrompt ? "正在润色" : "润色问题",
                  systemImage: viewModel.improvingPrompt ? "hourglass" : "wand.and.rays")
        }
        .disabled(promptEmpty || viewModel.improvingPrompt)
        if viewModel.currentMode == .direct {
            Divider()
            Button {
                viewModel.generateImage()
            } label: {
                Label(viewModel.isGeneratingImage ? "正在生成图片" : "生成图片",
                      systemImage: viewModel.isGeneratingImage ? "hourglass" : "photo.badge.plus")
            }
            .disabled(viewModel.isGeneratingImage || promptEmpty)
            if viewModel.imageGenComparableProviders.count >= 2 {
                Button {
                    viewModel.generateImageComparison()
                } label: {
                    Label(viewModel.isGeneratingImage ? "正在生成对比" : "图像生成对比",
                          systemImage: viewModel.isGeneratingImage ? "hourglass" : "photo.stack")
                }
                .disabled(viewModel.isGeneratingImage || promptEmpty)
            }
        }
    }

    private var iOSSkillBindingMenu: some View {
        let bound = viewModel.currentBoundSkill
        return Menu {
            Button {
                viewModel.setSelectedSkill(nil)
            } label: {
                if bound == nil {
                    Label("自动匹配", systemImage: "checkmark")
                } else {
                    Text("自动匹配")
                }
            }
            if viewModel.skillsStore.enabledSkills.isEmpty {
                Text("没有启用的技能")
            } else {
                Divider()
                ForEach(viewModel.skillsStore.enabledSkills) { skill in
                    Button {
                        viewModel.setSelectedSkill(skill.id)
                    } label: {
                        if bound?.id == skill.id {
                            Label(skill.name, systemImage: "checkmark")
                        } else {
                            Text(skill.name)
                        }
                    }
                }
            }
        } label: {
            Label(bound == nil ? "技能：自动匹配" : "技能：\(bound?.name ?? "")",
                  systemImage: bound == nil ? "wand.and.stars" : "wand.and.stars.inverse")
        }
    }

    private var iOSGitHubMenu: some View {
        Group {
            if viewModel.gitHubConnected {
                Menu {
                    if viewModel.gitHubReposLoading {
                        Text("加载仓库中…")
                    } else if viewModel.gitHubRepos.isEmpty {
                        Text("没有可用仓库")
                    } else {
                        ForEach(viewModel.gitHubRepos) { repo in
                            Button {
                                viewModel.setGitHubRepo(repo)
                            } label: {
                                let title = abbreviatedMiddle(repo.fullName, maxCharacters: 42)
                                if viewModel.currentGitHubRepo == repo.fullName {
                                    Label("\(title)\(repo.isPrivate ? " 🔒" : "")", systemImage: "checkmark")
                                } else {
                                    Text("\(title)\(repo.isPrivate ? " 🔒" : "")")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("重新加载") {
                        Task { await viewModel.loadGitHubRepos(force: true) }
                    }
                    if viewModel.currentGitHubRepo != nil {
                        Button("解除绑定", role: .destructive) { viewModel.clearGitHubRepo() }
                    }
                } label: {
                    Label(iOSGitHubMenuTitle, systemImage: "arrow.triangle.branch")
                }
                .task { await viewModel.loadGitHubRepos() }
            } else {
                Button {
                    viewModel.startGitHubDeviceFlow()
                } label: {
                    Label("连接 GitHub", systemImage: "arrow.triangle.branch")
                }
            }
        }
    }

    private var iOSGitHubMenuTitle: String {
        if let repo = viewModel.currentGitHubRepo {
            return "GitHub：\(repoShortName(repo))"
        }
        return "选择 GitHub 仓库"
    }
    #endif

    private func toolButtonCluster<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) {
            content()
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(viewModel.currentMode.kownTint.opacity(0.14), lineWidth: 1)
        }
    }

    // MARK: - 提示词润色(Prompt Improver)
    // 与 Prompt Enhancer(wand.and.stars sheet)、follow-up 互不相干:独立按钮 + 输入栏内联预览,
    // 走 viewModel.improvePrompt / acceptImprovedPrompt / dismissImprovement。

    /// 「润色」按钮:用小模型把当前输入改写得更清晰、具体、结构化(内联预览,非 sheet)。
    private var promptImproveButton: some View {
        let empty = viewModel.promptIsBlank
        return iconButton(viewModel.improvingPrompt ? "hourglass" : "wand.and.rays",
                          help: empty ? "先输入问题再润色" : "润色:让提问更清晰、具体、结构化") {
            viewModel.improvePrompt()
        }
        .disabled(empty || viewModel.improvingPrompt)
    }

    /// 润色结果的内联预览(带「采用」「却下」按钮)、运行中指示与错误提示。
    @ViewBuilder
    private var promptImprovePreview: some View {
        if let err = viewModel.promptImproveError {
            HStack(spacing: 8) {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    viewModel.dismissImprovement()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.20), lineWidth: 1)
            }
        } else if viewModel.improvingPrompt || viewModel.promptImprovement != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.rays")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.purple)
                    Text("润色建议")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    if viewModel.improvingPrompt {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button {
                        viewModel.dismissImprovement()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("却下(不采用)")
                }

                ScrollView {
                    Text(viewModel.promptImprovement?.isEmpty == false
                         ? (viewModel.promptImprovement ?? "")
                         : "正在润色…")
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)

                HStack(spacing: 8) {
                    Spacer()
                    Button("却下") {
                        viewModel.dismissImprovement()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("采用") {
                        viewModel.acceptImprovedPrompt()
                        inputFocused = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.improvingPrompt
                              || (viewModel.promptImprovement?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.purple.opacity(0.20), lineWidth: 1)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// 语音对话模式入口:听 → 发 → 朗读 → 再听的免手循环。
    /// 无可用 provider 或设备不支持语音识别时禁用。
    private var voiceButton: some View {
        let ready = dictation.isAvailable && viewModel.providers.contains(where: \.enabled)
        let tint = viewModel.currentMode.kownTint
        return Button {
            showVoice = true
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ready ? tint : .secondary)
                .frame(width: toolButtonSize, height: toolButtonSize)
                .background {
                    Circle().fill((ready ? tint : Color.primary).opacity(ready ? 0.13 : 0.055))
                }
                .overlay {
                    Circle().strokeBorder((ready ? tint : Color.primary).opacity(ready ? 0.30 : 0.07), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .help(ready ? "语音对话(免手连续对话)" : "语音对话(需启用 provider 且设备支持语音识别)")
        .accessibilityLabel(ready ? "语音对话" : "语音对话不可用")
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
                            .truncationMode(.middle)
                            .frame(maxWidth: 140)
                    }
                    .foregroundStyle(viewModel.currentMode.kownTint)
                    .padding(.horizontal, 9)
                    .frame(height: toolButtonSize)
                    .background(viewModel.currentMode.kownTint.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(viewModel.currentMode.kownTint.opacity(0.26), lineWidth: 1))
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
        viewModel.currentMode.kownPromptPlaceholder
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
            .foregroundStyle(viewModel.currentMode.kownTint)
            .padding(.horizontal, 9)
            .frame(height: toolButtonSize)
            .background(viewModel.currentMode.kownTint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(viewModel.currentMode.kownTint.opacity(0.22), lineWidth: 1))
        }
        .menuIndicator(.hidden)
        .fixedSize()

        #if os(macOS)
        return menu
            .menuStyle(.borderlessButton)
            .help("Debate 轮数(1=仅立论, 2=+反驳, 3-4=多轮收敛)")
        #else
        return menu
            .accessibilityLabel("Debate 轮数 \(viewModel.debateRoundsForNextSend) 轮")
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
                .frame(width: toolButtonSize, height: toolButtonSize)
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
        .accessibilityLabel(canEnable ? (isOn ? "关闭网页搜索" : "启用网页搜索") : "网页搜索不可用")
    }

    /// 设备工具开关 — 让模型本次发送可调用提醒/备忘录工具。仿 webSearchToggle 样式。
    @ViewBuilder
    private var deviceToolsToggle: some View {
        let isOn = viewModel.deviceToolsEnabledForNextSend
        Button {
            viewModel.deviceToolsEnabledForNextSend.toggle()
        } label: {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isOn ? Color.white : .secondary)
                .frame(width: toolButtonSize, height: toolButtonSize)
                .background {
                    Circle().fill(
                        isOn
                            ? LinearGradient(colors: [Color(red: 0.20, green: 0.60, blue: 0.62), Color.teal.opacity(0.82)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [Color.primary.opacity(0.06), Color.primary.opacity(0.035)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                }
                .overlay {
                    Circle().strokeBorder(isOn ? Color.white.opacity(0.24) : Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(isOn ? "下一条消息可创建提醒/备忘录(再按关闭)" : "本次发送启用设备工具(提醒/备忘录)")
    }

    /// 技能选择 — 手动给当前会话绑定一个技能,或留空走自动触发。
    @ViewBuilder
    private var skillPicker: some View {
        let bound = viewModel.currentBoundSkill
        Menu {
            Button {
                viewModel.setSelectedSkill(nil)
            } label: {
                if bound == nil { Label("自动(按输入匹配)", systemImage: "checkmark") }
                else { Text("自动(按输入匹配)") }
            }
            Divider()
            ForEach(viewModel.skillsStore.enabledSkills) { skill in
                Button {
                    viewModel.setSelectedSkill(skill.id)
                } label: {
                    if bound?.id == skill.id { Label(skill.name, systemImage: "checkmark") }
                    else { Text(skill.name) }
                }
            }
        } label: {
            Image(systemName: bound == nil ? "wand.and.stars" : "wand.and.stars.inverse")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(bound == nil ? .secondary : Color(red: 0.48, green: 0.36, blue: 0.90))
                .frame(width: toolButtonSize, height: toolButtonSize)
                .background {
                    Circle().fill(bound == nil
                                  ? Color.primary.opacity(0.05)
                                  : Color(red: 0.48, green: 0.36, blue: 0.90).opacity(0.16))
                }
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .help(bound == nil ? "技能:自动匹配(点选可固定到本会话)" : "本会话技能:\(bound!.name)")
        #endif
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
                .foregroundStyle(bound ? viewModel.currentMode.kownTint : .secondary)
                .frame(width: toolButtonSize, height: toolButtonSize)
                .background {
                    Circle().fill((bound ? viewModel.currentMode.kownTint : Color.primary).opacity(bound ? 0.12 : 0.055))
                }
                .overlay {
                    Circle().strokeBorder((bound ? viewModel.currentMode.kownTint : Color.primary).opacity(bound ? 0.26 : 0.07), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(bound ? "知识库:已绑定「\(viewModel.currentKnowledgeFolder?.name ?? "")」" : "知识库 / 资料夹")
        .accessibilityLabel(bound ? "知识库已绑定" : "知识库")
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
                .frame(width: toolButtonSize, height: toolButtonSize)
                .background {
                    Circle().fill(recording ? Color.red : Color.primary.opacity(0.055))
                }
                .overlay {
                    Circle().strokeBorder(recording ? Color.red.opacity(0.5) : Color.primary.opacity(0.07), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(recording ? "停止听写" : "语音听写(中文)")
        .accessibilityLabel(recording ? "停止听写" : "语音听写")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: toolButtonSize, height: toolButtonSize)
                .background {
                    Circle().fill(Color.primary.opacity(0.055))
                }
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    #if os(iOS)
    private var iOSKeyboardCompact: Bool {
        inputFocused
    }

    private var hasIOSContextChips: Bool {
        viewModel.deviceToolsEnabledForNextSend ||
        viewModel.currentBoundSkill != nil ||
        viewModel.currentGitHubRepo != nil
    }

    private var iOSContextChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                if viewModel.deviceToolsEnabledForNextSend {
                    contextChip(
                        "设备工具",
                        icon: "wrench.and.screwdriver.fill",
                        tint: Color(red: 0.20, green: 0.60, blue: 0.62)
                    ) {
                        viewModel.deviceToolsEnabledForNextSend = false
                    }
                }
                if let skill = viewModel.currentBoundSkill {
                    contextChip(
                        "技能：\(skill.name)",
                        icon: "wand.and.stars.inverse",
                        tint: Color(red: 0.48, green: 0.36, blue: 0.90)
                    ) {
                        viewModel.setSelectedSkill(nil)
                    }
                }
                if let repo = viewModel.currentGitHubRepo {
                    contextChip(
                        "GitHub：\(repoShortName(repo))",
                        icon: "arrow.triangle.branch",
                        tint: .teal
                    ) {
                        viewModel.clearGitHubRepo()
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityLabel("当前发送上下文")
    }

    private func contextChip(_ title: String, icon: String, tint: Color, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除 \(title)")
        }
        .foregroundStyle(tint)
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(tint.opacity(0.11), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 1)
        }
    }
    #endif

    private var shellSpacing: CGFloat {
        #if os(iOS)
        return iOSKeyboardCompact ? 4 : 6
        #else
        return 10
        #endif
    }

    private var shellHorizontalPadding: CGFloat {
        #if os(iOS)
        return iOSKeyboardCompact ? 8 : 12
        #else
        return 16
        #endif
    }

    private var shellVerticalPadding: CGFloat {
        #if os(iOS)
        return iOSKeyboardCompact ? 5 : 8
        #else
        return 12
        #endif
    }

    private var promptHorizontalPadding: CGFloat {
        #if os(iOS)
        return iOSKeyboardCompact ? 11 : 13
        #else
        return 16
        #endif
    }

    private var promptVerticalPadding: CGFloat {
        #if os(iOS)
        return iOSKeyboardCompact ? 7 : 9
        #else
        return 12
        #endif
    }

    private var promptMinHeight: CGFloat {
        #if os(iOS)
        return iOSKeyboardCompact ? 40 : 44
        #else
        return 48
        #endif
    }

    private var promptMaxLines: Int {
        #if os(iOS)
        return iOSKeyboardCompact ? 3 : 5
        #else
        return 5
        #endif
    }

    private var largePromptMaxHeight: CGFloat {
        #if os(iOS)
        return iOSKeyboardCompact ? 110 : 180
        #else
        return 220
        #endif
    }

    private var promptCornerRadius: CGFloat {
        #if os(iOS)
        return iOSKeyboardCompact ? 20 : 16
        #else
        return 16
        #endif
    }

    private var toolButtonSize: CGFloat {
        #if os(iOS)
        return iOSKeyboardCompact ? 32 : 34
        #else
        return 30
        #endif
    }

    /// 当前选中的会话是否就是后台正在跑的那个 — 决定停止按钮的行为/显示。
    /// 用户切到别的会话时,这里 = false,按钮回到普通"发送"语义,不会误取消另一会话的请求。
    private var isViewingRunningConv: Bool {
        viewModel.isRunning && viewModel.runningConvID == viewModel.selectedConversationID
    }

    private var sendButton: some View {
        let isEnabled = viewModel.canSend || isViewingRunningConv
        let tint = isViewingRunningConv ? Color.red : viewModel.currentMode.kownTint
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
                    .frame(width: sendButtonSize, height: sendButtonSize)
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
        .accessibilityLabel(isViewingRunningConv ? "停止生成" : "发送")
    }

    private var sendButtonSize: CGFloat {
        #if os(iOS)
        return iOSKeyboardCompact ? 38 : 42
        #else
        return 38
        #endif
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

    private func repoShortName(_ repo: String) -> String {
        if let leaf = repo.split(separator: "/", omittingEmptySubsequences: true).last, !leaf.isEmpty {
            return String(leaf)
        }
        return repo
    }

    private func abbreviatedMiddle(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters, maxCharacters > 12 else { return value }
        let headCount = max(6, (maxCharacters - 1) / 2)
        let tailCount = max(6, maxCharacters - headCount - 1)
        return "\(value.prefix(headCount))…\(value.suffix(tailCount))"
    }
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
