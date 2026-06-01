import Foundation

/// 神经语音 TTS 共用工具:SSML 构造 + 输出格式。
enum NeuralTTS {
    /// 微软两端(Edge / Azure)统一的 mp3 输出格式。
    static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"

    static func ssml(text: String, voice: String, ratePercent: Int) -> String {
        // voice 形如 "zh-CN-XiaoxiaoNeural" → lang 取前两段 "zh-CN"。
        let parts = voice.split(separator: "-")
        let lang = parts.count >= 2 ? "\(parts[0])-\(parts[1])" : "zh-CN"
        let rate = ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%"
        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='\(lang)'>"
            + "<voice name='\(voice)'><prosody rate='\(rate)' pitch='+0Hz'>\(xmlEscape(text))</prosody></voice></speak>"
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Azure 官方 TTS(REST)。需要 subscription key + region。返回 mp3 字节。
struct AzureTTSEngine {
    let region: String
    let key: String

    func synthesize(text: String, voice: String, ratePercent: Int) async throws -> Data {
        let urlString = "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1"
        guard let url = URL(string: urlString) else {
            throw TTSError.notConfigured("Azure region 无效: \(region)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        req.setValue(NeuralTTS.outputFormat, forHTTPHeaderField: "X-Microsoft-OutputFormat")
        req.setValue("kown", forHTTPHeaderField: "User-Agent")
        req.httpBody = NeuralTTS.ssml(text: text, voice: voice, ratePercent: ratePercent).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw TTSError.network("Azure HTTP \(http.statusCode) \(body)")
        }
        guard !data.isEmpty else { throw TTSError.empty }
        return data
    }
}
