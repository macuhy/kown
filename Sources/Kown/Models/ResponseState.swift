import Foundation
import Observation

enum ResponsePhase: Sendable {
    case idle
    case streaming
    case finished
    case failed(String)
}

@Observable
@MainActor
final class ResponseState: Identifiable {
    let id: UUID
    var text: String = ""
    /// `text.count` 的缓存。`String.count` 是 O(N);回答卡 body 每次求值要读 3 次(折叠阈值 / 展开角标 / footer 字数),
    /// 超长回答 + Council 多卡重渲染下累积成可观开销。只在 flush/finish/reset 时更新一次,view 直接读这个。
    var charCount: Int = 0
    /// 模型「思考过程」累计文本(reasoning / thinking / thought)。与 `text` 同样走节流 flush。
    /// 上限 `maxReasoningChars`:扩展思考模型(o1 / DeepSeek thinking / Claude thinking)能流出 50–200KB,
    /// 而 reasoning 走单个 `Text(reasoning)` 渲染(无 markdown 路径的 maxFinishedChars 截断),
    /// 每 50ms flush 都整段重新测量 → 烧 CPU。到顶后停止追加(同 markdown 的封顶哲学)。
    var reasoning: String = ""
    /// 思考文本上限,与 MarkdownText.MD.maxFinishedChars 对齐。
    static let maxReasoningChars = 40_000
    var phase: ResponsePhase = .idle
    var startedAt: Date?
    var finishedAt: Date?
    /// 工具调用/搜索进度等附加事件,在 UI 顶部以 chip 形式渲染。
    var events: [String] = []
    /// 本轮 token 用量(流末尾的 usage chunk 填充)。用于回答卡的成本角标 + 落盘进 Turn。
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    /// 命中提示缓存的输入 token 数(input 已含缓存,缓存比 = cached/input)。
    var cachedInputTokens: Int = 0
    /// 本卡(provider)自己 web_search 命中的来源(按 url 去重)。用于 panel 小卡显示各自引用。
    var sources: [SourceRef] = []

    /// 流式 chunk 缓冲。每次 `append(_:)` 写这里、不立刻碰 `text`(避免触发 SwiftUI invalidate)。
    /// 一个 throttle 的 task 把 buffer 一次性 flush 到 `text`,把 layout pass 从几十次/秒
    /// 降到几十 Hz 这个量级。Council 多列并发流式时,CPU 占用从 100% 降到通常 < 30%。
    @ObservationIgnored private var pendingChunks: String = ""
    /// 思考文本的同款缓冲,与 `pendingChunks` 共用同一个 flushTask 一起提交。
    @ObservationIgnored private var pendingReasoning: String = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    /// UserDefaults 里存的刷新间隔(毫秒)。Settings → 性能 可调。
    /// 默认 50ms ≈ 20Hz;低性能机器可以调到 100 / 200ms 以进一步降负载。
    static let flushIntervalKey = "kown.stream.flushIntervalMs.v1"
    static let defaultFlushIntervalMs: Int = 50
    static let allowedFlushIntervalsMs: [Int] = [30, 50, 100, 200, 500]

    /// 当前生效的刷新间隔(纳秒),每次 scheduleFlush 时实时从 UserDefaults 取,
    /// 用户改 Settings 后下一次 chunk 就立刻应用,不用重启。
    private static func currentFlushIntervalNanos() -> UInt64 {
        let raw = UserDefaults.standard.integer(forKey: flushIntervalKey)
        let ms = allowedFlushIntervalsMs.contains(raw) ? raw : defaultFlushIntervalMs
        return UInt64(ms) * 1_000_000
    }

    init(id: UUID) {
        self.id = id
    }

    func reset() {
        flushTask?.cancel()
        flushTask = nil
        pendingChunks = ""
        pendingReasoning = ""
        text = ""
        charCount = 0
        reasoning = ""
        events = []
        inputTokens = 0
        outputTokens = 0
        cachedInputTokens = 0
        sources = []
        phase = .streaming
        startedAt = Date()
        finishedAt = nil
    }

    func append(_ chunk: String) {
        pendingChunks += chunk
        scheduleFlushIfNeeded()
    }

    /// 追加一段思考过程增量(与正文共用节流 flush)。
    func appendReasoning(_ chunk: String) {
        pendingReasoning += chunk
        scheduleFlushIfNeeded()
    }

    /// 启动一个延迟 flush task,把累积的 chunk 一次性 commit 到 `text`(只触发一次 SwiftUI invalidate)。
    /// 已经有 pending task 就不重复启;flush 完成后会自动清掉自己。
    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        let interval = Self.currentFlushIntervalNanos()
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            guard let self else { return }
            self.flushPending()
            self.flushTask = nil
        }
    }

    /// 把 buffer 里所有 chunk 合并提交到 `text` / `reasoning`。`finish() / fail()` 前手动 flush 一次保证最后几个字节不丢。
    private func flushPending() {
        if !pendingReasoning.isEmpty {
            // 到顶后只清空缓冲、不再追加,避免 reasoning 无限增长 + 每次 flush 重测整段。
            if reasoning.count < Self.maxReasoningChars {
                reasoning += pendingReasoning
                if reasoning.count > Self.maxReasoningChars {
                    reasoning = String(reasoning.prefix(Self.maxReasoningChars)) + "\n\n[思考内容过长,已截断]"
                }
            }
            pendingReasoning = ""
        }
        guard !pendingChunks.isEmpty else { return }
        text += pendingChunks
        pendingChunks = ""
        charCount = text.count
    }

    func logEvent(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        events.append(trimmed)
    }

    func finish() {
        flushTask?.cancel()
        flushTask = nil
        flushPending()
        phase = .finished
        finishedAt = Date()
    }

    func fail(_ message: String) {
        flushTask?.cancel()
        flushTask = nil
        flushPending()
        phase = .failed(message)
        finishedAt = Date()
    }

    var elapsedSeconds: Double? {
        guard let startedAt else { return nil }
        let end = finishedAt ?? Date()
        return end.timeIntervalSince(startedAt)
    }

    /// 历史回看：给定文本和可选错误，构造一个已结束的 ResponseState 用于复用渲染组件
    static func historical(id: UUID, text: String, error: String?, reasoning: String = "") -> ResponseState {
        let s = ResponseState(id: id)
        s.text = text
        s.charCount = text.count
        s.reasoning = reasoning
        if let error, !error.isEmpty {
            s.phase = .failed(error)
        } else {
            s.phase = .finished
        }
        return s
    }
}
