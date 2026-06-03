import Foundation

/// OpenAI 兼容的图像生成(/images/generations)。OpenAI(gpt-image / DALL·E)、硅基流动等都兼容。
/// 返回若干张图片的原始字节(png)。
enum ImageGenerationClient {
    static func generate(baseURL: String, apiKey: String, model: String,
                         prompt: String, size: String = "1024x1024") async throws -> [Data] {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + "/images/generations") else {
            throw NSError(domain: "ImageGen", code: -1, userInfo: [NSLocalizedDescriptionKey: "图像生成 URL 无效"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        let body: [String: Any] = [
            "model": model, "prompt": prompt, "n": 1, "size": size, "response_format": "b64_json"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ImageGen", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "图像生成失败(HTTP \(http.statusCode)):\(msg.prefix(300))"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            throw NSError(domain: "ImageGen", code: -2, userInfo: [NSLocalizedDescriptionKey: "图像生成返回格式异常"])
        }
        var out: [Data] = []
        for item in arr {
            if let b64 = item["b64_json"] as? String, let d = Data(base64Encoded: b64) {
                out.append(d)
            } else if let urlStr = item["url"] as? String, let u = URL(string: urlStr),
                      let d = try? await URLSession.shared.data(from: u).0 {
                out.append(d)
            }
        }
        guard !out.isEmpty else {
            throw NSError(domain: "ImageGen", code: -3, userInfo: [NSLocalizedDescriptionKey: "未返回图片"])
        }
        return out
    }
}
