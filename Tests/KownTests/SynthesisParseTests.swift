import XCTest
@testable import Kown

/// 覆盖合成终稿的解析:【合成说明】/【最优答案】两段抽取 + 容错。
final class SynthesisParseTests: XCTestCase {

    func testParsesBothSections() {
        let raw = """
        【合成说明】综合了 A 的结构与 B 的数据,分歧处取 B。
        【最优答案】这是最终答案正文。
        """
        let result = SynthesisService.parse(raw)
        XCTAssertEqual(result?.rationale, "综合了 A 的结构与 B 的数据,分歧处取 B。")
        XCTAssertEqual(result?.text, "这是最终答案正文。")
    }

    func testNoMarkersTreatsAllAsAnswer() {
        let result = SynthesisService.parse("没有任何标记的一整段答案")
        XCTAssertEqual(result?.text, "没有任何标记的一整段答案")
        XCTAssertEqual(result?.rationale, "")
    }

    func testAnswerOnlyWithoutRationale() {
        let result = SynthesisService.parse("【最优答案】只有答案没有说明")
        XCTAssertEqual(result?.text, "只有答案没有说明")
        XCTAssertEqual(result?.rationale, "")
    }

    func testTraditionalMarkers() {
        let raw = "【合成說明】說明\n【最優答案】繁體答案"
        let result = SynthesisService.parse(raw)
        XCTAssertEqual(result?.rationale, "說明")
        XCTAssertEqual(result?.text, "繁體答案")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(SynthesisService.parse("   \n  "))
    }

    func testEmptyAnswerAfterMarkerReturnsNil() {
        // 有说明但答案为空 → 视为无效。
        XCTAssertNil(SynthesisService.parse("【合成说明】只有说明\n【最优答案】"))
    }
}
