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
    /// 会话在输入数组里的顺序(通常已按 updatedAt 倒序),用于让搜索结果稳定且符合侧栏顺序。
    private var documentOrder: [UUID: Int] = [:]

    init() {}

    // MARK: - 构建 / 增量更新

    /// 全量重建索引。**后台线程算,主线程一次性替换**:拼全文(searchableText)+ 整段分词(tokenize)
    /// 在大语料上是 O(总字节数),原来同步跑在主线程 → 首次搜索/打开命令面板卡顿。现在挪到后台。
    func rebuild(_ conversations: [Conversation]) async {
        let snapshot = conversations
        let built = await Task.detached(priority: .userInitiated) { [self] in
            self.buildIndex(snapshot)
        }.value
        inverted = built.inverted
        documents = built.documents
        documentOrder = built.order
    }

    /// 纯函数版全量构建(可在后台线程跑):只用局部字典 + nonisolated 的 searchableText/tokenize,
    /// 不碰 self 的 @MainActor 倒排表。
    nonisolated private func buildIndex(
        _ conversations: [Conversation]
    ) -> (inverted: [String: Set<UUID>], documents: [UUID: String], order: [UUID: Int]) {
        var inverted: [String: Set<UUID>] = [:]
        var documents: [UUID: String] = [:]
        var order: [UUID: Int] = [:]
        for (offset, conv) in conversations.enumerated() where conv.deletedAt == nil {
            let doc = searchableText(conv)
            documents[conv.id] = doc
            order[conv.id] = offset
            for token in tokenize(doc) {
                inverted[token, default: []].insert(conv.id)
            }
        }
        return (inverted, documents, order)
    }

    /// 增量更新单个会话(新增或覆盖)
    func update(_ conversation: Conversation) {
        remove(conversation.id)
        guard conversation.deletedAt == nil else { return }
        let frontOrder = (documentOrder.values.min() ?? 0) - 1
        index(conversation, order: frontOrder)
    }

    /// 从索引中移除某个会话
    func remove(_ id: UUID) {
        guard let oldDoc = documents.removeValue(forKey: id) else { return }
        documentOrder.removeValue(forKey: id)
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
        return hits.sorted { lhs, rhs in
            let left = documentOrder[lhs.id] ?? Int.max
            let right = documentOrder[rhs.id] ?? Int.max
            if left != right { return left < right }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: - 内部:索引构建

    /// 取会话的可搜索全文:标题 + 每个 Turn 的 prompt / 各 response / chair 综合 / summary 汇总
    /// + 辩论各轮发言 + 各家思考过程,确保全局搜索能覆盖所有模式的内容。
    nonisolated private func searchableText(_ conv: Conversation) -> String {
        var parts: [String] = [conv.title]
        for turn in conv.turns {
            parts.append(turn.prompt)
            parts.append(contentsOf: turn.responses.values)
            if let chair = turn.chairSummary { parts.append(chair) }
            if let summary = turn.summaryText { parts.append(summary) }
            if let rounds = turn.debateRounds {
                for round in rounds { parts.append(contentsOf: round.responses.values) }
            }
            if let reasoning = turn.reasoningByProvider { parts.append(contentsOf: reasoning.values) }
        }
        return parts.joined(separator: "\n")
    }

    private func index(_ conv: Conversation, order: Int? = nil) {
        let doc = searchableText(conv)
        documents[conv.id] = doc
        if let order {
            documentOrder[conv.id] = order
        } else if documentOrder[conv.id] == nil {
            documentOrder[conv.id] = documentOrder.count
        }
        for token in tokenize(doc) {
            inverted[token, default: []].insert(conv.id)
        }
    }

    // MARK: - 内部:分词

    /// 把文本切成索引词条:连续 CJK 字符取 bigram(单字也保留),英文/数字按词。
    nonisolated private func tokenize(_ text: String) -> Set<String> {
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

// MARK: - 跨对话语义召回(发送时注入)

/// 发送时在后台路径用:从历史会话里捞与当前问题相关的片段,拼成一段可注入 system prompt 的上下文。
///
/// 全 `nonisolated` 纯函数,**不碰** `@MainActor` 的 `ConversationSearchIndex`——后台 `assembleSystemPrompt`
/// 只拿一份 `[Conversation]` 值快照(COW)进来打分,与记忆注入(`MemoryStore.relevanceBlock`)同构。
enum ConversationRecall {
    /// 返回「相关历史对话」上下文块;无命中返回 nil。
    /// - excluding: 当前会话 id(避免把正在聊的会话召回给自己)。
    nonisolated static func recallBlock(
        corpus: [Conversation],
        query: String,
        excluding: UUID?,
        topK: Int = 3
    ) -> String? {
        let terms = queryTerms(query)
        guard !terms.isEmpty else { return nil }
        // 至少覆盖一半查询词(向上取整),降低单字误召回噪声。
        let need = max(1, (terms.count + 1) / 2)

        struct Scored { let title: String; let snippet: String; let score: Int }
        var scored: [Scored] = []
        for conv in corpus where conv.deletedAt == nil && conv.id != excluding {
            let doc = searchableText(conv)
            guard !doc.isEmpty else { continue }
            var matched = 0
            var firstTerm: String?
            for t in terms where doc.range(of: t, options: .caseInsensitive) != nil {
                matched += 1
                if firstTerm == nil { firstTerm = t }
            }
            guard matched >= need, let ft = firstTerm else { continue }
            let title = conv.title.trimmingCharacters(in: .whitespaces)
            scored.append(Scored(
                title: title.isEmpty ? "未命名会话" : title,
                snippet: snippet(doc, around: ft),
                score: matched))
        }
        guard !scored.isEmpty else { return nil }
        let top = scored.sorted { $0.score > $1.score }.prefix(topK)
        let lines = top.map { "• 《\($0.title)》:\($0.snippet)" }
        return "[相关历史对话 — 来自你过去的会话,可参考但不必引用]\n" + lines.joined(separator: "\n")
    }

    /// 可搜索全文:标题 + 每轮 prompt / 各家 response / chair 综合。够覆盖召回用。
    nonisolated private static func searchableText(_ conv: Conversation) -> String {
        var parts: [String] = [conv.title]
        for turn in conv.turns {
            parts.append(turn.prompt)
            parts.append(contentsOf: turn.responses.values)
            if let chair = turn.chairSummary { parts.append(chair) }
        }
        return parts.joined(separator: "\n")
    }

    /// 把查询拆成词:中文连续段整段、英文/数字按词。
    nonisolated private static func queryTerms(_ query: String) -> [String] {
        var terms: [String] = []
        var ascii = ""
        var cjk = ""
        func flushA() { if !ascii.isEmpty { terms.append(ascii); ascii.removeAll(keepingCapacity: true) } }
        func flushC() { if !cjk.isEmpty { terms.append(cjk); cjk.removeAll(keepingCapacity: true) } }
        for ch in query {
            if ch.isCJK { flushA(); cjk.append(ch) }
            else if ch.isLetter || ch.isNumber { flushC(); ascii.append(ch) }
            else { flushA(); flushC() }
        }
        flushA(); flushC()
        // 过滤掉过短的英文噪声词(单字母);中文段保留。
        return terms.filter { $0.count >= 2 || $0.allSatisfy { $0.isCJK } }
    }

    /// 取 term 在 doc 首次出现位置前后的一小段上下文(换行压成空格)。
    nonisolated private static func snippet(_ doc: String, around term: String, radius: Int = 28) -> String {
        guard let r = doc.range(of: term, options: .caseInsensitive) else {
            return String(doc.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        }
        var lo = r.lowerBound, hi = r.upperBound
        var l = 0
        while lo > doc.startIndex, l < radius { lo = doc.index(before: lo); l += 1 }
        var rr = 0
        while hi < doc.endIndex, rr < radius { hi = doc.index(after: hi); rr += 1 }
        var s = String(doc[lo..<hi]).replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if lo > doc.startIndex { s = "…" + s }
        if hi < doc.endIndex { s += "…" }
        return s
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
