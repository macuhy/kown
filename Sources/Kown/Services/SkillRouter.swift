import Foundation

/// 按用户输入自动挑一个最匹配的技能。纯启发式(对齐 `QuestionRouter`:不额外调模型,零延迟零成本)。
///
/// 打分:技能关键词在 prompt 中命中累加权重;命中越多分越高。超过阈值才返回,
/// 否则返回 nil(不强行套技能)。手动绑定的技能由调用方优先,Router 只在「无手动绑定 +
/// 用户开了自动触发」时介入。
enum SkillRouter {
    /// 命中一个关键词的基础分。
    private static let keywordHitScore = 1.0
    /// 返回结果需要达到的最低分(至少命中一个关键词)。
    private static let threshold = 1.0

    /// 在已启用技能里挑最匹配的一个;没有够格的返回 nil。
    static func match(prompt: String, skills: [Skill]) -> Skill? {
        let text = prompt.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var best: Skill?
        var bestScore = 0.0
        for skill in skills where skill.enabled {
            let score = self.score(text: text, skill: skill)
            if score > bestScore {
                bestScore = score
                best = skill
            }
        }
        return bestScore >= threshold ? best : nil
    }

    /// 单个技能对 prompt 的匹配分:关键词命中次数加权。
    static func score(text: String, skill: Skill) -> Double {
        var score = 0.0
        for kw in skill.keywords {
            let k = kw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            if text.contains(k) { score += keywordHitScore }
        }
        return score
    }
}
