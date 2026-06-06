import XCTest
@testable import Kown

/// 覆盖「答案差异分析」的解析逻辑:从小模型输出里抽出共識 / 分歧两组要点。
@MainActor
final class ConsensusParseTests: XCTestCase {

    func testParsesBothSections() {
        let raw = """
        共識:
        - 都认为应该先做缓存
        - 都建议加索引
        分歧:
        - 甲主张用 Redis,乙主张用本地缓存
        """
        let r = ConsensusAnalyzer.parse(raw)
        XCTAssertEqual(r?.agreements, ["都认为应该先做缓存", "都建议加索引"])
        XCTAssertEqual(r?.disagreements, ["甲主张用 Redis,乙主张用本地缓存"])
    }

    func testSimplifiedAndTraditionalHeaders() {
        // 「共识」(简体)与「共識」(繁体)都应识别。
        let raw = "共识:\n1. 一致点A\n分歧:\n2. 分歧点B"
        let r = ConsensusAnalyzer.parse(raw)
        XCTAssertEqual(r?.agreements, ["一致点A"])
        XCTAssertEqual(r?.disagreements, ["分歧点B"])
    }

    func testSkipsNoneMarkers() {
        let raw = "共識:\n无\n分歧:\n- 真的分歧"
        let r = ConsensusAnalyzer.parse(raw)
        XCTAssertEqual(r?.agreements, [])
        XCTAssertEqual(r?.disagreements, ["真的分歧"])
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ConsensusAnalyzer.parse("   "))
    }

    func testNoRecognizableContentReturnsNil() {
        // 没有任何分区标题、也没有归到分区的条目 → nil。
        XCTAssertNil(ConsensusAnalyzer.parse("随便一段没有结构的文字"))
    }

    func testOnlyAgreementsStillValid() {
        let r = ConsensusAnalyzer.parse("共識:\n- 唯一一致点")
        XCTAssertEqual(r?.agreements, ["唯一一致点"])
        XCTAssertEqual(r?.disagreements, [])
    }
}
