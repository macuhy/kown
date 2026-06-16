#if os(macOS)
import Foundation
import Speech
import AVFoundation

/// 单条音轨的流式中文识别(供会议双轨捕获用,macOS 专属)。
///
/// 把一路连续 PCM(麦克风 / 系统声音)喂给 `SFSpeechRecognizer` 的
/// `SFSpeechAudioBufferRecognitionRequest`,边喂边出 partial。
///
/// **滚动续接**:单个识别请求有时长上限(系统约 1 分钟,且 partial 文本越积越长),
/// 所以这里在一段「静默切句」或「到达滚动窗上限」后,把当前请求 `endAudio()` 收尾、
/// 立刻开一个新请求接着喂——保证长会议不断流。每段识别产出一条带时间戳的 `MeetingUtterance`。
///
/// **时间戳**:用「会议开始的绝对时刻」`sessionStart` 做基准,
/// 段开始/结束时刻相对它求差,得到相对秒。识别本身不给精确词时间戳,这里用喂音频的墙钟时间近似。
///
/// **并发**:`SFSpeechRecognizer` 回调在后台线程触发,本类不隔离到 MainActor;
/// 内部状态用串行队列 `serial` 保护,产物通过 `@Sendable` 闭包回调出去(也在 `serial` 上)。
final class StreamingTrackRecognizer: @unchecked Sendable {

    private let speaker: MeetingUtterance.Speaker
    private let sessionStart: Date
    /// 一段识别最长滚动窗(秒)。到点就收尾换新请求,防止单请求超时 / partial 过长。
    private let rollWindow: TimeInterval

    /// 产出/更新一条话语时回调(在内部串行队列上):
    /// - 中间态(partial):`isFinal == false`,UI 增量刷新这条气泡。
    /// - 终态:`isFinal == true`,这条定稿,下一句换新 id。
    private let onUtterance: @Sendable (_ id: UUID, _ utterance: MeetingUtterance, _ isFinal: Bool) -> Void
    /// 非致命提示:例如本地识别不可用时自动切到联网识别。
    private let onNotice: @Sendable (_ message: String) -> Void
    /// 识别链路持续失败时的可见错误提示。
    private let onError: @Sendable (_ message: String) -> Void

    private let recognizer: SFSpeechRecognizer?
    private let serial = DispatchQueue(label: "com.kown.meeting.track")

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var stopped = false

    // 当前段
    private var currentID = UUID()
    private var segmentStart: TimeInterval = 0
    private var segmentStartedAt: Date?
    private var lastText = ""
    private var didFallbackToServerRecognition = false
    private var lastErrorNoticeAt: Date?

    init(
        speaker: MeetingUtterance.Speaker,
        sessionStart: Date,
        rollWindow: TimeInterval = 45,
        onUtterance: @escaping @Sendable (_ id: UUID, _ utterance: MeetingUtterance, _ isFinal: Bool) -> Void,
        onNotice: @escaping @Sendable (_ message: String) -> Void = { _ in },
        onError: @escaping @Sendable (_ message: String) -> Void = { _ in }
    ) {
        self.speaker = speaker
        self.sessionStart = sessionStart
        self.rollWindow = rollWindow
        self.onUtterance = onUtterance
        self.onNotice = onNotice
        self.onError = onError
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    /// 开始这条轨道的识别(开第一个滚动请求)。
    func start() {
        serial.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.beginSegment()
        }
    }

    /// 喂一段 PCM(来自麦克风 tap 或系统声音回调)。可在任意后台线程调用。
    ///
    /// `AVAudioPCMBuffer` 非 Sendable,直接 `serial.async` 捕获会触发并发告警;
    /// 这里用 `nonisolated(unsafe)` 显式承诺:buffer 只在本队列单线程消费,不存在数据竞争。
    func append(_ buffer: AVAudioPCMBuffer) {
        nonisolated(unsafe) let buf = buffer
        serial.async { [weak self] in
            guard let self, !self.stopped else { return }
            // 到滚动窗上限:先收尾当前段、换新请求,再喂这块。
            if let startedAt = self.segmentStartedAt,
               Date().timeIntervalSince(startedAt) >= self.rollWindow {
                self.finishSegment(restart: true)
            }
            self.request?.append(buf)
        }
    }

    /// 停止整条轨道:收尾当前段(定稿),不再重启。
    func stop() {
        serial.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.finishSegment(restart: false)
        }
    }

    // MARK: - 段生命周期(全部在 serial 上)

    private func beginSegment() {
        guard !stopped, let recognizer, recognizer.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        let useOnDevice = recognizer.supportsOnDeviceRecognition && !didFallbackToServerRecognition
        if useOnDevice {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        currentID = UUID()
        segmentStart = Date().timeIntervalSince(sessionStart)
        segmentStartedAt = Date()
        lastText = ""

        let segID = currentID
        let segStart = segmentStart
        let segUsesOnDevice = useOnDevice
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            // 在回调线程先把需要的值抽成 Sendable 标量,再过队列(SFSpeechRecognitionResult 非 Sendable)。
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error.map(Self.describeRecognitionError)
            self.serial.async {
                // 回调可能晚于段切换:只处理「仍是当前段」的结果。
                guard segID == self.currentID else { return }
                if let text {
                    self.lastText = text
                    let end = Date().timeIntervalSince(self.sessionStart)
                    let u = MeetingUtterance(
                        id: segID, speaker: self.speaker, text: text,
                        start: segStart, end: max(end, segStart)
                    )
                    self.onUtterance(segID, u, isFinal)
                    if isFinal {
                        // 系统判定本段说完:定稿并自动续下一段(若没停)。
                        self.advanceAfterFinal()
                        return
                    }
                }
                if let errorMessage {
                    // 出错也定稿当前 partial 文本并续接,别让长会议因一次错误断流。
                    self.handleRecognitionError(errorMessage, segmentUsesOnDevice: segUsesOnDevice)
                }
            }
        }
    }

    /// 主动收尾当前段:`endAudio()` 让识别尽快给 final;若 `restart` 则立刻开下一段。
    private func finishSegment(restart: Bool) {
        guard request != nil || task != nil else {
            if restart && !stopped { beginSegment() }
            return
        }
        // 如果已有非空 partial,先以它定稿(回调里的 final 可能慢,这里主动补一条 final)。
        emitFinalForLastTextIfNeeded()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        // 让接下来的迟到回调不再命中本段。
        currentID = UUID()
        segmentStartedAt = nil
        lastText = ""
        if restart && !stopped { beginSegment() }
    }

    /// 识别给出 final(或出错)后:换新段继续(若没停)。这里不再补 final 文本(回调已发过)。
    private func advanceAfterFinal(restartDelay: TimeInterval = 0) {
        request?.endAudio()
        task = nil
        request = nil
        currentID = UUID()
        segmentStartedAt = nil
        lastText = ""
        guard !stopped else { return }
        if restartDelay > 0 {
            serial.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
                guard let self, !self.stopped, self.request == nil, self.task == nil else { return }
                self.beginSegment()
            }
        } else {
            beginSegment()
        }
    }

    private func handleRecognitionError(_ message: String, segmentUsesOnDevice: Bool) {
        emitFinalForLastTextIfNeeded()

        if segmentUsesOnDevice && !didFallbackToServerRecognition {
            didFallbackToServerRecognition = true
            onNotice("本地语音识别不可用,已自动切换为系统联网识别。")
            advanceAfterFinal()
            return
        }

        notifyErrorThrottled("语音识别暂时中断,正在自动重连:\(message)")
        advanceAfterFinal(restartDelay: 1.5)
    }

    private func emitFinalForLastTextIfNeeded() {
        guard !lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let end = Date().timeIntervalSince(sessionStart)
        let u = MeetingUtterance(
            id: currentID, speaker: speaker, text: lastText,
            start: segmentStart, end: max(end, segmentStart)
        )
        onUtterance(currentID, u, true)
    }

    private func notifyErrorThrottled(_ message: String) {
        let now = Date()
        if let last = lastErrorNoticeAt, now.timeIntervalSince(last) < 15 { return }
        lastErrorNoticeAt = now
        onError(message)
    }

    private static func describeRecognitionError(_ error: Error) -> String {
        let ns = error as NSError
        let detail = ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "\(ns.domain) code \(ns.code)"
        }
        return detail
    }
}
#endif
