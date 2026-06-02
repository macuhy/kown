import Foundation
import Observation

// MARK: - 跨会话全文搜索索引

/// 单条会话的搜索命中结果
struct ConversationSearchHit: Identifiable, Equatable {
    /// 命中的会话 id
    let id: UUID
    /// 命中片段(已截取上下文,供高亮展示)
    let snippet: String
    /// 片段中需要高亮的子串范围(相对 snippet),可能为空
    let highlight: Range<String.Index>?
}

/// 对所有会话建内存倒排索引,支持中文 bigram + 英文按词的全文搜索。
///
/// 仅驻留内存、不落盘:重启后由 `rebuild` 重建。不触碰任何持久化/同步代码。
@Observable
@MainActor
final class ConversationSearchIndex {
    /// 倒排索引:词条 -> 命中的会话 id 集合
    private var inverted: [String: Set<UUID>] = [:]
    /// 每个会话的可搜索全文(用于二次校验 + 提取片段)
    private var documents: [UUID: String] = [:]

    init() {}

    // MARK: - 构建 / 增量更新

    /// 全量重建索引
    func rebuild(_ conversations: [Conversation]) {
        inverted.removeAll(keepingCapacity: true)
        documents.removeAll(keepingCapacity: true)
        for conv in conversations where conv.deletedAt == nil {
            index(conv)
        }
    }

    /// 增量更新单个会话(新增或覆盖)
    func update(_ conversation: Conversation) {
        remove(conversation.id)
        index(conversation)
    }

    /// 从索引中移除某个会话
    func remove(_ id: UUID) {
        guard let oldDoc = documents.removeValue(forKey: id) else { return }
        for token in tokenize(oldDoc) {
            inverted[token]?.remove(id)
            if inverted[token]?.isEmpty == true {
                inverted.removeValue(forKey: token)
            }
        }
    }

    // MARK: - 搜索

    /// 搜索关键词,返回命中的会话(含一条高亮片段)。
    /// 多个空格分隔的词按 AND 关系匹配。
    func search(_ query: String) -> [ConversationSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 拆出用户输入里的「词」(中文整段 / 英文单词),分别取候选集合求交集
        let terms = userTerms(trimmed)
        guard !terms.isEmpty else { return [] }

        var candidates: Set<UUID>?
        for term in terms {
            let ids = candidateIDs(for: term)
            if candidates == nil {
                candidates = ids
            } else {
                candidates?.formIntersection(ids)
            }
            if candidates?.isEmpty == true { return [] }
        }
        guard let ids = candidates, !ids.isEmpty else { return [] }

        // 二次校验:倒排可能因 bigram 产生误命中,用原文 contains 复核并取片段
        var hits: [ConversationSearchHit] = []
        for id in ids {
            guard let doc = documents[id] else { continue }
            guard let firstTerm = terms.first(where: { doc.range(of: $0, options: .caseInsensitive) != nil }) else {
                continue
            }
            // 要求所有词都出现(AND)
            let allPresent = terms.allSatisfy { doc.range(of: $0, options: .caseInsensitive) != nil }
            guard allPresent else { continue }
            hits.append(makeHit(id: id, doc: doc, term: firstTerm))
        }
        return hits
    }

    // MARK: - 内部:索引构建

    /// 取会话的可搜索全文:标题 + 每个 Turn 的 prompt / 各 response / chair 综合 / summary 汇总
    private func searchableText(_ conv: Conversation) -> String {
        var parts: [String] = [conv.title]
        for turn in conv.turns {
            parts.append(turn.prompt)
            parts.append(contentsOf: turn.responses.values)
            if let chair = turn.chairSummary { parts.append(chair) }
            if let summary = turn.summaryText { parts.append(summary) }
        }
        return parts.joined(separator: "\n")
    }

    private func index(_ conv: Conversation) {
        let doc = searchableText(conv)
        documents[conv.id] = doc
        for token in tokenize(doc) {
            inverted[token, default: []].insert(conv.id)
        }
    }

    // MARK: - 内部:分词

    /// 把文本切成索引词条:连续 CJK 字符取 bigram(单字也保留),英文/数字按词。
    private func tokenize(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        var asciiBuffer = ""
        var cjkBuffer: [Character] = []

        func flushASCII() {
            if !asciiBuffer.isEmpty {
                tokens.insert(asciiBuffer.lowercased())
                asciiBuffer.removeAll(keepingCapacity: true)
            }
        }
        func flushCJK() {
            guard !cjkBuffer.isEmpty else { return }
            if cjkBuffer.count == 1 {
                tokens.insert(String(cjkBuffer[0]))
            } else {
                for i in 0..<(cjkBuffer.count - 1) {
                    tokens.insert(String(cjkBuffer[i...(i + 1)]))
                }
            }
            cjkBuffer.removeAll(keepingCapacity: true)
        }

        for ch in text {
            if ch.isCJK {
                flushASCII()
                cjkBuffer.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                asciiBuffer.append(ch)
            } else {
                flushASCII()
                flushCJK()
            }
        }
        flushASCII()
        flushCJK()
        return tokens
    }

    /// 把用户查询拆成「词」:中文连续段整段保留(逐字符校验交给原文 contains),英文单词独立。
    private func userTerms(_ query: String) -> [String] {
        var terms: [String] = []
        var asciiBuffer = ""
        var cjkBuffer = ""

        func flushASCII() {
            if !asciiBuffer.isEmpty { terms.append(asciiBuffer); asciiBuffer.removeAll(keepingCapacity: true) }
        }
        func flushCJK() {
            if !cjkBuffer.isEmpty { terms.append(cjkBuffer); cjkBuffer.removeAll(keepingCapacity: true) }
        }

        for ch in query {
            if ch.isCJK {
                flushASCII()
                cjkBuffer.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                asciiBuffer.append(ch)
            } else {
                flushASCII()
                flushCJK()
            }
        }
        flushASCII()
        flushCJK()
        return terms
    }

    /// 取单个查询词对应的候选会话集合(用倒排做初筛)。
    private func candidateIDs(for term: String) -> Set<UUID> {
        let tokens = tokenize(term)
        guard !tokens.isEmpty else { return [] }
        var result: Set<UUID>?
        for token in tokens {
            let ids = inverted[token] ?? []
            if result == nil { result = ids } else { result?.formIntersection(ids) }
            if result?.isEmpty == true { return [] }
        }
        return result ?? []
    }

    // MARK: - 内部:片段提取

    /// 取出 term 在 doc 中首次出现位置的上下文片段并标注高亮范围。
    private func makeHit(id: UUID, doc: String, term: String) -> ConversationSearchHit {
        guard let matchRange = doc.range(of: term, options: .caseInsensitive) else {
            return ConversationSearchHit(id: id, snippet: shorten(doc), highlight: nil)
        }

        let contextRadius = 24
        // 计算前后扩展边界(按字符)
        var lower = matchRange.lowerBound
        var upper = matchRange.upperBound
        var leftCount = 0
        while lower > doc.startIndex, leftCount < contextRadius {
            lower = doc.index(before: lower)
            leftCount += 1
        }
        var rightCount = 0
        while upper < doc.endIndex, rightCount < contextRadius {
            upper = doc.index(after: upper)
            rightCount += 1
        }

        var snippet = String(doc[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let needLeadingEllipsis = lower > doc.startIndex
        let needTrailingEllipsis = upper < doc.endIndex
        if needLeadingEllipsis { snippet = "…" + snippet }
        if needTrailingEllipsis { snippet = snippet + "…" }

        let highlight = snippet.range(of: term, options: .caseInsensitive)
        return ConversationSearchHit(id: id, snippet: snippet, highlight: highlight)
    }

    /// 没有匹配位置时的兜底:截断开头一段。
    private func shorten(_ text: String, limit: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}

// MARK: - 字符判定

private extension Character {
    /// 是否为 CJK 表意文字(中文/日文汉字范围,够用)
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x4E00...0x9FFF).contains(v)   // CJK 统一表意
                || (0x3400...0x4DBF).contains(v)   // 扩展 A
                || (0xF900...0xFAFF).contains(v)   // 兼容表意
                || (0x3040...0x30FF).contains(v)   // 平假名 / 片假名
        }
    }
}
