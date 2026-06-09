import Foundation
import Observation

/// 表盘聊天状态机:读配置 → 流式提问 → 收尾自动朗读。
@MainActor
@Observable
final class WatchChatModel {
    var config: WatchProviderConfig?
    var answer: String = ""
    var error: String?
    var isStreaming: Bool = false

    private let speaker = WatchSpeaker()
    private var task: Task<Void, Never>?

    init() {
        config = WatchConfigStore.load()
    }

    func reloadConfig() {
        config = WatchConfigStore.load()
    }

    var isSpeaking: Bool { speaker.isSpeaking }

    func ask(mode: WatchMode, prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isStreaming { task?.cancel(); isStreaming = false; return }
        guard let cfg = config else { error = "未配置模型"; return }

        answer = ""
        error = nil
        isStreaming = true
        speaker.stop()

        let client = WatchChatClient(config: cfg)
        task = Task { [weak self] in
            do {
                try await client.stream(system: mode.systemPrompt, user: trimmed) { [weak self] delta in
                    await self?.appendDelta(delta)
                }
                self?.finishStreaming()
            } catch {
                self?.failStreaming(error)
            }
        }
    }

    private func appendDelta(_ delta: String) {
        answer += delta
    }

    private func finishStreaming() {
        isStreaming = false
        // 收尾自动朗读完整回答。
        speaker.speak(answer)
    }

    private func failStreaming(_ error: Error) {
        isStreaming = false
        if !Task.isCancelled {
            self.error = error.localizedDescription
        }
    }

    func speakAnswer() {
        speaker.speak(answer)
    }

    func stopSpeaking() {
        speaker.stop()
    }
}
