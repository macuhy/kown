import XCTest
@testable import Kown

/// 覆盖 `ToolRouter.sources(from:)` —— web_search 引用来源解析(0.9.0 接通的那条链)。
/// 这是会驱动「回答下方引用卡片」的纯函数,容易随 JSON 字段名/去重逻辑回归。
final class ToolSourcesTests: XCTestCase {

    private func result(content: String, name: String = "web_search", isError: Bool = false) -> ToolResult {
        ToolResult(callID: "1", name: name, content: content, summary: "", isError: isError)
    }

    func testParsesAndDedupsByURL() {
        let json = #"""
        {"results":[
          {"title":"A","url":"https://a.com","snippet":"sa"},
          {"title":"B","url":"https://b.com","snippet":"sb"},
          {"title":"A dup","url":"https://a.com","snippet":"dup"}
        ]}
        """#
        let refs = ToolRouter.sources(from: result(content: json))
        XCTAssertEqual(refs.count, 2, "同一 url 应去重")
        XCTAssertEqual(refs.map(\.url), ["https://a.com", "https://b.com"])
        XCTAssertEqual(refs.first?.title, "A")
    }

    func testNonWebSearchReturnsEmpty() {
        XCTAssertTrue(ToolRouter.sources(from: result(content: #"{"results":[{"url":"https://a.com"}]}"#, name: "other")).isEmpty)
    }

    func testErrorResultReturnsEmpty() {
        XCTAssertTrue(ToolRouter.sources(from: result(content: #"{"results":[{"url":"https://a.com"}]}"#, isError: true)).isEmpty)
    }

    func testMalformedContentReturnsEmpty() {
        XCTAssertTrue(ToolRouter.sources(from: result(content: "not json")).isEmpty)
        XCTAssertTrue(ToolRouter.sources(from: result(content: #"{"nope":1}"#)).isEmpty)
    }

    func testSkipsEntriesWithoutURL() {
        let json = #"{"results":[{"title":"no url"},{"title":"ok","url":"https://ok.com"}]}"#
        let refs = ToolRouter.sources(from: result(content: json))
        XCTAssertEqual(refs.map(\.url), ["https://ok.com"])
    }
}
