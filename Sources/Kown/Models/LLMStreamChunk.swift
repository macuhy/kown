import Foundation

/// Stream payload emitted by `LLMClient.stream(...)`.
/// 文本与工具事件走同一条流,UI 各自路由到 `ResponseState.text` / `ResponseState.events`。
enum LLMStreamChunk: Sendable {
    case text(String)
    /// 模型的「思考过程」增量(reasoning / thinking / thought)。
    /// OpenAI 兼容的 `reasoning_content`、Anthropic 的 `thinking_delta`、Gemini 的 thought part
    /// 都归一到这条流,UI 路由到 `ResponseState.reasoning`(可折叠的「💭 思考过程」区块),
    /// 与正文 `text` 分开渲染。
    case reasoning(String)
    case toolEvent(String)
    /// 一步结构化的工具调用进度(Agent 步骤可视化)。client 在识别 tool_use 时发 `.running`,
    /// 执行完用同一 `id` 再发 `.done` / `.error`,AppViewModel 按 id upsert 进 `ResponseState.toolSteps`,
    /// 由 `AgentStepsView` 按轮次渲染成步骤树。与平铺的 `.toolEvent` 并存(后者仍喂旧的 events chips)。
    case toolStep(ToolStep)
    /// 一次工具调用(web_search)命中的结构化引用来源。client 在 ToolRouter.execute 后解析并发出,
    /// AppViewModel 累积到 `liveSources`、落盘进 `Turn.sources`(回答下方以 SourcesStrip 展示)。
    case sources([SourceRef])
    /// 模型用量信息 — 单次流式结束时由 client 解析 API 末尾的 usage 块后发出。
    /// `input` 是 prompt tokens,`output` 是 completion tokens。
    /// 部分 model 中途也会先发 input(message_start),后发 output(message_delta),
    /// AppViewModel 累加同一 round 的 max(input) 和 sum(output) 即可。
    /// `cachedInputTokens` = 命中提示缓存的输入 token 数(读取缓存);`inputTokens` 已归一为
    /// 「含缓存在内的 prompt 总 token」,故缓存比 = cached / input 跨厂商一致。
    case usage(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int)
}

/// 一步工具调用的结构化进度。`id` = 模型给的 tool_use id,用于把 running → done/error 更新到同一步。
struct ToolStep: Identifiable, Sendable, Hashable, Codable {
    enum Status: String, Sendable, Hashable, Codable {
        case running    // 已发起调用,等结果
        case done       // 成功
        case error      // 失败
    }

    let id: String
    /// 第几轮工具循环(0 起,UI 显示 +1)。
    let round: Int
    /// 工具名(原始,如 web_search)。
    let toolName: String
    /// 参数摘要(如「query: 北京天气」),给用户看的一行。
    let argsSummary: String
    var status: Status
    /// 完成后的结果摘要(成功/失败文案,沿用 ToolResult.summary)。
    var resultSummary: String?

    init(id: String, round: Int, toolName: String, argsSummary: String,
         status: Status = .running, resultSummary: String? = nil) {
        self.id = id
        self.round = round
        self.toolName = toolName
        self.argsSummary = argsSummary
        self.status = status
        self.resultSummary = resultSummary
    }

    /// 工具名 → 中文展示名 + 图标。
    var displayName: String {
        switch toolName {
        case "web_search":       return "联网搜索"
        case "create_reminder":  return "创建提醒"
        case "list_reminders":   return "查看提醒"
        case "create_event":     return "添加日程"
        case "list_events":      return "查看日程"
        case "create_note":      return "写入备忘录"
        case "github_read_file": return "读取 GitHub 文件"
        case "local_read_file":  return "读取本地文件"
        case "local_list_dir":   return "列出目录"
        case "local_write_file": return "暂存文件改动"
        default:
            // MCP 工具:mcp__<slug>__<tool> → 「<tool> · <slug>」,去掉前缀更易读。
            if toolName.hasPrefix("mcp__") {
                let rest = String(toolName.dropFirst("mcp__".count))
                if let sep = rest.range(of: "__") {
                    return "\(String(rest[sep.upperBound...])) · \(String(rest[..<sep.lowerBound]))"
                }
                return rest
            }
            return toolName
        }
    }

    /// 从工具调用的参数 JSON 里提炼一行摘要(优先常见关键字段,截断到 60 字)。
    static func summarizeArgs(argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !obj.isEmpty else { return "" }
        let priorityKeys = ["query", "path", "rel", "title", "start", "days", "body"]
        for k in priorityKeys {
            if let v = obj[k] as? String, !v.isEmpty {
                return "\(k): \(String(v.prefix(60)))"
            }
        }
        for (k, v) in obj {
            if let s = v as? String, !s.isEmpty {
                return "\(k): \(String(s.prefix(60)))"
            }
        }
        return ""
    }

    var iconName: String {
        switch toolName {
        case "web_search":       return "magnifyingglass"
        case "create_reminder", "list_reminders": return "checklist"
        case "create_event", "list_events":       return "calendar"
        case "create_note":      return "note.text"
        case "github_read_file": return "chevron.left.forwardslash.chevron.right"
        case "local_read_file", "local_list_dir", "local_write_file": return "folder"
        default:                  return toolName.hasPrefix("mcp__") ? "powerplug" : "wrench.and.screwdriver"
        }
    }
}
