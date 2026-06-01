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

/// 硅基流动 CosyVoice2 TTS(OpenAI 兼容 `/audio/speech`,国内直连,返回 mp3)。
struct SiliconFlowTTSEngine {
    let baseURL: String
    let key: String
    let model: String

    /// voiceName 是短名(如 "alex");请求里拼成 `model:name`。ratePercent → speed(0.25~4.0)。
    func synthesize(text: String, voiceName: String, ratePercent: Int) async throws -> Data {
        let urlString = joinURL(baseURL, "/audio/speech")
        guard let url = URL(string: urlString) else {
            throw TTSError.notConfigured("SiliconFlow URL 无效: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let speed = max(0.25, min(4.0, 1.0 + Double(ratePercent) / 100.0))
        let body: [String: Any] = [
            "model": model,
            "input": text,
            "voice": "\(model):\(voiceName)",
            "response_format": "mp3",
            "speed": speed,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw TTSError.network("SiliconFlow HTTP \(http.statusCode) \(preview)")
        }
        guard !data.isEmpty else { throw TTSError.empty }
        return data
    }
}
