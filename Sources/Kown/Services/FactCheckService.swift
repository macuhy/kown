import Foundation

/// 内建事实核查:从答案里抽取关键论断 → 用 Firecrawl 搜索反查 → 让模型逐条判定「已验证 / 存疑 / 无法核实」。
/// opt-in(成本 + 调用网络),由 UI「事实核查」按钮触发,结果写回 `Turn.factCheck`。
enum FactCheckService {
    /// 最多核查的论断数(控制调用次数 / 成本)。
    static let maxClaims = 4
    /// 每条论断检索的来源数。
    static let hitsPerClaim = 3

    /// 跑事实核查。任一阶段失败 / 抽不出论断时返回 nil。
    @MainActor
    static func check(
        question: String,
        answer: String,
        provider: ProviderConfig,
        firecrawlBaseURL: String,
        firecrawlKey: String
    ) async -> FactCheckResult? {
        guard !provider.kind.isCLI else { return nil }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let apiKey: String
        do { apiKey = try KeychainStore.load(id: provider.id) } catch { return nil }
        let client = ProviderRegistry.client(for: provider.kind)

        // 1) 抽取关键论断(JSON)。
        let claims = await extractClaims(question: question, answer: trimmed,
                                         provider: provider, apiKey: apiKey, client: client)
        guard !claims.isEmpty else { return nil }

        // 2) 逐条检索来源(顺序跑,避免 Firecrawl 限流)。
        let firecrawl = FirecrawlClient(baseURL: firecrawlBaseURL, apiKey: firecrawlKey)
        var sourcesByClaim: [[SourceRef]] = []
        for claim in claims {
            var refs: [SourceRef] = []
            if let hits = try? await firecrawl.search(query: claim, limit: hitsPerClaim) {
                refs = hits.prefix(hitsPerClaim).map {
                    SourceRef(title: $0.title, url: $0.url, snippet: String($0.description.prefix(280)))
                }
            }
            sourcesByClaim.append(refs)
        }

        // 3) 让模型基于检索结果逐条判定。
        let verdicts = await judge(claims: claims, sourcesByClaim: sourcesByClaim,
                                   provider: provider, apiKey: apiKey, client: client)

        var out: [FactCheckResult.Claim] = []
        for (i, claim) in claims.enumerated() {
            let v = verdicts[i] ?? (verdict: "unverifiable", note: "未能判定。")
            out.append(.init(claim: claim, verdict: v.verdict, note: v.note,
                             sources: sourcesByClaim[safe: i] ?? []))
        }
        guard !out.isEmpty else { return nil }
        return FactCheckResult(claims: out, providerID: provider.id.uuidString)
    }

    // MARK: - 1) 抽取论断

    private static func extractClaims(
        question: String, answer: String,
        provider: ProviderConfig, apiKey: String, client: LLMClient
    ) async -> [String] {
        let prompt = """
        下面是一个问题和它的答案。请从答案里挑出最多 \(maxClaims) 条**可核查的事实性论断**(具体的数字、日期、事件、因果、定义等;主观看法 / 建议不算)。
        每条改写成一句独立、便于搜索核实的话。

        **只输出一个 JSON 对象**,不要任何额外文字 / 代码围栏:
        {"claims":["论断1","论断2"]}
        若答案没有可核查的事实性论断,输出 {"claims":[]}。

        【问题】
        \(snippet(question, 1000))

        【答案】
        \(snippet(answer, 5000))
        """
        let options = ChatOptions(systemPrompt: nil, temperature: 0.1, maxTokens: 600)
        var collected = ""
        do {
            for try await chunk in client.stream(prompt: prompt, options: options, config: provider, apiKey: apiKey) {
                if case .text(let t) = chunk { collected += t }
            }
        } catch { return [] }
        guard let json = PromptBuilders.extractJSONObject(from: collected),
              let data = json.data(using: .utf8) else { return [] }
        struct DTO: Decodable { let claims: [String]? }
        let dto = try? JSONDecoder().decode(DTO.self, from: data)
        return (dto?.claims ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxClaims)
            .map { $0 }
    }

    // MARK: - 3) 判定

    private static func judge(
        claims: [String], sourcesByClaim: [[SourceRef]],
        provider: ProviderConfig, apiKey: String, client: LLMClient
    ) async -> [Int: (verdict: String, note: String)] {
        var lines: [String] = []
        lines.append("下面是若干条论断,以及每条从网络检索到的资料片段。请逐条判定该论断是否被资料支持。")
        lines.append("判定取值: verified(资料明确支持)/ doubtful(资料与之矛盾或可疑)/ unverifiable(资料不足以判断)。")
        lines.append("")
        for (i, claim) in claims.enumerated() {
            lines.append("=== 论断 #\(i + 1) ===")
            lines.append(claim)
            let refs = sourcesByClaim[safe: i] ?? []
            if refs.isEmpty {
                lines.append("(无检索结果)")
            } else {
                for r in refs {
                    lines.append("- [\(r.title)] \(snippet(r.snippet, 200))")
                }
            }
            lines.append("")
        }
        lines.append("**只输出一个 JSON 对象**,不要额外文字 / 代码围栏,键为论断序号字符串:")
        lines.append("{\"1\":{\"verdict\":\"verified\",\"note\":\"一句话依据\"},\"2\":{\"verdict\":\"doubtful\",\"note\":\"…\"}}")
        lines.append("note 用中文,不超过 60 字。")
        let prompt = lines.joined(separator: "\n")

        let options = ChatOptions(systemPrompt: nil, temperature: 0.1, maxTokens: 900)
        var collected = ""
        do {
            for try await chunk in client.stream(prompt: prompt, options: options, config: provider, apiKey: apiKey) {
                if case .text(let t) = chunk { collected += t }
            }
        } catch { return [:] }

        guard let json = PromptBuilders.extractJSONObject(from: collected),
              let data = json.data(using: .utf8) else { return [:] }
        struct V: Decodable { let verdict: String?; let note: String? }
        guard let dict = try? JSONDecoder().decode([String: V].self, from: data) else { return [:] }
        var out: [Int: (verdict: String, note: String)] = [:]
        for (k, v) in dict {
            guard let idx = Int(k), idx >= 1, idx <= claims.count else { continue }
            out[idx - 1] = (verdict: normalize(v.verdict),
                            note: (v.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    private static func normalize(_ v: String?) -> String {
        let s = (v ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("verif") || s.contains("支持") || s.contains("已验证") { return "verified" }
        if s.hasPrefix("doubt") || s.contains("存疑") || s.contains("矛盾") { return "doubtful" }
        return "unverifiable"
    }

    private static func snippet(_ text: String, _ max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
