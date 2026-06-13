#if os(macOS)
import Foundation

/// 实时屏幕副驾(macOS):把屏幕滚动缓冲当上下文,回答用户「刚那页讲了啥 / 总结我刚读的这段」。
///
/// 自成一条轻量问答链路(不走主发送管线、不建会话):直接挑一个可用模型 → 拼「屏幕内容 + 问题」
/// → 流式收答案,边收边回调给 UI。复用 `ScreenCopilotService.shared` 的 buffer 与 provider 挑选惯例。
extension AppViewModel {

    /// 屏幕副驾问答可用性:有已启用的非 CLI 模型即可(CLI 不便流式喂长上下文)。
    var screenCopilotCanAnswer: Bool {
        chairProvider != nil || providers.contains { $0.enabled && !$0.kind.isCLI }
    }

    /// 用当前屏幕缓冲回答一个问题。
    /// - onDelta: 每收到一段文本就回调(累计全文由调用方拼)。
    /// - 返回:nil = 成功;非 nil = 错误文案(给 UI 展示)。
    @discardableResult
    func answerFromScreen(question: String, onDelta: @escaping (String) -> Void) async -> String? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let context = ScreenCopilotService.shared.contextSnapshot() else {
            return "屏幕缓冲还是空的——先开启「看屏幕」,在屏幕上停留几秒让它读到内容再问。"
        }
        guard let provider = screenCopilotProvider() else {
            return "没有可用的模型,请先在设置里启用一个云端模型(CLI 模型不支持)。"
        }

        let userPrompt = """
        下面【屏幕内容】是用户屏幕上最近出现过的文字(由本机 OCR 抓取,按时间先后拼接,可能有识别错误、错乱或重复)。
        请把它当作用户「刚刚看过的东西」,据此回答用户的问题。若问题是「刚那页讲了啥 / 总结我刚读的这段」之类,
        就概括屏幕内容的要点;信息不足时如实说明,不要编造屏幕上没有的内容。用中文回答。

        【屏幕内容】
        \(context)

        【用户的问题】
        \(q.isEmpty ? "总结一下我刚才在屏幕上看的内容。" : q)
        """

        let key = (try? KeychainStore.load(id: provider.id)) ?? ""
        let client = ProviderRegistry.client(for: provider.kind)
        let options = ChatOptions(
            systemPrompt: "你是用户的屏幕助理,基于用户屏幕上出现过的文字简明作答。",
            temperature: 0.3,
            maxTokens: 1200
        )
        do {
            for try await chunk in client.stream(
                prompt: userPrompt, options: options, config: provider, apiKey: key
            ) {
                if case .text(let t) = chunk { onDelta(t) }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 挑屏幕副驾问答用的模型:chair 优先(非 CLI),否则第一个已启用非 CLI。
    private func screenCopilotProvider() -> ProviderConfig? {
        if let chair = chairProvider, !chair.kind.isCLI { return chair }
        return providers.first { $0.enabled && !$0.kind.isCLI }
    }
}
#endif
