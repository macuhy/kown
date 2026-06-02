import SwiftUI

/// 语音对话模式:免手操作的「听 → 想 → 说 → 听」连续循环。
/// 复用 SpeechRecognizer(STT)/ SpeechService(TTS)/ AppViewModel.send()。
/// AppViewModel 是 @Observable(无 Combine publisher),故循环用单条可取消的轮询 Task 驱动。
@MainActor
final class VoiceLoopController: ObservableObject {
    enum Phase: Equatable {
        case idle, listening, thinking, speaking
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var transcript: String = ""
    @Published private(set) var replyText: String = ""

    private let viewModel: AppViewModel
    private var loopTask: Task<Void, Never>?
    /// 最近一次收到识别增量的时刻(用于静音判定)。
    private var lastHeard = Date()
    /// 静音多久就当一句话说完(秒)。
    private let silenceSeconds: TimeInterval = 1.8

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - 生命周期

    func start() {
        guard loopTask == nil else { return }
        transcript = ""
        replyText = ""
        phase = .listening
        loopTask = Task { await self.runLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        SpeechRecognizer.shared.stop()
        SpeechService.shared.stop()
        phase = .idle
    }

    private func sleep(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    // MARK: - 主循环

    private func runLoop() async {
        defer { loopTask = nil }

        // 没有当前会话先建一个,否则 send() 会因找不到会话直接返回。
        if viewModel.selectedConversation == nil {
            viewModel.newConversation(mode: viewModel.currentMode)
        }

        while !Task.isCancelled {
            // 1. 听
            phase = .listening
            transcript = ""
            let heard: String
            do {
                heard = try await listenOnce()
            } catch {
                phase = .error((error as? VoiceError)?.message ?? "语音识别失败")
                return
            }
            if Task.isCancelled { break }
            guard !heard.isEmpty else { await sleep(300); continue }  // 没听清,重听

            // 2. 想(发送 + 等本轮跑完)
            transcript = heard
            phase = .thinking
            let before = viewModel.selectedConversation?.turns.count ?? 0
            viewModel.prompt = heard
            viewModel.send()
            await waitSendDone()
            if Task.isCancelled { break }

            let after = viewModel.selectedConversation?.turns.count ?? 0
            guard after > before,
                  let turn = viewModel.selectedConversation?.turns.last,
                  let reply = spokenReply(turn), !reply.isEmpty else {
                phase = .error("没有得到可朗读的回答")
                return
            }

            // 3. 说(朗读回答 + 等播完)
            replyText = reply
            phase = .speaking
            SpeechService.shared.speak(reply)
            await waitSpeakDone()
            // 4. 回到 1 继续听
        }
    }

    // MARK: - 各步等待(轮询 @Published / @Observable 状态)

    /// 起 STT,等到一句话说完(自动结束 / 静音 / 超时),返回识别文本。
    private func listenOnce() async throws -> String {
        let stt = SpeechRecognizer.shared
        stt.lastError = nil
        lastHeard = Date()
        stt.start { [weak self] text in
            guard let self else { return }
            self.transcript = text
            self.lastHeard = Date()
        }

        // 等录音真正开始(权限回调是异步的);被拒/失败则报错。
        let startDeadline = Date().addingTimeInterval(4)
        while !stt.isRecording {
            if let err = stt.lastError { throw VoiceError(err) }
            if Task.isCancelled { return "" }
            if Date() > startDeadline { return "" }   // 起不来,交给外层重试
            await sleep(80)
        }

        // 等说完:系统自动结束 / 静音超过阈值 / 30s 兜底。
        lastHeard = Date()
        let maxListen = Date().addingTimeInterval(30)
        while stt.isRecording {
            if Task.isCancelled { stt.stop(); return "" }
            if let err = stt.lastError { stt.stop(); throw VoiceError(err) }
            if Date() > maxListen { stt.stop(); break }
            if !transcript.isEmpty, Date().timeIntervalSince(lastHeard) > silenceSeconds {
                stt.stop(); break
            }
            await sleep(120)
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 等本轮发送跑完(isRunning 由 true 回 false)。
    private func waitSendDone() async {
        // send() 可能异步置 isRunning;先等它起来(最多 3s)。
        let upDeadline = Date().addingTimeInterval(3)
        while !viewModel.isRunning, Date() < upDeadline {
            if Task.isCancelled { return }
            await sleep(80)
        }
        let doneDeadline = Date().addingTimeInterval(180)
        while viewModel.isRunning {
            if Task.isCancelled { return }
            if Date() > doneDeadline { break }
            await sleep(150)
        }
    }

    /// 等朗读播完(speakingText 变 nil 且不在 preparing)。
    private func waitSpeakDone() async {
        let tts = SpeechService.shared
        let upDeadline = Date().addingTimeInterval(3)
        while tts.speakingText == nil, !tts.preparing, Date() < upDeadline {
            if Task.isCancelled { return }
            await sleep(80)
        }
        let maxSpeak = Date().addingTimeInterval(240)
        while tts.speakingText != nil || tts.preparing {
            if Task.isCancelled { return }
            if Date() > maxSpeak { break }
            await sleep(150)
        }
    }

    // MARK: - 取「主回答」朗读

    private func spokenReply(_ turn: Turn) -> String? {
        switch viewModel.currentMode {
        case .direct:  return firstResponse(turn)
        case .council: return nonEmpty(turn.chairSummary) ?? nonEmpty(turn.summaryText) ?? firstResponse(turn)
        case .compare: return nonEmpty(turn.chairSummary) ?? firstResponse(turn)
        case .debate:
            let lastRound = turn.debateRounds?.sorted { $0.index < $1.index }.last
            let lastRoundReply = lastRound?.responses.values.first { !$0.isEmpty }
            return nonEmpty(turn.chairSummary) ?? lastRoundReply ?? firstResponse(turn)
        }
    }

    private func firstResponse(_ turn: Turn) -> String? {
        for cfg in turn.orderedPanelConfigs {
            if let t = turn.responses[cfg.id.uuidString], !t.isEmpty { return t }
        }
        return turn.responses.values.first { !$0.isEmpty }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

/// 语音循环里的可读错误。
private struct VoiceError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 语音对话全屏界面:顶部紧凑状态 + 可滚动的对话历史(渲染 markdown)+ 结束按钮。
struct VoiceConversationView: View {
    let viewModel: AppViewModel
    @StateObject private var controller: VoiceLoopController
    @ObservedObject private var speech = SpeechService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pulse = false

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _controller = StateObject(wrappedValue: VoiceLoopController(viewModel: viewModel))
    }

    private var turns: [Turn] { viewModel.selectedConversation?.turns ?? [] }

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.12), Color.platformWindowBackground],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                statusHeader
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                transcriptScroll
                controls
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 600)
        #endif
        .onAppear { pulse = true; controller.start() }
        .onDisappear { controller.stop() }
    }

    // MARK: - 顶部状态

    private var statusHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 54, height: 54)
                    .scaleEffect(animating ? 1.12 : 0.9)
                    .animation(animating ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                               value: pulse)
                if case .thinking = controller.phase {
                    ProgressView().tint(tint)
                } else {
                    Image(systemName: orbIcon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(tint)
                if controller.phase == .listening {
                    Text(controller.transcript.isEmpty ? "请开始说话" : controller.transcript)
                        .font(.subheadline)
                        .foregroundStyle(controller.transcript.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                } else if case .error(let msg) = controller.phase {
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 对话历史(可滚动)

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(turns) { turn in
                        userBubble(turn.prompt)
                        let answer = displayAnswer(turn)
                        if !answer.isEmpty { assistantBubble(answer) }
                    }
                    if viewModel.isRunning {
                        if let lp = viewModel.liveTurnPrompt, !lp.isEmpty { userBubble(lp) }
                        thinkingBubble
                    } else if controller.phase == .listening, !controller.transcript.isEmpty {
                        userBubble(controller.transcript, pending: true)
                    }
                    Color.clear.frame(height: 1).id("voiceBottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: turns.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: controller.phase) { _, _ in scrollToBottom(proxy) }
            .onChange(of: controller.transcript) { _, _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.isRunning) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("voiceBottom", anchor: .bottom) }
    }

    private func userBubble(_ text: String, pending: Bool = false) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(pending ? 0.10 : 0.18),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if pending {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    }
                }
        }
    }

    private func assistantBubble(_ text: String) -> some View {
        HStack(alignment: .top) {
            Group {
                // 正在朗读这条 → karaoke 高亮(已读/未读);否则渲染 markdown。
                if speech.speakingText == text, let full = speech.spokenText {
                    karaokeText(full, progress: speech.spokenCharProgress)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarkdownText(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(Color.platformControlBackground.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
            Spacer(minLength: 40)
        }
    }

    /// 已读部分用正常色、未读部分降透明度,游标按 Character 计数切分。
    private func karaokeText(_ full: String, progress: Int) -> Text {
        let clamped = max(0, min(progress, full.count))
        let idx = full.index(full.startIndex, offsetBy: clamped)
        let read = String(full[..<idx])
        let rest = String(full[idx...])
        return Text(read).foregroundColor(.primary)
            + Text(rest).foregroundColor(.secondary.opacity(0.45))
    }

    private var thinkingBubble: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("思考中…").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 40)
        }
        .padding(14)
        .background(Color.platformControlBackground.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 该轮要展示 / 朗读的「主回答」(与 VoiceLoopController.spokenReply 一致)。
    private func displayAnswer(_ turn: Turn) -> String {
        func firstResponse() -> String {
            for cfg in turn.orderedPanelConfigs {
                if let t = turn.responses[cfg.id.uuidString], !t.isEmpty { return t }
            }
            return turn.responses.values.first { !$0.isEmpty } ?? ""
        }
        func nonEmpty(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        switch viewModel.currentMode {
        case .direct:  return firstResponse()
        case .council: return nonEmpty(turn.chairSummary) ?? nonEmpty(turn.summaryText) ?? firstResponse()
        case .compare: return nonEmpty(turn.chairSummary) ?? firstResponse()
        case .debate:
            let last = turn.debateRounds?.sorted { $0.index < $1.index }.last?.responses.values.first { !$0.isEmpty }
            return nonEmpty(turn.chairSummary) ?? last ?? firstResponse()
        }
    }

    @ViewBuilder
    private var controls: some View {
        if case .error = controller.phase {
            HStack(spacing: 12) {
                Button { controller.start() } label: {
                    Label("重试", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(role: .cancel) { close() } label: {
                    Label("退出", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button(role: .destructive) { close() } label: {
                Label("结束", systemImage: "xmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private func close() {
        controller.stop()
        dismiss()
    }

    // MARK: - 状态映射

    private var animating: Bool {
        switch controller.phase {
        case .listening, .speaking: return true
        default: return false
        }
    }

    private var statusTitle: String {
        switch controller.phase {
        case .idle:      return "准备中"
        case .listening: return "聆听中…"
        case .thinking:  return "思考中…"
        case .speaking:  return "回答中…"
        case .error:     return "出错了"
        }
    }

    private var orbIcon: String {
        switch controller.phase {
        case .listening: return "mic.fill"
        case .speaking:  return "speaker.wave.3.fill"
        case .error:     return "exclamationmark.triangle.fill"
        default:         return "ellipsis"
        }
    }

    private var tint: Color {
        switch controller.phase {
        case .listening: return .red
        case .thinking:  return .blue
        case .speaking:  return Color(red: 0.10, green: 0.62, blue: 0.55)
        case .error:     return .orange
        case .idle:      return .accentColor
        }
    }
}
