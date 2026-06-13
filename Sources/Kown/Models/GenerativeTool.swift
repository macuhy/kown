import Foundation

/// 「AI 现做交互小工具」(Generative UI)的数据模型。
///
/// 模型为当前问题临时造一个**能用的交互式 mini-app**(贷款计算器、可筛选数据表、可调参图……),
/// 关键差异:这个工具能**回调模型** —— 用户在工具里操作 → JS↔Swift 桥把请求送回 LLM/本机计算 →
/// 结果回填工具。超越静态 Artifacts(`ArtifactBlock`/`ArtifactKind`,那只渲染一次性 HTML/SVG/Mermaid)。
///
/// 纯数据 + 解析,无 UI / 平台依赖,SwiftPM / iOS / mac 三端共用(对齐 `StructuredOutput` / `ArtifactBlock`)。

// MARK: - 回调声明

/// 工具声明的一个「回调接口」:用户在工具里触发某操作时,要把请求送回宿主处理。
/// 模型在生成工具时连同 HTML/JS 一起声明它会发起哪些回调,宿主据此校验 + 分发(清晰边界,安全)。
struct GenerativeCallback: Codable, Hashable, Sendable, Identifiable {
    /// 回调如何被处理。
    enum Kind: String, Codable, Sendable {
        /// 把 `args` 拼成 prompt 发给 LLM,回填模型的文本/JSON 回答。
        case llm
        /// 把 `args.code`(或 `args` 里约定的代码字段)交给本机 `CodeSandboxService` 跑,回填 stdout。
        case compute
    }

    /// 回调名(JS 侧 `postMessage({callback: "<name>", …})` 用;在一个工具内唯一)。
    let name: String
    /// 处理方式(llm / compute)。
    let kind: Kind
    /// 给模型/自身看的说明:这个回调做什么、期望什么入参、回填什么。
    let purpose: String

    var id: String { name }
}

// MARK: - 工具规格

/// 模型产出的一份完整工具规格:自包含 HTML(内联 JS/CSS)+ 它声明的回调接口。
/// 一次「生成交互工具」产出一个 `GenerativeToolSpec`,可被多次「让 AI 改工具」迭代成新版本。
struct GenerativeToolSpec: Codable, Hashable, Sendable {
    /// 工具标题(给用户看,如「房贷月供计算器」)。
    var title: String
    /// 一句话说明工具能做什么。
    var summary: String
    /// 自包含 HTML 文档(应内联所有 CSS/JS,**不引任何 CDN / 外链**;宿主会再包一层桥接骨架)。
    var html: String
    /// 工具声明的回调接口(可空 —— 纯前端工具不回调模型也合法)。
    var callbacks: [GenerativeCallback]

    /// 按名字查回调(分发时校验用;未声明的回调一律拒绝,安全边界)。
    func callback(named name: String) -> GenerativeCallback? {
        callbacks.first { $0.name == name }
    }
}

// MARK: - 一次回调请求 / 结果(JS ↔ Swift 桥的数据契约)

/// JS 通过 `window.webkit.messageHandlers.kown.postMessage(...)` 发来的一次回调请求。
/// 宽容解析:字段缺失/类型不符都折叠成可诊断的失败,绝不崩。
struct GenerativeToolRequest: Sendable {
    /// JS 侧生成的请求 id(宿主处理完用它 resolve 对应的 Promise)。
    let requestID: String
    /// 要调用的回调名(必须在 spec.callbacks 里声明过)。
    let callback: String
    /// 入参(转交给 LLM prompt / 代码执行;统一序列化成 JSON 字符串以满足 Sendable)。
    let argsJSON: String

    /// 从 WKScriptMessage 的 body(`[String: Any]`)解析;不合法返回 nil。
    init?(body: Any) {
        guard let dict = body as? [String: Any] else { return nil }
        guard let reqID = dict["requestId"] as? String, !reqID.isEmpty else { return nil }
        guard let cb = dict["callback"] as? String, !cb.isEmpty else { return nil }
        self.requestID = reqID
        self.callback = cb
        let argsObj = (dict["args"] as? [String: Any]) ?? [:]
        if JSONSerialization.isValidJSONObject(argsObj),
           let data = try? JSONSerialization.data(withJSONObject: argsObj),
           let s = String(data: data, encoding: .utf8) {
            self.argsJSON = s
        } else {
            self.argsJSON = "{}"
        }
    }

    /// 解析回入参字典(在处理回调时用;失败返回空字典)。
    var args: [String: Any] {
        guard let data = argsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}

/// 宿主处理一次回调后回填给 JS 的结果。`ok=false` 时 `error` 非空,JS 侧 reject。
/// `valueJSON` 是已序列化好的结果 JSON 片段(字符串/对象/数组都行),满足 Sendable 且回填零拷贝。
struct GenerativeToolResult: Sendable {
    let requestID: String
    let ok: Bool
    /// 成功结果的 JSON 片段(如 `"\"42\""`、`"{...}"`);失败时为 nil。
    let valueJSON: String?
    /// 失败原因(给工具 / 用户看)。成功时为 nil。
    let error: String?

    /// 把任意可序列化值包成成功结果(自动 JSON 编码;不可序列化时降级成字符串)。
    static func success(requestID: String, value: Any) -> GenerativeToolResult {
        GenerativeToolResult(requestID: requestID, ok: true, valueJSON: encodeValue(value), error: nil)
    }
    /// 直接用一段字符串当结果(最常见:LLM 文本 / 代码 stdout)。
    static func successText(requestID: String, _ text: String) -> GenerativeToolResult {
        GenerativeToolResult(requestID: requestID, ok: true, valueJSON: encodeValue(text), error: nil)
    }
    static func failure(requestID: String, error: String) -> GenerativeToolResult {
        GenerativeToolResult(requestID: requestID, ok: false, valueJSON: nil, error: error)
    }

    /// 把任意值编码成 JSON 片段。标量用 `JSONSerialization`(fragmentsAllowed),失败兜底成带引号字符串。
    private static func encodeValue(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        // 标量(String/Number/Bool):用 fragmentsAllowed 编码。
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        // 终极兜底:转成带转义的字符串字面量。
        let str = "\(value)"
        let escaped = str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    /// 序列化成 `window.kownResolve(...)` 的实参 JSON(`{ok, value?, error?}`)。
    /// 始终返回合法 JSON 字符串。
    func payloadJSON() -> String {
        var parts: [String] = ["\"ok\":\(ok)"]
        if let valueJSON { parts.append("\"value\":\(valueJSON)") }
        if let error {
            let escaped = error
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            parts.append("\"error\":\"\(escaped)\"")
        }
        return "{\(parts.joined(separator: ","))}"
    }
}

// MARK: - 错误

enum GenerativeToolError: LocalizedError {
    case noProvider
    case emptyReply
    case parseFailed(String)
    case unknownCallback(String)
    case callbackDisabled(String)

    var errorDescription: String? {
        switch self {
        case .noProvider: return "没有可用的模型(需要至少启用一个非 CLI 厂商)"
        case .emptyReply: return "模型没有返回可用的工具规格"
        case .parseFailed(let d): return "工具规格解析失败:\(d)"
        case .unknownCallback(let n): return "工具发起了未声明的回调「\(n)」,已拒绝"
        case .callbackDisabled(let n): return "回调「\(n)」需要的能力未开启"
        }
    }
}

// MARK: - 持久化(按会话存生成的工具)

/// 已生成的一条工具(落盘单元):规格 + 它从哪条回答生成 + 时间戳 + 版本号(每次「让 AI 改」+1)。
struct StoredGenerativeTool: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// 触发生成的那条回答(turn)的 id;无来源(直接从输入造)时为 nil。
    let sourceTurnID: UUID?
    var spec: GenerativeToolSpec
    var version: Int
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), sourceTurnID: UUID?, spec: GenerativeToolSpec, version: Int = 1) {
        self.id = id
        self.sourceTurnID = sourceTurnID
        self.spec = spec
        self.version = version
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}

/// 生成式工具的持久化。按会话一个 JSON 文件:`generative-tools/<conversationID>.json`,
/// 内容是 `[StoredGenerativeTool]`(最新在最后)。放同步根下随 iCloud 同步。
/// 模式完全对齐 `ArtifactVersionStore`(内存缓存 + 原子写 + iCloud 占位触发下载)。
@MainActor
enum GenerativeToolStore {
    /// 单会话最多保留的工具数(防膨胀,超出丢最老的)。
    static let maxToolsPerConversation = 20

    private static var cache: [UUID: [StoredGenerativeTool]] = [:]

    static var dir: URL {
        let url = Platform.syncedDataDir.appendingPathComponent("generative-tools", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700 as NSNumber]
        )
        return url
    }

    private static func fileURL(for conversationID: UUID) -> URL {
        dir.appendingPathComponent("\(conversationID.uuidString).json")
    }

    /// 读某会话的全部工具(无则空数组)。
    static func tools(conversationID: UUID) -> [StoredGenerativeTool] {
        loadAll(conversationID: conversationID)
    }

    /// 追加一条新生成的工具并落盘,返回它(含分配好的 id)。
    @discardableResult
    static func append(_ tool: StoredGenerativeTool, conversationID: UUID) -> StoredGenerativeTool {
        var list = loadAll(conversationID: conversationID)
        list.append(tool)
        if list.count > maxToolsPerConversation {
            list = Array(list.suffix(maxToolsPerConversation))
        }
        cache[conversationID] = list
        save(list, conversationID: conversationID)
        return tool
    }

    /// 用「让 AI 改」的新规格替换某条工具(version +1,bump updatedAt)。找不到则忽略。
    static func update(toolID: UUID, conversationID: UUID, newSpec: GenerativeToolSpec) {
        var list = loadAll(conversationID: conversationID)
        guard let idx = list.firstIndex(where: { $0.id == toolID }) else { return }
        list[idx].spec = newSpec
        list[idx].version += 1
        list[idx].updatedAt = Date()
        cache[conversationID] = list
        save(list, conversationID: conversationID)
    }

    /// 删除某条工具。
    static func remove(toolID: UUID, conversationID: UUID) {
        var list = loadAll(conversationID: conversationID)
        list.removeAll { $0.id == toolID }
        cache[conversationID] = list
        save(list, conversationID: conversationID)
    }

    // MARK: - Private

    private static func loadAll(conversationID: UUID) -> [StoredGenerativeTool] {
        if let cached = cache[conversationID] { return cached }
        var result: [StoredGenerativeTool] = []
        let url = fileURL(for: conversationID)
        if let data = try? Data(contentsOf: url), !data.isEmpty,
           let decoded = try? JSONDecoder().decode([StoredGenerativeTool].self, from: data) {
            result = decoded
        } else {
            // iCloud 占位文件:触发下载,本次按空处理,稍后重试自然命中。
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        cache[conversationID] = result
        return result
    }

    private static func save(_ list: [StoredGenerativeTool], conversationID: UUID) {
        do {
            let data = try JSONEncoder().encode(list)
            try data.write(to: fileURL(for: conversationID), options: .atomic)
        } catch {
            NSLog("Kown: GenerativeToolStore save failed: \(error.localizedDescription)")
        }
    }
}
