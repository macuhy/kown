import Foundation

/// 答案质量增强:自我反思修订 + 事实核查。两者都是 opt-in 的「对某一轮再跑一遍」动作,
/// 结构对齐 `analyzeConsensus` / `judgeCompare`:独立 state、写回 Turn、落盘。
extension AppViewModel {

    // MARK: - 取一轮的主答案(用于反思 / 核查的输入)

    /// 取一轮里最值得复核的「主答案」:Council/Debate 优先 chair 综合;否则取首个非空回答。
    func primaryAnswer(for turn: Turn) -> String {
        if let chair = turn.chairSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !chair.isEmpty {
            return chair
        }
        if let summary = turn.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        for key in turn.panelOrder {
            let t = (turn.responses[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return turn.responses.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    // MARK: - 自我反思修订

    func isRevising(turnID: UUID) -> Bool { revisingTurns.contains(turnID) }

    /// 对某轮主答案跑一轮「批评 + 修订」,结果写回 `Turn.selfRevision`。
    func reviseTurn(turnID: UUID) {
        guard !revisingTurns.contains(turnID) else { return }
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
        let turn = conversations[convIdx].turns[turnIdx]
        let answer = primaryAnswer(for: turn)
        guard !answer.isEmpty else {
            revisionErrors[turnID] = "这一轮还没有可修订的答案。"
            return
        }
        guard let cfg = chairProvider ?? providers.first(where: { $0.enabled && !$0.kind.isCLI }), !cfg.kind.isCLI else {
            revisionErrors[turnID] = "没有可用的 API provider(CLI 不支持)。到配置里启用一个。"
            return
        }
        let question = turn.prompt
        revisingTurns.insert(turnID)
        revisionErrors[turnID] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.revisingTurns.remove(turnID) }
            guard let result = await SelfReflectionService.reflect(question: question, answer: answer, provider: cfg) else {
                self.revisionErrors[turnID] = "自我反思失败(\(cfg.displayName)):稍后再试。"
                return
            }
            guard let cIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  let tIdx = self.conversations[cIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
            self.conversations[cIdx].turns[tIdx].selfRevision = SelfRevision(
                critique: result.critique, revised: result.revised, providerID: cfg.id.uuidString
            )
            self.conversations[cIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[cIdx])
        }
    }

    // MARK: - 事实核查

    func isFactChecking(turnID: UUID) -> Bool { factCheckingTurns.contains(turnID) }

    /// 对某轮主答案做事实核查(抽论断 → web 检索 → 逐条判定),结果写回 `Turn.factCheck`。
    func factCheckTurn(turnID: UUID) {
        guard !factCheckingTurns.contains(turnID) else { return }
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
        let turn = conversations[convIdx].turns[turnIdx]
        let answer = primaryAnswer(for: turn)
        guard !answer.isEmpty else {
            factCheckErrors[turnID] = "这一轮还没有可核查的答案。"
            return
        }
        guard canEnableWebSearch, let key = try? WebSearchKey.load(), !key.isEmpty else {
            factCheckErrors[turnID] = "事实核查需先在 设置 ▸ Web Search 配置 Firecrawl Key。"
            return
        }
        guard let cfg = chairProvider ?? providers.first(where: { $0.enabled && !$0.kind.isCLI }), !cfg.kind.isCLI else {
            factCheckErrors[turnID] = "没有可用的 API provider(CLI 不支持)。到配置里启用一个。"
            return
        }
        let question = turn.prompt
        let baseURL = webSearchConfig.baseURL
        factCheckingTurns.insert(turnID)
        factCheckErrors[turnID] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.factCheckingTurns.remove(turnID) }
            guard let result = await FactCheckService.check(
                question: question, answer: answer, provider: cfg,
                firecrawlBaseURL: baseURL, firecrawlKey: key
            ), !result.claims.isEmpty else {
                self.factCheckErrors[turnID] = "事实核查没有产出可用结果(可能没抽到可核查的论断)。"
                return
            }
            guard let cIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  let tIdx = self.conversations[cIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
            self.conversations[cIdx].turns[tIdx].factCheck = result
            self.conversations[cIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[cIdx])
        }
    }
}
