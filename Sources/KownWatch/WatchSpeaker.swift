import Foundation
import AVFoundation

/// 表盘端文本朗读(TTS)。回答收尾后把全文读出来,满足「输出也语音播放」。
@MainActor
final class WatchSpeaker {
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 朗读前确保音频会话为播放态(watchOS 需要外接/AirPods 等输出)。
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let utterance = AVSpeechUtterance(string: trimmed)
        // 中文优先;含较多 ASCII 时让系统按内容自适应。
        utterance.voice = AVSpeechSynthesisVoice(language: preferredLanguage(for: trimmed))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    var isSpeaking: Bool { synth.isSpeaking }

    private func preferredLanguage(for text: String) -> String {
        let hasCJK = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return hasCJK ? "zh-CN" : "en-US"
    }
}
