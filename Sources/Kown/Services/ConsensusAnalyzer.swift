import Foundation

/// 把一轮里各家(带 provider 名)的回答交给小模型,抽取「共識(各模型一致点)/ 分歧(意见分歧点)」。
/// opt-in:由 UI「分析分歧」按钮触发(成本考量),结果写回 `Turn.consensusAnalysis`。
/// 参照 `ConversationSummarizer`:选 chair > 第一个非 CLI 的 enabled provider,小调用、低温、短输出。
enum ConsensusAnalyzer {
    /// 单家回答送进 prompt 的最大字符数(防止上下文炸开)。
    static let maxAnswerChars = 2000
    /// 输出 token 上限(结构化 JSON 比纯列表稍长,留足空间)。
    static let maxTokens = 1200

    /// provider 名 + 其回答文本(按 panelOrder 顺序)。
    struct NamedAnswer {
        let name: String
        let text: String
    }

    /// 跑差异分析,失败 / 选不到 provider / 回答不足 2 家时返回 nil(分析无意义)。
    @MainActor
    static func analyze(
        question: String,
        answers: [NamedAnswer],
        chair: ProviderConfig?,
        firstEnabled: ProviderConfig?
    ) async -> ConsensusAnalysis? {
        // 只有 >= 2 家有效回答才值得做共識/分歧分析。
        let valid = answers.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard valid.count >= 2 else { return nil }

        // 选 provider:chair 优先,否则第一个非 CLI 的 enabled。
        guard let provider = chair ?? firstEnabled, !provider.kind.isCLI else { return nil }

        let prompt = buildPrompt(question: question, answers: valid)
        do {
            let key = try KeychainStore.load(id: provider.id)
            let client = ProviderRegistry.client(for: provider.kind)
            let options = ChatOptions(
                systemPrompt: "你是一个答案对比分析助手。你会读到同一个问题下多个 AI 模型各自的回答,任务是找出它们的共識(一致结论)与分歧(意见分歧的点),并按要求输出严格 JSON。",
                temperature: 0.2,
                maxTokens: maxTokens
            )
            var collected = ""
            for try await chunk in client.stream(prompt: prompt, options: options, config: provider, apiKey: key) {
                if case .text(let t) = chunk { collected += t }
                if collected.count >= 8000 { break }
            }
            // 优先结构化 JSON(带 agreementScore + 分歧点立场);失败退回纯文本解析(绝不变砖)。
            return parseStructured(collected) ?? parse(collected)
        } catch {
            return nil
        }
    }

    // MARK: - Prompt

    private static func buildPrompt(question: String, answers: [NamedAnswer]) -> String {
        var lines: [String] = []
        lines.append("下面是针对同一个问题,多个 AI 模型各自给出的回答。请对比它们,做差异分析:")
        lines.append("1) 一致度:0-100 的整数,衡量各家回答在核心结论上的一致程度(越高越一致)。")
        lines.append("2) 共識(agreements):各模型基本一致认同的关键结论 / 要点。")
        lines.append("3) 分歧(disagreements):模型之间意见分歧的点;每个分歧点列出**哪个模型持什么立场**。")
        lines.append("")
        lines.append("只输出一个 JSON 对象,不要任何额外解释或代码块标记,严格遵循以下结构(中文内容,简短具体):")
        lines.append("""
        {
          "agreementScore": 0,
          "agreements": ["一致点1", "一致点2"],
          "disagreements": [
            {"point": "分歧点描述", "positions": [{"model": "模型展示名", "stance": "该模型立场一句话"}]}
          ]
        }
        """)
        lines.append("")
        lines.append("说明:agreements 没有时用空数组 [];disagreements 没有时用空数组 [];positions 里的 model 必须用下方给出的模型展示名。")
        lines.append("")
        lines.append("【问题】")
        lines.append(snippet(question, max: 800))
        lines.append("")
        lines.append("【各模型回答】")
        for a in answers {
            lines.append("=== \(a.name) ===")
            lines.append(snippet(a.text, max: maxAnswerChars))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parse(结构化 JSON)

    /// 解析结构化 JSON 输出(agreementScore + agreements + disagreements[{point, positions}])。
    /// 容错:剥代码围栏、截首尾花括号;字段缺失用默认值;完全解析不出 → 返回 nil(由调用点退回纯文本)。
    static func parseStructured(_ raw: String) -> ConsensusAnalysis? {
        guard let json = extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // agreements:字符串数组,清洗空白与空项。
        let agreements = ((obj["agreements"] as? [Any]) ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "无" && $0 != "無" }

        // disagreements:对象数组,每个有 point + positions[{model, stance}]。
        var points: [ConsensusDisagreement] = []
        for item in (obj["disagreements"] as? [Any]) ?? [] {
            guard let d = item as? [String: Any] else { continue }
            let point = (d["point"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !point.isEmpty, point != "无", point != "無" else { continue }
            var positions: [ConsensusDisagreement.Position] = []
            for p in (d["positions"] as? [Any]) ?? [] {
                guard let pd = p as? [String: Any] else { continue }
                let model = (pd["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stance = (pd["stance"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !model.isEmpty || !stance.isEmpty else { continue }
                positions.append(.init(model: model, stance: stance))
            }
            points.append(ConsensusDisagreement(point: point, positions: positions))
        }

        // 一致度:容忍数字 / 字符串数字;裁剪到 0-100。缺失则 nil(退化为纯文本视图)。
        var score: Int? = nil
        if let n = obj["agreementScore"] as? NSNumber {
            score = min(100, max(0, n.intValue))
        } else if let s = obj["agreementScore"] as? String,
                  let n = Int(s.trimmingCharacters(in: .whitespaces)) {
            score = min(100, max(0, n))
        }

        // 至少要有一条共識或一个分歧点,否则视作没解析出有效内容。
        guard !agreements.isEmpty || !points.isEmpty else { return nil }

        // 纯文本 disagreements 从结构化分歧点合成,保持旧 UI / 导出 / 合成终稿等消费方不变。
        let flatDisagreements = points.map { point -> String in
            if point.positions.isEmpty { return point.point }
            let stances = point.positions
                .map { p in p.model.isEmpty ? p.stance : "\(p.model):\(p.stance)" }
                .filter { !$0.isEmpty }
                .joined(separator: ";")
            return stances.isEmpty ? point.point : "\(point.point)(\(stances))"
        }

        return ConsensusAnalysis(
            agreements: agreements,
            disagreements: flatDisagreements,
            agreementScore: score,
            disagreementPoints: points.isEmpty ? nil : points
        )
    }

    /// 从可能带前后缀 / 代码围栏的文本里抠出第一个 `{ ... }` JSON 对象子串。
    private static func extractJSONObject(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else { return nil }
        return String(trimmed[start...end])
    }

    // MARK: - Parse(纯文本退路)

    /// 解析模型输出的「共識: / 分歧:」两段列表。容错大小写、全/半角冒号、缺一节。
    static func parse(_ raw: String) -> ConsensusAnalysis? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        enum Section { case none, agreement, disagreement }
        var section: Section = .none
        var agreements: [String] = []
        var disagreements: [String] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let header = line.replacingOccurrences(of: " ", with: "")
            if header.hasPrefix("共識") || header.hasPrefix("共识") {
                section = .agreement
                continue
            }
            if header.hasPrefix("分歧") {
                section = .disagreement
                continue
            }
            let item = stripBullet(line)
            guard !item.isEmpty, item != "无", item != "無" else { continue }
            switch section {
            case .agreement: agreements.append(item)
            case .disagreement: disagreements.append(item)
            case .none: break
            }
        }

        guard !agreements.isEmpty || !disagreements.isEmpty else { return nil }
        return ConsensusAnalysis(agreements: agreements, disagreements: disagreements)
    }

    /// 去掉行首的项目符号 / 序号 / 冒号残留。
    private static func stripBullet(_ s: String) -> String {
        var r = s
        // 去掉残留的「共識:」「分歧:」前缀(同一行写法)。
        for prefix in ["共識:", "共识:", "分歧:", "共識:", "共识:", "分歧:"] {
            if r.hasPrefix(prefix) { r.removeFirst(prefix.count) }
        }
        while let f = r.first,
              f == "-" || f == "*" || f == "•" || f == "·" || f == "." || f == "、"
              || f == ")" || f == ")" || f == ":" || f == ":" || (f.isNumber && f.isASCII) || f == " " {
            // 注意:只剥 ASCII 数字作行号。中文数字「一/二/三」在 Swift 里 isNumber 也为真,
            // 若一并剥掉会把「一致点」误伤成「致点」,故加 isASCII 限制。
            r.removeFirst()
        }
        return r.trimmingCharacters(in: .whitespaces)
    }

    private static func snippet(_ text: String, max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }
}
