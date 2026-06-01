import XCTest
@testable import Kown

/// 覆盖从 AppViewModel 抽出的纯静态 prompt 构造逻辑(现在可测)。
/// 辩论轮次标题随 N 变化、shorten 截断是最容易手滑回归的点。
final class PromptBuildersTests: XCTestCase {

    func testDebateRoundTitle() {
        // 2 轮:立论 + 反驳/修正
        XCTAssertEqual(PromptBuilders.debateRoundTitle(round: 1, total: 2), "立论")
        XCTAssertEqual(PromptBuilders.debateRoundTitle(round: 2, total: 2), "反驳 / 修正")
        // 3+ 轮:最后一轮叫收敛 / 最终立场,中间轮带编号
        XCTAssertEqual(PromptBuilders.debateRoundTitle(round: 1, total: 3), "立论")
        XCTAssertEqual(PromptBuilders.debateRoundTitle(round: 2, total: 3), "反驳 / 修正 #1")
        XCTAssertEqual(PromptBuilders.debateRoundTitle(round: 3, total: 3), "收敛 / 最终立场")
    }

    func testShorten() {
        XCTAssertEqual(PromptBuilders.shorten("  hi  ", max: 10), "hi")
        XCTAssertEqual(PromptBuilders.shorten("abcdef", max: 3), "abc…")
        XCTAssertEqual(PromptBuilders.shorten("abc", max: 3), "abc")
    }
}
