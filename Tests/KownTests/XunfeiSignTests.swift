import XCTest
@testable import Kown

/// 锁住讯飞鉴权算法 —— 期望值由验证过能握手成功(101)的参考实现(Python)用同一套**假**凭证算出。
/// 若 Swift 实现跑偏(HMAC 串、authorization 格式、URL 编码),这里会立刻红。
final class XunfeiSignTests: XCTestCase {
    // 假凭证 + 固定时间,保证可复现(不含真实 key)。
    private let apiSecret = "test-secret-123"
    private let apiKey = "test-key-456"
    private let host = "tts-api.xfyun.cn"
    private let path = "/v2/tts"
    private let date = "Mon, 01 Jun 2026 10:00:00 GMT"

    func testSignatureMatchesReference() {
        let sig = XunfeiTTSEngine.signature(apiSecret: apiSecret, host: host, path: path, date: date)
        XCTAssertEqual(sig, "TsRLqf/XCoSp5Qg611OrkJU5y0fkTLqTkC9nOdlOv6k=")
    }

    func testAuthorizationMatchesReference() {
        let sig = XunfeiTTSEngine.signature(apiSecret: apiSecret, host: host, path: path, date: date)
        let auth = XunfeiTTSEngine.authorization(apiKey: apiKey, signature: sig)
        XCTAssertEqual(auth,
            "YXBpX2tleT0idGVzdC1rZXktNDU2IiwgYWxnb3JpdGhtPSJobWFjLXNoYTI1NiIsIGhlYWRlcnM9Imhvc3QgZGF0ZSByZXF1ZXN0LWxpbmUiLCBzaWduYXR1cmU9IlRzUkxxZi9YQ29TcDVRZzYxMU9ya0pVNXkwZmtUTHFUa0M5bk9kbE92Nms9Ig==")
    }

    func testSignedURLIsWSSWithEncodedQuery() throws {
        let url = try XCTUnwrap(XunfeiTTSEngine.signedURL(
            host: host, path: path, apiKey: apiKey, apiSecret: apiSecret, date: date))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, host)
        XCTAssertEqual(url.path, path)
        let q = try XCTUnwrap(url.query)
        XCTAssertTrue(q.contains("authorization="))
        XCTAssertTrue(q.contains("date="))
        XCTAssertTrue(q.contains("host="))
        // base64 的 +/= 必须被百分号编码,空格 / 冒号 / 逗号也要(否则签名串对不上 / URL 非法)
        XCTAssertFalse(q.contains(" "))
        XCTAssertFalse(q.contains("+"))
    }
}
