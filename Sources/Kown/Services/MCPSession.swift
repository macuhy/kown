import Foundation

/// 一次用户发送内的 MCP 工具会话快照:持有已连接的 server 连接 + 命名空间化工具列表 + 路由表。
/// 在发送的后台任务里通过 `connect(servers:)` 建立,经 `ToolContext.mcp` 传给 `ToolRouter`,
/// 工具循环结束后 `closeAll()` 释放(stdio 子进程退出)。
struct MCPSession: Sendable {
    /// 工具命名空间前缀:`mcp__<slug>__<tool>`,把 MCP 工具和内建工具区分开,防撞名。
    static let namespacePrefix = "mcp__"

    /// slug → 连接。
    let connections: [String: MCPConnection]
    /// 暴露给模型的命名空间化工具(可空,但连接成功通常非空)。
    let tools: [LLMTool]
    /// 命名空间名 → (slug, 原始工具名),供 `callTool` 反查连接 + 还原工具名。
    let routes: [String: (slug: String, original: String)]

    static func isMCPTool(_ name: String) -> Bool { name.hasPrefix(namespacePrefix) }

    /// 连接全部 server,聚合工具。单个 server 失败只跳过它,不影响其它(返回的工具仍可用)。
    /// 全部失败 / 没有 server 返回 nil。
    static func connect(servers: [MCPServerConfig]) async -> MCPSession? {
        guard !servers.isEmpty else { return nil }
        var connections: [String: MCPConnection] = [:]
        var tools: [LLMTool] = []
        var routes: [String: (slug: String, original: String)] = [:]
        for server in servers {
            let conn = MCPConnection(config: server)
            do {
                let (serverTools, serverRoutes) = try await withTimeout(seconds: 25) {
                    try await conn.connectAndListTools()
                }
                guard !serverTools.isEmpty else { await conn.close(); continue }
                connections[server.slug] = conn
                tools.append(contentsOf: serverTools)
                for (ns, original) in serverRoutes {
                    routes[ns] = (slug: server.slug, original: original)
                }
            } catch {
                await conn.close()
                // 单个 server 连不上 / 没工具:静默跳过,不打断本次发送。
            }
        }
        guard !connections.isEmpty else { return nil }
        return MCPSession(connections: connections, tools: tools, routes: routes)
    }

    /// 执行一次 MCP 工具调用(`call.name` 是命名空间名)。失败返回 isError 的 ToolResult,绝不抛错。
    func callTool(_ call: ToolCall) async -> ToolResult {
        guard let route = routes[call.name], let conn = connections[route.slug] else {
            return ToolResult(callID: call.id, name: call.name,
                              content: #"{"error":"unknown MCP tool"}"#,
                              summary: "⚠ 未知 MCP 工具: \(call.name)", isError: true)
        }
        do {
            let (content, isError) = try await withTimeout(seconds: 60) {
                try await conn.call(originalName: route.original, argumentsJSON: call.argumentsJSON)
            }
            let summary = isError
                ? "⚠ \(route.original) 失败"
                : "✓ \(route.original)"
            return ToolResult(callID: call.id, name: call.name, content: content,
                              summary: summary, isError: isError)
        } catch {
            let msg = error.localizedDescription
            return ToolResult(callID: call.id, name: call.name,
                              content: "{\"error\":\"\(msg)\"}",
                              summary: "⚠ \(route.original): \(msg)", isError: true)
        }
    }

    func closeAll() async {
        for conn in connections.values { await conn.close() }
    }
}
