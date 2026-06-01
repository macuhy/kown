import Foundation

/// Stream payload emitted by `LLMClient.stream(...)`.
/// 文本与工具事件走同一条流,UI 各自路由到 `ResponseState.text` / `ResponseState.events`。
enum LLMStreamChunk: Sendable {
    case text(String)
    case toolEvent(String)
    /// 一次工具调用(web_search)命中的结构化引用来源。client 在 ToolRouter.execute 后解析并发出,
    /// AppViewModel 累积到 `liveSources`、落盘进 `Turn.sources`(回答下方以 SourcesStrip 展示)。
    case sources([SourceRef])
    /// 模型用量信息 — 单次流式结束时由 client 解析 API 末尾的 usage 块后发出。
    /// `input` 是 prompt tokens,`output` 是 completion tokens。
    /// 部分 model 中途也会先发 input(message_start),后发 output(message_delta),
    /// AppViewModel 累加同一 round 的 max(input) 和 sum(output) 即可。
    case usage(inputTokens: Int, outputTokens: Int)
}
