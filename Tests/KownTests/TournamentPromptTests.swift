import XCTest
@testable import Kown

/// 覆盖擂台/淘汰赛模式的纯逻辑:轮次标题、裁判判决 JSON 解析、对决 prompt 构造。
@MainActor
final class TournamentPromptTests: XCTestCase {

    func testRoundTitleFinal() {
        XCTAssertEqual(PromptBuilders.tournamentRoundTitle(matchCount: 1, isFinalRound: true), "决赛")
    }

    func testRoundTitleByMatchCount() {
        XCTAssertEqual(PromptBuilders.tournamentRoundTitle(matchCount: 2, isFinalRound: false), "半决赛")
        XCTAssertEqual(PromptBuilders.tournamentRoundTitle(matchCount: 3, isFinalRound: false), "四分之一决赛")
        XCTAssertEqual(PromptBuilders.tournamentRoundTitle(matchCount: 4, isFinalRound: false), "四分之一决赛")
        XCTAssertEqual(PromptBuilders.tournamentRoundTitle(matchCount: 8, isFinalRound: false), "晋级赛")
        XCTAssertEqual(PromptBuilders.tournamentRoundTitle(matchCount: 1, isFinalRound: false), "晋级赛")
    }

    func testParseVerdictWinnerA() {
        let v = PromptBuilders.parseTournamentVerdict(from: #"{"winner":"A","rationale":"更准确"}"#)
        XCTAssertEqual(v?.winnerIsA, true)
        XCTAssertEqual(v?.rationale, "更准确")
    }

    func testParseVerdictWinnerB() {
        let v = PromptBuilders.parseTournamentVerdict(from: #"{"winner":"B","rationale":"更完整"}"#)
        XCTAssertEqual(v?.winnerIsA, false)
        XCTAssertEqual(v?.rationale, "更完整")
    }

    func testParseVerdictCaseInsensitiveAndFenced() {
        // 小写 + 带 ```json 围栏 + 前后说明,都应能解析。
        let text = "裁判结果:\n```json\n{\"winner\":\"a\",\"rationale\":\"x\"}\n```"
        let v = PromptBuilders.parseTournamentVerdict(from: text)
        XCTAssertEqual(v?.winnerIsA, true)
    }

    func testParseVerdictInvalidReturnsNil() {
        XCTAssertNil(PromptBuilders.parseTournamentVerdict(from: "平局了,不分胜负"))
        XCTAssertNil(PromptBuilders.parseTournamentVerdict(from: #"{"winner":"C","rationale":"x"}"#))
    }

    func testBuildMatchPromptContainsLabelsAndForcesJSON() {
        let p = PromptBuilders.buildTournamentMatchPrompt(
            originalPrompt: "怎么排序?",
            aLabel: "模型甲", aResponse: "用快排", aError: nil,
            bLabel: "模型乙", bResponse: "用归并", bError: nil
        )
        XCTAssertTrue(p.contains("模型甲"))
        XCTAssertTrue(p.contains("模型乙"))
        XCTAssertTrue(p.contains("怎么排序?"))
        XCTAssertTrue(p.contains("winner"))
    }

    func testBuildMatchPromptHandlesError() {
        let p = PromptBuilders.buildTournamentMatchPrompt(
            originalPrompt: "Q",
            aLabel: "甲", aResponse: "", aError: "超时",
            bLabel: "乙", bResponse: "答案", bError: nil
        )
        XCTAssertTrue(p.contains("超时"))
    }
}
