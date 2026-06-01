import Foundation
import CryptoKit

/// 讯飞在线语音合成(v2/tts)。WebSocket + HMAC-SHA256 鉴权,`aue=lame` 直接回 mp3。
/// 需要三件凭证:APPID / APIKey / APISecret(讯飞开放平台「在线语音合成」应用)。
struct XunfeiTTSEngine {
    let appID: String
    let apiKey: String
    let apiSecret: String

    private static let host = "tts-api.xfyun.cn"
    private static let path = "/v2/tts"

    /// voice = 发音人 vcn(如 xiaoyan);ratePercent → 讯飞 speed(0~100,默认 50)。
    func synthesize(text: String, voice: String, ratePercent: Int) async throws -> Data {
        guard !appID.isEmpty, !apiKey.isEmpty, !apiSecret.isEmpty else {
            throw TTSError.notConfigured("讯飞需要 APPID / APIKey / APISecret(设置 ▸ 朗读)")
        }
        guard let url = Self.signedURL(host: Self.host, path: Self.path,
                                       apiKey: apiKey, apiSecret: apiSecret, date: Self.rfc1123Date()) else {
            throw TTSError.network("讯飞 URL 构造失败")
        }

        // 不手动设 Host(URLSessionWebSocketTask 自己管握手头;手动设会干扰)。
        let req = URLRequest(url: url)
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: req)
        ws.resume()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        // 发送一帧完整文本(status=2 表示一次性送完)
        try await ws.send(.string(frame(text: text, voice: voice, ratePercent: ratePercent)))

        var audio = Data()
        while true {
            let message = try await ws.receive()
            let json: [String: Any]
            switch message {
            case .string(let s):
                json = (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
            case .data(let d):
                json = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            @unknown default:
                continue
            }
            if let code = json["code"] as? Int, code != 0 {
                let msg = json["message"] as? String ?? "未知错误"
                throw TTSError.network("讯飞错误 code=\(code) \(msg)")
            }
            if let data = json["data"] as? [String: Any] {
                if let b64 = data["audio"] as? String, let chunk = Data(base64Encoded: b64) {
                    audio.append(chunk)
                }
                if let status = data["status"] as? Int, status == 2 {
                    break   // 最后一帧
                }
            }
        }
        guard !audio.isEmpty else { throw TTSError.empty }
        return audio
    }

    // MARK: - 鉴权(静态纯函数,便于单测)

    /// HMAC-SHA256 签名(base64)。签名串:`host: <host>\ndate: <date>\nGET <path> HTTP/1.1`。
    static func signature(apiSecret: String, host: String, path: String, date: String) -> String {
        let origin = "host: \(host)\ndate: \(date)\nGET \(path) HTTP/1.1"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(origin.utf8), using: SymmetricKey(data: Data(apiSecret.utf8)))
        return Data(mac).base64EncodedString()
    }

    /// authorization 参数(base64 of `api_key="…", algorithm="hmac-sha256", headers="host date request-line", signature="…"`)。
    static func authorization(apiKey: String, signature: String) -> String {
        let origin = "api_key=\"\(apiKey)\", algorithm=\"hmac-sha256\", headers=\"host date request-line\", signature=\"\(signature)\""
        return Data(origin.utf8).base64EncodedString()
    }

    /// 拼出带鉴权 query 的 wss URL。用 percentEncodedQuery 锁死编码,避免 URLSession 二次规范化。
    static func signedURL(host: String, path: String, apiKey: String, apiSecret: String, date: String) -> URL? {
        let sig = signature(apiSecret: apiSecret, host: host, path: path, date: date)
        let auth = authorization(apiKey: apiKey, signature: sig)
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = host
        comps.path = path
        comps.percentEncodedQuery = "authorization=\(enc(auth))&date=\(enc(date))&host=\(enc(host))"
        return comps.url
    }

    private func frame(text: String, voice: String, ratePercent: Int) -> String {
        let speed = max(0, min(100, 50 + ratePercent))
        let textB64 = Data(text.utf8).base64EncodedString()
        let payload: [String: Any] = [
            "common": ["app_id": appID],
            "business": [
                "aue": "lame",            // mp3 输出
                "sfl": 1,                 // 流式 mp3
                "vcn": voice,
                "speed": speed,
                "volume": 50,
                "pitch": 50,
                "tte": "UTF8",
            ],
            "data": [
                "status": 2,
                "text": textB64,
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func rfc1123Date() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: Date())
    }
}
