import Foundation

/// 一个 MCP server 的单条连接。JSON-RPC 2.0:`initialize` → `notifications/initialized`
/// → `tools/list` → `tools/call`。两种传输各自实现 `rpc` / `notify`,上层逻辑共用。
///
/// actor 隔离:HTTP 的 sessionID / stdio 的子进程 + 读缓冲都是可变状态;一条连接同一时刻
/// 只处理一个 RPC(MCP 工具循环本就是串行调用),actor 天然满足。
actor MCPConnection {
    let serverName: String
    let slug: String
    private let transport: MCPTransport

    // HTTP 状态
    private var sessionID: String?
    // stdio 状态(仅 macOS)
    #if os(macOS)
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer: [UInt8] = []
    private static let readQueue = DispatchQueue(label: "kown.mcp.stdio.read", attributes: .concurrent)
    #endif

    private var nextID = 1

    init(config: MCPServerConfig) {
        self.serverName = config.name
        self.slug = config.slug
        self.transport = config.transport
    }

    // MARK: - 公开流程

    /// 连接 + 握手 + 拉工具。返回**命名空间化**的工具(`mcp__<slug>__<tool>`)+ 原始名映射。
    /// 任何一步失败抛错;调用方应捕获并跳过这个 server。超时由调用方用 `withTimeout` 包裹
    /// (这里不内置:`[String: Any]` 不是 Sendable,不能穿过 `@Sendable` 闭包的 actor 边界)。
    func connectAndListTools() async throws -> (tools: [LLMTool], routes: [String: String]) {
        try await startTransportIfNeeded()
        _ = try await rpc(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "Kown", "version": "1.0"]
        ])
        try await notify(method: "notifications/initialized", params: [:])
        let result = try await rpc(method: "tools/list", params: [:])
        let rawTools = (result["tools"] as? [[String: Any]]) ?? []
        var tools: [LLMTool] = []
        var routes: [String: String] = [:]   // 命名空间名 → 原始工具名
        for t in rawTools {
            guard let name = t["name"] as? String, !name.isEmpty else { continue }
            let desc = (t["description"] as? String) ?? name
            let schema = (t["inputSchema"] as? [String: Any]) ?? [:]
            let nsName = "\(MCPSession.namespacePrefix)\(slug)__\(name)"
            tools.append(LLMTool(
                name: nsName,
                description: desc,
                parameters: Self.mapInputSchema(schema)
            ))
            routes[nsName] = name
        }
        return (tools, routes)
    }

    /// 调用一个工具(`originalName` 已去命名空间)。返回给模型看的内容字符串 + 是否出错。
    /// 超时由调用方用 `withTimeout` 包裹。
    func call(originalName: String, argumentsJSON: String) async throws -> (content: String, isError: Bool) {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let result = try await rpc(method: "tools/call", params: [
            "name": originalName,
            "arguments": args
        ])
        // result.content 是 [{type:"text",text:"..."}] / image 等;把所有 text 拼起来给模型。
        let content = (result["content"] as? [[String: Any]]) ?? []
        var texts: [String] = []
        for block in content {
            if let text = block["text"] as? String { texts.append(text) }
            else if let type = block["type"] as? String { texts.append("[\(type) content]") }
        }
        let joined = texts.isEmpty ? Self.jsonString(result) : texts.joined(separator: "\n")
        let isError = (result["isError"] as? Bool) ?? false
        return (joined, isError)
    }

    func close() {
        #if os(macOS)
        stdinHandle?.closeFile()
        process?.terminate()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stdoutBuffer.removeAll()
        #endif
    }

    // MARK: - JSON-RPC

    private func rpc(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: body)
        switch transport {
        case .http:
            return try await httpSend(data, id: id, expectResponse: true) ?? [:]
        case .stdio:
            return try await stdioSend(data, id: id, expectResponse: true) ?? [:]
        }
    }

    private func notify(method: String, params: [String: Any]) async throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: body)
        switch transport {
        case .http:
            _ = try await httpSend(data, id: nil, expectResponse: false)
        case .stdio:
            _ = try await stdioSend(data, id: nil, expectResponse: false)
        }
    }

    // MARK: - HTTP (Streamable)

    private func startTransportIfNeeded() async throws {
        switch transport {
        case .http: break   // 无状态,握手即连接
        case .stdio: try startStdio()
        }
    }

    private func httpSend(_ requestData: Data, id: Int?, expectResponse: Bool) async throws -> [String: Any]? {
        guard case let .http(urlString, headers) = transport else { return nil }
        guard let url = URL(string: urlString) else { throw LLMError.badURL(urlString) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers where !k.isEmpty { req.setValue(v, forHTTPHeaderField: k) }
        if let sid = sessionID { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = requestData

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.httpError(status: 0, body: "no http response")
        }
        // 捕获并保留 server 分配的会话 id(后续请求回带)。
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
            sessionID = sid
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw LLMError.httpError(status: http.statusCode, body: body)
        }
        // 通知 / 无需回执:排空即可。
        if !expectResponse {
            for try await _ in bytes.lines { }
            return nil
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            // SSE:逐事件找到 id 匹配的 JSON-RPC 响应。
            for try await event in SSELineStream(bytes: bytes) {
                guard let data = event.data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let match = try Self.matchResponse(json, id: id) { return match }
            }
            throw LLMError.decoding("MCP SSE 未返回 id=\(id ?? -1) 的响应")
        } else {
            var buf = Data()
            for try await b in bytes { buf.append(b) }
            guard let json = try? JSONSerialization.jsonObject(with: buf) as? [String: Any] else {
                throw LLMError.decoding("MCP HTTP 响应不是 JSON")
            }
            return try Self.matchResponse(json, id: id) ?? [:]
        }
    }

    // MARK: - stdio (macOS only)

    private func startStdio() throws {
        #if os(macOS)
        guard process == nil else { return }
        guard case let .stdio(command, args, userEnv) = transport else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [command] + args
        // GUI app 的 launchd PATH 很瘦;补上常见安装位置,再叠加用户自定义 env。
        var env = ProcessInfo.processInfo.environment
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                          "\(home)/.local/bin", "\(home)/.npm-global/bin"]
        env["PATH"] = (extraPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        for (k, v) in userEnv where !k.isEmpty { env[k] = v }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe   // 排掉,免得子进程日志阻塞
        try p.run()
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        stdoutHandle = outPipe.fileHandleForReading
        #else
        throw LLMError.decoding("stdio MCP 仅 macOS 支持")
        #endif
    }

    private func stdioSend(_ requestData: Data, id: Int?, expectResponse: Bool) async throws -> [String: Any]? {
        #if os(macOS)
        guard let stdin = stdinHandle else { throw LLMError.decoding("MCP stdio 未启动") }
        var line = requestData
        line.append(0x0A)
        try stdin.write(contentsOf: line)
        guard expectResponse else { return nil }
        // 逐行读 stdout,跳过通知 / 不匹配的行,直到拿到 id 匹配的响应。
        while let raw = try await stdioReadLine() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let match = try Self.matchResponse(json, id: id) { return match }
        }
        throw LLMError.decoding("MCP stdio 进程在返回 id=\(id ?? -1) 前结束")
        #else
        throw LLMError.decoding("stdio MCP 仅 macOS 支持")
        #endif
    }

    #if os(macOS)
    private func stdioReadLine() async throws -> String? {
        while true {
            if let nl = stdoutBuffer.firstIndex(of: 0x0A) {
                let lineBytes = Array(stdoutBuffer[stdoutBuffer.startIndex..<nl])
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
                return String(decoding: lineBytes, as: UTF8.self)
            }
            guard let handle = stdoutHandle else { return nil }
            let chunk = await Self.readChunk(handle)
            if chunk.isEmpty {
                if stdoutBuffer.isEmpty { return nil }
                let s = String(decoding: stdoutBuffer, as: UTF8.self)
                stdoutBuffer.removeAll()
                return s
            }
            stdoutBuffer.append(contentsOf: chunk)
        }
    }

    /// 在后台队列上做阻塞读(`availableData` 阻塞到有数据 / EOF),不卡 actor 执行器。
    private static func readChunk(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { cont in
            readQueue.async {
                let d = handle.availableData
                cont.resume(returning: d)
            }
        }
    }
    #endif

    // MARK: - 静态工具

    /// JSON-RPC 信封 → result;命中 error 抛错;id 不匹配返回 nil(交给调用方继续等)。
    private static func matchResponse(_ json: [String: Any], id: Int?) throws -> [String: Any]? {
        // 通知(无 id)忽略。
        let respID = json["id"]
        if let id, let r = respID as? Int, r != id { return nil }
        if respID == nil { return nil }
        if let error = json["error"] as? [String: Any] {
            let msg = (error["message"] as? String) ?? "MCP error"
            let code = (error["code"] as? Int).map { " (code \($0))" } ?? ""
            throw LLMError.httpError(status: 200, body: "MCP: \(msg)\(code)")
        }
        return (json["result"] as? [String: Any]) ?? [:]
    }

    /// MCP `inputSchema`(JSON Schema)→ Kown 的 `ToolParameters`。
    /// 浅层映射:取每个 property 的 `type` + `description`;嵌套对象 / 数组降级为 string 透传
    /// (模型仍可传 JSON 字符串,server 端自行解析)。`required` 原样保留。
    static func mapInputSchema(_ schema: [String: Any]) -> ToolParameters {
        let props = (schema["properties"] as? [String: Any]) ?? [:]
        var mapped: [String: ToolParameterSchema] = [:]
        for (key, value) in props {
            let spec = (value as? [String: Any]) ?? [:]
            let rawType = (spec["type"] as? String) ?? ((spec["type"] as? [String])?.first) ?? "string"
            let type: String
            switch rawType {
            case "string", "integer", "number", "boolean": type = rawType
            default: type = "string"   // object / array / null / 联合类型 → string 透传
            }
            let desc = (spec["description"] as? String) ?? (spec["title"] as? String) ?? key
            mapped[key] = ToolParameterSchema(type: type, description: desc)
        }
        let required = (schema["required"] as? [String]) ?? []
        return ToolParameters(properties: mapped, required: required.filter { mapped[$0] != nil })
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

/// 给一个 async 操作加超时;超时抛 `LLMError.decoding`。原任务被取消(协作式)。
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw LLMError.decoding("操作超时(\(Int(seconds))s)")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
