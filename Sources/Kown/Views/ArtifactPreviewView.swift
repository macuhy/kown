import SwiftUI
import WebKit

// MARK: - 跨平台 WKWebView 封装

/// 渲染一段完整 HTML 文档的 WebView。Coordinator 记住上次加载的 html,避免相同内容重复 reload 闪烁。
#if os(macOS)
struct ArtifactWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator { var lastHTML: String? }
}
#else
struct ArtifactWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator { var lastHTML: String? }
}
#endif

// MARK: - Artifact → 完整 HTML 文档

/// 把抽出的 artifact 包成可直接 loadHTMLString 的完整 HTML 文档。
/// Mermaid 走**内联离线 mermaid.min.js**(绝不引 CDN,也绝不 `Bundle.module`)。
enum ArtifactHTMLBuilder {
    /// 内联一次读取的 mermaid.min.js(找不到返回 nil → mermaid 退化为显示源码提示)。
    /// 走 `Bundle.main` + resourcePath 兜底链,与 ChangelogService 一致,App Translocation 下也安全。
    static let mermaidJS: String? = loadMermaidJS()

    private static func loadMermaidJS() -> String? {
        if let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let resPath = Bundle.main.resourcePath {
            for candidate in ["mermaid.min.js", "Kown_Kown.bundle/mermaid.min.js"] {
                let p = (resPath as NSString).appendingPathComponent(candidate)
                if let s = try? String(contentsOfFile: p, encoding: .utf8) { return s }
            }
        }
        return nil
    }

    static func document(for block: ArtifactBlock, dark: Bool) -> String {
        switch block.kind {
        case .html:
            return htmlDocument(block.source, dark: dark)
        case .svg:
            return svgDocument(block.source, dark: dark)
        case .mermaid:
            return mermaidDocument(block.source, dark: dark)
        }
    }

    private static func bodyBG(_ dark: Bool) -> String { dark ? "#1c1c1e" : "#ffffff" }
    private static func fg(_ dark: Bool) -> String { dark ? "#e5e5e7" : "#1c1c1e" }

    /// 已经是完整文档(含 <html>/<!doctype>)就原样用;否则包一层最小骨架。
    private static func htmlDocument(_ src: String, dark: Bool) -> String {
        let lower = src.lowercased()
        if lower.contains("<!doctype") || lower.contains("<html") { return src }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;padding:12px;background:\(bodyBG(dark));color:\(fg(dark));
        font-family:-apple-system,system-ui,sans-serif;}</style></head>
        <body>\(src)</body></html>
        """
    }

    private static func svgDocument(_ src: String, dark: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;height:100%;background:\(bodyBG(dark));
        display:flex;align-items:center;justify-content:center;}
        svg{max-width:100%;max-height:100vh;height:auto;}</style></head>
        <body>\(src)</body></html>
        """
    }

    private static func mermaidDocument(_ src: String, dark: Bool) -> String {
        guard let js = mermaidJS else {
            return htmlDocument("<pre>未能加载 mermaid 渲染库,以下为源码:\n\n\(escapeHTML(src))</pre>", dark: dark)
        }
        let theme = dark ? "dark" : "default"
        // 源码放进 <div class="mermaid"> 文本节点,避免被当 HTML 解析;mermaid 读 textContent。
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;padding:12px;background:\(bodyBG(dark));
        display:flex;align-items:center;justify-content:center;}
        .mermaid{max-width:100%;}</style>
        <script>\(js)</script></head>
        <body>
        <div class="mermaid">\(escapeHTML(src))</div>
        <script>
        try { mermaid.initialize({ startOnLoad: true, theme: "\(theme)", securityLevel: "strict" }); }
        catch (e) { document.body.innerHTML = "<pre>渲染失败:" + e + "</pre>"; }
        </script>
        </body></html>
        """
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - 预览面板(Canvas)

/// Artifacts Canvas 面板:从当前(流式 / 最近一轮)回答里抽 artifact,
/// 预览 / 源码两种模式 — 源码可编辑(0.5s 防抖实时重渲染),底部可「让 AI 修改」,
/// 每次保存 / AI 修改生成一个版本(v1 原始),版本按会话持久化(`ArtifactVersionStore`)。
/// 节流(0.30s)重抽,避免在每次流式 flush(~20Hz)上重 parse + 重建 HTML。
struct ArtifactPreviewPanel: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    private enum ViewMode: String, CaseIterable {
        case preview, code
        var displayName: String { self == .preview ? "预览" : "源码" }
    }

    private struct SourceToken: Equatable {
        let conversationID: UUID?
        let turnID: UUID?
        let providerID: UUID?
        let charCount: Int
        let isRunning: Bool
    }

    @State private var blocks: [ArtifactBlock] = []
    @State private var selectedID: Int?
    @State private var renderedHTML: String = ""
    @State private var lastSourceHash: Int = 0

    // Canvas 化:编辑 / 版本 / AI 修改状态
    @State private var viewMode: ViewMode = .preview
    @State private var draft: String = ""
    @State private var draftDirty = false
    @State private var versions: [ArtifactVersion] = []
    @State private var selectedVersionID: UUID?     // nil = 跟随最新版本
    @State private var activeKey: String?           // 当前 artifact 的持久化键
    @State private var renderDebounce: Task<Void, Never>?
    @State private var aiInstruction = ""
    @State private var aiFocus = ""
    @State private var showFocusField = false
    @State private var isRevising = false
    @State private var reviseError: String?
    @State private var publishPayload: ArtifactPublishPayload?   // 非 nil 时弹「发布到 GitHub Pages」sheet

    @State private var refreshTask: Task<Void, Never>?
    @State private var lastRefreshAt: Date = .distantPast
    private static let refreshInterval: TimeInterval = 0.30

    var body: some View {
        VStack(spacing: 0) {
            header
            if !blocks.isEmpty {
                canvasToolbar
            }
            Divider()
            if blocks.isEmpty {
                emptyState
            } else if viewMode == .code {
                sourceEditor
            } else {
                ArtifactWebView(html: renderedHTML)
                    .id(webViewKey)
                    .background(Color.platformControlBackground)
            }
            if currentBlock != nil {
                Divider()
                aiReviseBar
            }
        }
        .frame(minWidth: 280)
        .onAppear { refresh(force: true) }
        .onChange(of: sourceToken) { _, _ in scheduleRefresh(force: false) }
        .onChange(of: viewModel.isRunning) { _, _ in scheduleRefresh(force: true) }
        .onChange(of: viewModel.selectedConversationID) { _, _ in scheduleRefresh(force: true) }
        .onDisappear {
            refreshTask?.cancel()
            renderDebounce?.cancel()
        }
        .sheet(item: $publishPayload) { payload in
            ArtifactPublishSheet(payload: payload)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.righthalf.inset.filled")
                .foregroundStyle(ConversationMode.direct.kownTint)
            Text("Canvas")
                .font(.headline)
            Spacer()
            if blocks.count > 1 {
                Picker("", selection: Binding(
                    get: { selectedID ?? blocks.last?.id ?? 0 },
                    set: { selectedID = $0; syncArtifactState(); rebuildHTML() }
                )) {
                    ForEach(blocks) { b in
                        Text("\(b.kind.displayName) #\(b.id + 1)").tag(b.id)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            } else if let only = blocks.first {
                Text(only.kind.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Button {
                viewModel.showArtifactPanel = false
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭预览")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 第二行工具栏:预览/源码切换 + 版本历史 + 手动保存。
    private var canvasToolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 150)

            if versions.count > 1 {
                versionMenu
            }

            Spacer()

            if draftDirty {
                Button {
                    saveDraft()
                } label: {
                    Label("保存", systemImage: "checkmark.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(!canEdit)
                .help("把当前修改保存为新版本")

                Button {
                    discardDraft()
                } label: {
                    Label("还原", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("放弃未保存的修改")
            }

            // 仅连接了 GitHub 才显示发布入口。
            if viewModel.gitHubConnected {
                Button {
                    preparePublish()
                } label: {
                    Label("发布", systemImage: "globe")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(currentBlock == nil)
                .help("发布到 GitHub Pages…")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// 组装发布 sheet 的输入:当前展示的源码 → 自包含 HTML(浅色,公开页面),
    /// 默认 slug 优先沿用上次发布的(覆盖更新),否则取会话标题拼音化 / 短 hash。
    private func preparePublish() {
        guard let block = currentBlock else { return }
        let src = draftDirty ? draft : (baseSource ?? block.source)
        let effective = ArtifactBlock(id: block.id, kind: block.kind, source: src, isClosed: block.isClosed)
        let html = ArtifactHTMLBuilder.document(for: effective, dark: false)
        let key = persistenceKey
        let previous = key.flatMap { ArtifactPublishMemory.slug(for: $0) }
        let slug = previous ?? GitHubPagesPublisher.defaultSlug(
            title: viewModel.selectedConversation?.title,
            fallbackSeed: key ?? src
        )
        publishPayload = ArtifactPublishPayload(
            html: html, defaultSlug: slug, artifactKey: key, previousSlug: previous)
    }

    /// 版本历史菜单:v1 原始 → vN 最新,可切换回看任意版本。
    private var versionMenu: some View {
        Menu {
            ForEach(Array(versions.enumerated()), id: \.element.id) { idx, v in
                Button {
                    selectedVersionID = (idx == versions.count - 1) ? nil : v.id
                    draft = v.source
                    draftDirty = false
                    reviseError = nil
                    rebuildHTML()
                } label: {
                    let mark = (effectiveVersion?.id == v.id) ? "✓ " : ""
                    Text("\(mark)v\(idx + 1) · \(v.origin.displayName) · \(v.createdAt.formatted(date: .omitted, time: .shortened))")
                }
            }
        } label: {
            Label(currentVersionLabel, systemImage: "clock.arrow.circlepath")
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("版本历史")
    }

    private var currentVersionLabel: String {
        guard let v = effectiveVersion,
              let idx = versions.firstIndex(where: { $0.id == v.id }) else { return "v1" }
        return "v\(idx + 1)/\(versions.count)"
    }

    // MARK: - 源码编辑

    /// 等宽 TextEditor;改动 0.5s 防抖重渲染(切回预览即见),保存才生成版本。
    /// 性能:纯文本编辑器、无语法高亮 / attributed 重排,大文本不会卡输入(0.21.1 的教训)。
    private var sourceEditor: some View {
        TextEditor(text: Binding(
            get: { draft },
            set: { newValue in
                guard newValue != draft else { return }
                draft = newValue
                draftDirty = (newValue != (baseSource ?? ""))
                scheduleRender()
            }
        ))
        .font(.system(.footnote, design: .monospaced))
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 8)
        .background(Color.platformTextBackground)
        .disabled(!canEdit && !draftDirty)
        .overlay(alignment: .bottomTrailing) {
            if !canEdit {
                Text(viewModel.isRunning ? "回答生成中,完成后可编辑" : "此内容暂不可编辑")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(10)
            }
        }
    }

    // MARK: - 让 AI 修改

    private var aiReviseBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = reviseError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if showFocusField {
                TextField("重点片段(可选)— 粘贴要重点修改的源码片段", text: $aiFocus, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1...3)
            }
            HStack(spacing: 8) {
                Button {
                    showFocusField.toggle()
                    if !showFocusField { aiFocus = "" }
                } label: {
                    Image(systemName: showFocusField ? "text.badge.minus" : "text.badge.plus")
                        .foregroundStyle(showFocusField ? ConversationMode.direct.kownTint : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("附上要重点修改的源码片段")

                TextField("让 AI 修改这个 artifact…", text: $aiInstruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit { sendAIRevision() }

                if isRevising {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        sendAIRevision()
                    } label: {
                        Image(systemName: "paperplane.circle.fill")
                            .font(.title3)
                            .foregroundStyle(
                                aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canEdit
                                    ? Color.secondary : ConversationMode.direct.kownTint
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canEdit)
                    .help("发送修改要求(结果作为新版本,不进对话)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("当前回答里没有可预览的内容")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("当模型输出 ```html / ```svg / ```mermaid 代码块时,这里会实时渲染。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground.opacity(0.4))
    }

    // MARK: - 当前 artifact / 版本解析

    private var currentBlock: ArtifactBlock? {
        guard let id = selectedID ?? blocks.last?.id else { return nil }
        return blocks.first(where: { $0.id == id })
    }

    /// 当前 artifact 的持久化键。要求:有会话、有最近一轮(回答已落盘)、围栏闭合。
    /// 流式进行中(turn 可能尚未 append / 文本来自 liveStates)不给键 → 不可编辑,避免错挂版本。
    private var persistenceKey: String? {
        guard !viewModel.isRunning,
              let conv = viewModel.selectedConversation,
              let turn = conv.turns.last,
              let block = currentBlock, block.isClosed else { return nil }
        return ArtifactVersionStore.key(turnID: turn.id, blockID: block.id)
    }

    private var canEdit: Bool { persistenceKey != nil }

    /// 当前查看的版本(nil = 无历史 → 直接用消息里的原始 source)。
    private var effectiveVersion: ArtifactVersion? {
        if let id = selectedVersionID, let v = versions.first(where: { $0.id == id }) { return v }
        return versions.last
    }

    /// 展示 / 编辑的基准源码:有版本历史用版本,否则用消息原文。
    private var baseSource: String? {
        effectiveVersion?.source ?? currentBlock?.source
    }

    /// WebView 身份键:换会话 / 换 artifact / 换版本 / 流式结束(isClosed 翻转)/ 新一轮回答时,
    /// 强制重建底层 WKWebView,避免**复用同一个 web view 在 reload 后渲染空白**
    /// (用户反馈的「渲染一次之后就不渲染了」——抽取正常、面板非空,但 WebView 是白的)。
    /// 流式增长 / 草稿防抖重渲染期间键保持不变,内容靠 `updateNSView` 增量 reload,不闪。
    private var webViewKey: String {
        let convID = viewModel.selectedConversationID?.uuidString ?? "-"
        let turnCount = viewModel.selectedConversation?.turns.count ?? 0
        let sel = selectedID ?? blocks.last?.id ?? -1
        let closed = blocks.first(where: { $0.id == sel })?.isClosed ?? false
        let ver = selectedVersionID?.uuidString ?? "latest\(versions.count)"
        return "\(convID)|\(turnCount)|\(sel)|\(closed)|\(ver)"
    }

    /// 取要预览的源文本:优先正在流式的首个 panel 回答,否则最近一轮的首份回答。
    private var sourceText: String {
        if let cfg = viewModel.providersForCurrentSend().panel.first,
           let s = viewModel.liveStates[cfg.id], !s.text.isEmpty {
            return s.text
        }
        if let conv = viewModel.selectedConversation, let turn = conv.turns.last,
           let cfg = turn.orderedPanelConfigs.first {
            return turn.responses[cfg.id.uuidString] ?? ""
        }
        return ""
    }

    /// `onChange` 用轻量 token 触发,避免每次 live flush 都让 SwiftUI 对整段回答做 String 等值比较。
    private var sourceToken: SourceToken {
        let convID = viewModel.selectedConversationID
        if let cfg = viewModel.providersForCurrentSend().panel.first,
           let state = viewModel.liveStates[cfg.id], !state.text.isEmpty {
            return SourceToken(conversationID: convID, turnID: nil, providerID: cfg.id,
                               charCount: state.charCount, isRunning: viewModel.isRunning)
        }
        if let turn = viewModel.selectedConversation?.turns.last,
           let cfg = turn.orderedPanelConfigs.first {
            let text = turn.responses[cfg.id.uuidString] ?? ""
            return SourceToken(conversationID: convID, turnID: turn.id, providerID: cfg.id,
                               charCount: text.utf16.count, isRunning: viewModel.isRunning)
        }
        return SourceToken(conversationID: convID, turnID: nil, providerID: nil,
                           charCount: 0, isRunning: viewModel.isRunning)
    }

    private func refresh(force: Bool) {
        lastRefreshAt = Date()
        let text = sourceText
        let hash = text.hashValue
        guard force || hash != lastSourceHash else {
            // 文本没变,但可编辑性可能翻转(流式刚结束:liveStates → turn.responses 文本相同,
            // 而 isRunning 已变 false)→ 轻量同步持久化键,否则面板会一直停在「不可编辑」。
            if persistenceKey != activeKey {
                syncArtifactState()
                rebuildHTML()
            }
            return
        }
        lastSourceHash = hash
        let newBlocks = ArtifactExtractor.extract(text)
        if newBlocks != blocks {
            blocks = newBlocks
            // 选中项失效时默认选最后一个(最新的 artifact)。
            if selectedID == nil || !newBlocks.contains(where: { $0.id == selectedID }) {
                selectedID = newBlocks.last?.id
            }
        }
        syncArtifactState()
        rebuildHTML()
    }

    /// 事件驱动节流:只有源文本真的变化时才抽取 artifact;空闲时不再靠 0.3s Timer 常驻唤醒主线程。
    private func scheduleRefresh(force: Bool) {
        if force {
            refreshTask?.cancel()
            refreshTask = nil
            refresh(force: true)
            return
        }

        let elapsed = Date().timeIntervalSince(lastRefreshAt)
        guard elapsed < Self.refreshInterval else {
            refreshTask?.cancel()
            refreshTask = nil
            refresh(force: false)
            return
        }
        guard refreshTask == nil else { return }

        let delay = Self.refreshInterval - elapsed
        refreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            refresh(force: false)
            refreshTask = nil
        }
    }

    /// 让编辑 / 版本状态跟上「当前指向的 artifact」:
    /// - 换 artifact(键变了)→ 重新加载版本历史、重置草稿;
    /// - 同一 artifact 且无未保存改动 → 草稿跟随基准源(流式增长时同步)。
    /// 有未保存改动时**绝不**覆盖草稿(tick 不会冲掉正在输入的内容)。
    private func syncArtifactState() {
        let newKey = persistenceKey
        if newKey != activeKey {
            activeKey = newKey
            selectedVersionID = nil
            reviseError = nil
            if let key = newKey, let convID = viewModel.selectedConversationID {
                versions = ArtifactVersionStore.versions(conversationID: convID, key: key)
            } else {
                versions = []
            }
            draft = baseSource ?? ""
            draftDirty = false
        } else if !draftDirty {
            let base = baseSource ?? ""
            if draft != base { draft = base }
        }
    }

    /// 源码编辑的防抖重渲染(~0.5s):连续输入只触发最后一次 HTML 重建,
    /// 避免每个按键都重建整页文档(CPU 不变量,参考 0.21.1 输入框卡死修复)。
    private func scheduleRender() {
        renderDebounce?.cancel()
        renderDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            rebuildHTML()
        }
    }

    private func rebuildHTML() {
        guard let block = currentBlock else {
            renderedHTML = ""
            return
        }
        let src = draftDirty ? draft : (baseSource ?? block.source)
        let effective = ArtifactBlock(id: block.id, kind: block.kind, source: src, isClosed: block.isClosed)
        renderedHTML = ArtifactHTMLBuilder.document(for: effective, dark: colorScheme == .dark)
    }

    // MARK: - 保存 / 还原 / AI 修改

    /// 把当前草稿保存为新版本(手动编辑)。首次保存自动补 v1(原始)。
    private func saveDraft() {
        guard draftDirty,
              let key = persistenceKey,
              let convID = viewModel.selectedConversationID,
              let block = currentBlock else { return }
        ArtifactVersionStore.append(
            ArtifactVersion(origin: .manual, source: draft),
            conversationID: convID, key: key, originalSource: block.source
        )
        versions = ArtifactVersionStore.versions(conversationID: convID, key: key)
        selectedVersionID = nil
        draftDirty = false
        rebuildHTML()
    }

    /// 放弃未保存的草稿,回到当前版本。
    private func discardDraft() {
        renderDebounce?.cancel()
        draft = baseSource ?? ""
        draftDirty = false
        rebuildHTML()
    }

    /// 「让 AI 修改」:当前 artifact 全文 + 修改要求(+ 可选重点片段)发给当前会话的模型,
    /// 要求返回完整修改后代码(单代码块),解析后作为新版本替换渲染。**不进**主对话流。
    private func sendAIRevision() {
        let instruction = aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !isRevising,
              let key = persistenceKey,
              let convID = viewModel.selectedConversationID,
              let block = currentBlock else { return }
        let kind = block.kind
        let source = draftDirty ? draft : (baseSource ?? block.source)
        let focus = showFocusField ? aiFocus : nil
        isRevising = true
        reviseError = nil
        Task { @MainActor in
            defer { isRevising = false }
            do {
                let reply = try await viewModel.runArtifactRevision(
                    prompt: ArtifactExtractor.revisionPrompt(
                        source: source, kind: kind, instruction: instruction, focus: focus),
                    systemPrompt: ArtifactExtractor.revisionSystemPrompt(for: kind)
                )
                guard let revised = ArtifactExtractor.revisedSource(fromReply: reply, kind: kind),
                      !revised.isEmpty else {
                    throw ArtifactRevisionError.emptyReply
                }
                ArtifactVersionStore.append(
                    ArtifactVersion(origin: .ai, source: revised),
                    conversationID: convID, key: key, originalSource: block.source
                )
                versions = ArtifactVersionStore.versions(conversationID: convID, key: key)
                selectedVersionID = nil
                draft = revised
                draftDirty = false
                aiInstruction = ""
                aiFocus = ""
                showFocusField = false
                rebuildHTML()
            } catch {
                reviseError = error.localizedDescription
            }
        }
    }
}

// MARK: - 发布到 GitHub Pages

/// 发布 sheet 的输入快照(按下按钮那一刻的 HTML / slug,不随面板继续流式变化)。
struct ArtifactPublishPayload: Identifiable {
    let id = UUID()
    /// 自包含 HTML(发布产物)。
    let html: String
    /// 默认文件名 slug(上次发布的 slug 或标题拼音化)。
    let defaultSlug: String
    /// artifact 持久化键(用于记忆 slug;流式中 / 无会话时为 nil,不记忆)。
    let artifactKey: String?
    /// 该 artifact 上次发布用的 slug(nil = 首次发布)。
    let previousSlug: String?
}

/// 轻量确认 sheet:展示目标仓库(自动建/复用公开仓库 `kown-pages`)+ 可改的文件名 slug,
/// 发布成功后给出页面链接(复制 / 浏览器打开),并按需提示 Pages 首次启用要等几分钟。
struct ArtifactPublishSheet: View {
    let payload: ArtifactPublishPayload
    @Environment(\.dismiss) private var dismiss

    @State private var slug: String
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var result: GitHubPagesPublisher.Result?
    @State private var copied = false

    private let tint = ConversationMode.direct.kownTint
    private let warmTint = Color(red: 0.95, green: 0.49, blue: 0.16)

    init(payload: ArtifactPublishPayload) {
        self.payload = payload
        _slug = State(initialValue: payload.defaultSlug)
    }

    var body: some View {
        ZStack {
            publishBackground
            VStack(spacing: 0) {
                publishHeader
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
                Group {
                    if let result {
                        successView(result)
                    } else {
                        formView
                    }
                }
                .padding(18)
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 540)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private var publishBackground: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(colors: [tint.opacity(0.16), Color.clear], center: .topLeading, startRadius: 30, endRadius: 360)
            RadialGradient(colors: [warmTint.opacity(0.11), Color.clear], center: .bottomTrailing, startRadius: 40, endRadius: 380)
        }
        .ignoresSafeArea()
    }

    private var publishHeader: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [tint, warmTint.opacity(0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "globe")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            .shadow(color: tint.opacity(0.20), radius: 14, x: 0, y: 7)

            VStack(alignment: .leading, spacing: 5) {
                Text("发布到 GitHub Pages")
                    .font(.headline.weight(.bold))
                Text("生成公开网页链接,方便把交付物或 artifact 发给别人查看。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.regularMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("关闭发布面板")
        }
        .padding(18)
    }

    // MARK: 表单

    private var formView: some View {
        VStack(alignment: .leading, spacing: 14) {
            targetCard
            slugCard

            if let prev = payload.previousSlug, GitHubPagesPublisher.sanitizeSlug(slug) == prev {
                inlineNotice(
                    "此内容之前发布过,本次将覆盖更新同一页面。",
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: tint
                )
            }

            if let errorMessage {
                inlineNotice(errorMessage, systemImage: "exclamationmark.triangle.fill", tint: .red)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .disabled(isPublishing)
                if isPublishing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("发布中")
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                } else {
                    Button {
                        publish()
                    } label: {
                        Label("发布", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(GitHubPagesPublisher.sanitizeSlug(slug).isEmpty)
                }
            }
        }
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发布目标")
                .font(.caption.weight(.black))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            infoRow("仓库", value: "\(GitHubPagesPublisher.repoName) · 自动创建或复用", systemImage: "tray.full", tint: tint)
            infoRow("可见性", value: "公开页面,任何拿到链接的人都能访问", systemImage: "exclamationmark.triangle", tint: warmTint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 1)
        }
    }

    private var slugCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("页面文件名")
                .font(.caption.weight(.black))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                TextField("文件名", text: $slug)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                Text(".html")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
            }
            .background(Color.platformTextBackground.opacity(0.74), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }

            Label("pages/\(GitHubPagesPublisher.sanitizeSlug(slug)).html", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.40), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: 成功

    private func successView(_ result: GitHubPagesPublisher.Result) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label(result.isUpdate ? "已更新页面" : "已发布页面", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.green)
                Text(result.isUpdate ? "链接保持不变,内容已经覆盖更新。" : "页面链接已生成,可以复制或直接打开检查。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.18), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("页面链接")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.secondary)
                Text(result.pageURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.platformTextBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
            }

            resultNotice(result)

            HStack(spacing: 10) {
                Button {
                    Platform.copyText(result.pageURL)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制链接", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    if let url = URL(string: result.pageURL) { Platform.open(url) }
                } label: {
                    Label("打开", systemImage: "safari")
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func resultNotice(_ result: GitHubPagesPublisher.Result) -> some View {
        if result.pagesJustEnabled {
            inlineNotice("Pages 站点刚开启,页面可能要等几分钟才能访问。", systemImage: "clock", tint: tint)
        } else if result.needsManualPagesSetup {
            inlineNotice("未能自动开启 Pages:请到仓库 Settings → Pages 选择默认分支开启一次。", systemImage: "exclamationmark.triangle", tint: warmTint)
        } else if result.isUpdate {
            inlineNotice("CDN 缓存可能延迟几分钟,链接不变。", systemImage: "info.circle", tint: tint)
        }
    }

    private func infoRow(_ title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inlineNotice(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.17), lineWidth: 1)
            }
    }

    // MARK: 动作

    private func publish() {
        let cleaned = GitHubPagesPublisher.sanitizeSlug(slug)
        guard !cleaned.isEmpty else {
            errorMessage = "文件名不能为空(只能用字母、数字、连字符)"
            return
        }
        slug = cleaned
        guard let token = GitHubAuth.token() else {
            errorMessage = GitHubError.notConnected.localizedDescription
            return
        }
        isPublishing = true
        errorMessage = nil
        Task { @MainActor in
            defer { isPublishing = false }
            do {
                let r = try await GitHubPagesPublisher(token: token).publish(slug: cleaned, html: payload.html)
                result = r
                if let key = payload.artifactKey {
                    ArtifactPublishMemory.remember(slug: cleaned, for: key)
                }
            } catch {
                errorMessage = GitHubPagesPublisher.friendlyMessage(for: error)
            }
        }
    }
}
