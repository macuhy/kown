import Foundation
import CryptoKit

/// 微软 Edge「大声朗读」TTS。免 key、免费、神经语音。
/// 走逆向出来的 websocket 端点(非官方),失效时上层会回退系统语音。
/// 协议:连上后先发 speech.config,再发 ssml;服务端以 binary 帧回 mp3 音频,
/// 每帧前 2 字节是大端 header 长度;收到文本帧 `Path:turn.end` 表示结束。
struct EdgeTTSEngine {
    private static let trustedToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let secMSGECVersion = "1-130.0.2849.68"
    private static let baseURL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"

    func synthesize(text: String, voice: String, ratePercent: Int) async throws -> Data {
        let token = Self.secMSGEC()
        var comps = URLComponents(string: Self.baseURL)!
        comps.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: Self.trustedToken),
            URLQueryItem(name: "Sec-MS-GEC", value: token),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: Self.secMSGECVersion),
        ]
        guard let url = comps.url else { throw TTSError.network("Edge URL 构造失败") }

        var req = URLRequest(url: url)
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0",
                     forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: req)
        ws.resume()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        try await ws.send(.string(Self.configMessage()))
        try await ws.send(.string(Self.ssmlMessage(text: text, voice: voice, ratePercent: ratePercent)))

        var audio = Data()
        // 收帧直到 turn.end。整体兜底超时由调用方的 Task 取消负责;这里再设一个保底帧数上限。
        while true {
            let message = try await ws.receive()
            switch message {
            case .data(let data):
                if let chunk = Self.extractAudio(from: data) {
                    audio.append(chunk)
                }
            case .string(let text):
                if text.contains("Path:turn.end") {
                    if audio.isEmpty { throw TTSError.empty }
                    return audio
                }
            @unknown default:
                break
            }
        }
    }

    // MARK: - 帧解析

    /// binary 帧:前 2 字节大端 = header 长度,header 内含 `Path:audio`,其后为 mp3 字节。
    private static func extractAudio(from data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let headerLen = Int(data[0]) << 8 | Int(data[1])
        let bodyStart = 2 + headerLen
        guard bodyStart <= data.count else { return nil }
        let header = String(data: data.subdata(in: 2..<bodyStart), encoding: .utf8) ?? ""
        guard header.contains("Path:audio") else { return nil }
        guard bodyStart < data.count else { return nil }
        return data.subdata(in: bodyStart..<data.count)
    }

    // MARK: - 出站消息

    private static func configMessage() -> String {
        let config = "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"\(NeuralTTS.outputFormat)\"}}}}"
        return "X-Timestamp:\(timestamp())\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n\(config)"
    }

    private static func ssmlMessage(text: String, voice: String, ratePercent: Int) -> String {
        let ssml = NeuralTTS.ssml(text: text, voice: voice, ratePercent: ratePercent)
        let reqID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "X-RequestId:\(reqID)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp())\r\nPath:ssml\r\n\r\n\(ssml)"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return f.string(from: Date())
    }

    // MARK: - Sec-MS-GEC token

    /// token = SHA256( windowsFileTimeTicks(向下取整到 5 分钟) + trustedToken ),大写十六进制。
    private static func secMSGEC() -> String {
        let unix = Date().timeIntervalSince1970
        var ticks = Int64((unix + 11_644_473_600.0) * 10_000_000.0)
        ticks -= ticks % 3_000_000_000   // 5 分钟 = 3e9 个 100ns tick
        let toHash = "\(ticks)\(trustedToken)"
        let digest = SHA256.hash(data: Data(toHash.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }
}
