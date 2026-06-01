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
        let url = try makeSignedURL()

        var req = URLRequest(url: url)
        req.setValue(Self.host, forHTTPHeaderField: "Host")
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

    // MARK: - 鉴权 URL

    private func makeSignedURL() throws -> URL {
        let date = Self.rfc1123Date()
        let signatureOrigin = "host: \(Self.host)\ndate: \(date)\nGET \(Self.path) HTTP/1.1"
        let sigKey = SymmetricKey(data: Data(apiSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signatureOrigin.utf8), using: sigKey)
        let signature = Data(mac).base64EncodedString()
        let authOrigin = "api_key=\"\(apiKey)\", algorithm=\"hmac-sha256\", headers=\"host date request-line\", signature=\"\(signature)\""
        let authorization = Data(authOrigin.utf8).base64EncodedString()

        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        let urlString = "wss://\(Self.host)\(Self.path)?authorization=\(enc(authorization))&date=\(enc(date))&host=\(enc(Self.host))"
        guard let url = URL(string: urlString) else {
            throw TTSError.network("讯飞 URL 构造失败")
        }
        return url
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
