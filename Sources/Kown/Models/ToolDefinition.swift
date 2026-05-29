import Foundation

/// Provider-agnostic tool descriptor. 各客户端按自己的协议序列化。
struct LLMTool: Sendable, Hashable {
    let name: String
    let description: String
    let parameters: ToolParameters
}

struct ToolParameters: Sendable, Hashable {
    /// property name → schema
    let properties: [String: ToolParameterSchema]
    let required: [String]
}

struct ToolParameterSchema: Sendable, Hashable {
    /// JSON schema type: "string", "integer", "number", "boolean"
    let type: String
    let description: String
}

/// Model 发起的一次工具调用。
struct ToolCall: Sendable {
    let id: String
    let name: String
    /// 原始 JSON 字符串(各 provider 给的 arguments 都是 JSON);执行时再解析。
    let argumentsJSON: String
}

/// 工具执行结果,回灌给模型。
struct ToolResult: Sendable {
    let callID: String
    let name: String
    /// 给模型看的内容(已序列化字符串,通常是 JSON)。
    let content: String
    /// 给用户看的事件日志摘要,例如 "✓ 5 条结果" 或 "⚠ 搜索失败: 401"。
    let summary: String
    let isError: Bool
}
