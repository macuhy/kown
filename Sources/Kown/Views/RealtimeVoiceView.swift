import SwiftUI
import AVFoundation

/// 「实时双工(Beta)」编排器:把协议层(RealtimeVoiceSession)和音频管线
/// (RealtimeAudioPipeline)接成一条真双工通路 —— 麦克风持续上行、模型语音流式下行、
/// 服务端 VAD 判定插话即打断(barge-in),双向 transcription 实时上屏。
/// 会话结束时把双方字幕按轮次落成普通会话记录(Direct 模式)。
@MainActor
final class RealtimeVoiceController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case live
        case ended
        case failed(String)
    }

    /// 一轮「用户说 → 模型答」的字幕(结束时落成 Turn)。
    struct RealtimeRound: Identifiable, Equatable {
        let id = UUID()
        var user: String
        var model: String
    }

    @Published private(set) var phase: Phase = .idle
    /// 模型语音是否还在播(下行队列未清空)→「对方说话」指示。
    @Published private(set) var isModelSpeaking = false
    @Published private(set) var micMuted = false
    /// 当前未完结轮次的双向增量字幕。
    @Published private(set) var currentInput = ""
    @Published private(set) var currentOutput = ""
    /// 已完结的轮次(turnComplete / 打断时归档)。
    @Published private(set) var rounds: [RealtimeRound] = []
    /// 非致命提示条(goAway 预告 / 服务端错误帧 / 回声消除降级 / 重连中)。
    @Published var notice: String?
    /// 结束后落档的轮数(UI 提示「已保存 N 轮」)。
    @Published private(set) var archivedCount = 0

    private let viewModel: AppViewModel
    private var session: RealtimeVoiceSession?
    private var pipeline: RealtimeAudioPipeline?
    /// 本次会话用的 Gemini provider(落档时做 providerSnapshot)。
    private var activeProviderConfig: ProviderConfig?
    private var activeSystemInstruction = ""
    /// 断线自动重连一次的预算;setupComplete 后恢复为 1。
    private var reconnectBudget = 1
    /// 用户主动结束标记:close 引发的 .closed 事件不再当错误处理。
    private var userClosing = false
    private var archived = false
    /// 引擎配置变化(插拔耳机)重启管线的防抖。
    private var pipelineRestarting = false
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    #endif

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - 生命周期

    func start() {
        switch phase {
        case .idle, .failed: break
        default: return
        }
        // 1. 找第一个启用的 Gemini 配置 + API Key(复用现有 provider 体系)。
        let geminis = viewModel.providers.filter { $0.kind == .gemini && $0.enabled }
        guard let cfg = geminis.first(where: { KeychainStore.hasKey(id: $0.id) }) ?? geminis.first else {
            phase = .failed("需要先配置 Gemini:请在「设置 ▸ 模型」中添加并启用 Google Gemini,并填入 API Key。")
            return
        }
        guard let apiKey = try? KeychainStore.load(id: cfg.id) else {
            phase = .failed("Gemini「\(cfg.displayName)」未填 API Key,请在「设置 ▸ 模型」中补上。")
            return
        }
        activeProviderConfig = cfg
        activeSystemInstruction = composeSystemInstruction()
        phase = .connecting
        notice = nil
        userClosing = false
        archived = false
        archivedCount = 0
        reconnectBudget = 1

        // 2. 先要麦克风权限,拿到再连(避免连上了却没声可发)。
        // requestMicPermission 的回调已派发回主线程(见其实现),这里 assumeIsolated 取回 MainActor 隔离。
        RealtimeAudioPipeline.requestMicPermission { [weak self] granted in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.phase == .connecting else { return }   // 等权限期间被用户退出
                guard granted else {
                    self.phase = .failed("麦克风权限被拒绝:请在系统设置中允许 Kown 使用麦克风。")
                    return
                }
                self.openSocket(apiKey: apiKey)
            }
        }
    }

    /// 结束并落档(幂等)。视图消失兜底也走这里。
    func end() {
        guard phase != .ended else { return }
        userClosing = true
        session?.close()
        session = nil
        pipeline?.stop()
        pipeline = nil
        removeObservers()
        finalizeRound()
        archiveIfNeeded()
        isModelSpeaking = false
        phase = .ended
    }

    /// 失败状态下重试:重置后重新走 start()。
    func retry() {
        guard case .failed = phase else { return }
        cleanupTransport()
        rounds = []
        currentInput = ""
        currentOutput = ""
        phase = .idle
        start()
    }

    /// 视图消失兜底:还在跑就按「结束」处理(落档 + 释放 engine/socket/tap)。
    func shutdownIfNeeded() {
        switch phase {
        case .connecting, .live: end()
        case .idle, .ended: cleanupTransport()
        case .failed: cleanupTransport()
        }
    }

    func toggleMute() {
        guard phase == .live, let pipeline else { return }
        micMuted.toggle()
        pipeline.setMuted(micMuted)
        if micMuted {
            // 服务端 VAD 开启时的规范信号:告知音频流暂停;再次发音频自动重开。
            session?.sendAudioStreamEnd()
        }
    }

    // MARK: - 连接

    private func openSocket(apiKey: String) {
        let s = RealtimeVoiceSession()
        s.onEvent = { [weak self] event in self?.handle(event) }
        session = s
        s.connect(apiKey: apiKey,
                  model: RealtimeVoiceConfig.model,
                  voiceName: RealtimeVoiceConfig.voiceName,
                  systemInstruction: activeSystemInstruction,
                  customBaseURL: RealtimeVoiceConfig.wsBaseURL)
    }

    /// setupComplete 后才起音频(协议要求 setup 完成前不得发 realtimeInput)。
    private func startPipeline() {
        if pipeline == nil {
            let p = RealtimeAudioPipeline()
            p.onChunk = { [weak self] data in
                guard let self, self.phase == .live, !self.micMuted else { return }
                self.session?.sendAudioChunk(data)
            }
            p.onPlaybackDrained = { [weak self] in
                self?.isModelSpeaking = false
            }
            p.onConfigurationChange = { [weak self] in
                self?.restartPipelineAfterConfigChange()
            }
            pipeline = p
        }
        guard let pipeline else { return }
        do {
            try pipeline.start()
            if micMuted { pipeline.setMuted(true) }
            if !pipeline.echoCancellationActive {
                notice = "未能启用回声消除:外放时模型可能听到自己的声音,建议佩戴耳机。"
            }
            installObserversIfNeeded()
        } catch {
            failFatal("音频启动失败:\(error.localizedDescription)")
        }
    }

    /// 插拔耳机 / 切输出设备后引擎自动停 → 整链重启一次(tap 格式可能已变,必须重建)。
    private func restartPipelineAfterConfigChange() {
        guard phase == .live, let pipeline, !pipelineRestarting else { return }
        pipelineRestarting = true
        pipeline.stop()
        do {
            try pipeline.start()
            if micMuted { pipeline.setMuted(true) }
        } catch {
            failFatal("音频设备变化后恢复失败:\(error.localizedDescription)")
        }
        pipelineRestarting = false
    }

    // MARK: - 事件处理(协议层 → UI / 管线)

    private func handle(_ event: RealtimeVoiceEvent) {
        switch event {
        case .setupComplete:
            phase = .live
            reconnectBudget = 1     // 成功(重)连上,恢复一次重连额度
            if notice?.contains("重连") == true { notice = nil }
            startPipeline()

        case .audioChunk(let data):
            guard phase == .live else { return }
            isModelSpeaking = true
            pipeline?.enqueuePlayback(data)

        case .inputTranscript(let t):
            currentInput += t

        case .outputTranscript(let t):
            currentOutput += t

        case .interrupted:
            // 服务端 VAD 判定用户插话:立即停播清队列,当前轮就地归档。
            pipeline?.stopPlayback()
            isModelSpeaking = false
            finalizeRound()

        case .turnComplete:
            finalizeRound()

        case .generationComplete:
            break   // 音频还在播,以 onPlaybackDrained 为准

        case .goAway(let timeLeft):
            let left = timeLeft.map { "(剩余 \($0))" } ?? ""
            notice = "服务端预告即将断开\(left):实时会话时长有上限,结束后可重新进入。"

        case .serverError(let msg):
            // 显式错误帧必须呈现(「SSE 错误被吞成空响应」前科),原文已记 DebugLogStore。
            notice = "服务端错误:\(msg)"

        case .closed(let code, let reason):
            guard !userClosing else { return }
            isModelSpeaking = false
            if phase == .live || phase == .connecting {
                if reconnectBudget > 0, let cfg = activeProviderConfig,
                   let apiKey = try? KeychainStore.load(id: cfg.id) {
                    reconnectBudget -= 1
                    notice = "连接断开,正在自动重连…"
                    phase = .connecting
                    openSocket(apiKey: apiKey)
                } else {
                    let detail = (reason?.isEmpty == false) ? ":\(reason!)" : ""
                    failFatal("连接已断开(code \(code))\(detail)。原始信息见「设置 ▸ 调试日志」。")
                }
            }
        }
    }

    /// 致命失败:停掉一切、保住已有字幕(落档),进入 failed 态供重试。
    private func failFatal(_ message: String) {
        cleanupTransport()
        finalizeRound()
        archiveIfNeeded()
        phase = .failed(message)
    }

    private func cleanupTransport() {
        userClosing = true
        session?.close()
        session = nil
        pipeline?.stop()
        pipeline = nil
        removeObservers()
        isModelSpeaking = false
        userClosing = false
    }

    // MARK: - 轮次 / 落档

    private func finalizeRound() {
        let user = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = currentOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        currentInput = ""
        currentOutput = ""
        guard !user.isEmpty || !model.isEmpty else { return }
        rounds.append(RealtimeRound(user: user, model: model))
    }

    /// 把双方字幕按轮次落成一条普通 Direct 会话(复用 ConversationStore / providerSnapshot 体系)。
    private func archiveIfNeeded() {
        guard !archived, !rounds.isEmpty, let cfg = activeProviderConfig else { return }
        archived = true
        var snapshot = cfg
        snapshot.model = RealtimeVoiceConfig.model
        let pid = snapshot.id.uuidString
        let turns = rounds.map { round in
            Turn(prompt: round.user.isEmpty ? "(语音,未识别到文字)" : round.user,
                 systemPrompt: activeSystemInstruction,
                 responses: [pid: round.model],
                 providerSnapshot: [pid: snapshot],
                 panelOrder: [pid])
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        let conv = Conversation(title: "实时语音 \(fmt.string(from: Date()))",
                                mode: .direct,
                                turns: turns,
                                systemPrompt: activeSystemInstruction.isEmpty ? nil : activeSystemInstruction)
        viewModel.conversations.insert(conv, at: 0)
        viewModel.selectedConversationID = conv.id
        ConversationStore.saveImmediately(conv)
        archivedCount = turns.count
    }

    /// 系统提示 = Persona 前缀(含技能)+ 会话级覆盖(否则全局系统提示)。与 send() 同序。
    private func composeSystemInstruction() -> String {
        var parts: [String] = []
        let fx = viewModel.personaEffectsForSend()
        if !fx.systemPromptPrefix.isEmpty { parts.append(fx.systemPromptPrefix) }
        let convPrompt = viewModel.selectedConversation?.systemPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let global = viewModel.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !convPrompt.isEmpty {
            parts.append(convPrompt)
        } else if !global.isEmpty {
            parts.append(global)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 系统事件(来电中断等)

    private func installObserversIfNeeded() {
        #if os(iOS)
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in
                guard let self, self.phase == .live || self.phase == .connecting else { return }
                self.end()
                self.notice = "音频被系统中断(来电或其他 App 占用),实时会话已结束并保存。"
            }
        }
        #endif
    }

    private func removeObservers() {
        #if os(iOS)
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
            interruptionObserver = nil
        }
        #endif
    }
}

// MARK: - 视图

/// 实时双工(Beta)全屏界面:连接状态 + 实时双向字幕 + 静音 / 设置 / 结束。
/// 动画纪律:**禁 repeatForever**(CPU 卡死前科),全部用事件驱动的一次性过渡。
struct RealtimeVoiceView: View {
    let viewModel: AppViewModel
    /// 返回经典语音模式(由 VoiceConversationView 传入)。
    let onExit: () -> Void
    @StateObject private var controller: RealtimeVoiceController
    @State private var showSettings = false

    init(viewModel: AppViewModel, onExit: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onExit = onExit
        _controller = StateObject(wrappedValue: RealtimeVoiceController(viewModel: viewModel))
    }

    private var tint: Color { viewModel.currentMode.kownTint }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [tint.opacity(0.16), Color.purple.opacity(0.06), Color.platformWindowBackground],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if let notice = controller.notice {
                    noticeBar(notice)
                }
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                captions
                controls
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
        }
        .onAppear { controller.start() }
        .onDisappear { controller.shutdownIfNeeded() }
        .sheet(isPresented: $showSettings) {
            RealtimeVoiceSettingsSheet()
        }
    }

    // MARK: 顶部状态

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(orbTint.opacity(0.16))
                    .frame(width: 54, height: 54)
                    // 事件驱动的一次性缩放(随说话状态切换),不用 repeatForever。
                    .scaleEffect(controller.isModelSpeaking ? 1.10 : 1.0)
                    .animation(.easeInOut(duration: 0.25), value: controller.isModelSpeaking)
                if controller.phase == .connecting {
                    ProgressView().tint(orbTint)
                } else {
                    Image(systemName: orbIcon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(orbTint)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(statusTitle)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(orbTint)
                    Text("实时双工 Beta")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.12), in: Capsule())
                }
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                controller.notice = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: 实时字幕

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if controller.rounds.isEmpty, controller.currentInput.isEmpty,
                       controller.currentOutput.isEmpty {
                        emptyHint
                    }
                    ForEach(controller.rounds) { round in
                        if !round.user.isEmpty { userBubble(round.user) }
                        if !round.model.isEmpty { modelBubble(round.model) }
                    }
                    if !controller.currentInput.isEmpty {
                        userBubble(controller.currentInput, live: true)
                    }
                    if !controller.currentOutput.isEmpty {
                        modelBubble(controller.currentOutput, live: true)
                    }
                    Color.clear.frame(height: 1).id("realtimeBottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: controller.rounds.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: controller.currentInput) { _, _ in scrollToBottom(proxy) }
            .onChange(of: controller.currentOutput) { _, _ in scrollToBottom(proxy) }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(controller.phase == .connecting ? "正在建立实时连接…" : "直接开口说话即可")
                .font(.callout.weight(.semibold))
            Text("双向语音全程实时:模型说话时你可以随时插话打断。字幕为服务端实时转写,结束后自动保存为普通会话。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.platformControlBackground.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func userBubble(_ text: String, live: Bool = false) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(tint.opacity(live ? 0.10 : 0.18),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if live {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(tint.opacity(0.45),
                                          style: StrokeStyle(lineWidth: 1, dash: [4]))
                    }
                }
        }
    }

    private func modelBubble(_ text: String, live: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.platformControlBackground.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(live ? Color.purple.opacity(0.30) : Color.primary.opacity(0.06),
                                      lineWidth: 1)
                }
            Spacer(minLength: 40)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("realtimeBottom", anchor: .bottom)
        }
    }

    // MARK: 控制按钮

    @ViewBuilder
    private var controls: some View {
        WrappingHStack(horizontalSpacing: 10, verticalSpacing: 8) {
            switch controller.phase {
            case .idle, .connecting:
                actionButton("结束", systemImage: "xmark.circle.fill", role: .destructive,
                             prominent: true, tint: .red) { endAndExit() }
                actionButton("设置", systemImage: "gearshape") { showSettings = true }

            case .live:
                actionButton(controller.micMuted ? "取消静音" : "静音",
                             systemImage: controller.micMuted ? "mic.slash.fill" : "mic.fill",
                             prominent: controller.micMuted, tint: controller.micMuted ? .orange : nil) {
                    controller.toggleMute()
                }
                actionButton("设置", systemImage: "gearshape") { showSettings = true }
                actionButton("结束", systemImage: "xmark.circle.fill", role: .destructive,
                             prominent: true, tint: .red) { endAndExit() }

            case .ended:
                actionButton("返回", systemImage: "arrow.uturn.backward", prominent: true, tint: tint) {
                    onExit()
                }

            case .failed:
                actionButton("重试", systemImage: "arrow.clockwise", prominent: true, tint: tint) {
                    controller.retry()
                }
                actionButton("返回", systemImage: "arrow.uturn.backward") { onExit() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func endAndExit() {
        controller.end()
        onExit()
    }

    @ViewBuilder
    private func actionButton(
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
            button.buttonStyle(.borderedProminent).tint(buttonTint ?? tint)
        } else {
            button.buttonStyle(.bordered).tint(buttonTint)
        }
    }

    // MARK: 状态映射

    private var orbIcon: String {
        switch controller.phase {
        case .idle, .connecting: return "bolt.horizontal"
        case .live:
            if controller.isModelSpeaking { return "speaker.wave.3.fill" }
            return controller.micMuted ? "mic.slash.fill" : "mic.fill"
        case .ended:  return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var orbTint: Color {
        switch controller.phase {
        case .idle, .connecting: return tint
        case .live: return controller.isModelSpeaking ? .purple : .red
        case .ended: return .green
        case .failed: return .orange
        }
    }

    private var statusTitle: String {
        switch controller.phase {
        case .idle:       return "准备中"
        case .connecting: return "连接中…"
        case .live:
            if controller.isModelSpeaking { return "对方说话…" }
            return controller.micMuted ? "已静音" : "聆听中…"
        case .ended:      return "已结束"
        case .failed:     return "出错了"
        }
    }

    private var statusSubtitle: String {
        switch controller.phase {
        case .idle:
            return "正在准备实时通道"
        case .connecting:
            return "正在连接 Gemini Live(\(RealtimeVoiceConfig.model))"
        case .live:
            if controller.isModelSpeaking { return "开口即可随时打断" }
            return controller.micMuted ? "麦克风已静音,点「取消静音」继续" : "请说话,服务端自动判定断句"
        case .ended:
            return controller.archivedCount > 0
                ? "已把 \(controller.archivedCount) 轮对话保存为普通会话"
                : "本次没有产生可保存的对话"
        case .failed(let msg):
            return msg
        }
    }
}

// MARK: - 设置(模型 / 音色 / 中转地址)

/// 实时双工的可调项。Live 模型是 preview 名、迭代快,全部做成可改默认值:
/// 官方更名或走中转时,不用等发版就能自救。改动在下次进入实时模式时生效。
private struct RealtimeVoiceSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = RealtimeVoiceConfig.model
    @State private var voice = RealtimeVoiceConfig.voiceName
    @State private var wsBase = RealtimeVoiceConfig.wsBaseURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("实时双工设置")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Live 模型").font(.caption.weight(.semibold))
                    Spacer()
                    Menu("建议") {
                        ForEach(RealtimeVoiceConfig.suggestedModels, id: \.self) { m in
                            Button(m) { model = m }
                        }
                    }
                    .font(.caption)
                }
                TextField("gemini-3.1-flash-live-preview", text: $model)
                    .textFieldStyle(.roundedBorder)
                Text("需要支持 Live API(BidiGenerateContent)的原生音频对话模型。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("音色").font(.caption.weight(.semibold))
                    Spacer()
                    Menu("建议") {
                        ForEach(RealtimeVoiceConfig.suggestedVoices, id: \.self) { v in
                            Button(v) { voice = v }
                        }
                    }
                    .font(.caption)
                }
                TextField("Kore", text: $voice)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WebSocket 中转地址(可选)").font(.caption.weight(.semibold))
                TextField("留空 = 官方 wss://generativelanguage.googleapis.com", text: $wsBase)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Text("走中转的用户填中转域名(支持 https:// 或 wss:// 前缀);留空走官方。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text("改动将在下次进入实时模式时生效。")
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    RealtimeVoiceConfig.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    RealtimeVoiceConfig.voiceName = voice.trimmingCharacters(in: .whitespacesAndNewlines)
                    RealtimeVoiceConfig.wsBaseURL = wsBase.trimmingCharacters(in: .whitespacesAndNewlines)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 420)
        #endif
    }
}
