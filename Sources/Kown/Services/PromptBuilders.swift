import Foundation

/// Council / Debate / Compare 各阶段的 prompt 构造 + 通知预览,从 AppViewModel 抽出的纯静态逻辑。
/// 无状态、不依赖 viewModel,便于单测。函数间互相调用沿用裸名(同 enum 内静态成员)。
enum PromptBuilders {
    static func notificationPreview(
        summaryText: String?,
        chairSummary: String?,
        responses: [String: String],
        panelOrder: [String]
    ) -> String {
        let candidates: [String?] = [
            summaryText,
            chairSummary,
            panelOrder.compactMap { responses[$0] }.first(where: { !$0.isEmpty })
        ]
        let pick = candidates.compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "已完成,点开查看"
        return String(pick.prefix(120))
    }

    // MARK: - Debate prompt

    static func buildDebateOpeningPrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        speaker: ProviderConfig,
        totalRounds: Int
    ) -> String {
        var lines: [String] = []
        lines.append("你正在参加一场多模型辩论(共 \(totalRounds) 轮)。你的身份是: \(providerLabel(speaker))。")
        lines.append("其他参与者:")
        for cfg in panel where cfg.id != speaker.id {
            lines.append("- \(providerLabel(cfg))")
        }
        lines.append("")
        lines.append("【辩题 / 用户问题】")
        lines.append(originalPrompt)
        lines.append("")
        lines.append("【第 1 轮:立论】")
        lines.append("请给出你的初始立场,但不要为了反对而反对。目标是逼近正确答案。")
        lines.append("要求:")
        lines.append("1) 先用一句话给结论或倾向。")
        lines.append("2) 给出 3-5 条关键理由 / 证据 / 假设。")
        lines.append("3) 指出你认为最容易被其他模型挑战的薄弱点。")
        lines.append("4) 如果需要其他参与者回应,列出 1-2 个具体追问。")
        lines.append("中文输出,控制在 250-450 字。")
        return lines.joined(separator: "\n")
    }

    /// Debate 模式下每一轮的标题。第 1 轮固定"立论";最后一轮叫"收敛/最终立场";中间叫"反驳 / 修正"。
    static func debateRoundTitle(round: Int, total: Int) -> String {
        if round == 1 { return "立论" }
        if round == total { return total >= 3 ? "收敛 / 最终立场" : "反驳 / 修正" }
        return "反驳 / 修正 #\(round - 1)"
    }

    static func buildDebateRebuttalPrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        completedRounds: [DebateRound],
        speaker: ProviderConfig,
        totalRounds: Int
    ) -> String {
        let nextRound = completedRounds.count + 1
        let isFinal = nextRound == totalRounds
        var lines: [String] = []
        lines.append("你正在参加一场多模型辩论(共 \(totalRounds) 轮,当前是第 \(nextRound) 轮)。你的身份是: \(providerLabel(speaker))。")
        lines.append("")
        lines.append("【辩题 / 用户问题】")
        lines.append(originalPrompt)
        lines.append("")
        // 自家立论用一句话摘要带过,只把其他模型的完整发言喂回去 —
        // 避免 self-consistency 把 speaker 锚定在自己的旧立场上。
        let speakerKey = speaker.id.uuidString
        if let mySummary = ownSummary(for: speakerKey, in: completedRounds) {
            lines.append("【你上一轮的核心立场(仅供参考,可被推翻)】")
            lines.append(mySummary)
            lines.append("")
        }
        lines.append("【其他模型的发言】")
        lines.append(renderDebateRounds(
            completedRounds,
            panel: panel,
            maxPerAnswer: 1200,
            excludeSpeakerKey: speakerKey
        ))
        lines.append("")
        if isFinal && totalRounds >= 3 {
            lines.append("【第 \(nextRound) 轮:收敛 / 最终立场】")
            lines.append("这是最后一轮,请尽量收敛分歧、给出你的最终结论。")
            lines.append("要求:")
            lines.append("1) 简述本轮你最认同其他模型的 1-2 点(点名来源模型)。")
            lines.append("2) 指出仍未解决的 1-2 个真分歧,说明为什么没法在这一轮内解决。")
            lines.append("3) 给出你的最终结论,以及你对它的置信度(高/中/低)和适用边界。")
            lines.append("中文输出,控制在 250-450 字。")
        } else {
            lines.append("【第 \(nextRound) 轮:反驳 / 修正】")
            lines.append("请阅读其他模型的立论后发言。")
            lines.append("要求:")
            lines.append("1) 指出你同意的 1-2 点(点名来源模型)。")
            lines.append("2) 反驳或修正至少 1 个你认为有问题的观点,格式: @模型名: 你的 X 我不同意,因为 Y。")
            lines.append("3) 如果你的原立场需要改变,明确说明改变了什么、为什么;如果不改变,说明为什么。")
            lines.append("4) 最后给出你更新后的结论。")
            lines.append("中文输出,控制在 250-450 字。")
        }
        return lines.joined(separator: "\n")
    }

    /// 抽取某 speaker 在已完成轮次里最后一条非空发言的前 N 字,作为反驳轮的"自家立场摘要"。
    static func ownSummary(for speakerKey: String, in rounds: [DebateRound]) -> String? {
        for round in rounds.sorted(by: { $0.index > $1.index }) {
            if let text = round.responses[speakerKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return shorten(text, max: 240)
            }
        }
        return nil
    }

    static func buildDebateModeratorPrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        rounds: [DebateRound],
        finalResponses: [String: String],
        finalErrors: [String: String]
    ) -> String {
        var lines: [String] = []
        lines.append("你是这场多模型辩论的主持人兼裁判。请基于辩论全过程做最终归纳,不要再展开新的长篇论证。")
        lines.append("")
        lines.append("【辩题 / 用户问题】")
        lines.append(originalPrompt)
        lines.append("")
        if rounds.isEmpty {
            lines.append("【各模型最终发言】")
            for cfg in panel {
                let key = cfg.id.uuidString
                lines.append("=== \(providerLabel(cfg)) ===")
                if let err = finalErrors[key], !err.isEmpty {
                    lines.append("(调用失败:\(err))")
                } else {
                    lines.append(shorten(finalResponses[key] ?? "(空响应)", max: 1400))
                }
                lines.append("")
            }
        } else {
            lines.append("【辩论记录】")
            lines.append(renderDebateRounds(rounds, panel: panel, maxPerAnswer: 1400))
        }
        lines.append("")
        lines.append("请输出 Markdown,包含:")
        lines.append("**1. 共识**:各方最终基本同意的点(3-5 条)")
        lines.append("**2. 关键分歧**:仍未解决的争议,标注主要模型")
        lines.append("**3. 立场变迁**:对比首轮立论与最终发言,列出哪些模型修正了观点、改了什么、为什么(没有变化的也注明)")
        lines.append("**4. 最强论点**:你认为最有价值的 2-3 个论点及来源")
        lines.append("**5. 最终判断**:给用户一个可执行结论,并说明置信度/风险")
        lines.append("中文输出,控制在 400-750 字。")
        return lines.joined(separator: "\n")
    }

    static func renderDebateRounds(
        _ rounds: [DebateRound],
        panel: [ProviderConfig],
        maxPerAnswer: Int,
        excludeSpeakerKey: String? = nil
    ) -> String {
        var lines: [String] = []
        let byID = Dictionary(uniqueKeysWithValues: panel.map { ($0.id.uuidString, $0) })
        for round in rounds.sorted(by: { $0.index < $1.index }) {
            lines.append("## 第 \(round.index) 轮: \(round.title)")
            let order = round.panelOrder.isEmpty ? panel.map { $0.id.uuidString } : round.panelOrder
            for key in order where key != excludeSpeakerKey {
                guard let cfg = byID[key] else { continue }
                lines.append("=== \(providerLabel(cfg)) ===")
                if let err = round.errors[key], !err.isEmpty {
                    lines.append("(调用失败:\(err))")
                } else {
                    lines.append(shorten(round.responses[key] ?? "(空响应)", max: maxPerAnswer))
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func providerLabel(_ cfg: ProviderConfig) -> String {
        "\(cfg.displayName) · \(cfg.model)"
    }

    static func shorten(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max)) + "…"
    }

    // MARK: - Chair 合成 prompt

    static func buildChairPrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        responses: [String: String],
        errors: [String: String]
    ) -> String {
        var lines: [String] = []
        lines.append("你是这个 council 的主席。其他模型针对同一个问题给出了各自答案，请综合判断。\n")
        lines.append("【问题】")
        lines.append(originalPrompt)
        lines.append("")
        lines.append("【各模型回答】")
        for cfg in panel {
            let key = cfg.id.uuidString
            let label = "\(cfg.displayName) · \(cfg.model)"
            if let err = errors[key], !err.isEmpty {
                lines.append("=== \(label) (调用失败：\(err)) ===")
                lines.append("")
            } else {
                let body = responses[key] ?? ""
                lines.append("=== \(label) ===")
                lines.append(body.isEmpty ? "(空响应)" : body)
                lines.append("")
            }
        }
        lines.append("请用 200-400 字回答：1) 共识与主要分歧；2) 你倾向的结论与理由。中文输出。")
        return lines.joined(separator: "\n")
    }

    /// Council 模式的"总结员" prompt — 中立汇总,不输出立场和倾向。
    /// 如果 chair 已经跑过,把 chair 结论也一并放进材料里(总结可能引用它,但不二次裁断)。
    static func buildSummaryPrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        responses: [String: String],
        errors: [String: String],
        chairSummary: String?
    ) -> String {
        var lines: [String] = []
        lines.append("你是一个中立的总结员。任务:把以下各家 AI 对同一问题的回答**汇总**,不出立场、不裁断、不二次推理,只做信息提取与去重。")
        lines.append("")
        lines.append("【问题】")
        lines.append(originalPrompt)
        lines.append("")
        lines.append("【各模型回答】")
        for cfg in panel {
            let key = cfg.id.uuidString
            let label = "\(cfg.displayName) · \(cfg.model)"
            if let err = errors[key], !err.isEmpty {
                lines.append("=== \(label) (调用失败:\(err)) ===")
                lines.append("")
            } else {
                let body = responses[key] ?? ""
                lines.append("=== \(label) ===")
                lines.append(body.isEmpty ? "(空响应)" : body)
                lines.append("")
            }
        }
        if let chairSummary, !chairSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("【主席综合(可参考,但不要照搬观点)】")
            lines.append(chairSummary)
            lines.append("")
        }
        lines.append("请输出以下三块,Markdown 格式,总长度 250-450 字:")
        lines.append("")
        lines.append("**共识点**:各家都讲到的关键信息(bullet,3-6 条)")
        lines.append("")
        lines.append("**分歧/独家**:某一家提到、其他家没提到或不同意的点(bullet,标注是哪家)")
        lines.append("")
        lines.append("**事实/数字汇总**:涉及到的数字、日期、专有名词、引用链接等硬信息合并去重(bullet)")
        lines.append("")
        lines.append("不要写自己的判断、推荐、结论。中文输出。")
        return lines.joined(separator: "\n")
    }

    // MARK: - Council 投票打分

    /// Council 投票 prompt — 让 chair 对每家答案按 4 个维度(0-10)打分,输出 JSON。
    /// 用「#序号」标识各家(UUID 当 key 模型容易写错),解析时按序号映射回 providerID。
    static func buildCouncilVotingPrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        responses: [String: String],
        errors: [String: String]
    ) -> String {
        var lines: [String] = []
        lines.append("你是评审。下面多个 AI 针对同一问题各给了答案,请逐一打分(不是综合,而是逐份评分)。")
        lines.append("")
        lines.append("【问题】")
        lines.append(originalPrompt)
        lines.append("")
        lines.append("【各份回答】")
        for (i, cfg) in panel.enumerated() {
            let key = cfg.id.uuidString
            lines.append("=== #\(i + 1) \(providerLabel(cfg)) ===")
            if let err = errors[key], !err.isEmpty {
                lines.append("(调用失败:\(err))")
            } else {
                lines.append(shorten(responses[key] ?? "(空响应)", max: 1200))
            }
            lines.append("")
        }
        lines.append("请对每份回答在以下维度打 0-10 分(整数):")
        lines.append("- accuracy 准确性 / completeness 完整性 / actionability 可执行性 / clarity 清晰度")
        lines.append("")
        lines.append("**只输出一个 JSON 对象**,不要任何额外文字 / 解释 / Markdown 代码围栏,格式严格如下:")
        lines.append("{\"scores\":{\"1\":{\"accuracy\":8,\"completeness\":7,\"actionability\":6,\"clarity\":9}," +
                     "\"2\":{\"accuracy\":5,\"completeness\":6,\"actionability\":7,\"clarity\":6}},\"rationale\":\"一句话总评\"}")
        lines.append("键 \"1\" \"2\" … 对应上面的 #1 #2 …。rationale 用中文,不超过 80 字。")
        return lines.joined(separator: "\n")
    }

    /// 从模型返回文本里解析投票 JSON,映射回 providerID。失败返回 nil(UI 降级不展示)。
    static func parseCouncilVote(from text: String, panel: [ProviderConfig]) -> CouncilVote? {
        guard let jsonString = extractJSONObject(from: text),
              let data = jsonString.data(using: .utf8) else { return nil }

        struct DTO: Decodable {
            struct S: Decodable { let accuracy: Int?; let completeness: Int?; let actionability: Int?; let clarity: Int? }
            let scores: [String: S]?
            let rationale: String?
        }
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data), let rawScores = dto.scores else { return nil }

        func clamp(_ v: Int?) -> Int { max(0, min(10, v ?? 0)) }
        var scores: [String: CouncilVote.Score] = [:]
        for (idxStr, s) in rawScores {
            guard let idx = Int(idxStr), idx >= 1, idx <= panel.count else { continue }
            let providerID = panel[idx - 1].id.uuidString
            scores[providerID] = CouncilVote.Score(
                accuracy: clamp(s.accuracy), completeness: clamp(s.completeness),
                actionability: clamp(s.actionability), clarity: clamp(s.clarity)
            )
        }
        guard !scores.isEmpty else { return nil }
        return CouncilVote(scores: scores, rationale: (dto.rationale ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 从一段文本里抠出第一个完整的 JSON 对象({ … }),容忍前后多余文字 / 代码围栏。
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...idx]) }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    /// Compare 模式的"裁判" prompt — 让模型挑出胜者并说理由,不要综合两家。
    static func buildJudgePrompt(
        originalPrompt: String,
        panel: [ProviderConfig],
        responses: [String: String],
        errors: [String: String]
    ) -> String {
        var lines: [String] = []
        lines.append("你是裁判。两个 AI 针对同一问题给了各自答复,请评判哪个更好,而不是综合两家。")
        lines.append("")
        lines.append("【问题】")
        lines.append(originalPrompt)
        lines.append("")
        lines.append("【两份回答】")
        for (i, cfg) in panel.enumerated() {
            let key = cfg.id.uuidString
            let mark = i == 0 ? "A" : "B"
            let label = "\(mark) — \(cfg.displayName) · \(cfg.model)"
            if let err = errors[key], !err.isEmpty {
                lines.append("=== \(label) (调用失败:\(err)) ===")
                lines.append("")
            } else {
                let body = responses[key] ?? ""
                lines.append("=== \(label) ===")
                lines.append(body.isEmpty ? "(空响应)" : body)
                lines.append("")
            }
        }
        lines.append("请在 200 字以内给出:")
        lines.append("1) 关键分歧点(1-2 条)")
        lines.append("2) 判决:A 更好 / B 更好 / 各有千秋 / 都不行,任选其一")
        lines.append("3) 2-3 句理由,具体到事实/逻辑/可执行性而不是文笔")
        lines.append("中文输出。")
        return lines.joined(separator: "\n")
    }
}
