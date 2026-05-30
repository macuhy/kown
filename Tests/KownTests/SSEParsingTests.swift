import XCTest
@testable import Kown

/// 覆盖 SSE 行解析,重点是 **CRLF(`\r\n`)事件边界** —— 0.6.6 踩过的严重 bug:
/// Gemini 用 `\r\n\r\n` 分隔事件,若不先去掉行尾 `\r` 再判空行,所有 data 会累到流末尾
/// 合成一个大事件,JSON 解析失败 → 空响应。
final class SSEParsingTests: XCTestCase {

    /// 用 `SSELineStream.consumeLine` 重放一段 SSE 文本(模拟 iterator:每个 `\n` 触发一次,
    /// 最后一个 `\n` 之后的残段不处理)。
    private func events(from sse: String) -> [SSEEvent] {
        var pendingEvent: String?
        var pendingData: [String] = []
        var out: [SSEEvent] = []
        for raw in sse.components(separatedBy: "\n").dropLast() {
            if let e = SSELineStream.consumeLine(String(raw),
                                                 pendingEvent: &pendingEvent,
                                                 pendingData: &pendingData) {
                out.append(e)
            }
        }
        return out
    }

    func testCRLFEventBoundaries() {
        // Gemini 风格:每个事件用 \r\n\r\n 分隔
        let sse = "data: {\"a\":1}\r\n\r\ndata: {\"b\":2}\r\n\r\n"
        let evts = events(from: sse)
        XCTAssertEqual(evts.count, 2, "CRLF 分隔的两个事件都应被识别")
        XCTAssertEqual(evts[0].data, "{\"a\":1}")
        XCTAssertEqual(evts[1].data, "{\"b\":2}")
    }

    func testLFOnlyBoundary() {
        let evts = events(from: "data: hello\n\n")
        XCTAssertEqual(evts.count, 1)
        XCTAssertEqual(evts[0].data, "hello")
    }

    func testMultipleDataLinesJoined() {
        let evts = events(from: "data: a\ndata: b\n\n")
        XCTAssertEqual(evts.count, 1)
        XCTAssertEqual(evts[0].data, "a\nb")
    }

    func testCommentLinesIgnored() {
        let evts = events(from: ": keep-alive ping\r\ndata: x\r\n\r\n")
        XCTAssertEqual(evts.count, 1)
        XCTAssertEqual(evts[0].data, "x")
    }

    func testEventField() {
        let evts = events(from: "event: message\ndata: payload\n\n")
        XCTAssertEqual(evts.count, 1)
        XCTAssertEqual(evts[0].event, "message")
        XCTAssertEqual(evts[0].data, "payload")
    }

    func testBlankLineWithoutDataDoesNotEmit() {
        // 纯空行、无累积 → 不产出事件
        let evts = events(from: "\r\n\r\n\r\n")
        XCTAssertEqual(evts.count, 0)
    }
}
