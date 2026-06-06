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
}
