import Foundation
import Speech
import AVFoundation

/// 语音听写(STT)。麦克风 + SFSpeechRecognizer(中文),边说边出文字。
/// 与 SpeechService(朗读)分开:朗读用 playback session,听写用 record session,互斥使用。
@MainActor
final class SpeechRecognizer: NSObject, ObservableObject {
    static let shared = SpeechRecognizer()

    @Published private(set) var isRecording = false
    @Published var lastError: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        ?? SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 每次部分识别结果回调(传完整的当前转写文本)。
    private var onPartial: ((String) -> Void)?

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    /// 切换:正在录就停,否则申请权限后开始。
    func toggle(onPartial: @escaping (String) -> Void) {
        if isRecording { stop() } else { start(onPartial: onPartial) }
    }

    func start(onPartial: @escaping (String) -> Void) {
        lastError = nil
        self.onPartial = onPartial
        requestAuthorization { [weak self] granted, message in
            Task { @MainActor in
                guard let self else { return }
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
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        teardown()
        isRecording = false
    }

    // MARK: - 内部

    private func beginRecording() throws {
        // 收尾上一段(若有)
        task?.cancel()
        task = nil

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self.onPartial?(text) }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in
                    if self.isRecording { self.stop() }
                }
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

    /// 申请语音识别 + 麦克风权限(都通过才回调 granted=true)。
    private func requestAuthorization(_ completion: @escaping @Sendable (Bool, String?) -> Void) {
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

    private static func requestMic(_ completion: @escaping @Sendable (Bool) -> Void) {
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
