import XCTest
@testable import Kown

/// 覆盖本地 RAG 的切块 + BM25 检索。
final class LocalRAGTests: XCTestCase {

    func testChunkOverlap() {
        let text = String(repeating: "字", count: 1200)
        let chunks = LocalRAG.chunk(text, size: 500, overlap: 80)
        XCTAssertGreaterThan(chunks.count, 1)
        // 每块不超过 size
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 500 })
    }

    func testShortTextSingleChunk() {
        XCTAssertEqual(LocalRAG.chunk("短文本").count, 1)
    }

    func testTokenizeCJKBigrams() {
        let tokens = LocalRAG.tokenize("机器学习")
        // 单字 + 二元组
        XCTAssertTrue(tokens.contains("机"))
        XCTAssertTrue(tokens.contains("机器"))
        XCTAssertTrue(tokens.contains("学习"))
    }

    func testTokenizeAsciiWords() {
        let tokens = LocalRAG.tokenize("Hello World 2026")
        XCTAssertTrue(tokens.contains("hello"))
        XCTAssertTrue(tokens.contains("world"))
        XCTAssertTrue(tokens.contains("2026"))
    }

    func testChunkDedup() {
        let text = "第一段。\n第二段。\n第一段。"
        let chunks = LocalRAG.chunk(text, size: 50, overlap: 10)
        XCTAssertEqual(Set(chunks).count, chunks.count, "重复块应去重")
    }

    func testRRFFuse() {
        // idx 2 在两个列表都排第一 → 融合分最高(无歧义)。
        let fused = LocalRAG.rrfFuse([[2, 1, 0], [2, 0, 1]])
        XCTAssertEqual(fused.max { $0.value < $1.value }!.key, 2)
    }

    func testDot() {
        XCTAssertEqual(LocalRAG.dot([1, 0, 0], [1, 0, 0]), 1, accuracy: 1e-5)
        XCTAssertEqual(LocalRAG.dot([1, 0], [0, 1]), 0, accuracy: 1e-5)
    }

    @MainActor
    func testRetrieveRanksRelevantChunkFirst() async throws {
        // 稳定性关键:查询词必须**只**出现在目标文档里。BM25⁺(idf 带 +1,恒正)下,任何与查询
        // 共享字符的干扰文档都会拿到正分进入排序;一旦 NLEmbedding 向量模型可用(CI 时有时无),
        // RRF 融合可能把这种干扰文档顶到 B 前面 → 测试时绿时红。
        // 这里用「光合作用」做查询,且确保 A/C/D/E 都不含 光/合/作/用 等字(D 原文有「用」,改成「靠」),
        // 于是 BM25 只命中 B,B 永远排第一,与向量模型是否可用无关。
        let folder = KnowledgeFolder(name: "测试", docs: [
            KnowledgeDoc(name: "A", text: "猫是一种常见的家养宠物,喜欢睡觉和抓老鼠。"),
            KnowledgeDoc(name: "B", text: "光合作用是植物把二氧化碳和水转化成有机物的过程。"),
            KnowledgeDoc(name: "C", text: "篮球是一项团队运动,两队各五人争夺得分。"),
            KnowledgeDoc(name: "D", text: "钢琴是一种键盘乐器,靠琴槌敲击琴弦发声。"),
            KnowledgeDoc(name: "E", text: "长城是中国古代修建的军事防御工程,绵延万里。"),
        ])
        let hits = await LocalRAG.retrieve(query: "光合作用", folder: folder, topK: 1)
        let first = try XCTUnwrap(hits.first)
        XCTAssertTrue(first.contains("光合作用"))
    }

    @MainActor
    func testRetrieveEmptyOnNoMatchTokens() async {
        let folder = KnowledgeFolder(name: "空", docs: [])
        let hits = await LocalRAG.retrieve(query: "任何", folder: folder, topK: 3)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - 缓存版本纪律(后端标签:键空间不相交,向量绝不混算)

    func testBackendTagSeparatesContextualFromLegacy() {
        // legacy 标签就是语言名(兼容旧缓存文件)。
        XCTAssertEqual(RAGVectorCache.backendTag(contextualRevision: nil, lang: "zh"), "zh")
        XCTAssertEqual(RAGVectorCache.backendTag(contextualRevision: nil, lang: "en"), "en")
        // contextual 标签带修订号前缀,与 legacy 天然不相交。
        let cv = RAGVectorCache.backendTag(contextualRevision: 2, lang: "zh")
        XCTAssertEqual(cv, "cv2-zh")
        XCTAssertNotEqual(cv, "zh")
        XCTAssertTrue(RAGVectorCache.isContextualTag(cv))
        XCTAssertFalse(RAGVectorCache.isContextualTag("zh"))
    }

    func testBackendTagRevisionBumpInvalidatesOldVectors() {
        // 修订号升级 → 标签变化 → 缓存键变化 → 旧向量惰性失效重算(键不再命中)。
        let rev1 = RAGVectorCache.backendTag(contextualRevision: 1, lang: "zh")
        let rev2 = RAGVectorCache.backendTag(contextualRevision: 2, lang: "zh")
        XCTAssertNotEqual(rev1, rev2)
    }

    func testLanguageOfTag() {
        XCTAssertEqual(RAGVectorCache.language(ofTag: "cv2-zh"), "zh")
        XCTAssertEqual(RAGVectorCache.language(ofTag: "cv10-en"), "en")
        XCTAssertEqual(RAGVectorCache.language(ofTag: "zh"), "zh")   // legacy
        XCTAssertEqual(RAGVectorCache.language(ofTag: "en"), "en")
    }

    func testStableHashDeterministic() {
        // 缓存键依赖稳定哈希:同输入恒定、异输入不同。
        XCTAssertEqual(RAGVectorCache.stableHash("光合作用"), RAGVectorCache.stableHash("光合作用"))
        XCTAssertNotEqual(RAGVectorCache.stableHash("光合作用"), RAGVectorCache.stableHash("篮球"))
    }

    // MARK: - 无 contextual 资产时回退不崩(测试环境强制 legacy 路径)

    @MainActor
    func testRetrieveFallsBackWithoutContextualAssets() async {
        // isRunningUnderXCTest 为真 → contextualModel 一律返回 nil(不下载资产、不加载大模型),
        // 走 legacy/BM25 回退路径。这里验证回退路径不崩且仍能命中。
        XCTAssertTrue(isRunningUnderXCTest)
        let folder = KnowledgeFolder(name: "回退", docs: [
            KnowledgeDoc(name: "B", text: "光合作用是植物把二氧化碳和水转化成有机物的过程。"),
            KnowledgeDoc(name: "C", text: "篮球是一项团队运动,两队各五人争夺得分。"),
        ])
        let hits = await LocalRAG.retrieve(query: "光合作用", folder: folder, topK: 1)
        XCTAssertEqual(hits.first?.contains("光合作用"), true)
    }

    @MainActor
    func testEngineStatusInTestIsLegacy() async {
        // 测试环境禁用 contextual,引擎状态应为 legacy(资产从不在测试里下载)。
        let status = await RAGVectorCache.shared.engineStatus()
        XCTAssertEqual(status, .legacy)
    }

    @MainActor
    func testPreindexNoCrashOnEmptyAndPopulated() async {
        // 预索引在测试环境走 legacy(或两后端都不可用直接跳过),不得崩。
        await LocalRAG.preindex(folder: KnowledgeFolder(name: "空", docs: []))
        let folder = KnowledgeFolder(name: "有", docs: [
            KnowledgeDoc(name: "A", text: "光合作用是植物把二氧化碳和水转化成有机物的过程。"),
        ])
        await LocalRAG.preindex(folder: folder)   // 不崩即通过
    }

    // MARK: - 重排 JSON 解析与失败回退

    func testRerankParseOrderBasic() {
        // 1-based 输入 → 0-based 输出,顺序保留。
        XCTAssertEqual(RAGReranker.parseOrder("[3,1,2]", candidateCount: 3), [2, 0, 1])
    }

    func testRerankParseOrderStripsFenceAndProse() {
        // 容错:跳过 ``` 围栏与前后废话,只取第一个 [...]。
        let raw = "好的,结果如下:\n```json\n[2, 1]\n```\n仅供参考"
        XCTAssertEqual(RAGReranker.parseOrder(raw, candidateCount: 3), [1, 0])
    }

    func testRerankParseOrderDedupAndDropOutOfRange() {
        // 越界(5,0)丢弃、重复(2 出现两次)去重。
        XCTAssertEqual(RAGReranker.parseOrder("[2,2,5,0,1]", candidateCount: 3), [1, 0])
    }

    func testRerankParseOrderAcceptsFloats() {
        XCTAssertEqual(RAGReranker.parseOrder("[1.0, 3.0]", candidateCount: 3), [0, 2])
    }

    func testRerankParseOrderFailureReturnsNil() {
        // 解析失败 → nil → 调用方静默回退 RRF 顺序。
        XCTAssertNil(RAGReranker.parseOrder("没有数组", candidateCount: 3))
        XCTAssertNil(RAGReranker.parseOrder("[]", candidateCount: 3))            // 空数组无有效序号
        XCTAssertNil(RAGReranker.parseOrder("[9,9,9]", candidateCount: 3))       // 全越界
        XCTAssertNil(RAGReranker.parseOrder("[1]", candidateCount: 0))           // 无候选
    }

    @MainActor
    func testRerankSkippedUnderTest() async {
        // 测试不得依赖网络:rerank 在 XCTest 下一律返回 nil(静默回退 RRF)。
        let order = await RAGReranker.rerank(
            query: "查询", candidates: ["a", "b", "c", "d", "e"], topK: 2)
        XCTAssertNil(order)
    }

    // MARK: - 重排 provider 自动挑选(纯函数,不触网)

    func testRerankAutoPickPrefersBudgetTier() {
        let flagship = ProviderConfig(displayName: "F", kind: .anthropic,
                                      baseURL: "", model: "claude-opus-4", enabled: true)
        let budget = ProviderConfig(displayName: "B", kind: .anthropic,
                                    baseURL: "", model: "claude-haiku-4", enabled: true)
        let picked = RAGReranker.autoPick(from: [flagship, budget])
        XCTAssertEqual(picked?.model, "claude-haiku-4")
    }

    func testRerankAutoPickNilWhenNoUsable() {
        XCTAssertNil(RAGReranker.autoPick(from: []))
        let disabled = ProviderConfig(displayName: "D", kind: .anthropic,
                                      baseURL: "", model: "x", enabled: false)
        XCTAssertNil(RAGReranker.autoPick(from: [disabled]))
    }

    func testRerankConfigCodableDefaultsOnMissingFields() throws {
        // decodeIfPresent 容错:空对象 / 缺字段都解出默认(enabled 默认 true)。
        let empty = try JSONDecoder().decode(RAGRerankConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.enabled)
        XCTAssertNil(empty.providerID)
        XCTAssertNil(empty.model)

        let partial = try JSONDecoder().decode(
            RAGRerankConfig.self, from: Data(#"{"enabled":false}"#.utf8))
        XCTAssertFalse(partial.enabled)
    }
}
