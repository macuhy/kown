import SwiftUI

struct ResponseColumnView: View {
    let config: ProviderConfig
    @Bindable var state: ResponseState
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(accentGradient)
                .frame(height: 3)

            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            separator
            textBody
            separator
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .background(
            Color.platformControlBackground.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accentColor.opacity(0.28), lineWidth: 1)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 11) {
            providerMark
            VStack(alignment: .leading, spacing: 4) {
                // Provider name + status
                HStack {
                    Text(config.displayName)
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    HStack(spacing: 6) {
                        httpStatusBadge
                        statusDot
                    }
                }
                // Model tag
                Text(config.model)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Endpoint URL or CLI command
                HStack(spacing: 4) {
                    Text(config.kind.isCLI ? "EXEC" : "POST")
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(.tertiary)
                    Text(endpointDisplay)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
        HStack(spacing: 3) {
            if let code {
                Text("\(code)")
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
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
                .fill(accentColor.opacity(0.12))
            Image(systemName: providerSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accentColor)
        }
        .frame(width: 38, height: 38)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accentColor.opacity(0.20), lineWidth: 1)
        }
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
            Circle()
                .fill(phaseColor)
                .frame(width: 8, height: 8)
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

    // MARK: - Body

    private var textBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    toolEventsBlock
                    bodyContent
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .background(Color.platformTextBackground.opacity(0.34))
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
                    Text(line)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(line.hasPrefix("⚠") ? Color.orange : Color.blue)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill((line.hasPrefix("⚠") ? Color.orange : Color.blue).opacity(0.10))
                        )
                        .overlay(
                            Capsule().strokeBorder((line.hasPrefix("⚠") ? Color.orange : Color.blue).opacity(0.22), lineWidth: 1)
                        )
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
            VStack(spacing: 4) {
                Text("等待本轮发送")
                    .font(.headline)
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
                .font(.callout)
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
            // streaming 期间走纯 Text,不让 cmark 在每个 chunk 上 O(N) 重解析
            MarkdownText(text: state.text, streaming: isStreamingPhase)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isStreamingPhase: Bool {
        if case .streaming = state.phase { return true }
        return false
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let s = state.elapsedSeconds {
                Label(String(format: "%.1fs", s), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !state.text.isEmpty, case .finished = state.phase {
                Text("·  \(state.text.count) 字")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
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
                    .font(.caption)
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(state.text.isEmpty)
            .help("复制当前回答")
        }
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
