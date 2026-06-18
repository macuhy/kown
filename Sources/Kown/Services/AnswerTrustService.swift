import Foundation

/// 本地可信度 / 证据锁定分析。不调用网络和模型,只基于回答文本、引用角标和本轮来源结构化留痕。
enum AnswerTrustService {
    static func analyze(
        question: String,
        answer: String,
        sources: [SourceRef],
        knowledgeSources: [KnowledgeSourceRef],
        evidenceLocked: Bool = true
    ) -> AnswerTrustReport {
        let sentences = splitSentences(answer)
        let claims = sentences
            .filter(needsEvidence)
            .prefix(12)
            .map { sentence -> AnswerTrustReport.Claim in
                let citations = citationNumbers(in: sentence)
                let verdict: String
                let reason: String
                if !citations.isEmpty {
                    let missing = citations.filter { idx in
                        !sources.indices.map { $0 + 1 }.contains(idx)
                        && !knowledgeSources.map(\.index).contains(idx)
                    }
                    if missing.isEmpty {
                        verdict = "supported"
                        reason = "句内带有可回溯的引用角标。"
                    } else {
                        verdict = "weak"
                        reason = "引用角标 \(missing.map(String.init).joined(separator: ",")) 没有匹配来源。"
                    }
                } else if sources.isEmpty && knowledgeSources.isEmpty {
                    verdict = "unsupported"
                    reason = "本轮没有来源,且该句包含事实性或强结论信息。"
                } else {
                    verdict = "unsupported"
                    reason = "本轮有来源,但该句没有绑定引用角标。"
                }
                return AnswerTrustReport.Claim(
                    text: sentence,
                    verdict: verdict,
                    reason: reason,
                    citationNumbers: citations
                )
            }

        let base = sources.isEmpty && knowledgeSources.isEmpty ? 62 : 78
        let penalty = claims.reduce(0) { partial, claim in
            switch claim.verdict {
            case "supported": return partial
            case "weak": return partial + 7
            default: return partial + (evidenceLocked ? 12 : 9)
            }
        }
        let hedgePenalty = containsHedge(answer) ? 6 : 0
        let score = max(15, min(100, base - penalty - hedgePenalty + min(10, sources.count + knowledgeSources.count)))
        let verdict: String
        if score >= 82 { verdict = "high" }
        else if score >= 62 { verdict = "medium" }
        else { verdict = "low" }

        let unsupported = claims.filter { $0.verdict != "supported" }.count
        let summary: String
        if claims.isEmpty {
            summary = "没有发现明显需要证据锁定的强事实句,可作为普通观点/建议阅读。"
        } else if unsupported == 0 {
            summary = "关键事实句均带有可回溯来源,证据锁定通过。"
        } else {
            summary = "发现 \(unsupported) 条需要补证据或明确标注为推断的句子。"
        }

        return AnswerTrustReport(
            score: score,
            verdict: verdict,
            summary: summary,
            evidenceLocked: evidenceLocked,
            sourceCount: sources.count,
            knowledgeSourceCount: knowledgeSources.count,
            claims: Array(claims)
        )
    }

    private static func splitSentences(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "。")
        let separators = CharacterSet(charactersIn: "。！？!?;；")
        return normalized
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 12 }
    }

    private static func needsEvidence(_ sentence: String) -> Bool {
        if sentence.range(of: #"\d"#, options: .regularExpression) != nil { return true }
        let evidenceWords = [
            "根据", "数据显示", "研究", "报告", "调查", "证明", "导致", "因为", "由于",
            "增长", "下降", "超过", "低于", "最高", "最低", "首次", "最新", "目前",
            "必须", "一定", "显著", "确定", "事实", "统计", "排名", "市场份额"
        ]
        return evidenceWords.contains { sentence.contains($0) }
    }

    private static func citationNumbers(in sentence: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3})\]"#) else { return [] }
        let ns = sentence as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: sentence, range: range).compactMap { match in
            guard match.numberOfRanges >= 2 else { return nil }
            return Int(ns.substring(with: match.range(at: 1)))
        }
    }

    private static func containsHedge(_ text: String) -> Bool {
        ["可能", "大概", "似乎", "也许", "不确定", "无法确认", "猜测"].contains { text.contains($0) }
    }
}
