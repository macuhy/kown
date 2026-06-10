import SwiftUI

/// 表盘主界面:选模式 -> 语音输入(听写) -> 流式回答 -> 自动朗读。
struct WatchRootView: View {
    @State private var model = WatchChatModel()
    @StateObject private var conn = WatchConnectivityReceiver.shared
    @State private var mode: WatchMode = .direct
    @State private var input = ""
    @State private var webSearch = false
    @State private var contentVisible = false

    private let bottomAnchorID = "answer-bottom"

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 联网搜索或流式回答进行中 —— 按钮变停止、输入禁用。
    private var busy: Bool { model.isStreaming || model.isSearching }

    private var answerScrollBucket: Int {
        model.answer.count / 96
    }

    private var canUseWebSearch: Bool {
        conn.config?.canWebSearch == true
    }

    private var askButtonTitle: String {
        if model.isSearching { return "停止搜索" }
        if model.isStreaming { return "停止生成" }
        return "提问并朗读"
    }

    var body: some View {
        ZStack {
            ambientBackground

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        heroCard

                        if conn.config == nil {
                            notConfigured
                        } else {
                            modeSelector
                            if canUseWebSearch {
                                webSearchChip
                            }
                            promptCard

                            if let err = model.error {
                                errorCard(err)
                            }

                            if busy {
                                streamingCard
                            }

                            if !model.answer.isEmpty {
                                answerCard
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.horizontal, 7)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    .opacity(contentVisible ? 1 : 0)
                    .offset(y: contentVisible ? 0 : 8)
                }
                .scrollIndicators(.hidden)
                .onChange(of: answerScrollBucket) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: busy) { _, _ in
                    scrollToBottom(proxy)
                }
            }
        }
        .navigationTitle("Kown")
        .onOpenURL { url in
            // 表盘复杂功能点按(widgetURL kown://ask):主界面即提问界面,
            // 这里停掉朗读、清掉残留错误,让用户落地就能直接听写提问。
            guard url.scheme == "kown" else { return }
            model.stopSpeaking()
            model.error = nil
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                contentVisible = true
            }
        }
    }

    private var ambientBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.035, blue: 0.045),
                    Color(red: 0.055, green: 0.075, blue: 0.09),
                    Color(red: 0.015, green: 0.02, blue: 0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color(red: 0.08, green: 0.58, blue: 0.62).opacity(0.34))
                .frame(width: 104, height: 104)
                .blur(radius: 32)
                .offset(x: -58, y: -76)
            Circle()
                .fill(Color(red: 0.95, green: 0.46, blue: 0.18).opacity(0.20))
                .frame(width: 86, height: 86)
                .blur(radius: 28)
                .offset(x: 70, y: 96)
        }
        .ignoresSafeArea()
    }

    private var heroCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: conn.config == nil ? "applewatch.radiowaves.left.and.right" : "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(conn.config == nil ? .orange : .mint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(conn.config == nil ? "等待同步" : "随口问 Kown")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        )
    }

    private var statusText: String {
        guard let config = conn.config else {
            return "在 iPhone 上把 Provider 推送到手表"
        }
        if webSearch, canUseWebSearch {
            return "\(config.name) · \(config.model) · 联网"
        }
        return "\(config.name) · \(config.model)"
    }

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("还没收到模型配置")
                    .font(.headline)
            }

            Text("在 iPhone 打开 Kown，进入「设置 > Provider」，点击「同步到 Apple Watch」。配置会通过手表连接推送过来。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.orange.opacity(0.24), lineWidth: 1)
        )
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("回答模式")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 6) {
                ForEach(WatchMode.allCases) { item in
                    modeChip(item)
                }
            }
        }
    }

    private func modeChip(_ item: WatchMode) -> some View {
        let isSelected = item == mode

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                mode = item
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: modeIcon(item))
                    .font(.system(size: 12, weight: .bold))
                Text(item.label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.78))
            .background(
                Group {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.mint, Color(red: 0.88, green: 0.95, blue: 0.66)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    } else {
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.08))
                    }
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isSelected ? .white.opacity(0.16) : .white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy && !isSelected ? 0.62 : 1)
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "mic.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.mint)
                TextField("点按听写问题…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .disabled(busy)

                if !input.isEmpty && !busy {
                    Button {
                        input = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                model.ask(mode: mode, prompt: input, config: conn.config, webSearch: webSearch)
            } label: {
                HStack(spacing: 7) {
                    if busy {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text(askButtonTitle)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(.black)
                .background(
                    Capsule(style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.75, green: 1.0, blue: 0.82), Color(red: 0.42, green: 0.91, blue: 0.95)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                )
            }
            .buttonStyle(.plain)
            .opacity(!busy && trimmedInput.isEmpty ? 0.45 : 1)
            .disabled(!busy && trimmedInput.isEmpty)
        }
        .padding(11)
        .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var streamingCard: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.mint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.isSearching ? "正在联网搜索" : "正在组织回答")
                    .font(.caption.weight(.semibold))
                Text(model.isSearching ? "拿到资料后开始回答" : "完成后会自动朗读")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.mint.opacity(0.20), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.error = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: model.usedWebSearch ? "globe.asia.australia.fill" : "quote.bubble.fill")
                    .foregroundStyle(.mint)
                Text(answerTitle)
                    .font(.caption.weight(.bold))
                Spacer(minLength: 0)
                if model.usedWebSearch {
                    Text("资料")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.mint, in: Capsule(style: .continuous))
                } else {
                    Text("朗读")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Text(model.answer)
                .font(.body)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    model.speakAnswer()
                } label: {
                    Label("重读", systemImage: "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    model.stopSpeaking()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var webSearchChip: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                webSearch.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .bold))
                Text("联网搜索")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: webSearch ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .foregroundStyle(webSearch ? Color.black : Color.white.opacity(0.8))
            .frame(maxWidth: .infinity)
            .background(
                Group {
                    if webSearch {
                        Capsule(style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(red: 0.42, green: 0.91, blue: 0.95), Color.mint],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                    } else {
                        Capsule(style: .continuous).fill(.white.opacity(0.08))
                    }
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(.white.opacity(webSearch ? 0.16 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.62 : 1)
    }

    private var answerTitle: String {
        if model.isStreaming { return "实时回答" }
        if model.usedWebSearch { return "联网回答" }
        return "回答"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard busy || !model.answer.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    private func modeIcon(_ item: WatchMode) -> String {
        switch item {
        case .direct:
            return "bolt.fill"
        case .concise:
            return "text.line.first.and.arrowtriangle.forward"
        case .translate:
            return "character.book.closed.fill"
        }
    }
}
