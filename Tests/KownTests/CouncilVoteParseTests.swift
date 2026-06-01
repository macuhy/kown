import XCTest
@testable import Kown

/// 覆盖 Council 投票 JSON 解析(容错 + 序号→providerID 映射)。
final class CouncilVoteParseTests: XCTestCase {

    private func panel(_ n: Int) -> [ProviderConfig] {
        (0..<n).map { ProviderConfig(displayName: "P\($0)", kind: .openAICompatible) }
    }

    func testParsesCleanJSON() throws {
        let p = panel(2)
        let text = #"{"scores":{"1":{"accuracy":8,"completeness":7,"actionability":6,"clarity":9},"2":{"accuracy":5,"completeness":6,"actionability":7,"clarity":6}},"rationale":"第一个更准"}"#
        let vote = try XCTUnwrap(PromptBuilders.parseCouncilVote(from: text, panel: p))
        XCTAssertEqual(vote.scores.count, 2)
        XCTAssertEqual(vote.scores[p[0].id.uuidString]?.total, 30)
        XCTAssertEqual(vote.scores[p[1].id.uuidString]?.total, 24)
        XCTAssertEqual(vote.rationale, "第一个更准")
    }

    func testToleratesSurroundingTextAndFence() throws {
        let p = panel(1)
        let text = """
        这是我的评分:
        ```json
        {"scores":{"1":{"accuracy":10,"completeness":10,"actionability":10,"clarity":10}},"rationale":"满分"}
        ```
        以上。
        """
        let vote = try XCTUnwrap(PromptBuilders.parseCouncilVote(from: text, panel: p))
        XCTAssertEqual(vote.scores[p[0].id.uuidString]?.total, 40)
    }

    func testClampsOutOfRangeAndDropsBadIndex() throws {
        let p = panel(2)
        // 序号 3 越界应被丢弃;分数越界被夹到 0-10
        let text = #"{"scores":{"1":{"accuracy":99,"completeness":-5,"actionability":6,"clarity":9},"3":{"accuracy":5,"completeness":5,"actionability":5,"clarity":5}}}"#
        let vote = try XCTUnwrap(PromptBuilders.parseCouncilVote(from: text, panel: p))
        XCTAssertEqual(vote.scores.count, 1)
        let s = try XCTUnwrap(vote.scores[p[0].id.uuidString])
        XCTAssertEqual(s.accuracy, 10)
        XCTAssertEqual(s.completeness, 0)
    }

    func testReturnsNilOnGarbage() {
        XCTAssertNil(PromptBuilders.parseCouncilVote(from: "完全不是 JSON", panel: panel(2)))
    }
}
