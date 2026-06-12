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

    // MARK: - 结构化 JSON 解析

    func testParsesStructuredJSON() {
        let raw = """
        {
          "agreementScore": 82,
          "agreements": ["都建议先加缓存", "都认为要建索引"],
          "disagreements": [
            {"point": "缓存选型", "positions": [
              {"model": "甲", "stance": "用 Redis"},
              {"model": "乙", "stance": "用本地内存"}
            ]}
          ]
        }
        """
        let r = ConsensusAnalyzer.parseStructured(raw)
        XCTAssertEqual(r?.agreementScore, 82)
        XCTAssertEqual(r?.agreements, ["都建议先加缓存", "都认为要建索引"])
        XCTAssertEqual(r?.disagreementPoints?.count, 1)
        XCTAssertEqual(r?.disagreementPoints?.first?.point, "缓存选型")
        XCTAssertEqual(r?.disagreementPoints?.first?.positions.count, 2)
        XCTAssertEqual(r?.disagreementPoints?.first?.positions.first?.model, "甲")
        // 纯文本 disagreements 由结构化合成,旧 UI / 导出仍可消费。
        XCTAssertEqual(r?.disagreements.count, 1)
        XCTAssertTrue(r?.disagreements.first?.contains("甲:用 Redis") ?? false)
    }

    func testStructuredJSONWithCodeFenceAndPreamble() {
        // 模型常在 JSON 前后加解释 / 代码围栏 — extractJSONObject 要能抠出来。
        let raw = """
        好的,分析如下:
        ```json
        {"agreementScore": 50, "agreements": ["一致点"], "disagreements": []}
        ```
        """
        let r = ConsensusAnalyzer.parseStructured(raw)
        XCTAssertEqual(r?.agreementScore, 50)
        XCTAssertEqual(r?.agreements, ["一致点"])
        XCTAssertNil(r?.disagreementPoints)  // 空数组 → nil
    }

    func testStructuredScoreClampedAndStringTolerated() {
        // 越界裁剪 + 字符串数字容错。
        let over = ConsensusAnalyzer.parseStructured(
            #"{"agreementScore": 150, "agreements": ["x"], "disagreements": []}"#)
        XCTAssertEqual(over?.agreementScore, 100)
        let str = ConsensusAnalyzer.parseStructured(
            #"{"agreementScore": "30", "agreements": ["x"], "disagreements": []}"#)
        XCTAssertEqual(str?.agreementScore, 30)
    }

    func testStructuredMissingScoreStillParses() {
        // 缺 agreementScore:score 为 nil 但仍解析出内容(退化为无徽章视图)。
        let r = ConsensusAnalyzer.parseStructured(
            #"{"agreements": ["a"], "disagreements": []}"#)
        XCTAssertNil(r?.agreementScore)
        XCTAssertEqual(r?.agreements, ["a"])
    }

    func testStructuredEmptyContentReturnsNil() {
        // 既无共識也无分歧 → nil(由调用点退回纯文本路径)。
        XCTAssertNil(ConsensusAnalyzer.parseStructured(
            #"{"agreementScore": 60, "agreements": [], "disagreements": []}"#))
    }

    func testNonJSONFallsThroughStructuredToNil() {
        // 非 JSON → parseStructured 返回 nil(analyze 会再走纯文本 parse)。
        XCTAssertNil(ConsensusAnalyzer.parseStructured("共識:\n- 一致点\n分歧:\n- 分歧点"))
        // 而纯文本 parse 仍能处理它。
        XCTAssertNotNil(ConsensusAnalyzer.parse("共識:\n- 一致点\n分歧:\n- 分歧点"))
    }
}
