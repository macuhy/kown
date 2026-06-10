import Foundation
import Observation

/// 表盘聊天状态机:读配置 → 流式提问 → 收尾自动朗读。
@MainActor
@Observable
final class WatchChatModel {
    var answer: String = ""
    var error: String?
    var isStreaming: Bool = false
    /// 联网预搜索进行中(回答尚未开始流式),用于 UI 显示「联网搜索中…」。
    var isSearching: Bool = false
    /// 最近一次回答是否启用了联网,用于回答卡片展示来源状态。
    var usedWebSearch: Bool = false

    private let speaker = WatchSpeaker()
    private var task: Task<Void, Never>?

    var isSpeaking: Bool { speaker.isSpeaking }

    /// config 由 view 从 WatchConnectivityReceiver 传入(手机经 WCSession 推送过来的)。
    /// `webSearch` 为 true 且 config 含 Firecrawl 时,先联网搜索再回答。
    func ask(mode: WatchMode, prompt: String, config: WatchProviderConfig?, webSearch: Bool = false) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isStreaming || isSearching { task?.cancel(); isStreaming = false; isSearching = false; return }
        guard let cfg = config else { error = "未配置模型"; return }

        answer = ""
        error = nil
        speaker.stop()

        let wantSearch = webSearch && cfg.canWebSearch
        usedWebSearch = wantSearch
        isSearching = wantSearch
        isStreaming = !wantSearch

        let client = WatchChatClient(config: cfg)
        task = Task { [weak self] in
            // 先联网搜索(可选),命中拼成参考资料前缀;失败则降级为不联网继续回答。
            let userContent = wantSearch
                ? await Self.searchAndCompose(query: trimmed, config: cfg)
                : trimmed
            guard let self, !Task.isCancelled else { return }
            self.beginStreaming()
            do {
                try await client.stream(system: mode.systemPrompt, user: userContent) { [weak self] delta in
                    await self?.appendDelta(delta)
                }
                self.finishStreaming()
            } catch {
                self.failStreaming(error)
            }
        }
    }

    /// 联网搜索并把命中拼进 user 内容。失败 / 无命中时原样返回 query(降级)。
    private static func searchAndCompose(query: String, config: WatchProviderConfig) async -> String {
        guard let base = config.firecrawlBaseURL, let key = config.firecrawlKey else { return query }
        let hits = (try? await WatchWebSearch(baseURL: base, apiKey: key).search(query: query, limit: 3)) ?? []
        guard !hits.isEmpty else { return query }
        let block = hits.enumerated().map { i, h in
            "\(i + 1). \(h.title) — \(h.snippet)(\(h.url))"
        }.joined(separator: "\n")
        return "[联网资料]\n\(block)\n\n请优先依据以上资料回答,信息不足时说明。问题:\(query)"
    }

    private func beginStreaming() {
        isSearching = false
        isStreaming = true
    }

    private func appendDelta(_ delta: String) {
        answer += delta
    }

    private func finishStreaming() {
        isStreaming = false
        // 收尾自动朗读完整回答。
        speaker.speak(answer)
        // 把回答摘要同步给表盘复杂功能(accessoryRectangular 第二行)。
        WatchWidgetShared.updateAnswer(answer)
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
