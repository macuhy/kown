import Foundation

/// 表盘端的极简 Firecrawl /v1/search 封装。
/// 表盘是独立 module,用不到主 App 的 `FirecrawlClient`,这里只取「搜索」这一条最小路径,
/// 命中结果会被拼进 prompt 当参考资料,再交给 `WatchChatClient` 流式回答。
struct WatchWebSearch {
    let baseURL: String
    let apiKey: String

    struct Hit: Sendable {
        let title: String
        let url: String
        let snippet: String
    }

    /// 搜索 query,返回至多 `limit` 条命中。失败抛错(调用方降级为不联网)。
    func search(query: String, limit: Int = 3) async throws -> [Hit] {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + "/v1/search") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "limit": max(1, min(limit, 10))
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if let success = json["success"] as? Bool, success == false {
            throw URLError(.badServerResponse)
        }
        let raw = (json["data"] as? [[String: Any]]) ?? []
        return raw.compactMap { item in
            guard let url = item["url"] as? String else { return nil }
            let title = (item["title"] as? String) ?? url
            let snippet = (item["description"] as? String)
                ?? (item["content"] as? String)
                ?? ""
            return Hit(title: title, url: url, snippet: snippet)
        }
    }
}
