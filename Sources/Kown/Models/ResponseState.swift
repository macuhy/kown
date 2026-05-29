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
    var phase: ResponsePhase = .idle
    var startedAt: Date?
    var finishedAt: Date?
    /// 工具调用/搜索进度等附加事件,在 UI 顶部以 chip 形式渲染。
    var events: [String] = []

    /// 流式 chunk 缓冲。每次 `append(_:)` 写这里、不立刻碰 `text`(避免触发 SwiftUI invalidate)。
    /// 一个 throttle 的 task 把 buffer 一次性 flush 到 `text`,把 layout pass 从几十次/秒
    /// 降到几十 Hz 这个量级。Council 多列并发流式时,CPU 占用从 100% 降到通常 < 30%。
    @ObservationIgnored private var pendingChunks: String = ""
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
        text = ""
        events = []
        phase = .streaming
        startedAt = Date()
        finishedAt = nil
    }

    func append(_ chunk: String) {
        pendingChunks += chunk
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

    /// 把 buffer 里所有 chunk 合并提交到 `text`。`finish() / fail()` 前手动 flush 一次保证最后几个字节不丢。
    private func flushPending() {
        guard !pendingChunks.isEmpty else { return }
        text += pendingChunks
        pendingChunks = ""
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
    static func historical(id: UUID, text: String, error: String?) -> ResponseState {
        let s = ResponseState(id: id)
        s.text = text
        if let error, !error.isEmpty {
            s.phase = .failed(error)
        } else {
            s.phase = .finished
        }
        return s
    }
}
