import Foundation

/// 已挂载的 MCP server 配置的持久化与增删改查。
///
/// 存盘沿用 `SkillsStore` 约定:Application Support 下 App 专属子目录的一个 JSON 文件,
/// JSONEncoder/JSONDecoder 编解码、日期 `.iso8601`。本地库,不另起 iCloud 容器。
@Observable
final class MCPStore {
    private(set) var servers: [MCPServerConfig] = []

    private let storeURL: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Kown", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("mcp_servers.json")
        load()
    }

    /// 已启用的 server —— 发送时只连接这些。
    var enabledServers: [MCPServerConfig] { servers.filter { $0.enabled } }

    @discardableResult
    func add(_ server: MCPServerConfig) -> MCPServerConfig {
        servers.insert(server, at: 0)
        save()
        return server
    }

    func update(_ server: MCPServerConfig) {
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx] = server
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].enabled = enabled
        save()
    }

    func remove(_ server: MCPServerConfig) {
        servers.removeAll { $0.id == server.id }
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([MCPServerConfig].self, from: data) else { return }
        servers = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(servers) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
