import SwiftUI

struct ResponseColumnView: View {
    let config: ProviderConfig
    @Bindable var state: ResponseState
    @State private var copied = false
    // 折叠/展开:超长「已完成」回答默认折叠,点按展开。
    // 仅作用于 finished 阶段的纯展示;streaming 期间不折叠,保证自动滚动正常。
    @State private var expanded = false

    /// 超过该字符数的已完成回答默认折叠。
    private let collapseThreshold = 1_400
    /// 折叠态最多显示的行数。
    private let collapsedLineLimit = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(accentGradient)
                .frame(height: 4)

            header
                .padding(.horizontal, 18)
                .padding(.top, 15)
                .padding(.bottom, 12)

            separator
            textBody
            separator
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.10), Color.platformControlBackground.opacity(0.34), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(accentColor.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: accentColor.opacity(0.08), radius: 22, x: 0, y: 12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            providerMark
            VStack(alignment: .leading, spacing: 6) {
                // Provider name + status
                HStack(spacing: 8) {
                    Text(config.displayName)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .lineLimit(1)
                    Spacer()
                    HStack(spacing: 6) {
                        httpStatusBadge
                        statusDot
                    }
                    .fixedSize()
                }
                HStack(spacing: 6) {
                    metadataPill(config.model, icon: "cpu", emphasized: true)
                    metadataPill(endpointDisplay, icon: config.kind.isCLI ? "terminal" : "network", prefix: config.kind.isCLI ? "EXEC" : "POST")
                }
            }
        }
    }

    private var endpointDisplay: String {
        if config.kind.isCLI {
            let cmd  = config.cliCommand ?? ""
            let args = config.cliArgs ?? ""
            return [cmd, args].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let base = config.baseURL
        guard let comps = URLComponents(string: base),
              let host = comps.host else { return base }
        let path = comps.path.isEmpty ? "" : comps.path
        return host + path
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
                    bodyContent
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(18)
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
            .frame(minHeight: 280)
            .onChange(of: state.text) { _, _ in
                guard case .streaming = state.phase else { return }
                proxy.scrollTo("bottom")
            }
            .onChange(of: state.events.count) { _, _ in
                guard case .streaming = state.phase else { return }
                proxy.scrollTo("bottom")
            }
        }
    }

    @ViewBuilder
    private var toolEventsBlock: some View {
        if !state.events.isEmpty {
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
        return state.text.count > collapseThreshold
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
                Text(expanded ? "收起" : "展开全部 (\(state.text.count) 字)")
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
        HStack(spacing: 12) {
            if let s = state.elapsedSeconds {
                footerPill(String(format: "%.1fs", s), icon: "clock")
            }
            if !state.text.isEmpty, case .finished = state.phase {
                footerPill("\(state.text.count) 字", icon: "text.alignleft")
            }
            Spacer()

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
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background((copied ? Color.green : Color.secondary).opacity(0.10), in: Capsule())
            }
            .buttonStyle(.borderless)
            .disabled(state.text.isEmpty)
            .help("复制本列回答")
        }
    }

    private func footerPill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    // MARK: - Colors

    private var accentColor: Color {
        switch config.kind {
        case .openAICompatible: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .anthropic:        return Color(red: 0.83, green: 0.38, blue: 0.18)
        case .gemini:           return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .cliCommand:       return Color(red: 0.55, green: 0.45, blue: 0.78)
        }
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
        switch config.kind {
        case .openAICompatible: return "sparkles"
        case .anthropic:        return "text.book.closed"
        case .gemini:           return "diamond.fill"
        case .cliCommand:       return "terminal"
        }
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
