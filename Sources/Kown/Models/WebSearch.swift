import Foundation

/// Firecrawl 配置(非密钥部分)。
struct WebSearchConfig: Codable, Hashable, Sendable {
    /// 全局开关 — 关闭时,即使输入栏 🌐 被打开也不会注入工具。
    var enabled: Bool
    /// Firecrawl API base,例如 https://api.firecrawl.dev
    var baseURL: String
    /// /v1/search 拉取条数。
    var resultLimit: Int

    static let defaultConfig = WebSearchConfig(
        enabled: false,
        baseURL: "https://api.firecrawl.dev",
        resultLimit: 5
    )
}

@MainActor
enum WebSearchConfigStore {
    private static var configURL: URL {
        Platform.syncedDataDir.appendingPathComponent("web_search.json")
    }

    static func load() -> WebSearchConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(WebSearchConfig.self, from: data)
        else { return .defaultConfig }
        return cfg
    }

    static func save(_ cfg: WebSearchConfig) {
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        try? data.write(to: configURL, options: .atomic)
    }
}

/// Firecrawl key 走 `KeychainStore`,固定 id,避免与 provider id 冲突。
@MainActor
enum WebSearchKey {
    static let id = UUID(uuidString: "D8A6E1F7-9C4B-4F3A-B521-7E2C18A3F940")!

    static func save(_ key: String) throws {
        try KeychainStore.save(id: id, apiKey: key)
    }

    static func load() throws -> String {
        try KeychainStore.load(id: id)
    }

    static func hasKey() -> Bool {
        KeychainStore.hasKey(id: id)
    }

    static func delete() {
        KeychainStore.delete(id: id)
    }
}
