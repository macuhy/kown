import XCTest
@testable import Kown

/// 覆盖链式工作流的模板填充:`{{input}}` / `{{prev}}` 占位符替换。
@MainActor
final class ChainFillTests: XCTestCase {

    func testFillsBothPlaceholders() {
        let out = ChainRunner.fill("原始:{{input}}\n上一步:{{prev}}", input: "问题X", prev: "草稿Y")
        XCTAssertEqual(out, "原始:问题X\n上一步:草稿Y")
    }

    func testReplacesAllOccurrences() {
        let out = ChainRunner.fill("{{prev}} 和 {{prev}}", input: "i", prev: "P")
        XCTAssertEqual(out, "P 和 P")
    }

    func testLeavesUnknownPlaceholdersUntouched() {
        let out = ChainRunner.fill("{{input}} {{unknown}}", input: "A", prev: "B")
        XCTAssertEqual(out, "A {{unknown}}")
    }

    func testNoPlaceholderReturnsTemplateAsIs() {
        XCTAssertEqual(ChainRunner.fill("没有占位符", input: "x", prev: "y"), "没有占位符")
    }

    func testEmptyInputAndPrev() {
        XCTAssertEqual(ChainRunner.fill("[{{input}}][{{prev}}]", input: "", prev: ""), "[][]")
    }
}
