import Foundation

/// 接力流水线(Mixture-of-Agents):Direct 模式的 opt-in 子动作,完全模仿 `reviseTurn` 范式 ——
/// 独立 state、写回 Turn、落盘。把某轮已有答案当初稿,跨厂商串行「批判改写 → 润色定稿」,
/// 结果写回 `Turn.relayResult`。不新增 ConversationMode(作为答卡下方的子动作出现)。
extension AppViewModel {

    func isRelaying(turnID: UUID) -> Bool { relayingTurns.contains(turnID) }

    /// 对某轮跑一条三段接力流水线(起草 → 批判改写 → 润色定稿),结果写回 `Turn.relayResult`。
    func relayTurn(turnID: UUID) {
        guard !relayingTurns.contains(turnID) else { return }
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
        let turn = conversations[convIdx].turns[turnIdx]

        // 至少要有两家 enabled 非 CLI provider 才谈得上「跨厂商接力」(只有一家也能跑,但退化为同家三遍)。
        let pool = providers.filter { $0.enabled && !$0.kind.isCLI }
        guard !pool.isEmpty else {
            relayErrors[turnID] = "没有可用的 API provider:接力流水线需要带 API key 的 provider(CLI 不支持)。"
            return
        }

        let question = turn.prompt
        // 已有主答案当初稿(省一次起草调用);没有则让第一站现起草。
        let existingDraft = primaryAnswer(for: turn)
        let stages = RelayService.defaultStages(existingDraft: existingDraft)
        let providersSnapshot = providers

        relayingTurns.insert(turnID)
        relayErrors[turnID] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.relayingTurns.remove(turnID) }
            guard let result = await RelayService.run(
                question: question, stages: stages, providers: providersSnapshot
            ), !result.stages.isEmpty else {
                self.relayErrors[turnID] = "接力流水线没有产出可用结果,稍后再试。"
                return
            }
            guard let cIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  let tIdx = self.conversations[cIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
            self.conversations[cIdx].turns[tIdx].relayResult = result
            self.conversations[cIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[cIdx])
        }
    }
}
