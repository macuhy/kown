import SwiftUI
import WebKit

// MARK: - 桥接 JS(在 document start 注入,确保工具内联脚本运行前 window.kown 已就绪)

/// 注入到每个工具 WebView 的桥接脚本。提供:
/// - `window.kown.call(name, args)` → 返回 Promise;把 {requestId, callback, args} postMessage 给宿主,
///   宿主处理后调 `window.kownResolve(requestId, payloadJSON)` 兑现 Promise。
/// - `payload` = {ok, value?, error?}:ok 时 resolve(value),否则 reject(Error(error))。
private let kownBridgeJS = """
(function () {
  if (window.kown && window.kown.__installed) return;
  var pending = {};
  var seq = 0;
  function uid() { seq += 1; return 'k' + Date.now() + '_' + seq; }
  window.kown = {
    __installed: true,
    call: function (name, args) {
      return new Promise(function (resolve, reject) {
        var id = uid();
        pending[id] = { resolve: resolve, reject: reject };
        try {
          window.webkit.messageHandlers.kown.postMessage({
            requestId: id, callback: String(name), args: args || {}
          });
        } catch (e) {
          delete pending[id];
          reject(new Error('宿主桥不可用:' + e));
        }
      });
    }
  };
  // 宿主回填:payload 是 {ok, value?, error?}。
  window.kownResolve = function (requestId, payload) {
    var p = pending[requestId];
    if (!p) return;
    delete pending[requestId];
    try {
      if (payload && payload.ok) { p.resolve(payload.value); }
      else { p.reject(new Error((payload && payload.error) || '回调失败')); }
    } catch (e) { p.reject(e); }
  };
})();
"""

// MARK: - 跨平台 WKWebView 封装(带回调桥)

#if os(macOS)
struct GenerativeToolWebView: NSViewRepresentable {
    let html: String
    /// 处理 JS 回调:由 ViewModel 注入。返回结果后 Coordinator 负责 evaluateJavaScript 回填。
    let onCallback: (GenerativeToolRequest) async -> GenerativeToolResult

    func makeCoordinator() -> Coordinator { Coordinator(onCallback: onCallback) }

    func makeNSView(context: Context) -> WKWebView {
        let web = makeConfiguredWebView(coordinator: context.coordinator)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.onCallback = onCallback
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.detach(from: web)
    }

    typealias Coordinator = GenerativeToolWebCoordinator
}
#else
struct GenerativeToolWebView: UIViewRepresentable {
    let html: String
    let onCallback: (GenerativeToolRequest) async -> GenerativeToolResult

    func makeCoordinator() -> Coordinator { Coordinator(onCallback: onCallback) }

    func makeUIView(context: Context) -> WKWebView {
        let web = makeConfiguredWebView(coordinator: context.coordinator)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.onCallback = onCallback
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.detach(from: web)
    }

    typealias Coordinator = GenerativeToolWebCoordinator
}
#endif

/// 组装一个带桥接的 WKWebView:document-start 注入 `window.kown`,注册名为 `kown` 的 message handler,
/// 并把导航锁在初始 loadHTMLString(禁止跳转到任何外部 URL,安全边界)。
@MainActor
private func makeConfiguredWebView(coordinator: GenerativeToolWebCoordinator) -> WKWebView {
    let controller = WKUserContentController()
    controller.addUserScript(WKUserScript(
        source: kownBridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    // 弱引用避免 controller → coordinator → webView 的保留环;dismantle 时也会显式 detach。
    controller.add(coordinator, name: GenerativeToolWebCoordinator.handlerName)
    let config = WKWebViewConfiguration()
    config.userContentController = controller
    let web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = coordinator
    coordinator.webView = web
    return web
}

// MARK: - Coordinator:消息处理 + 导航锁

/// WebView 协调器:接 JS 回调、调 ViewModel、回填结果;并拦截外部导航。
/// `@MainActor` + 弱持 webView;闭包 onCallback 由 representable 每次 update 刷新(始终指向最新 ViewModel)。
@MainActor
final class GenerativeToolWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let handlerName = "kown"

    var onCallback: (GenerativeToolRequest) async -> GenerativeToolResult
    var lastHTML: String?
    weak var webView: WKWebView?
    /// 初始文档是否已开始加载 —— 之后任何非同源/外链导航一律拒绝。
    private var didLoadInitial = false

    init(onCallback: @escaping (GenerativeToolRequest) async -> GenerativeToolResult) {
        self.onCallback = onCallback
    }

    /// 从 controller 摘掉自己 + 断开 delegate(dismantle 时调,防 WebKit 回调打到已废弃对象)。
    func detach(from web: WKWebView) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        web.navigationDelegate = nil
        webView = nil
    }

    // MARK: WKScriptMessageHandler

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        // WebKit 在主线程派发;桥到 MainActor 安全地解析 + 处理。
        let body = message.body
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let request = GenerativeToolRequest(body: body) else { return }
            let result = await self.onCallback(request)
            self.resolve(result)
        }
    }

    /// 把结果回填给 JS:`window.kownResolve(<requestId>, <payload>)`。
    private func resolve(_ result: GenerativeToolResult) {
        guard let web = webView else { return }
        let idJSON = jsStringLiteral(result.requestID)
        let payload = result.payloadJSON()
        let js = "window.kownResolve && window.kownResolve(\(idJSON), \(payload));"
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 把字符串安全地包成 JS 字符串字面量(走 JSON 编码,转义引号/换行)。
    private func jsStringLiteral(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]),
           let arr = String(data: data, encoding: .utf8) {
            // ["..."] → 取中间的 "..."。
            return String(arr.dropFirst().dropLast())
        }
        return "\"\""
    }

    // MARK: WKNavigationDelegate(导航锁:只许初始文档,禁外链)

    /// 初始 loadHTMLString 放行一次;之后任何导航(点链接 / JS 跳转 / 表单提交)一律拦截。
    /// 用 async 版本(而非 escaping completion handler)避免把非 Sendable 回调送过 Task 边界。
    /// 方法随类 @MainActor 隔离,直接读写 main-actor 状态。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if !didLoadInitial {
            didLoadInitial = true
            return .allow
        }
        return .cancel
    }
}

// MARK: - 工具文档骨架(深浅色 + 视口 + 安全外壳)

/// 把模型给的 HTML 包成可直接 loadHTMLString 的完整文档。
/// 模型通常已给完整 <!doctype html>;此时只在 `<head>` 注入一段最小自适应样式底座。
/// 若模型只给了片段,补一层骨架。绝不引任何外链(桥接 JS 由 WKUserScript 注入,不在这里拼)。
enum GenerativeToolHTMLBuilder {
    static func document(_ src: String, dark: Bool) -> String {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let isFullDoc = lower.contains("<!doctype") || lower.contains("<html")
        if isFullDoc { return trimmed }
        let bg = dark ? "#1c1c1e" : "#ffffff"
        let fg = dark ? "#e5e5e7" : "#1c1c1e"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html,body{margin:0;padding:14px;background:\(bg);color:\(fg);
        font-family:-apple-system,system-ui,sans-serif;line-height:1.5;}
        button,input,select,textarea{font:inherit;}
        </style></head>
        <body>\(trimmed)</body></html>
        """
    }
}

// MARK: - 生成式工具面板(Canvas)

/// 「AI 现做交互工具」面板:展示当前 active 工具(WKWebView 渲染,带回调桥),
/// 支持工具历史切换、「让 AI 改工具」、删除。严格模仿 `ArtifactPreviewPanel` 的生命周期管理:
/// 换会话 / 换工具 / 换版本时通过 `webViewKey` 强制重建底层 WebView(防「渲染一次后白屏」)。
struct GenerativeToolPanel: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var instruction = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.generatingTool && viewModel.activeGenerativeTool == nil {
                generatingState
            } else if let tool = viewModel.activeGenerativeTool {
                toolBody(tool)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 300)
    }

    // MARK: 头部(标题 + 工具历史切换 + 关闭)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(ConversationMode.direct.kownTint)
            Text("交互工具")
                .font(.headline)
            Spacer()
            let tools = viewModel.generativeToolsForCurrentConversation
            if tools.count > 1 {
                Menu {
                    ForEach(tools.reversed()) { t in
                        Button {
                            viewModel.openGenerativeTool(t)
                        } label: {
                            let mark = (viewModel.activeGenerativeTool?.id == t.id) ? "✓ " : ""
                            Text("\(mark)\(t.spec.title)\(t.version > 1 ? " · v\(t.version)" : "")")
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("工具历史")
            }
            Button {
                viewModel.showGenerativeToolPanel = false
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 工具主体(WebView + 修改栏)

    @ViewBuilder
    private func toolBody(_ tool: StoredGenerativeTool) -> some View {
        // 标题 / 说明条
        VStack(alignment: .leading, spacing: 2) {
            Text(tool.spec.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if !tool.spec.summary.isEmpty {
                Text(tool.spec.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)

        GenerativeToolWebView(
            html: GenerativeToolHTMLBuilder.document(tool.spec.html, dark: colorScheme == .dark),
            onCallback: { [weak viewModel] request in
                guard let viewModel else {
                    return .failure(requestID: request.requestID, error: "工具已关闭")
                }
                return await viewModel.handleToolCallback(request)
            }
        )
        .id(webViewKey(tool))
        .background(Color.platformControlBackground)

        Divider()
        reviseBar
    }

    /// WebView 身份键:换会话 / 换工具 / 工具版本变化时强制重建底层 WebView,防复用后白屏
    ///(与 `ArtifactPreviewPanel.webViewKey` 同款思路)。
    private func webViewKey(_ tool: StoredGenerativeTool) -> String {
        let convID = viewModel.selectedConversationID?.uuidString ?? "-"
        return "\(convID)|\(tool.id.uuidString)|v\(tool.version)"
    }

    private var reviseBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = viewModel.generativeToolError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                TextField("让 AI 改这个工具…(如『加一个利率滑块』)", text: $instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit { sendRevision() }
                if viewModel.generatingTool {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        sendRevision()
                    } label: {
                        Image(systemName: "paperplane.circle.fill")
                            .font(.title3)
                            .foregroundStyle(
                                instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.secondary : ConversationMode.direct.kownTint
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("按要求修改工具(产出新版本)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sendRevision() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.runToolRevision(instruction: text)
        instruction = ""
    }

    // MARK: 空 / 生成中

    private var generatingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在为你现做交互工具…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground.opacity(0.4))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars.inverse")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            if let err = viewModel.generativeToolError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                Text("还没有交互工具")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("在回答下方点「生成交互工具」,模型会为这个问题现做一个能用、能回调它的小工具。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground.opacity(0.4))
    }
}
