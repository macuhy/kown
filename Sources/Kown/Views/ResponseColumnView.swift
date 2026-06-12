import SwiftUI

struct ResponseColumnView: View {
    let config: ProviderConfig
    @Bindable var state: ResponseState
    @State private var copied = false
    // 折叠/展开:超长「已完成」回答默认折叠,点按展开。
    // 仅作用于 finished 阶段的纯展示;streaming 期间不折叠,保证自动滚动正常。
    @State private var expanded = false
    /// 自动滚底节流闸:flush 每 ~50ms 触发一次 text 变更,N 列 Council 并发时 = N×20Hz 次 scrollTo,
    /// 每次都强制一次 anchor 解析 + 布局。用它把每列 scrollTo 合并到 ~8Hz。
    @State private var scrollPending = false
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// 超过该字符数的已完成回答默认折叠。
    private let collapseThreshold = 1_400
    /// 内容超过该字符数后,渲染高度必然远超 textBody 的 minHeight(即使被折叠成
    /// `collapsedLineLimit` 行也够),此时省略 minHeight 约束。
    /// 否则 minHeight 会逼着布局系统同步测量整列内容(含 MarkdownText)再与最小值
    /// 比较,Council/Compare 多列并发时切回会话瞬间主线程被 N 列测量卡住。
    private let minHeightSkipThreshold = 2_000
    /// 折叠态最多显示的行数。
    private let collapsedLineLimit = 14

    private var isCompact: Bool {
        #if os(iOS)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }

    private var cardCorner: CGFloat { isCompact ? 19 : 22 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(accentGradient)
                .frame(height: 4)

            header
                .padding(.horizontal, isCompact ? 14 : 18)
                .padding(.top, isCompact ? 12 : 15)
                .padding(.bottom, isCompact ? 10 : 12)

            separator
            textBody
            separator
            footer
                .padding(.horizontal, isCompact ? 14 : 18)
                .padding(.vertical, isCompact ? 8 : 10)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.10), Color.platformControlBackground.opacity(0.34), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: cardCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(accentColor.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: accentColor.opacity(0.08), radius: 22, x: 0, y: 12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            providerMark
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        providerName
                        Spacer(minLength: 8)
                        responseStatusGroup
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        providerName
                        responseStatusGroup
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        metadataPill(config.model, icon: "cpu", emphasized: true)
                        metadataPill(endpointDisplay, icon: endpointIcon, prefix: endpointPrefix)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        metadataPill(config.model, icon: "cpu", emphasized: true)
                        metadataPill(endpointDisplay, icon: endpointIcon, prefix: endpointPrefix)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var providerName: some View {
        Text(config.displayName)
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .lineLimit(1)
    }

    private var responseStatusGroup: some View {
        HStack(spacing: 6) {
            httpStatusBadge
            statusDot
        }
        .fixedSize()
    }

    private var endpointDisplay: String {
        if config.kind.isCLI {
            let cmd  = config.cliCommand ?? ""
            let args = config.cliArgs ?? ""
            return [cmd, args].filter { !$0.isEmpty }.joined(separator: " ")
        }
        if config.kind.isAppleFM {
            return "端侧推理 · 不走网络"
        }
        let base = config.baseURL
        guard let comps = URLComponents(string: base),
              let host = comps.host else { return base }
        let path = comps.path.isEmpty ? "" : comps.path
        return host + path
    }

    /// 端点 pill 的图标 / 前缀:CLI 是本机命令,Apple 本地模型是端侧推理,其余走 HTTP。
    private var endpointIcon: String {
        if config.kind.isCLI { return "terminal" }
        if config.kind.isAppleFM { return "apple.logo" }
        return "network"
    }

    private var endpointPrefix: String {
        if config.kind.isCLI { return "EXEC" }
        if config.kind.isAppleFM { return "本地" }
        return "POST"
    }

    @ViewBuilder
    private var httpStatusBadge: some View {
        switch state.phase {
        case .finished:
            httpBadge(code: 200, text: "OK", color: .green)
        case .failed(let msg):
            if let code = extractHTTPStatus(msg) {
                httpBadge(code: code, text: code < 500 ? "Client Error" : "Server Error",
                          color: code < 500 ? .orange : .red)
            } else {
                httpBadge(code: nil, text: "Error", color: .red)
            }
        case .streaming:
            phaseLabel
        case .idle:
            EmptyView()
        }
    }

    private func httpBadge(code: Int?, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            if let code {
                Text("\(code)")
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
        .overlay { Capsule().strokeBorder(color.opacity(0.20), lineWidth: 1) }
    }

    private func extractHTTPStatus(_ msg: String) -> Int? {
        let pattern = #"HTTP (\d{3})"#
        guard let range = msg.range(of: pattern, options: .regularExpression) else { return nil }
        let sub = String(msg[range])
        return sub.components(separatedBy: " ").compactMap(Int.init).first
    }

    private var providerMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accentColor.opacity(0.92), accentColor.opacity(0.46)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: providerSymbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 40, height: 40)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: accentColor.opacity(0.18), radius: 12, x: 0, y: 6)
    }

    @ViewBuilder
    private var statusDot: some View {
        if case .streaming = state.phase {
            // 用系统 ProgressView 替代之前的 .repeatForever 自定义脉冲动画。
            // 之前的方案在 Council 模式下多列同时跑 → 后台 macOS 仍在 tick 动画 → 长时间占 CPU 卡死。
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
                .id(phaseKey)
        } else {
            ZStack {
                Circle()
                    .fill(phaseColor.opacity(0.14))
                Circle()
                    .fill(phaseColor)
                    .frame(width: 8, height: 8)
            }
                .frame(width: 18, height: 18)
                .id(phaseKey)
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch state.phase {
        case .streaming:
            badge("生成中", color: accentColor)
        case .finished:
            badge("完成", color: .green)
        case .failed:
            badge("失败", color: .red)
        case .idle:
            EmptyView()
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
        }
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.11), in: Capsule())
            .foregroundStyle(color)
            .overlay {
                Capsule()
                    .strokeBorder(color.opacity(0.18), lineWidth: 1)
            }
    }

    private func metadataPill(
        _ text: String,
        icon: String,
        prefix: String? = nil,
        emphasized: Bool = false
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            if let prefix {
                Text(prefix)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(accentColor)
            }
            Text(text)
                .font(.system(.caption2, design: .monospaced).weight(emphasized ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Color.primary.opacity(emphasized ? 0.62 : 0.46))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(emphasized ? 0.09 : 0.07), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: - Body

    private var textBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    toolEventsBlock
                    if !state.reasoning.isEmpty {
                        ReasoningDisclosure(reasoning: state.reasoning, streaming: isStreamingPhase, tint: accentColor)
                    }
                    bodyContent
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(isCompact ? 14 : 18)
            }
            .background(
                ZStack {
                    Color.platformTextBackground.opacity(0.26)
                    LinearGradient(
                        colors: [accentColor.opacity(0.035), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            )
            // minHeight 只为空态/短内容撑住列卡高度;内容够长时必然超过最小值,
            // 传 nil 跳过约束,避免无谓的多列同步内容测高(见 minHeightSkipThreshold)。
            .frame(minHeight: bodyMinHeight)
            .onChange(of: state.text) { _, _ in scheduleScrollToBottom(proxy) }
            .onChange(of: state.events.count) { _, _ in scheduleScrollToBottom(proxy) }
        }
    }

    /// textBody 的最小高度:仅空态/短内容需要(空态、连接中、失败、短回答时列卡
    /// 不至于太矮);长内容直接返回 nil 不加约束。始终经同一个 `.frame` 修饰符传入
    /// (nil = 不约束),保证跨越阈值时 ScrollView 视图身份稳定、滚动位置不丢。
    private var bodyMinHeight: CGFloat? {
        state.charCount > minHeightSkipThreshold ? nil : (isCompact ? 220 : 280)
    }

    /// 节流自动滚底:首次变更后 ~120ms 内的连续 flush 合并为一次 scrollTo(尾沿取当前底部)。
    /// 仅 streaming 期间生效;把多列并发下的 scrollTo 频率从 N×20Hz 降到每列 ~8Hz。
    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy) {
        guard case .streaming = state.phase, !scrollPending else { return }
        scrollPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            scrollPending = false
            if case .streaming = state.phase { proxy.scrollTo("bottom") }
        }
    }

    @ViewBuilder
    private var toolEventsBlock: some View {
        if !state.toolSteps.isEmpty {
            // 有结构化步骤时优先渲染步骤树(替代平铺 chips)。
            AgentStepsView(steps: state.toolSteps)
        } else if !state.events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(state.events.enumerated()), id: \.offset) { _, line in
                    let color = line.hasPrefix("⚠") ? Color.orange : Color.blue
                    Label(line, systemImage: line.hasPrefix("⚠") ? "exclamationmark.triangle.fill" : "hammer.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(color.opacity(0.10), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(color.opacity(0.22), lineWidth: 1)
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch state.phase {
        case .idle:
            idleContent
        case .failed(let message):
            failedContent(message)
        case .streaming:
            if state.text.isEmpty {
                connectingContent
            } else {
                responseText
            }
        case .finished:
            responseText
        }
    }

    private var idleContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(accentColor.opacity(0.72))
                .frame(width: 58, height: 58)
                .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(spacing: 4) {
                Text("等待本轮发送")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Text("发送后会自动流式滚动到底部。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 230)
    }

    private var connectingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("正在建立连接...")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 230)
    }

    private func failedContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("请求失败", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.body)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
    }

    @ViewBuilder
    private var responseText: some View {
        if state.text.isEmpty {
            Text("...")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // streaming 期间走纯 Text,不让 cmark 在每个 chunk 上 O(N) 重解析
                MarkdownText(text: state.text, streaming: isStreamingPhase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 折叠态:限制行数 + 底部渐隐,提示「下面还有内容」。
                    .lineLimit(isCollapsed ? collapsedLineLimit : nil)
                    .mask(isCollapsed ? AnyView(collapseMask) : AnyView(Rectangle()))

                if canCollapse {
                    expandToggle
                }
            }
        }
    }

    /// 是否具备折叠能力:已完成且文本超过阈值(streaming 期间不折叠,避免影响自动滚动)。
    private var canCollapse: Bool {
        guard case .finished = state.phase else { return false }
        return state.charCount > collapseThreshold
    }

    /// 当前是否处于折叠态。
    private var isCollapsed: Bool {
        canCollapse && !expanded
    }

    /// 折叠态底部渐隐遮罩。
    private var collapseMask: some View {
        LinearGradient(
            colors: [.black, .black, .black.opacity(0.08)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                Text(expanded ? "收起" : "展开全部 (\(state.charCount) 字)")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(accentColor.opacity(0.10), in: Capsule())
            .overlay {
                Capsule().strokeBorder(accentColor.opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 2)
    }

    private var isStreamingPhase: Bool {
        if case .streaming = state.phase { return true }
        return false
    }

    // MARK: - Footer

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                footerMetrics
                Spacer()
                copyButton
            }
            WrappingHStack(horizontalSpacing: 8, verticalSpacing: 7) {
                footerMetrics
                copyButton
            }
        }
    }

    @ViewBuilder
    private var footerMetrics: some View {
        if let s = state.elapsedSeconds {
            footerPill(String(format: "%.1fs", s), icon: "clock")
        }
        if !state.text.isEmpty, case .finished = state.phase {
            footerPill("\(state.charCount) 字", icon: "text.alignleft")
        }
        if state.inputTokens > 0 || state.outputTokens > 0 {
            TokenCostPill(
                usage: TurnTokenUsage(input: state.inputTokens, output: state.outputTokens, cachedInput: state.cachedInputTokens),
                model: config.model, providerKind: config.kind
            )
        }
    }

    private var copyButton: some View {
        Button {
            Platform.copyText(state.text)
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeInOut(duration: 0.15)) { copied = false }
            }
        } label: {
            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(copied ? .green : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background((copied ? Color.green : Color.secondary).opacity(0.10), in: Capsule())
                .fixedSize()
        }
        .buttonStyle(.borderless)
        .disabled(state.text.isEmpty)
        .help("复制本列回答")
    }

    private func footerPill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08), in: Capsule())
            .fixedSize()
    }

    // MARK: - Colors

    private var accentColor: Color {
        config.kownTint
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentColor.opacity(0.95), accentColor.opacity(0.32)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var phaseColor: Color {
        switch state.phase {
        case .idle:      return .gray.opacity(0.4)
        case .streaming: return accentColor
        case .finished:  return .green
        case .failed:    return .red
        }
    }

    private var providerSymbol: String {
        config.kownSymbol
    }

    private var phaseKey: String {
        switch state.phase {
        case .idle: return "idle"
        case .streaming: return "streaming"
        case .finished: return "finished"
        case .failed: return "failed"
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}
