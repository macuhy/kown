import Foundation

/// 单条搜索结果。
struct FirecrawlSearchHit: Sendable, Codable {
    let title: String
    let url: String
    let description: String
}

/// Firecrawl SaaS 的轻量封装 — 当前只实现 /v1/search。
struct FirecrawlClient: Sendable {
    let baseURL: String
    let apiKey: String

    func search(query: String, limit: Int) async throws -> [FirecrawlSearchHit] {
        let urlString = joinURL(baseURL, "/v1/search")
        guard let url = URL(string: urlString) else {
            throw LLMError.badURL(urlString)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "query": query,
            "limit": max(1, min(limit, 100))   // Firecrawl /v1/search 上限是 100
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(status: http.statusCode, body: body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("Firecrawl: 非 JSON 响应")
        }
        if let success = json["success"] as? Bool, success == false {
            let msg = (json["error"] as? String) ?? "Firecrawl 失败"
            throw LLMError.httpError(status: -1, body: msg)
        }
        let raw = (json["data"] as? [[String: Any]]) ?? []
        return raw.compactMap { item in
            guard let url = item["url"] as? String else { return nil }
            let title = (item["title"] as? String) ?? url
            let desc = (item["description"] as? String)
                ?? (item["content"] as? String)
                ?? ""
            return FirecrawlSearchHit(title: title, url: url, description: desc)
        }
    }
}
