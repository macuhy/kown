import Foundation
import AVFoundation

/// 回答朗读(TTS)。单例,跨卡片共享一个合成器:同一时间只读一段,点别处自动切换。
@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()

    private let synth = AVSpeechSynthesizer()
    /// 当前正在朗读的文本(供卡片判断按钮显示「朗读」还是「停止」)。
    @Published private(set) var speakingText: String?

    private override init() {
        super.init()
        synth.delegate = self
    }

    /// 朗读 / 停止切换:正在读这段就停;否则(停掉别处后)读这段。
    func toggle(_ text: String) {
        if speakingText == text { stop(); return }
        speak(text)
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let u = AVSpeechUtterance(string: trimmed)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        synth.speak(u)
        speakingText = text
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speakingText = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil }
    }
}
