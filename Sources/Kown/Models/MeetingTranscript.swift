import Foundation

/// 会议双轨捕获的一条转写话语(一个「气泡」)。
///
/// 纯值类型、跨平台,无任何 UI / 平台依赖:macOS 的会议捕获产出它,
/// 合并/渲染逻辑(`MeetingTranscriptMerger`)是纯函数,可在 SwiftPM 测试里直接验证。
struct MeetingUtterance: Identifiable, Equatable, Sendable {
    /// 说话人维度:我(麦克风轨)/ 对方(系统声音轨)。
    /// 注意这是「轨道归属」而非声纹识别 —— 对方多人时统一标「对方」。
    enum Speaker: String, Sendable, Equatable, CaseIterable {
        case me = "我"
        case them = "对方"
    }

    let id: UUID
    var speaker: Speaker
    var text: String
    /// 相对会议开始的偏移(秒)。
    var start: TimeInterval
    /// 这句话结束时相对会议开始的偏移(秒)。
    var end: TimeInterval

    init(id: UUID = UUID(), speaker: Speaker, text: String, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }
}

/// 双轨时间线合并(纯函数,无状态、无副作用)。
///
/// 输入是两条轨道各自的(可能乱序的)话语数组,输出一条按时间排好序、
/// 相邻同说话人「碎气泡」已折叠的时间线;另提供给 LLM / 导出用的文本渲染。
enum MeetingTranscriptMerger {

    /// 相邻同说话人气泡折叠的默认间隔阈值(秒):
    /// 上一句结束到下一句开始 ≤ 该值(含轻微重叠)即折叠成一条。
    static let defaultCollapseGap: TimeInterval = 2.0

    /// 合并双轨:清洗(去空白、修正非法时间)→ 按开始时间稳定排序 → 相邻同说话人折叠。
    ///
    /// 排序 key:`start`,并列时按 `end`,再并列保持输入顺序(mine 在前)—— 全程稳定、可复现。
    static func merge(
        mine: [MeetingUtterance],
        theirs: [MeetingUtterance],
        collapseGap: TimeInterval = MeetingTranscriptMerger.defaultCollapseGap
    ) -> [MeetingUtterance] {
        let cleaned = (mine + theirs).compactMap(normalize)
        let sorted = stableSortByTime(cleaned)
        return collapseAdjacent(sorted, gap: collapseGap)
    }

    /// 清洗一条话语:文本去首尾空白(空文本丢弃),时间钳到合法区间(start ≥ 0、end ≥ start)。
    static func normalize(_ u: MeetingUtterance) -> MeetingUtterance? {
        let text = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var out = u
        out.text = text
        let start = (u.start.isFinite && u.start > 0) ? u.start : 0
        let end = (u.end.isFinite && u.end > start) ? u.end : start
        out.start = start
        out.end = end
        return out
    }

    /// 按 (start, end) 稳定排序:并列时保持输入顺序(Swift 的 `sorted` 不承诺稳定,这里用下标兜底)。
    static func stableSortByTime(_ items: [MeetingUtterance]) -> [MeetingUtterance] {
        items.enumerated()
            .sorted { l, r in
                if l.element.start != r.element.start { return l.element.start < r.element.start }
                if l.element.end != r.element.end { return l.element.end < r.element.end }
                return l.offset < r.offset
            }
            .map(\.element)
    }

    /// 折叠相邻同说话人的碎气泡:已按时间排序的输入里,同一说话人连续出现、
    /// 且与上一条的间隔(`next.start - prev.end`)≤ `gap`(重叠也算)时并成一条。
    /// 合并后 `start` 取首条、`end` 取两者较晚者,文本智能拼接(`joinedText`)。
    static func collapseAdjacent(
        _ sorted: [MeetingUtterance],
        gap: TimeInterval = MeetingTranscriptMerger.defaultCollapseGap
    ) -> [MeetingUtterance] {
        var out: [MeetingUtterance] = []
        out.reserveCapacity(sorted.count)
        for u in sorted {
            if var last = out.last,
               last.speaker == u.speaker,
               u.start - last.end <= gap {
                last.text = joinedText(last.text, u.text)
                last.end = max(last.end, u.end)
                out[out.count - 1] = last
            } else {
                out.append(u)
            }
        }
        return out
    }

    /// 拼接两段转写文本:前段已带句末标点就直接续,否则补一个逗号衔接。
    static func joinedText(_ a: String, _ b: String) -> String {
        let lhs = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        if let lastChar = lhs.last, "。!?;,、…!?.,;:: ".contains(lastChar) {
            return lhs + rhs
        }
        return lhs + "," + rhs
    }

    /// 渲染成带说话人 + 时间戳的纯文本(交给 `MeetingNotesSummarizer` / 导出用):
    /// ```
    /// [00:05] 我:大家好…
    /// [00:12] 对方:好的,我们开始…
    /// ```
    static func renderTranscript(_ utterances: [MeetingUtterance]) -> String {
        utterances
            .map { "[\(timestampLabel($0.start))] \($0.speaker.rawValue):\($0.text)" }
            .joined(separator: "\n")
    }

    /// 秒 → "mm:ss"(满 1 小时 → "h:mm:ss")。负数/非法值按 0 处理。
    static func timestampLabel(_ seconds: TimeInterval) -> String {
        let total = (seconds.isFinite && seconds > 0) ? Int(seconds.rounded(.down)) : 0
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
