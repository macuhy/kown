import Foundation

/// 单条搜索结果。
struct FirecrawlSearchHit: Sendable, Codable {
    let title: String
    let url: String
    let description: String
}

/// 抓取一个 URL 的结果。
struct FirecrawlScrape: Sendable {
    let title: String
    let markdown: String
}

/// Firecrawl SaaS 的轻量封装 — /v1/search + /v1/scrape。
struct FirecrawlClient: Sendable {
    let baseURL: String
    let apiKey: String

    /// 抓取单个网页正文为 markdown(/v1/scrape)。供「抓取链接入上下文」用。
    func scrape(url pageURL: String) async throws -> FirecrawlScrape {
        let urlString = joinURL(baseURL, "/v1/scrape")
        guard let url = URL(string: urlString) else { throw LLMError.badURL(urlString) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": pageURL,
            "formats": ["markdown"]
        ])
        req.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.httpError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("Firecrawl: 非 JSON 响应")
        }
        if let success = json["success"] as? Bool, success == false {
            throw LLMError.httpError(status: -1, body: (json["error"] as? String) ?? "Firecrawl 抓取失败")
        }
        let dataObj = (json["data"] as? [String: Any]) ?? [:]
        let markdown = (dataObj["markdown"] as? String) ?? ""
        let meta = (dataObj["metadata"] as? [String: Any]) ?? [:]
        let title = (meta["title"] as? String) ?? pageURL
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.decoding("Firecrawl: 没抓到正文")
        }
        return FirecrawlScrape(title: title, markdown: markdown)
    }

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
