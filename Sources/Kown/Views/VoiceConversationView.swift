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

/// 语音对话全屏界面:状态动效 + 实时识别 + 回答文本 + 结束按钮。
struct VoiceConversationView: View {
    let viewModel: AppViewModel
    @StateObject private var controller: VoiceLoopController
    @Environment(\.dismiss) private var dismiss
    @State private var pulse = false

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _controller = StateObject(wrappedValue: VoiceLoopController(viewModel: viewModel))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.18), Color.platformWindowBackground],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer(minLength: 12)
                Text(statusTitle)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(tint)
                orb
                detail
                Spacer(minLength: 12)
                controls
            }
            .padding(24)
            .frame(maxWidth: 560)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
        .onAppear { pulse = true; controller.start() }
        .onDisappear { controller.stop() }
    }

    // MARK: - 子视图

    private var orb: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: 180, height: 180)
                .scaleEffect(animating ? 1.12 : 0.92)
                .animation(animating ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                           value: pulse)
            Circle()
                .fill(tint.opacity(0.30))
                .frame(width: 120, height: 120)
            if case .thinking = controller.phase {
                ProgressView().controlSize(.large).tint(.white)
            } else {
                Image(systemName: orbIcon)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch controller.phase {
        case .error(let msg):
            Text(msg)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        case .speaking:
            ScrollView {
                Text(controller.replyText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
        default:
            Text(controller.transcript.isEmpty ? placeholder : controller.transcript)
                .font(.title3)
                .foregroundStyle(controller.transcript.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .frame(minHeight: 60)
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

    private var placeholder: String {
        switch controller.phase {
        case .listening: return "请开始说话"
        case .thinking:  return "正在生成回答"
        default:         return ""
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
