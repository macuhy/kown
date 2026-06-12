import Foundation

/// 技能保存后,用便宜模型据 `name / summary / keywords / instructions` 扩写出
/// ≤15 条**同义触发说法**(口语化、近义、常见变体),写回 `Skill.triggerPhrases`,
/// 提升 `SkillRouter` 的自动触发召回(用户随口一句也能命中技能)。
///
/// **后台、容错、绝不阻塞保存**:无可用 provider / 超时 / 解析失败 → 返回 nil,
/// 调用方(`SkillsStore`)保持原技能不变。provider 解析复用 `RAGReranker` 同款
/// 自动挑 budget 档逻辑(KeychainStore + ProviderRegistry + 低温小 maxTokens)。
enum SkillTriggerSynthesizer {
    /// 最多生成多少条触发说法。
    static let maxPhrases = 15
    /// 整个生成调用的超时。
    static let timeoutSeconds: Double = 8

    /// 为技能生成触发说法;任何失败返回 nil。返回的数组已清洗、去重、截断到 `maxPhrases`。
    nonisolated static func synthesize(for skill: Skill) async -> [String]? {
        guard !isRunningUnderXCTest else { return nil }   // 测试不得依赖网络
        guard let (provider, apiKey) = await loadSetup() else { return nil }

        let prompt = buildPrompt(for: skill)
        let options = ChatOptions(
            systemPrompt: "你是触发短语生成器。只输出一个 JSON 字符串数组,不要任何其他文字。",
            temperature: 0.4,
            maxTokens: 300
        )
        do {
            let raw: String = try await withTimeout(seconds: timeoutSeconds) {
                let client = ProviderRegistry.client(for: provider.kind)
                var collected = ""
                for try await chunk in client.stream(
                    prompt: prompt, options: options, config: provider, apiKey: apiKey
                ) {
                    if case .text(let t) = chunk { collected += t }
                    if collected.count >= 1500 { break }
                }
                return collected
            }
            return parsePhrases(raw, existingKeywords: skill.keywords)
        } catch {
            return nil   // 超时 / 网络 / provider 报错 → 保持原技能
        }
    }

    // MARK: - Provider 解析(复用 RAGReranker 的自动挑选,统一便宜档策略)

    private static func loadSetup() async -> (provider: ProviderConfig, apiKey: String)? {
        await MainActor.run { () -> (ProviderConfig, String)? in
            let providers = ProviderConfigStore.load()
            // 只在「有 key 或本地端点」的 provider 里挑,避免白发必败请求。
            let usable = providers.filter {
                KeychainStore.hasKey(id: $0.id) || RAGReranker.isLocalEndpoint($0.baseURL)
            }
            guard let picked = RAGReranker.autoPick(from: usable) else { return nil }
            let key = (try? KeychainStore.load(id: picked.id)) ?? ""
            return (picked, key)
        }
    }

    // MARK: - Prompt 与解析

    static func buildPrompt(for skill: Skill) -> String {
        var lines: [String] = []
        lines.append("下面是一个「技能」的定义。请生成用户可能用来**触发**这个技能的口语化说法。")
        lines.append("要求:同义/近义/常见变体,贴近真实聊天口吻;短(≤8 字为佳);中文为主,可含常见英文词。")
        lines.append("只输出一个 JSON 字符串数组(最多 \(maxPhrases) 条),例如 [\"帮我记一下\",\"存个备忘\"]。不要解释。")
        lines.append("")
        lines.append("【技能名】\(skill.name)")
        if !skill.summary.isEmpty {
            lines.append("【用途】\(skill.summary)")
        }
        if !skill.keywords.isEmpty {
            lines.append("【已有关键词】\(skill.keywords.joined(separator: "、"))")
        }
        let instr = skill.instructions.prefix(400)
        if !instr.isEmpty {
            lines.append("【说明节选】\(instr)")
        }
        return lines.joined(separator: "\n")
    }

    /// 解析模型输出的 JSON 字符串数组,清洗(trim / 去空 / 小写去重 / 去掉与已有关键词重复的)、
    /// 截断到 `maxPhrases`。容错:提取第一个 `[...]`(跳过 ``` 围栏与前后废话)。
    /// 没解出任何有效条目 → nil。
    static func parsePhrases(_ raw: String, existingKeywords: [String]) -> [String]? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.firstIndex(of: "["),
              let close = text[open...].lastIndex(of: "]") else { return nil }
        let body = String(text[open...close])
        guard let data = body.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return nil }

        let existing = Set(existingKeywords.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        var seen = Set<String>()
        var out: [String] = []
        for item in arr {
            let p = item.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = p.lowercased()
            guard !p.isEmpty, p.count <= 30, !existing.contains(key), seen.insert(key).inserted else { continue }
            out.append(p)
            if out.count >= maxPhrases { break }
        }
        return out.isEmpty ? nil : out
    }
}
