import Foundation

/// 一个外部 MCP(Model Context Protocol)server 的配置。
///
/// MCP 让用户把任意第三方工具(数据库 / 浏览器 / Figma / 自建服务……)挂进 Kown:
/// server 通过 `tools/list` 声明它能干什么,模型在工具循环里通过 `tools/call` 调用。
/// 两种传输:远程 `http`(Streamable HTTP / SSE,iOS+macOS 都能用)、本地 `stdio`
/// (用 `Process` 启动一个本地命令,仅 macOS——iOS 沙箱起不了子进程)。
struct MCPServerConfig: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// 展示名,同时作为工具命名空间来源(`mcp__<slug>__<tool>`,防撞内建工具名)。
    var name: String
    var enabled: Bool
    var transport: MCPTransport
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         enabled: Bool = true,
         transport: MCPTransport,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.transport = transport
        self.createdAt = createdAt
    }

    /// 命名空间 slug:小写、只留 `[a-z0-9_]`,空则回退到 id 前 6 位。用于工具名前缀。
    var slug: String { Self.makeSlug(name, fallback: id.uuidString) }

    static func makeSlug(_ name: String, fallback: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("_") }
        }
        // 折叠连续下划线
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if trimmed.isEmpty {
            return "srv" + fallback.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(6)
        }
        return trimmed
    }
}

/// MCP 传输方式。Codable 由编译器自动合成(枚举关联值)。
enum MCPTransport: Codable, Hashable, Sendable {
    /// 远程 Streamable HTTP / SSE 端点。`headers` 用于鉴权(如 Authorization: Bearer …)。
    case http(url: String, headers: [String: String])
    /// 本地 stdio 子进程(仅 macOS)。`command` 经 `/usr/bin/env` 解析 PATH。
    case stdio(command: String, args: [String], env: [String: String])

    var isHTTP: Bool { if case .http = self { return true }; return false }
    var isStdio: Bool { if case .stdio = self { return true }; return false }

    /// 一行人类可读摘要,用于设置页列表。
    var summary: String {
        switch self {
        case .http(let url, _): return url
        case .stdio(let command, let args, _):
            return ([command] + args).joined(separator: " ")
        }
    }
}
