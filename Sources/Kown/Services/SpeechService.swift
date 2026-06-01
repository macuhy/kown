import Foundation
import AVFoundation

/// 回答朗读(TTS)协调器。单例,跨卡片共享:同一时间只读一段,点别处自动切换。
/// 引擎可选(设置 ▸ 朗读):Edge 神经语音(免 key)/ Azure(自带 key)/ 系统语音。
/// 网络引擎失败时自动回退系统语音,保证「朗读」永远可用。
@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechService()

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var synthTask: Task<Void, Never>?

    /// 当前正在朗读的文本(供卡片判断按钮显示「朗读」还是「停止」)。
    @Published private(set) var speakingText: String?
    /// 网络引擎正在合成(下载 mp3)中 — UI 可显示 loading。
    @Published private(set) var preparing: Bool = false
    /// 上次朗读的诊断信息:网络引擎失败回退系统语音时记下原因(设置页展示),成功则清空。
    @Published private(set) var lastNote: String?

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
        stopPlaybackOnly()

        let engine = TTSConfig.engine
        guard engine.isNetwork else {
            systemSpeak(trimmed, original: text)
            return
        }

        // 网络引擎:先把按钮切到「停止」,后台合成 mp3 再播放;失败回退系统语音。
        speakingText = text
        preparing = true
        lastNote = nil
        let voice = TTSConfig.voice(for: engine)
        let rate = TTSConfig.ratePercent
        synthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await Self.synthesize(engine: engine, text: trimmed, voice: voice, rate: rate)
                if Task.isCancelled || self.speakingText != text { return }
                self.preparing = false
                try self.playData(data, original: text)
                self.lastNote = nil   // 成功:神经语音生效
            } catch {
                self.preparing = false
                // 被用户切走 / 取消就别再回退
                if Task.isCancelled || self.speakingText != text { return }
                // 网络引擎失败 → 系统语音兜底(系统语音不认神经音色名,所以切音色听起来「没变化」)
                self.lastNote = "「\(engine.displayName)」朗读失败,已回退系统语音(系统语音不支持切换音色):\(error.localizedDescription)"
                self.systemSpeak(trimmed, original: text)
            }
        }
    }

    func stop() {
        synthTask?.cancel()
        synthTask = nil
        stopPlaybackOnly()
        speakingText = nil
        preparing = false
    }

    // MARK: - 内部

    private static func synthesize(engine: TTSEngineKind, text: String, voice: String, rate: Int) async throws -> Data {
        switch engine {
        case .siliconflow:
            guard let key = TTSConfig.siliconflowKey, !key.isEmpty else {
                throw TTSError.notConfigured("未配置硅基流动 Key(设置 ▸ 朗读)")
            }
            return try await SiliconFlowTTSEngine(
                baseURL: TTSConfig.siliconflowBaseURL, key: key, model: TTSConfig.siliconflowModel
            ).synthesize(text: text, voiceName: voice, ratePercent: rate)
        case .edge:
            return try await EdgeTTSEngine().synthesize(text: text, voice: voice, ratePercent: rate)
        case .azure:
            guard let key = TTSConfig.azureKey, !key.isEmpty else {
                throw TTSError.notConfigured("未配置 Azure Key(设置 ▸ 朗读)")
            }
            return try await AzureTTSEngine(region: TTSConfig.azureRegion, key: key)
                .synthesize(text: text, voice: voice, ratePercent: rate)
        case .system:
            throw TTSError.notConfigured("系统语音不走该路径")
        }
    }

    private func playData(_ data: Data, original: String) throws {
        activatePlaybackSession()
        let p = try AVAudioPlayer(data: data)
        p.delegate = self
        player = p
        speakingText = original
        p.play()
    }

    private func systemSpeak(_ trimmed: String, original: String) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        activatePlaybackSession()
        let u = AVSpeechUtterance(string: trimmed)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        synth.speak(u)
        speakingText = original
    }

    /// 停掉当前播放(合成器 + mp3 player),但不动 speakingText/synthTask。
    private func stopPlaybackOnly() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player?.stop()
        player = nil
    }

    private func activatePlaybackSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    // MARK: - delegates

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.speakingText = nil
        }
    }
}
