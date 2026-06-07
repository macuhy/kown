import Foundation

/// 自动升级建议(建议式)的本地判定器:答完后扫一遍答案,启发式检测「低置信 / 回避」信号。
/// 纯本地、零网络、零额外模型调用 —— 命中就给一条 `EscalationSuggestion`,由 UI 非侵入提示
/// 「换更强模型 / 转 Council 重答」。默认仅建议,绝不自动重跑(见用户拍板:建议式)。
enum EscalationAdvisor {
    /// 示弱措辞(中英)。命中 ≥2 条,或命中 1 条且回答过短 → 视为低置信。
    private static let hedges: [String] = [
        "不确定", "不太确定", "无法确定", "难以确定", "不能确定", "我不确定",
        "可能不准确", "不能保证", "仅供参考", "建议咨询", "存在不确定", "不一定准确",
        "我无法保证", "可能有误",
        "i'm not sure", "im not sure", "not certain", "uncertain", "i cannot be sure",
        "i can't be sure", "may not be accurate", "i'm not certain"
    ]

    /// 明显回避 / 拒答的措辞。命中即建议升级。
    private static let refusals: [String] = [
        "无法回答", "不能回答", "我无法提供", "没有足够信息", "信息不足以",
        "i can't help", "i cannot help", "i'm unable to", "i am unable to", "i can't answer"
    ]

    /// 评估一条回答是否值得升级。返回 nil 表示不建议。
    /// 目前仅对单模型答案(Direct)做启发式;多模型分歧信号由 `ConsensusAnalyzer`(opt-in)另行承载。
    static func evaluate(answer: String) -> EscalationSuggestion? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        if refusals.contains(where: { lower.contains($0) }) {
            return EscalationSuggestion(reason: "回答似乎回避了问题或称信息不足")
        }

        let hedgeHits = hedges.reduce(into: 0) { acc, h in
            if lower.contains(h) { acc += 1 }
        }
        let tooShort = trimmed.count < 40

        if hedgeHits >= 2 {
            return EscalationSuggestion(reason: "回答中出现多处不确定措辞")
        }
        if hedgeHits >= 1 && tooShort {
            return EscalationSuggestion(reason: "回答较简短且含不确定措辞")
        }
        return nil
    }
}
