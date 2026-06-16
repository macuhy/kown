import SwiftUI

/// 语音对话模式:免手操作的「听 → 想 → 说 → 听」连续循环。
/// 复用 SpeechRecognizer(STT)/ SpeechService(TTS)/ AppViewModel.send()。
/// AppViewModel 是 @Observable(无 Combine publisher),故循环用单条可取消的轮询 Task 驱动。
@MainActor
final class VoiceLoopController: ObservableObject {
    enum Phase: Equatable {
        case idle, listening, confirming, thinking, speaking, paused
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var transcript: String = ""
    @Published private(set) var replyText: String = ""
    @Published private(set) var pendingUtterance: String = ""
    @Published private(set) var confirmProgress: Double = 0
    @Published private(set) var confirmationNeedsManualSend = false

    // MARK: - 连续对话(duplex / barge-in)模式
    /// 连续模式开关(持久化):开启后每轮 TTS 朗读结束自动恢复聆听、跳过手动确认直接发送,
    /// 且朗读期间用 VAD 监听用户开口 → 一开口立刻打断朗读转入聆听(barge-in)。
    @Published var continuousMode: Bool = VoiceLoopController.loadContinuousMode() {
        didSet {
            VoiceLoopController.saveContinuousMode(continuousMode)
            // 朗读中途关掉连续模式 → 立刻停掉 barge-in VAD,不再监听麦克风。
            if !continuousMode { vad.stop() }
        }
    }
    /// 朗读期间是否检测到了用户开口(VAD 命中),用于 runLoop 决定播完后行为。
    private var bargedIn = false
    /// barge-in 用的 VAD,仅在 .speaking 阶段且开启连续模式时运行。
    private let vad = VoiceActivityDetector()
    private static let continuousModeKey = "kown.voice.continuousMode.v1"

    static func loadContinuousMode() -> Bool {
        UserDefaults.standard.bool(forKey: continuousModeKey)
    }
    static func saveContinuousMode(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: continuousModeKey)
    }

    private let viewModel: AppViewModel
    private var loopTask: Task<Void, Never>?
    private var isPaused = false
    private var discardCurrentUtterance = false
    private var discardCurrentAnswer = false
    private var confirmationAction: ConfirmationAction?
    private var confirmationManualHold = false
    /// 最近一次收到识别增量的时刻(用于静音判定)。
    private var lastHeard = Date()
    /// 静音多久就当一句话说完(秒)。
    private let silenceSeconds: TimeInterval = 1.8
    /// 识别完成后给用户短暂修正 / 重说的缓冲时间。
    private let confirmSeconds: TimeInterval = 1.4

    private enum ConfirmationAction: Equatable {
        case send, retry
    }

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - 生命周期

    func start() {
        guard loopTask == nil else { return }
        isPaused = false
        discardCurrentUtterance = false
        discardCurrentAnswer = false
        confirmationAction = nil
        confirmationManualHold = false
        transcript = ""
        pendingUtterance = ""
        confirmProgress = 0
        confirmationNeedsManualSend = false
        replyText = ""
        phase = .listening
        loopTask = Task { await self.runLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        vad.stop()
        SpeechRecognizer.shared.stop()
        SpeechService.shared.stop()
        pendingUtterance = ""
        confirmProgress = 0
        confirmationNeedsManualSend = false
        phase = .idle
    }

    func pause() {
        guard loopTask != nil else { return }
        isPaused = true
        if phase == .listening { discardCurrentUtterance = true }
        if phase == .confirming {
            confirmationAction = .retry
            confirmationManualHold = false
            pendingUtterance = ""
            confirmProgress = 0
            confirmationNeedsManualSend = false
        }
        vad.stop()
        SpeechRecognizer.shared.stop()
        SpeechService.shared.stop()
        phase = .paused
    }

    func resume() {
        guard loopTask != nil else { start(); return }
        isPaused = false
        if phase == .paused { phase = .listening }
    }

    func submitCurrentUtterance() {
        guard phase == .listening, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        SpeechRecognizer.shared.stop()
    }

    func retryListening() {
        discardCurrentUtterance = true
        confirmationAction = .retry
        confirmationManualHold = false
        pendingUtterance = ""
        transcript = ""
        confirmProgress = 0
        confirmationNeedsManualSend = false
        SpeechRecognizer.shared.stop()
    }

    func sendConfirmedUtterance() {
        confirmationAction = .send
    }

    func updatePendingUtterance(_ text: String) {
        if text != pendingUtterance {
            confirmationManualHold = true
            confirmProgress = 0
            confirmationNeedsManualSend = true
        }
        pendingUtterance = text
    }

    func skipSpeechAndContinueListening() {
        SpeechService.shared.stop()
        phase = .listening
    }

    func interruptSpeechAndListen() {
        isPaused = false
        bargedIn = true
        vad.stop()
        SpeechService.shared.stop()
        phase = .listening
    }

    func cancelCurrentAnswer() {
        discardCurrentAnswer = true
        viewModel.cancel()
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
            await waitIfPaused()
            if Task.isCancelled { break }

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
            // 连续模式:跳过手动确认,静音判定到一句话说完就直接发,体感更接近实时助手。
            let confirmed: String
            if continuousMode {
                confirmed = heard
            } else {
                guard let c = await confirmHeardText(heard), !c.isEmpty else {
                    await sleep(120)
                    continue
                }
                confirmed = c
            }

            // 2. 想(发送 + 等本轮跑完)
            transcript = confirmed
            phase = .thinking
            let before = viewModel.selectedConversation?.turns.count ?? 0
            viewModel.prompt = confirmed
            viewModel.send()
            await waitSendDone()
            if Task.isCancelled { break }
            if discardCurrentAnswer {
                discardCurrentAnswer = false
                await sleep(150)
                continue
            }

            let after = viewModel.selectedConversation?.turns.count ?? 0
            guard after > before,
                  let turn = viewModel.selectedConversation?.turns.last,
                  let reply = spokenReply(turn), !reply.isEmpty else {
                phase = .error("没有得到可朗读的回答")
                return
            }

            // 3. 说(朗读回答 + 等播完)
            replyText = reply
            await waitIfPaused()
            if Task.isCancelled { break }
            phase = .speaking
            bargedIn = false
            SpeechService.shared.speak(reply)
            // 连续模式:朗读期间起 VAD,用户一开口立刻打断转聆听(barge-in)。
            if continuousMode {
                startBargeInDetection()
            }
            await waitSpeakDone()
            vad.stop()
            // barge-in 命中时 interruptSpeechAndListen 已把 phase 置为 .listening,
            // 这里不需要额外处理,直接回到 1 即可无缝继续听。
            // 4. 回到 1 继续听
        }
    }

    /// 起 barge-in VAD:检测到用户开口就调 interruptSpeechAndListen 打断朗读。
    /// 仅当仍在朗读阶段时才生效(避免播完后误触发)。
    private func startBargeInDetection() {
        vad.start { [weak self] in
            guard let self else { return }
            // 命中时若已不在朗读(已自然播完 / 被暂停),忽略。
            guard self.phase == .speaking, self.continuousMode, !self.isPaused else { return }
            self.interruptSpeechAndListen()
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
            if discardCurrentUtterance {
                stt.stop()
                discardCurrentUtterance = false
                return ""
            }
            if let err = stt.lastError { stt.stop(); throw VoiceError(err) }
            if Date() > maxListen { stt.stop(); break }
            if !transcript.isEmpty, Date().timeIntervalSince(lastHeard) > silenceSeconds {
                stt.stop(); break
            }
            await sleep(120)
        }
        if discardCurrentUtterance {
            discardCurrentUtterance = false
            return ""
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirmHeardText(_ heard: String) async -> String? {
        pendingUtterance = heard
        confirmationAction = nil
        confirmationManualHold = false
        confirmationNeedsManualSend = false
        confirmProgress = 0
        phase = .confirming

        let deadline = Date().addingTimeInterval(confirmSeconds)
        while true {
            if Task.isCancelled { return nil }
            if isPaused {
                pendingUtterance = ""
                confirmProgress = 0
                return nil
            }
            if confirmationAction == .retry {
                confirmationAction = nil
                pendingUtterance = ""
                confirmProgress = 0
                confirmationNeedsManualSend = false
                return nil
            }
            if confirmationAction == .send { break }
            if confirmationManualHold {
                confirmProgress = 0
                await sleep(80)
                continue
            }
            if Date() >= deadline { break }
            confirmProgress = 1 - max(0, deadline.timeIntervalSinceNow / confirmSeconds)
            await sleep(50)
        }

        let text = pendingUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingUtterance = ""
        confirmProgress = 0
        confirmationAction = nil
        confirmationManualHold = false
        confirmationNeedsManualSend = false
        return text.isEmpty ? nil : text
    }

    private func waitIfPaused() async {
        while isPaused && !Task.isCancelled {
            phase = .paused
            await sleep(120)
        }
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
        case .structured, .translate: return firstResponse(turn)
        case .tournament:
            // 朗读冠军(最后一轮对决胜者)的回答;无冠军时退回第一份非空回答。
            if let champ = tournamentChampionKey(turn), let t = turn.responses[champ], !t.isEmpty { return t }
            return firstResponse(turn)
        }
    }

    /// 取冠军 providerID(最后一轮唯一对决的胜者);无则 nil。
    private func tournamentChampionKey(_ turn: Turn) -> String? {
        guard let last = (turn.tournamentRounds ?? []).max(by: { $0.index < $1.index }) else { return nil }
        return last.matches.last?.winnerProviderID
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
    /// 切到「实时双工(Beta)」全屏:进入前停掉经典轮询循环(共用麦克风,不能并存),退出后恢复。
    @State private var showRealtime = false

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _controller = StateObject(wrappedValue: VoiceLoopController(viewModel: viewModel))
    }

    private var turns: [Turn] { viewModel.selectedConversation?.turns ?? [] }

    var body: some View {
        if showRealtime {
            RealtimeVoiceView(viewModel: viewModel) {
                // 退出实时模式 → 回到经典语音循环。
                showRealtime = false
                controller.start()
            }
        } else {
            classicBody
        }
    }

    private var classicBody: some View {
        let mode = viewModel.currentMode
        return ZStack {
            LinearGradient(
                colors: [
                    mode.kownTint.opacity(0.14),
                    mode.kownSecondaryTint.opacity(0.07),
                    Color.platformWindowBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    // MARK: - 顶部状态

    private var statusHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 54, height: 54)
                    // 一次性进出过渡,**不再用 repeatForever**:后者在 macOS 窗口切到后台后仍持续 tick,
                    // 烧满一个核(同 ResponseColumnView.statusDot 既有修复)。活动态改由系统 ProgressView 表达。
                    .scaleEffect(animating ? 1.08 : 1.0)
                    .animation(.easeInOut(duration: 0.25), value: animating)
                if controller.phase == .confirming, !controller.confirmationNeedsManualSend {
                    Circle()
                        .trim(from: 0, to: max(0.02, controller.confirmProgress))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 58, height: 58)
                        .rotationEffect(.degrees(-90))
                }
                if case .thinking = controller.phase {
                    ProgressView().tint(tint)
                } else if animating {
                    // 聆听 / 回答中:系统圈圈表示活动(自动随窗口可见性暂停),叠一个状态图标。
                    ZStack {
                        ProgressView().tint(tint).controlSize(.small)
                        Image(systemName: orbIcon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(tint)
                            .offset(y: 13)
                    }
                } else {
                    Image(systemName: orbIcon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(statusTitle)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(tint)
                    Text(viewModel.currentMode.localizedDisplayName)
                        .font(.caption2.weight(.black))
                        .foregroundStyle(viewModel.currentMode.kownTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(viewModel.currentMode.kownTint.opacity(0.12), in: Capsule())
                }
                if controller.phase == .listening || controller.phase == .confirming {
                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle((controller.transcript.isEmpty && controller.pendingUtterance.isEmpty) ? .secondary : .primary)
                        .lineLimit(2)
                } else if case .error(let msg) = controller.phase {
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            realtimeEntry
            continuousToggle
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// 进入「实时双工(Beta)」:真双工低延迟语音(Gemini Live),与经典轮询模式并存。
    /// 点击前先停掉经典循环(释放麦克风/STT/TTS),再切到 RealtimeVoiceView。
    private var realtimeEntry: some View {
        Button {
            controller.stop()
            showRealtime = true
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                Text("实时")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.purple)
        }
        .buttonStyle(.plain)
        .help("实时双工(Beta):基于 Gemini Live 的真双工低延迟语音,说话时可随时打断")
        .accessibilityLabel("进入实时双工模式")
    }

    /// 连续对话(duplex)开关:开启后自动发送 + 朗读时可被打断,体感接近实时语音助手。
    private var continuousToggle: some View {
        Button {
            controller.continuousMode.toggle()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: controller.continuousMode ? "infinity.circle.fill" : "infinity.circle")
                    .font(.system(size: 20, weight: .semibold))
                Text("连续")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(controller.continuousMode ? viewModel.currentMode.kownTint : .secondary)
        }
        .buttonStyle(.plain)
        .help(controller.continuousMode
              ? "连续对话已开启:说完自动发送,朗读时一开口即打断"
              : "开启连续对话:说完自动发送,朗读时一开口即打断")
        .accessibilityLabel(controller.continuousMode ? "关闭连续对话" : "开启连续对话")
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
                    } else if controller.phase == .confirming, !controller.pendingUtterance.isEmpty {
                        userBubble(controller.pendingUtterance, pending: true)
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
                .background(viewModel.currentMode.kownTint.opacity(pending ? 0.10 : 0.18),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if pending {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(viewModel.currentMode.kownTint.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4]))
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
                    .strokeBorder((speech.speakingText == text ? tint : Color.primary).opacity(speech.speakingText == text ? 0.20 : 0.06), lineWidth: 1)
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
            ProgressView().controlSize(.small).tint(tint)
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
        case .structured, .translate: return firstResponse()
        case .tournament:
            let champ = (turn.tournamentRounds ?? []).max(by: { $0.index < $1.index })?.matches.last?.winnerProviderID
            if let champ, let t = turn.responses[champ], !t.isEmpty { return t }
            return firstResponse()
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if controller.phase == .confirming {
                confirmationCard
            }

            switch controller.phase {
            case .error:
                controlGroup {
                    voiceButton("重试", systemImage: "arrow.clockwise", prominent: true, tint: viewModel.currentMode.kownTint) {
                        controller.start()
                    }
                    voiceButton("退出", systemImage: "xmark", role: .cancel) { close() }
                }
            case .paused:
                controlGroup {
                    voiceButton("继续", systemImage: "play.fill", prominent: true, tint: viewModel.currentMode.kownTint) {
                        controller.resume()
                    }
                    voiceButton("退出", systemImage: "xmark", role: .cancel) { close() }
                }
            case .listening:
                controlGroup {
                    voiceButton("暂停", systemImage: "pause.fill") { controller.pause() }
                    if !controller.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        voiceButton("发送此句", systemImage: "paperplane.fill", prominent: true, tint: viewModel.currentMode.kownTint) {
                            controller.submitCurrentUtterance()
                        }
                        voiceButton("重听", systemImage: "mic.badge.xmark") { controller.retryListening() }
                    }
                    voiceButton("结束", systemImage: "xmark.circle.fill", role: .destructive, prominent: true, tint: .red) { close() }
                }
            case .confirming:
                controlGroup {
                    voiceButton("重说", systemImage: "arrow.counterclockwise") { controller.retryListening() }
                    voiceButton("发送", systemImage: "paperplane.fill", prominent: true, tint: viewModel.currentMode.kownTint) {
                        controller.sendConfirmedUtterance()
                    }
                    voiceButton("暂停", systemImage: "pause.fill") { controller.pause() }
                }
            case .thinking:
                controlGroup {
                    voiceButton("取消回答", systemImage: "stop.fill", role: .destructive, prominent: true, tint: .red) {
                        controller.cancelCurrentAnswer()
                    }
                    voiceButton("暂停后续", systemImage: "pause.fill") { controller.pause() }
                    voiceButton("退出", systemImage: "xmark") { close() }
                }
            case .speaking:
                controlGroup {
                    voiceButton("打断并听", systemImage: "mic.fill", prominent: true, tint: viewModel.currentMode.kownTint) {
                        controller.interruptSpeechAndListen()
                    }
                    voiceButton("跳过朗读", systemImage: "forward.fill") {
                        controller.skipSpeechAndContinueListening()
                    }
                    voiceButton("暂停", systemImage: "pause.fill") { controller.pause() }
                    voiceButton("结束", systemImage: "xmark.circle.fill", role: .destructive) { close() }
                }
            case .idle:
                controlGroup {
                    voiceButton("开始", systemImage: "play.fill", prominent: true, tint: viewModel.currentMode.kownTint) {
                        controller.start()
                    }
                    voiceButton("退出", systemImage: "xmark") { close() }
                }
            }
        }
    }

    private func controlGroup<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        WrappingHStack(horizontalSpacing: 10, verticalSpacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.and.magnifyingglass")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(viewModel.currentMode.kownTint)
                Text("确认识别内容")
                    .font(.caption.weight(.black))
                Spacer()
                Text(controller.confirmationNeedsManualSend ? "点发送继续" : "自动发送")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if controller.confirmationNeedsManualSend {
                Text("已暂停自动发送，修正后点击发送。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: controller.confirmProgress)
                    .tint(viewModel.currentMode.kownTint)
            }
            TextField(
                "修正后发送…",
                text: Binding(
                    get: { controller.pendingUtterance },
                    set: { controller.updatePendingUtterance($0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.platformControlBackground.opacity(0.48), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(viewModel.currentMode.kownTint.opacity(0.18), lineWidth: 1)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(viewModel.currentMode.kownTint.opacity(0.16), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func voiceButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        prominent: Bool = false,
        tint buttonTint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .padding(.vertical, 4)
        }

        if prominent {
            button
                .buttonStyle(.borderedProminent)
                .tint(buttonTint ?? viewModel.currentMode.kownTint)
        } else {
            button
                .buttonStyle(.bordered)
                .tint(buttonTint)
        }
    }

    private func close() {
        controller.stop()
        dismiss()
    }

    // MARK: - 状态映射

    private var animating: Bool {
        switch controller.phase {
        case .listening, .confirming, .speaking: return true
        default: return false
        }
    }

    private var statusTitle: String {
        switch controller.phase {
        case .idle:      return "准备中"
        case .listening: return "聆听中…"
        case .confirming:return "确认后发送"
        case .thinking:  return "思考中…"
        case .speaking:  return "回答中…"
        case .paused:    return "已暂停"
        case .error:     return "出错了"
        }
    }

    private var statusSubtitle: String {
        switch controller.phase {
        case .idle:
            return "点击开始进入语音循环"
        case .listening:
            if controller.transcript.isEmpty {
                return controller.continuousMode ? "请开始说话，静音后自动发送" : "请开始说话，静音后会进入确认"
            }
            return controller.transcript
        case .confirming:
            return controller.pendingUtterance.isEmpty ? "可重说，也可等待自动发送" : controller.pendingUtterance
        case .thinking:
            return "正在生成回答，可取消或暂停后续聆听"
        case .speaking:
            if speech.preparing { return "正在合成语音…" }
            if let note = speech.lastNote { return note }
            return controller.continuousMode ? "正在朗读回答，开口即可打断提问" : "正在朗读回答，可打断并继续提问"
        case .paused:
            return viewModel.isRunning ? "当前回答仍在生成，完成后等待继续" : "语音输入和朗读已暂停"
        case .error(let msg):
            return msg
        }
    }

    private var orbIcon: String {
        switch controller.phase {
        case .listening: return "mic.fill"
        case .confirming:return "checkmark.bubble.fill"
        case .speaking:  return "speaker.wave.3.fill"
        case .paused:    return "pause.fill"
        case .error:     return "exclamationmark.triangle.fill"
        default:         return "ellipsis"
        }
    }

    private var tint: Color {
        switch controller.phase {
        case .listening: return .red
        case .confirming:return viewModel.currentMode.kownTint
        case .thinking:  return viewModel.currentMode.kownSecondaryTint
        case .speaking:  return viewModel.currentMode.kownTint
        case .paused:    return .secondary
        case .error:     return .orange
        case .idle:      return viewModel.currentMode.kownTint
        }
    }
}
