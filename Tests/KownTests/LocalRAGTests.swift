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

    func testRetrieveRanksRelevantChunkFirst() throws {
        let folder = KnowledgeFolder(name: "测试", docs: [
            KnowledgeDoc(name: "A", text: "猫是一种常见的家养宠物,喜欢睡觉和抓老鼠。"),
            KnowledgeDoc(name: "B", text: "光合作用是植物把二氧化碳和水转化成有机物的过程。"),
        ])
        let hits = LocalRAG.retrieve(query: "植物的光合作用是什么", folder: folder, topK: 1)
        let first = try XCTUnwrap(hits.first)
        XCTAssertTrue(first.contains("光合作用"))
    }

    func testRetrieveEmptyOnNoMatchTokens() {
        let folder = KnowledgeFolder(name: "空", docs: [])
        XCTAssertTrue(LocalRAG.retrieve(query: "任何", folder: folder, topK: 3).isEmpty)
    }
}
