#if os(macOS)
import Foundation
import Speech
import AVFoundation
import Combine

/// 会议实时双轨捕获总控(macOS 专属)。
///
/// 把三件事缝在一起:
///  1. **系统声音**(对方):`SystemAudioCaptureService`(ScreenCaptureKit 纯音频)→ 「对方」轨。
///  2. **麦克风**(我):`AVAudioEngine` inputNode tap → 「我」轨。
///  3. 两路各自一个 `StreamingTrackRecognizer` 流式识别,产出带时间戳的 `MeetingUtterance`。
///
/// 对 UI 暴露:`isCapturing`、`elapsed`(计时)、`liveUtterances`(已按时间合并的实时时间线,增量更新)。
/// 停止后,`renderedTranscript()` 给出带说话人 + 时间戳的纯文本,喂给 `MeetingNotesSummarizer`。
///
/// **互斥**:语音对话(F4)用的是 `SpeechRecognizer.shared` / `SpeechService.shared` 同一套麦克风+识别;
/// 会议捕获也要独占麦克风,二者不能同时跑。`start()` 前检查语音是否在用,在用就抛错让 UI 提示。
///
/// **并发**:音频回调 / 识别回调都在后台;本类标 `@MainActor` 只为 `@Published` 安全发布,
/// 真正的音频/识别工作交给非隔离的子服务,回调进来后 `Task { @MainActor in ... }` 收口。
@MainActor
final class MeetingCaptureService: ObservableObject {
    static let shared = MeetingCaptureService()

    enum CaptureState: Equatable {
        case idle
        case running
    }

    @Published private(set) var state: CaptureState = .idle
    /// 已合并、按时间排好序的实时时间线(双色字幕直接渲染它)。
    @Published private(set) var liveUtterances: [MeetingUtterance] = []
    /// 计时(秒),每 0.5s 更新一次。
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var lastError: String?
    /// 非致命状态提示(如本地语音识别自动回退到联网识别)。
    @Published var statusNotice: String?
    /// 系统声音那路是否真的在出声(用于 UI 提示「没捕到对方声音?」)。
    @Published private(set) var systemTrackActive = false

    var isCapturing: Bool { state == .running }

    // 子服务
    private let systemAudio = SystemAudioCaptureService()
    private let micEngine = AVAudioEngine()
    private var micTrack: StreamingTrackRecognizer?
    private var systemTrack: StreamingTrackRecognizer?

    // 两路各自维护「当前未定稿气泡 + 已定稿气泡」,合并成 liveUtterances。
    private var minePending: MeetingUtterance?
    private var theirsPending: MeetingUtterance?
    private var mineFinal: [MeetingUtterance] = []
    private var theirsFinal: [MeetingUtterance] = []

    private var sessionStart = Date()
    private var timer: Timer?

    private init() {}

    // MARK: - 互斥检查

    /// 语音对话 / 朗读是否正在占用麦克风+识别。会议捕获要和它互斥。
    var voiceBusy: Bool {
        SpeechRecognizer.shared.isRecording || SpeechService.shared.speakingText != nil
    }

    // MARK: - 启停

    enum StartError: LocalizedError {
        case voiceBusy
        case micUnavailable
        case recognizerUnavailable
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .voiceBusy:
                return "语音对话正在进行中,请先结束语音对话再开始会议捕获(两者都要用麦克风)。"
            case .micUnavailable:
                return "麦克风不可用,请检查输入设备和麦克风权限。"
            case .recognizerUnavailable:
                return "语音识别当前不可用(请检查系统语言支持或网络)。"
            case .underlying(let m):
                return m
            }
        }
    }

    /// 开始会议捕获:申请权限 → 起系统声音流 + 麦克风引擎 + 两路识别。
    /// 任一硬性前置(语音占用 / 识别不可用 / 麦克风权限被拒)失败时抛错并回滚,绝不半启动。
    func start() async throws {
        guard state == .idle else { return }
        guard !voiceBusy else { throw StartError.voiceBusy }

        // 语音 + 麦克风权限(系统声音权限在 SystemAudioCaptureService.start 里触发)。
        guard await requestSpeechAndMic() else { throw StartError.recognizerUnavailable }

        lastError = nil
        statusNotice = nil
        liveUtterances = []
        minePending = nil; theirsPending = nil
        mineFinal = []; theirsFinal = []
        systemTrackActive = false
        sessionStart = Date()
        elapsed = 0

        // 两路识别器
        let micTrack = StreamingTrackRecognizer(
            speaker: .me, sessionStart: sessionStart
        ) { [weak self] id, u, isFinal in
            Task { @MainActor [weak self] in self?.ingestMine(id: id, utterance: u, isFinal: isFinal) }
        } onNotice: { [weak self] message in
            Task { @MainActor [weak self] in self?.setTrackNotice("我", message) }
        } onError: { [weak self] message in
            Task { @MainActor [weak self] in self?.setTrackError("我", message) }
        }
        let systemTrack = StreamingTrackRecognizer(
            speaker: .them, sessionStart: sessionStart
        ) { [weak self] id, u, isFinal in
            Task { @MainActor [weak self] in self?.ingestTheirs(id: id, utterance: u, isFinal: isFinal) }
        } onNotice: { [weak self] message in
            Task { @MainActor [weak self] in self?.setTrackNotice("对方", message) }
        } onError: { [weak self] message in
            Task { @MainActor [weak self] in self?.setTrackError("对方", message) }
        }
        guard micTrack.isAvailable else { throw StartError.recognizerUnavailable }
        self.micTrack = micTrack
        self.systemTrack = systemTrack

        // 麦克风引擎(我):tap 回调在音频线程,把 track 实例传进去(不经 self)。
        do {
            try startMicEngine(feeding: micTrack)
        } catch {
            await rollback()
            throw StartError.micUnavailable
        }
        micTrack.start()
        systemTrack.start()

        // 系统声音(对方)—— 失败不致命:仍能单麦克风开会,给个提示。
        // 注意:audio 回调在后台队列,不能碰 MainActor 隔离的 self.systemTrack;
        // 把 track 实例捕成局部常量(StreamingTrackRecognizer 自带串行队列,线程安全)。
        let systemTrackRef = systemTrack
        do {
            try await systemAudio.start(
                onAudio: { [weak self] buffer in
                    systemTrackRef.append(buffer)
                    Task { @MainActor [weak self] in self?.systemTrackActive = true }
                },
                onStop: { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.systemTrackActive = false
                        self?.lastError = (error as? SystemAudioCaptureService.CaptureError)?.errorDescription
                            ?? "系统声音捕获中断:\(error.localizedDescription)"
                    }
                }
            )
        } catch {
            // 系统声音起不来(常见:屏幕录制权限被拒)。不回滚整个会议,只提示。
            lastError = (error as? SystemAudioCaptureService.CaptureError)?.errorDescription
                ?? "无法捕获系统声音:\(error.localizedDescription)"
        }

        state = .running
        startTimer()
    }

    /// 停止捕获:停定时器 → 停两路识别(收尾定稿)→ 停麦克风 → 停系统声音。
    func stop() async {
        guard state == .running else { return }
        stopTimer()
        micTrack?.stop()
        systemTrack?.stop()
        stopMicEngine()
        await systemAudio.stop()
        // 给识别一点收尾时间,把最后的 partial 定稿合进时间线。
        try? await Task.sleep(nanoseconds: 300_000_000)
        micTrack = nil
        systemTrack = nil
        state = .idle
        rebuildTimeline()
    }

    /// 停止后渲染成喂给 LLM / 导出的纯文本。
    func renderedTranscript() -> String {
        MeetingTranscriptMerger.renderTranscript(liveUtterances)
    }

    // MARK: - 摄入(在 MainActor 上,来自两路识别回调)

    private func ingestMine(id: UUID, utterance: MeetingUtterance, isFinal: Bool) {
        if isFinal {
            if !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mineFinal.append(utterance)
            }
            if minePending?.id == id { minePending = nil }
        } else {
            minePending = utterance
        }
        rebuildTimeline()
    }

    private func ingestTheirs(id: UUID, utterance: MeetingUtterance, isFinal: Bool) {
        if isFinal {
            if !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                theirsFinal.append(utterance)
            }
            if theirsPending?.id == id { theirsPending = nil }
        } else {
            theirsPending = utterance
        }
        rebuildTimeline()
    }

    private func setTrackNotice(_ track: String, _ message: String) {
        statusNotice = "\(track)轨:\(message)"
    }

    private func setTrackError(_ track: String, _ message: String) {
        lastError = "\(track)轨:\(message)"
    }

    /// 合并两路(已定稿 + 当前 pending)成实时时间线。纯函数 `MeetingTranscriptMerger.merge` 出活。
    private func rebuildTimeline() {
        var mine = mineFinal
        if let p = minePending { mine.append(p) }
        var theirs = theirsFinal
        if let p = theirsPending { theirs.append(p) }
        liveUtterances = MeetingTranscriptMerger.merge(mine: mine, theirs: theirs)
    }

    // MARK: - 麦克风引擎

    private func startMicEngine(feeding track: StreamingTrackRecognizer) throws {
        if micEngine.isRunning { micEngine.stop() }
        micEngine.inputNode.removeTap(onBus: 0)

        let input = micEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw StartError.micUnavailable
        }
        // tap 在音频线程:只把 buffer 转交识别器(其内部串行队列安全),不碰 MainActor 的 self。
        // 必须显式 @Sendable:本类是 @MainActor,不标的话闭包会继承 MainActor 隔离,
        // Swift 6 在 tap 回调队列(RealtimeMessenger.mServiceQueue)做执行器断言 → SIGTRAP 崩溃。
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            track.append(buffer)
        }
        micEngine.prepare()
        try micEngine.start()
    }

    private func stopMicEngine() {
        if micEngine.isRunning { micEngine.stop() }
        micEngine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - 计时

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .running else { return }
                self.elapsed = Date().timeIntervalSince(self.sessionStart)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 回滚 / 权限

    private func rollback() async {
        stopTimer()
        micTrack?.stop(); systemTrack?.stop()
        stopMicEngine()
        await systemAudio.stop()
        micTrack = nil; systemTrack = nil
        state = .idle
    }

    /// 申请语音识别 + 麦克风权限(都在后台回调,收口成 async)。
    /// 回调闭包必须显式 @Sendable:本类是 @MainActor,不标的话闭包继承 MainActor 隔离,
    /// TCC 在后台队列回调时执行器断言 → SIGTRAP 崩溃(和 installTap 同款坑)。
    private func requestSpeechAndMic() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { cont in
            if SFSpeechRecognizer.authorizationStatus() == .authorized {
                cont.resume(returning: true)
            } else {
                SFSpeechRecognizer.requestAuthorization { @Sendable in
                    cont.resume(returning: $0 == .authorized)
                }
            }
        }
        guard speechOK else { return false }

        return await withCheckedContinuation { cont in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: cont.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable in
                    cont.resume(returning: $0)
                }
            default: cont.resume(returning: false)
            }
        }
    }
}
#endif
