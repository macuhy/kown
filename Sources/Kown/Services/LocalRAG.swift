import Foundation

/// 纯本地检索:把文档切块,用 BM25(关键词)对 query 打分,返回最相关的 top-K 片段。
/// 不依赖 embedding API,零成本、可离线。中文按「单字 + 相邻二元组」切词,英文按词。
enum LocalRAG {
    /// 单块目标字符数 + 重叠。
    static let chunkSize = 500
    static let chunkOverlap = 80
    /// 注入上下文的总字符上限。
    static let maxInjectChars = 6000

    struct Chunk: Sendable {
        let docName: String
        let text: String
    }

    /// 把文档切成带重叠的块(按段落优先,过长再硬切)。
    static func chunk(_ text: String, size: Int = chunkSize, overlap: Int = chunkOverlap) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let chars = Array(trimmed)
        guard chars.count > size else { return [trimmed] }
        var out: [String] = []
        var start = 0
        let step = max(1, size - overlap)
        while start < chars.count {
            let end = min(start + size, chars.count)
            out.append(String(chars[start..<end]))
            if end == chars.count { break }
            start += step
        }
        return out
    }

    /// 检索:在 folder 的所有文档块里,按 BM25 对 query 打分,返回 top-K 片段文本(带文档名)。
    static func retrieve(query: String, folder: KnowledgeFolder, topK: Int = 4) -> [String] {
        var chunks: [Chunk] = []
        for doc in folder.docs {
            for c in chunk(doc.text) {
                chunks.append(Chunk(docName: doc.name, text: c))
            }
        }
        guard !chunks.isEmpty else { return [] }

        let queryTerms = tokenize(query)
        guard !queryTerms.isEmpty else { return [] }

        let docTokens = chunks.map { tokenize($0.text) }
        let scores = bm25Scores(query: queryTerms, docs: docTokens)

        let ranked = scores.enumerated()
            .filter { $0.element > 0 }
            .sorted { $0.element > $1.element }
            .prefix(topK)

        var out: [String] = []
        var used = 0
        for (idx, _) in ranked {
            let c = chunks[idx]
            let block = "【\(c.docName)】\n\(c.text)"
            if used + block.count > maxInjectChars { break }
            out.append(block)
            used += block.count
        }
        return out
    }

    // MARK: - BM25

    static func bm25Scores(query: [String], docs: [[String]], k1: Double = 1.5, b: Double = 0.75) -> [Double] {
        let n = docs.count
        guard n > 0 else { return [] }
        let avgdl = Double(docs.reduce(0) { $0 + $1.count }) / Double(n)

        // 文档频率
        var df: [String: Int] = [:]
        for doc in docs {
            for term in Set(doc) { df[term, default: 0] += 1 }
        }
        // 每文档词频
        let tfs: [[String: Int]] = docs.map { doc in
            var m: [String: Int] = [:]
            for t in doc { m[t, default: 0] += 1 }
            return m
        }

        let qset = Set(query)
        var scores = [Double](repeating: 0, count: n)
        for term in qset {
            guard let dft = df[term], dft > 0 else { continue }
            let idf = log((Double(n) - Double(dft) + 0.5) / (Double(dft) + 0.5) + 1.0)
            for i in 0..<n {
                let f = Double(tfs[i][term] ?? 0)
                guard f > 0 else { continue }
                let dl = Double(docs[i].count)
                let denom = f + k1 * (1 - b + b * dl / max(avgdl, 1))
                scores[i] += idf * (f * (k1 + 1)) / max(denom, 0.0001)
            }
        }
        return scores
    }

    // MARK: - 分词

    /// 英文按词(连续字母数字),中文 / CJK 按「单字 + 相邻二元组」。其他符号丢弃。
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var asciiBuf = ""
        var cjkRun: [Character] = []

        func flushAscii() {
            if !asciiBuf.isEmpty { tokens.append(asciiBuf); asciiBuf = "" }
        }
        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            for ch in cjkRun { tokens.append(String(ch)) }
            if cjkRun.count >= 2 {
                for i in 0..<(cjkRun.count - 1) {
                    tokens.append(String(cjkRun[i]) + String(cjkRun[i + 1]))
                }
            }
            cjkRun = []
        }

        for scalar in text.lowercased().unicodeScalars {
            let ch = Character(scalar)
            if isCJK(scalar) {
                flushAscii()
                cjkRun.append(ch)
            } else if scalar.properties.isAlphabetic || (scalar.value >= 48 && scalar.value <= 57) {
                flushCJK()
                asciiBuf.append(ch)
            } else {
                flushAscii(); flushCJK()
            }
        }
        flushAscii(); flushCJK()
        return tokens
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF,   // CJK 统一表意
             0x3400...0x4DBF,   // 扩展 A
             0x3040...0x30FF,   // 平假名 / 片假名
             0xAC00...0xD7AF:   // 韩文
            return true
        default:
            return false
        }
    }
}
