import Foundation

/// 红队压测:指定一个「对手模型」(红队)专门猎杀某条答案里的幻觉 / 最弱论断 / 没出处的数据,
/// 再让原模型(辩护方)逐条辩护或改口。opt-in(成本 + 两段调用),由 UI「红队压测」按钮触发,
/// 结果写回 `Turn.redTeamResult`。
///
/// 设计对齐 `FactCheckService`:两段 JSON 调用(抽攻击点 → 逐条回应),容错解析,
/// 任一阶段失败 / 抽不出攻击点时返回 nil(绝不变砖)。论断抽取思路复用 FactCheck 的「JSON 列表」范式。
enum RedTeamService {
    /// 最多攻击的点数(控制调用 token / 成本)。
    static let maxAttacks = 5
    /// 抽攻击点的输出 token 上限。
    static let maxAttackTokens = 1100
    /// 辩护回应的输出 token 上限(逐条要写辩护,留足空间)。
    static let maxDefenseTokens = 1600
    /// 单段送进 prompt 的答案最大字符数。
    static let maxAnswerChars = 5000

    /// 跑一轮红队压测。
    /// - red:担任红队(攻击方)的 provider。
    /// - defender:担任辩护方的 provider(通常 = 原答案归属的模型)。
    /// 任一阶段失败 / 抽不出攻击点时返回 nil。
    @MainActor
    static func attack(
        question: String,
        answer: String,
        red: ProviderConfig,
        defender: ProviderConfig
    ) async -> RedTeamResult? {
        guard !red.kind.isCLI, !defender.kind.isCLI else { return nil }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let redKey: String
        let defenderKey: String
        do {
            redKey = try KeychainStore.load(id: red.id)
            defenderKey = try KeychainStore.load(id: defender.id)
        } catch { return nil }
        let redClient = ProviderRegistry.client(for: red.kind)
        let defenderClient = ProviderRegistry.client(for: defender.kind)

        // 1) 红队出击:点名最弱的论断 / 疑似幻觉 / 没出处的数据 + 一句整体结论。
        let (rawAttacks, verdict) = await extractAttacks(
            question: question, answer: trimmed, provider: red, apiKey: redKey, client: redClient)
        guard !rawAttacks.isEmpty else { return nil }

        // 2) 辩护方逐条回应:辩护(维持)或改口(承认)。
        let responses = await defend(
            question: question, answer: trimmed, attacks: rawAttacks,
            provider: defender, apiKey: defenderKey, client: defenderClient)

        var out: [RedTeamResult.Attack] = []
        for (i, a) in rawAttacks.enumerated() {
            let r = responses[i] ?? (defense: "", resolution: "defended")
            out.append(.init(claim: a.claim, kind: a.kind, attack: a.attack,
                             defense: r.defense, resolution: r.resolution))
        }
        guard !out.isEmpty else { return nil }
        return RedTeamResult(
            attacks: out,
            verdict: verdict,
            redProviderID: red.id.uuidString,
            defenderProviderID: defender.id.uuidString
        )
    }

    // MARK: - 1) 红队出击

    private struct RawAttack {
        let claim: String
        let kind: String
        let attack: String
    }

    private static func extractAttacks(
        question: String, answer: String,
        provider: ProviderConfig, apiKey: String, client: LLMClient
    ) async -> (attacks: [RawAttack], verdict: String) {
        let prompt = """
        你是严苛的红队审稿人(对手模型)。下面是一个问题和某 AI 给出的答案。\
        请专门挑刺:找出答案里**最站不住脚**的地方,最多 \(maxAttacks) 条,优先级:
        1) 疑似幻觉(编造的事实 / 不存在的引用 / 自相矛盾)— kind 填 "hallucination"
        2) 论证薄弱(结论缺乏依据、以偏概全、逻辑跳跃)— kind 填 "weak"
        3) 关键数据 / 论断没有出处(给了数字或断言却无来源)— kind 填 "unsourced"

        每条点名答案里的**具体内容**(claim),并给出为什么它站不住(attack,一句话,尖锐具体)。
        再给一句整体结论(verdict):这份答案整体有多可信、最该警惕什么。

        **只输出一个 JSON 对象**,不要任何额外文字 / 代码围栏:
        {"verdict":"整体结论一句话","attacks":[{"claim":"被攻击的具体内容","kind":"hallucination","attack":"为什么站不住"}]}
        若答案确实挑不出明显问题,attacks 用空数组 []。所有文本用中文。

        【问题】
        \(snippet(question, 1200))

        【答案】
        \(snippet(answer, maxAnswerChars))
        """
        let options = ChatOptions(
            systemPrompt: "你是红队对手模型,任务是尽力找出目标答案的幻觉、薄弱论证与无出处数据,只按要求输出严格 JSON。",
            temperature: 0.3,
            maxTokens: maxAttackTokens
        )
        var collected = ""
        do {
            for try await chunk in client.stream(prompt: prompt, options: options, config: provider, apiKey: apiKey) {
                if case .text(let t) = chunk { collected += t }
                if collected.count >= 9000 { break }
            }
        } catch { return ([], "") }

        guard let json = PromptBuilders.extractJSONObject(from: collected),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], "")
        }
        let verdict = (obj["verdict"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var attacks: [RawAttack] = []
        for item in (obj["attacks"] as? [Any]) ?? [] {
            guard let d = item as? [String: Any] else { continue }
            let claim = (d["claim"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let attack = (d["attack"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !claim.isEmpty || !attack.isEmpty else { continue }
            attacks.append(RawAttack(claim: claim, kind: normalizeKind(d["kind"] as? String), attack: attack))
            if attacks.count >= maxAttacks { break }
        }
        return (attacks, verdict)
    }

    // MARK: - 2) 辩护方回应

    private static func defend(
        question: String, answer: String, attacks: [RawAttack],
        provider: ProviderConfig, apiKey: String, client: LLMClient
    ) async -> [Int: (defense: String, resolution: String)] {
        var lines: [String] = []
        lines.append("你之前回答了下面这个问题。现在有一个红队对手模型挑出了若干攻击点。")
        lines.append("请对**每一条**攻击作出诚实回应:要么辩护(你有依据维持原结论,resolution 填 \"defended\"),")
        lines.append("要么改口(攻击成立,你承认并修正,resolution 填 \"conceded\")。不要嘴硬,有错就认。")
        lines.append("")
        lines.append("【原问题】")
        lines.append(snippet(question, 1000))
        lines.append("")
        lines.append("【你的原答案】")
        lines.append(snippet(answer, maxAnswerChars))
        lines.append("")
        lines.append("【红队攻击点】")
        for (i, a) in attacks.enumerated() {
            lines.append("=== 攻击 #\(i + 1)(\(kindLabel(a.kind)))===")
            if !a.claim.isEmpty { lines.append("被质疑内容:\(a.claim)") }
            lines.append("质疑理由:\(a.attack)")
            lines.append("")
        }
        lines.append("**只输出一个 JSON 对象**,不要额外文字 / 代码围栏,键为攻击序号字符串:")
        lines.append("{\"1\":{\"defense\":\"你的回应一段话\",\"resolution\":\"defended\"},\"2\":{\"defense\":\"…\",\"resolution\":\"conceded\"}}")
        lines.append("defense 用中文,简洁有力,不超过 120 字。")
        let prompt = lines.joined(separator: "\n")

        let options = ChatOptions(
            systemPrompt: "你要为自己之前的答案接受红队质询,逐条诚实回应:能辩护就辩护,该改口就改口,只按要求输出严格 JSON。",
            temperature: 0.3,
            maxTokens: maxDefenseTokens
        )
        var collected = ""
        do {
            for try await chunk in client.stream(prompt: prompt, options: options, config: provider, apiKey: apiKey) {
                if case .text(let t) = chunk { collected += t }
                if collected.count >= 12000 { break }
            }
        } catch { return [:] }

        guard let json = PromptBuilders.extractJSONObject(from: collected),
              let data = json.data(using: .utf8) else { return [:] }
        struct R: Decodable { let defense: String?; let resolution: String? }
        guard let dict = try? JSONDecoder().decode([String: R].self, from: data) else { return [:] }
        var out: [Int: (defense: String, resolution: String)] = [:]
        for (k, v) in dict {
            guard let idx = Int(k), idx >= 1, idx <= attacks.count else { continue }
            out[idx - 1] = (defense: (v.defense ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            resolution: normalizeResolution(v.resolution))
        }
        return out
    }

    // MARK: - 归一化 / 工具

    private static func normalizeKind(_ k: String?) -> String {
        let s = (k ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("hallu") || s.contains("幻觉") || s.contains("编造") { return "hallucination" }
        if s.hasPrefix("unsource") || s.contains("出处") || s.contains("来源") || s.contains("无源") { return "unsourced" }
        return "weak"
    }

    private static func normalizeResolution(_ r: String?) -> String {
        let s = (r ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("conced") || s.contains("承认") || s.contains("改口") || s.contains("修正") { return "conceded" }
        return "defended"
    }

    /// 攻击类型中文标签(prompt 与 UI 共用)。
    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "hallucination": return "疑似幻觉"
        case "unsourced":     return "数据无出处"
        default:              return "论证薄弱"
        }
    }

    private static func snippet(_ text: String, _ max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }
}
