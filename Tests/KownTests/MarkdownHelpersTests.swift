import XCTest
@testable import Kown

/// 覆盖 MarkdownText 的纯文本帮手(`MD`):数学样式不误伤货币、未闭合围栏补全、block 检测。
/// 这些直接决定回答渲染对不对,且容易回归(stylizeMath 的 `$` 误判尤其)。
@MainActor
final class MarkdownHelpersTests: XCTestCase {

    func testStylizeMathLeavesCurrencyAlone() {
        // "$5" / "$10" 没有 LaTeX 字符,不应被当成公式
        XCTAssertEqual(MD.stylizeMath("价格是 $5 和 $10"), "价格是 $5 和 $10")
    }

    func testStylizeMathInline() {
        XCTAssertEqual(MD.stylizeMath("结果 $x^2+1$ 完"), "结果 `x^2+1` 完")
    }

    func testStylizeMathBlock() {
        XCTAssertEqual(MD.stylizeMath("$$\\int_0^1 x dx$$"), "\n```\n\\int_0^1 x dx\n```\n")
    }

    func testStylizeMathNoDollarUnchanged() {
        let s = "普通文本,无公式"
        XCTAssertEqual(MD.stylizeMath(s), s)
    }

    func testBalancedFencesClosesOdd() {
        XCTAssertEqual(MD.balancedFences("```swift\nlet x = 1"), "```swift\nlet x = 1\n```")
    }

    func testBalancedFencesLeavesEven() {
        let s = "```\ncode\n```"
        XCTAssertEqual(MD.balancedFences(s), s)
    }

    func testHasBlockLevelExtras() {
        XCTAssertTrue(MD.hasBlockLevelExtras("```\ncode\n```"))
        XCTAssertTrue(MD.hasBlockLevelExtras("| a | b |\n|---|---|"))
        XCTAssertTrue(MD.hasBlockLevelExtras("- [ ] 待办\n- [x] 完成"))
        XCTAssertTrue(MD.hasBlockLevelExtras("# 标题\n正文"))      // 标题走 MarkdownUI 才能放大
        XCTAssertTrue(MD.hasBlockLevelExtras("正文\n### 三级标题"))
        XCTAssertFalse(MD.hasBlockLevelExtras("普通**加粗**文本"))
        XCTAssertFalse(MD.hasBlockLevelExtras("#标签不是标题(无空格)"))
    }
}
