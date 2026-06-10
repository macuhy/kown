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

// MARK: - 预览面板

/// Artifacts 实时预览面板:从当前(流式 / 最近一轮)回答里抽 artifact,选一个用 WebView 渲染。
/// 节流(0.30s)重抽,避免在每次流式 flush(~20Hz)上重 parse + 重建 HTML。
struct ArtifactPreviewPanel: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var blocks: [ArtifactBlock] = []
    @State private var selectedID: Int?
    @State private var renderedHTML: String = ""
    @State private var lastSourceHash: Int = 0

    private let tick = Timer.publish(every: 0.30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if blocks.isEmpty {
                emptyState
            } else {
                ArtifactWebView(html: renderedHTML)
                    .id(webViewKey)
                    .background(Color.platformControlBackground)
            }
        }
        .frame(minWidth: 280)
        .onAppear { refresh(force: true) }
        .onReceive(tick) { _ in refresh(force: false) }
        .onChange(of: viewModel.selectedConversationID) { _, _ in refresh(force: true) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.righthalf.inset.filled")
                .foregroundStyle(ConversationMode.direct.kownTint)
            Text("预览")
                .font(.headline)
            Spacer()
            if blocks.count > 1 {
                Picker("", selection: Binding(
                    get: { selectedID ?? blocks.last?.id ?? 0 },
                    set: { selectedID = $0; rebuildHTML() }
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

    /// WebView 身份键:换会话 / 换 artifact / 流式结束(isClosed 翻转)/ 新一轮回答时,
    /// 强制重建底层 WKWebView,避免**复用同一个 web view 在 reload 后渲染空白**
    /// (用户反馈的「渲染一次之后就不渲染了」——抽取正常、面板非空,但 WebView 是白的)。
    /// 流式增长期间(同会话、同 block、未闭合)键保持不变,内容靠 `updateNSView` 增量 reload,不闪。
    private var webViewKey: String {
        let convID = viewModel.selectedConversationID?.uuidString ?? "-"
        let turnCount = viewModel.selectedConversation?.turns.count ?? 0
        let sel = selectedID ?? blocks.last?.id ?? -1
        let closed = blocks.first(where: { $0.id == sel })?.isClosed ?? false
        return "\(convID)|\(turnCount)|\(sel)|\(closed)"
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

    private func refresh(force: Bool) {
        let text = sourceText
        let hash = text.hashValue
        guard force || hash != lastSourceHash else { return }
        lastSourceHash = hash
        let newBlocks = ArtifactExtractor.extract(text)
        if newBlocks != blocks {
            blocks = newBlocks
            // 选中项失效时默认选最后一个(最新的 artifact)。
            if selectedID == nil || !newBlocks.contains(where: { $0.id == selectedID }) {
                selectedID = newBlocks.last?.id
            }
        }
        rebuildHTML()
    }

    private func rebuildHTML() {
        guard let id = selectedID ?? blocks.last?.id,
              let block = blocks.first(where: { $0.id == id }) else {
            renderedHTML = ""
            return
        }
        renderedHTML = ArtifactHTMLBuilder.document(for: block, dark: colorScheme == .dark)
    }
}
