import Foundation

/// 红队压测:opt-in「对某一轮再跑一遍」动作,完全模仿 `reviseTurn` / `factCheckTurn` 范式 ——
/// 独立 state、写回 Turn、落盘。指定一个「对手模型」(红队)猎杀答案的幻觉 / 薄弱论断 / 无出处数据,
/// 原模型(辩护方)逐条辩护或改口,结果写回 `Turn.redTeamResult`。
extension AppViewModel {

    func isRedTeaming(turnID: UUID) -> Bool { redTeamingTurns.contains(turnID) }

    /// 取一轮主答案归属的辩护方 provider:优先该轮 panel 首个有非空回答的 provider(用快照里的 id),
    /// 解析不到时回退 chair / 首个 enabled 非 CLI。CLI 不能辩护(无 API key)。
    private func defenderProvider(for turn: Turn) -> ProviderConfig? {
        for key in turn.panelOrder {
            let text = (turn.responses[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // 快照里的配置可能 model 与当前 providers 不同;优先用「当前仍存在的同 id provider」拿可用 key,
            // 否则直接用快照配置(其 id 对应的 Keychain key 仍在)。
            if let live = providers.first(where: { $0.id.uuidString == key && !$0.kind.isCLI }) {
                return live
            }
            if let snap = turn.providerSnapshot[key], !snap.kind.isCLI {
                return snap
            }
        }
        return chairProvider ?? providers.first(where: { $0.enabled && !$0.kind.isCLI })
    }

    /// 挑红队(对手模型):优先选一个**不同于辩护方**的 enabled 非 CLI provider(真对手);
    /// 没有别家时退回 chair,再退回辩护方自己(自我红队也比没有强)。
    private func redTeamProvider(excluding defender: ProviderConfig) -> ProviderConfig? {
        if let other = providers.first(where: { $0.enabled && !$0.kind.isCLI && $0.id != defender.id }) {
            return other
        }
        if let chair = chairProvider, !chair.kind.isCLI, chair.id != defender.id {
            return chair
        }
        return defender.kind.isCLI ? nil : defender
    }

    /// 对某轮主答案跑一轮红队压测,结果写回 `Turn.redTeamResult`。
    func redTeamTurn(turnID: UUID) {
        guard !redTeamingTurns.contains(turnID) else { return }
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
        let turn = conversations[convIdx].turns[turnIdx]
        let answer = primaryAnswer(for: turn)
        guard !answer.isEmpty else {
            redTeamErrors[turnID] = "这一轮还没有可压测的答案。"
            return
        }
        guard let defender = defenderProvider(for: turn), !defender.kind.isCLI else {
            redTeamErrors[turnID] = "没有可用的 API provider 作辩护方(CLI 不支持)。到配置里启用一个。"
            return
        }
        guard let red = redTeamProvider(excluding: defender), !red.kind.isCLI else {
            redTeamErrors[turnID] = "没有可用的对手模型(需要一个带 API key 的 provider)。"
            return
        }
        let question = turn.prompt
        redTeamingTurns.insert(turnID)
        redTeamErrors[turnID] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.redTeamingTurns.remove(turnID) }
            guard let result = await RedTeamService.attack(
                question: question, answer: answer, red: red, defender: defender
            ), !result.attacks.isEmpty else {
                self.redTeamErrors[turnID] = "红队压测没有产出可用结果(可能没找到可攻击的薄弱点)。"
                return
            }
            guard let cIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  let tIdx = self.conversations[cIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
            self.conversations[cIdx].turns[tIdx].redTeamResult = result
            self.conversations[cIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[cIdx])
        }
    }
}
