import Foundation
import NaturalLanguage

/// 纯本地检索:文档切块,**BM25(关键词)+ 向量(语义)混合**(RRF 融合)取 top-K 片段。
/// 向量用 Apple `NLEmbedding`(句向量,完全离线、零成本);拿不到向量时自动退回纯 BM25。
/// 中文按「单字 + 相邻二元组」切词;英文按词。
enum LocalRAG {
    /// 单块目标字符数 + 重叠。
    static let chunkSize = 500
    static let chunkOverlap = 80
    /// 注入上下文的总字符上限。
    static let maxInjectChars = 6000

    struct Chunk: Sendable {
        let docId: UUID
        let docName: String
        let text: String
        /// 1-based 页码(PDF 分块入库时携带);无分页或老文档为 nil。
        let page: Int?

        init(docId: UUID, docName: String, text: String, page: Int? = nil) {
            self.docId = docId
            self.docName = docName
            self.text = text
            self.page = page
        }
    }

    /// 检索命中的片段(带可回溯的来源元数据)。供「句级溯源」用:答案里的 `[n]` 角标
    /// 映射到这里的第 n 条,点开可弹出 `docName` 文档的 `text` 原文。
    struct RetrievedChunk: Sendable {
        let docId: UUID
        let docName: String
        let text: String
        /// 命中片段所在页码(大文档分块入库才有);展示成「第 N 页」引用。
        let page: Int?

        init(docId: UUID, docName: String, text: String, page: Int? = nil) {
            self.docId = docId
            self.docName = docName
            self.text = text
            self.page = page
        }
    }

    /// 把文档切块:优先按换行的自然段聚合到 ~size,过长的段再带重叠硬切,最后去重。
    static func chunk(_ text: String, size: Int = chunkSize, overlap: Int = chunkOverlap) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let paragraphs = trimmed
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var out: [String] = []
        var buf = ""
        func flush() {
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            buf = ""
        }
        for p in paragraphs {
            if p.count > size {
                flush()
                out.append(contentsOf: hardSplit(p, size: size, overlap: overlap))
                continue
            }
            if buf.count + p.count + 1 > size { flush() }
            buf += (buf.isEmpty ? "" : "\n") + p
        }
        flush()
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// 把「逐页文本」切成带页码的预切块:每页内部用同一套切块规则,块的页码 = 该页页码。
    /// 供大文档(PDF)分块入库用,结果存进 `KnowledgeDoc.chunks`,检索时直接复用并回溯页码。
    /// `pages` 为 1-based 顺序的每页文本(下标 0 = 第 1 页)。
    static func chunkPages(_ pages: [String], size: Int = chunkSize, overlap: Int = chunkOverlap) -> [DocChunk] {
        var out: [DocChunk] = []
        for (idx, pageText) in pages.enumerated() {
            let pageNo = idx + 1
            for c in chunk(pageText, size: size, overlap: overlap) {
                out.append(DocChunk(text: c, page: pageNo))
            }
        }
        return out
    }

    private static func hardSplit(_ text: String, size: Int, overlap: Int) -> [String] {
        let chars = Array(text)
        guard chars.count > size else { return [text] }
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

    /// 检索:BM25 + 向量混合(RRF),返回 top-K 片段文本(带文档名)。
    /// `nonisolated async`:切块 / BM25 是纯计算,向量走 `RAGVectorCache`(actor)—— 整段在后台线程跑,
    /// 不再卡发送时的主线程(扫块 + NLEmbedding 在大知识库上可达 0.5–2s)。
    nonisolated static func retrieve(query: String, folder: KnowledgeFolder, topK: Int = 4) async -> [String] {
        let chunks = await retrieveChunks(query: query, folder: folder, topK: topK)
        return chunks.map { "【\($0.docName)】\n\($0.text)" }
    }

    /// 同 `retrieve`,但保留可回溯的来源元数据(docId / docName),用于「句级溯源」。
    nonisolated static func retrieveDetailed(query: String, folder: KnowledgeFolder, topK: Int = 4) async -> [RetrievedChunk] {
        let chunks = await retrieveChunks(query: query, folder: folder, topK: topK)
        return chunks.map { RetrievedChunk(docId: $0.docId, docName: $0.docName, text: $0.text, page: $0.page) }
    }

    /// 检索核心:切块 → BM25 + 向量混合(RRF)→ 取 top-K(受 `maxInjectChars` 预算约束),返回选中块。
    nonisolated private static func retrieveChunks(query: String, folder: KnowledgeFolder, topK: Int) async -> [Chunk] {
        var seen = Set<String>()
        var chunks: [Chunk] = []
        for doc in folder.docs {
            // 大文档分块入库的文档直接用预切块(带页码);老文档现场切 text(无页码)。
            if let pre = doc.chunks, !pre.isEmpty {
                for dc in pre {
                    let t = dc.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty, seen.insert(t).inserted else { continue }
                    chunks.append(Chunk(docId: doc.id, docName: doc.name, text: t, page: dc.page))
                }
            } else {
                for c in chunk(doc.text) where seen.insert(c).inserted {
                    chunks.append(Chunk(docId: doc.id, docName: doc.name, text: c))
                }
            }
        }
        guard !chunks.isEmpty else { return [] }

        // --- BM25 排名 ---
        let queryTerms = tokenize(query)
        var bmOrder: [Int] = []
        if !queryTerms.isEmpty {
            let scores = bm25Scores(query: queryTerms, docs: chunks.map { tokenize($0.text) })
            bmOrder = scores.enumerated().filter { $0.element > 0 }
                .sorted { $0.element > $1.element }.map { $0.offset }
        }

        // --- 向量排名(语义)---
        var vecOrder: [Int] = []
        let cache = RAGVectorCache.shared
        if let (qv, lang) = await cache.queryVector(forQuery: query) {
            var sims: [(Int, Float)] = []
            for (i, c) in chunks.enumerated() {
                if let v = await cache.vector(forText: c.text, lang: lang), v.count == qv.count {
                    let s = dot(qv, v)
                    if s > 0 { sims.append((i, s)) }
                }
            }
            vecOrder = sims.sorted { $0.1 > $1.1 }.map { $0.0 }
            await cache.persistIfDirty()
        }

        // --- RRF 融合;某一信号缺失时退回另一信号 ---
        let fused = rrfFuse([bmOrder, vecOrder])
        let rankedIdx: [Int]
        if fused.isEmpty {
            rankedIdx = Array((bmOrder.isEmpty ? vecOrder : bmOrder).prefix(topK))
        } else {
            rankedIdx = fused.sorted { $0.value > $1.value }.prefix(topK).map { $0.key }
        }

        var out: [Chunk] = []
        var used = 0
        for idx in rankedIdx {
            let c = chunks[idx]
            let blockLen = c.docName.count + c.text.count + 4
            if used + blockLen > maxInjectChars { break }
            out.append(c)
            used += blockLen
        }
        return out
    }

    /// Reciprocal Rank Fusion:每个排名列表 score += 1/(k + rank)。
    static func rrfFuse(_ lists: [[Int]], k: Double = 60) -> [Int: Double] {
        var fused: [Int: Double] = [:]
        for list in lists {
            for (rank, idx) in list.enumerated() {
                fused[idx, default: 0] += 1.0 / (k + Double(rank))
            }
        }
        return fused
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    // MARK: - BM25

    static func bm25Scores(query: [String], docs: [[String]], k1: Double = 1.5, b: Double = 0.75) -> [Double] {
        let n = docs.count
        guard n > 0 else { return [] }
        let avgdl = Double(docs.reduce(0) { $0 + $1.count }) / Double(n)

        var df: [String: Int] = [:]
        for doc in docs {
            for term in Set(doc) { df[term, default: 0] += 1 }
        }
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

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
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

    /// 文本是否以 CJK 为主(决定句向量用中文还是英文模型)。
    static func isCJKHeavy(_ text: String) -> Bool {
        var cjk = 0, alpha = 0
        for s in text.unicodeScalars {
            if isCJK(s) { cjk += 1 } else if s.properties.isAlphabetic { alpha += 1 }
        }
        return cjk > alpha
    }
}

/// 句向量缓存:NLEmbedding 模型按需加载;向量按「语言:内容哈希」缓存,
/// 单位化 + Float16 量化后存内存,二进制 plist 落本地目录(不进 iCloud)。
///
/// `actor`:把可变缓存 + 非 Sendable 的 NLEmbedding 模型隔离在 actor 内,让 `LocalRAG.retrieve`
/// 能在后台线程安全地访问(不再钉死在主线程)。NLEmbedding 不跨 actor 边界 —— 句向量在 actor 内算完
/// 只把 Sendable 的 `[Float]` 返出去。
actor RAGVectorCache {
    static let shared = RAGVectorCache()

    private var memory: [String: [Float]] = [:]
    private var dirty = false
    private var loaded = false

    private var zhTried = false
    private var enTried = false
    private var zhModel: NLEmbedding?
    private var enModel: NLEmbedding?

    private var fileURL: URL { Platform.localDataDir.appendingPathComponent("rag-vectors.plist") }

    /// 按查询语言选句向量模型并直接算出 query 向量;返回 (向量, 语言标签)。
    /// 中英都拿不到则 nil(退回纯 BM25)。模型不外泄,只在 actor 内部用掉。
    func queryVector(forQuery query: String) -> (vec: [Float], lang: String)? {
        guard let (model, lang) = pickModel(forQuery: query),
              let v = model.vector(for: query) else { return nil }
        return (normalizeQuantize(v), lang)
    }

    /// 取(或计算并缓存)某块在指定语言模型下的句向量。
    func vector(forText text: String, lang: String) -> [Float]? {
        load()
        let key = lang + ":" + String(Self.stableHash(text))
        if let cached = memory[key] { return cached }
        guard let model = model(for: lang), let v = model.vector(for: text) else { return nil }
        let q = normalizeQuantize(v)
        memory[key] = q
        dirty = true
        return q
    }

    /// 按查询语言挑句向量模型(actor 内部用,不外泄 NLEmbedding)。
    private func pickModel(forQuery query: String) -> (NLEmbedding, String)? {
        if LocalRAG.isCJKHeavy(query) {
            if let m = zh() { return (m, "zh") }
            if let m = en() { return (m, "en") }
        } else {
            if let m = en() { return (m, "en") }
            if let m = zh() { return (m, "zh") }
        }
        return nil
    }

    private func model(for lang: String) -> NLEmbedding? {
        lang == "zh" ? zh() : en()
    }

    private func zh() -> NLEmbedding? {
        if !zhTried { zhTried = true; zhModel = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) }
        return zhModel
    }
    private func en() -> NLEmbedding? {
        if !enTried { enTried = true; enModel = NLEmbedding.sentenceEmbedding(for: .english) }
        return enModel
    }

    /// 单位化 + Float16 量化(余弦即点积)。
    /// Float16 的带参初始化器在 x86_64 上不可用(只有 arm64 支持),而 mac 发版是
    /// arm64+x86_64 的 universal 构建 —— x86_64 那一刀会编译失败(0.12.0 起 mac Release
    /// 一直挂在这)。故用 arch 守卫:arm64 走 Float16 量化,x86_64 退化为 Float(存储
    /// 类型同为 [Float],数值上几乎一致,不影响索引文件格式与跨架构读取)。
    private func normalizeQuantize(_ v: [Double]) -> [Float] {
        var norm = 0.0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        let inv = norm > 0 ? 1.0 / norm : 1.0
        return v.map { d in
            let scaled = Float(d * inv)
            #if arch(arm64)
            return Float(Float16(scaled))
            #else
            return scaled
            #endif
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? PropertyListDecoder().decode([String: [Float]].self, from: data) else { return }
        memory = dict
    }

    func persistIfDirty() {
        guard dirty else { return }
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        if let data = try? enc.encode(memory) {
            try? data.write(to: fileURL, options: .atomic)
            dirty = false
        }
    }

    /// FNV-1a 64-bit 稳定哈希(跨进程稳定,用作缓存键)。
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
