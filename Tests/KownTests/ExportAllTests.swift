import XCTest
@testable import Kown

/// 覆盖「导出全部会话」拼接。
final class ExportAllTests: XCTestCase {
    func testMarkdownForAllEmpty() {
        XCTAssertTrue(ConversationExporter.markdownForAll([]).contains("暂无会话"))
    }

    func testMarkdownForAllConcatenates() {
        let a = Conversation(title: "甲", mode: .direct)
        let b = Conversation(title: "乙", mode: .council)
        let md = ConversationExporter.markdownForAll([a, b])
        XCTAssertTrue(md.contains("全部会话(2)"))
        XCTAssertTrue(md.contains("甲"))
        XCTAssertTrue(md.contains("乙"))
        XCTAssertTrue(md.contains("\n\n---\n\n"))  // 会话间分隔
    }
}
