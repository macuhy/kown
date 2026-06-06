import Foundation

extension AppViewModel {
    /// 对某一轮的各家回答做「共識 / 分歧」差异分析(opt-in,成本考量)。
    /// 收集该轮 panel 各家最终文本(带 provider 名)→ 交给小模型 `ConsensusAnalyzer` →
    /// 解析结果写回 `Turn.consensusAnalysis` 并落盘。结构参照 `suggestFollowUps`:
    /// 独立 state(`analyzingConsensusTurns` / `consensusErrors`),不触碰 follow-up state。
    func analyzeConsensus(turnID: UUID) {
        guard !analyzingConsensusTurns.contains(turnID) else { return }
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
        let turn = conversations[convIdx].turns[turnIdx]

        // 收集各家(按 panelOrder)非空回答,带 provider 展示名。
        var answers: [ConsensusAnalyzer.NamedAnswer] = []
        for key in turn.panelOrder {
            let text = (turn.responses[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let name = turn.providerSnapshot[key]?.displayName ?? "模型"
            answers.append(.init(name: name, text: text))
        }
        guard answers.count >= 2 else {
            consensusErrors[turnID] = "至少需要两家有效回答才能分析差异。"
            return
        }
        guard let cfg = chairProvider ?? providers.first(where: { $0.enabled && !$0.kind.isCLI }) else {
            consensusErrors[turnID] = "没有可用的 API provider:差异分析只能用带 API key 的 provider(CLI 不支持)。到配置里启用一个。"
            return
        }

        let question = turn.prompt
        analyzingConsensusTurns.insert(turnID)
        consensusErrors[turnID] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.analyzingConsensusTurns.remove(turnID) }
            let result = await ConsensusAnalyzer.analyze(
                question: question,
                answers: answers,
                chair: self.chairProvider,
                firstEnabled: cfg
            )
            guard let result else {
                self.consensusErrors[turnID] = "差异分析失败(\(cfg.displayName)):没拿到可用结果,稍后再试。"
                return
            }
            // 写回 turn(重新定位,期间会话/轮次可能已变化)。
            guard let cIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  let tIdx = self.conversations[cIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
            self.conversations[cIdx].turns[tIdx].consensusAnalysis = result
            self.conversations[cIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[cIdx])
        }
    }

    /// 某轮是否正在做差异分析(供 UI 显示 loading)。
    func isAnalyzingConsensus(turnID: UUID) -> Bool {
        analyzingConsensusTurns.contains(turnID)
    }
}
