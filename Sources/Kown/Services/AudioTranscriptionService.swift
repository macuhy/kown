import Foundation
import Speech

/// 音频文件的本地转写(m4a / wav / mp3 等)。用 `SFSpeechRecognizer` +
/// `SFSpeechURLRecognitionRequest`,尽量走 `requiresOnDeviceRecognition`(离线、隐私优先)。
///
/// 与 `SpeechRecognizer`(实时麦克风 STT)互不影响:这里只处理已存在的音频文件,
/// 不碰 `AVAudioEngine` / 麦克风。识别中文(zh-CN),设备不支持离线时自动退回联网识别。
///
/// `SFSpeechRecognizer` / 识别回调在后台线程触发,本类不隔离到 MainActor,做成 `enum` 静态方法。
enum AudioTranscriptionService {

    enum TranscriptionError: LocalizedError {
        case notAuthorized
        case recognizerUnavailable
        case emptyResult
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:        return "没有语音识别权限,请在系统设置里允许 Kown 使用语音识别。"
            case .recognizerUnavailable: return "当前设备的语音识别不可用(请检查网络或系统语言支持)。"
            case .emptyResult:          return "没有从这段音频里识别到文字。"
            case .underlying(let m):    return m
            }
        }
    }

    /// 请求语音识别授权(只需 Speech 权限,不需要麦克风)。已授权直接 true。
    static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// 转写一个音频文件 URL,返回整段文字。
    /// `onPartial` 在识别过程中回调阶段性结果(主线程),用于 UI 进度展示。
    static func transcribe(
        url: URL,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard await requestAuthorization() else { throw TranscriptionError.notAuthorized }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = onPartial != nil
        // 尽量离线:设备支持时省流量、保隐私。不支持就退回联网识别。
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // 识别 task 的回调会被多次调用(partial → final);用 continuation 只 resume 一次。
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let box = ResumeOnce(cont)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    box.fail(TranscriptionError.underlying(error.localizedDescription))
                    return
                }
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                if !result.isFinal {
                    if let onPartial {
                        let snapshot = text
                        DispatchQueue.main.async { onPartial(snapshot) }
                    }
                    return
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    box.fail(TranscriptionError.emptyResult)
                } else {
                    box.succeed(trimmed)
                }
            }
        }
    }

    /// 守住 continuation 只被 resume 一次(识别回调可能在 final 后再触发,或 error 与 final 竞态)。
    /// `recognitionTask` 回调在后台线程串行触发,这里再加锁兜底。
    private final class ResumeOnce: @unchecked Sendable {
        private var cont: CheckedContinuation<String, Error>?
        private let lock = NSLock()
        init(_ cont: CheckedContinuation<String, Error>) { self.cont = cont }
        func succeed(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            cont?.resume(returning: value); cont = nil
        }
        func fail(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            cont?.resume(throwing: error); cont = nil
        }
    }
}
