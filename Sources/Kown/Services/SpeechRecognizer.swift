import Foundation
import Speech
import AVFoundation

/// 语音听写(STT)。麦克风 + SFSpeechRecognizer(中文),边说边出文字。
///
/// **不能标 `@MainActor`**:Speech / TCC 权限 / 音频 tap 的回调都在后台线程触发,
/// 若闭包被推断成 MainActor 隔离,Swift 6 运行时会在后台线程做执行器断言 → SIGTRAP 崩溃。
/// 所以本类不隔离到 MainActor;`@Published` 的变更统一派发回主线程,音频 tap 只碰局部 request。
final class SpeechRecognizer: NSObject, ObservableObject, @unchecked Sendable {
    @MainActor static let shared = SpeechRecognizer()

    @Published private(set) var isRecording = false
    @Published var lastError: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        ?? SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onPartial: ((String) -> Void)?

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// 切换:正在录就停,否则申请权限后开始。
    func toggle(onPartial: @escaping (String) -> Void) {
        if isRecording { stop() } else { start(onPartial: onPartial) }
    }

    func start(onPartial: @escaping (String) -> Void) {
        self.onPartial = onPartial
        onMain { self.lastError = nil }
        // 权限回调在后台线程 → 全部切回主线程再动引擎 / 状态
        requestAuthorization { granted, message in
            DispatchQueue.main.async {
                guard granted else {
                    self.lastError = message ?? "麦克风 / 语音识别权限被拒绝"
                    return
                }
                do {
                    try self.beginRecording()
                    self.isRecording = true
                } catch {
                    self.lastError = "无法开始录音: \(error.localizedDescription)"
                    self.teardown()
                }
            }
        }
    }

    func stop() {
        onMain {
            if self.audioEngine.isRunning { self.audioEngine.stop() }
            // 无条件摘 tap:即使引擎没在跑(上次 start 抛错),tap 也可能还挂着。
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.request?.endAudio()
            self.task?.finish()
            self.teardown()
            self.isRecording = false
        }
    }

    // MARK: - 录音(在主线程调用)

    private func beginRecording() throws {
        task?.cancel()
        task = nil

        // 防御:无论之前是什么状态,先停引擎、摘掉可能残留的 tap。
        // installTap 在同一 bus 上重复安装会抛 NSException("nullptr == Tap()") → 整个 App 崩溃。
        // 上一次 audioEngine.start() 抛错时 tap 已装但 teardown() 不摘,下一次就会撞上这条路径。
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.request = req

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // macOS 上输入设备未就绪 / 没有麦克风时,format 可能是 0Hz、0 声道,
        // installTap 会抛 NSException("IsFormatSampleRateAndChannelCountValid") → 崩溃。提前拦掉。
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Kown.SpeechRecognizer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "音频输入设备不可用,请检查麦克风"])
        }
        // tap 在音频线程回调:只 append 局部 req(线程安全),不碰 self,避免隔离断言。
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.onMain { self.onPartial?(text) }
            }
            if error != nil || (result?.isFinal ?? false) {
                self.stop()
            }
        }
    }

    private func teardown() {
        request = nil
        task = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - 权限(回调在后台线程,闭包非隔离)

    private func requestAuthorization(_ completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                completion(false, "请在系统设置里允许 Kown 使用语音识别")
                return
            }
            Self.requestMic { granted in
                completion(granted, granted ? nil : "请在系统设置里允许 Kown 使用麦克风")
            }
        }
    }

    private static func requestMic(_ completion: @escaping (Bool) -> Void) {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { completion($0) }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { completion($0) }
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { completion($0) }
        default: completion(false)
        }
        #endif
    }
}
