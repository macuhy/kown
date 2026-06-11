import Foundation

/// 会议纪要的结构化结果(由 LLM 从转写文字里提炼)。
/// 纯值类型、跨平台,无任何 UI / 平台依赖,SwiftPM / iOS / mac 三端共用。
struct MeetingNotes: Sendable, Equatable {
    /// 整场会议的摘要(几句话)。
    var summary: String
    /// 关键决议(逐条)。
    var decisions: [String]
    /// 行动项(待办 + 负责人 + 截止日期)。
    var actionItems: [ActionItem]

    /// 一条行动项。
    struct ActionItem: Sendable, Equatable, Identifiable {
        let id = UUID()
        /// 要做什么。
        var task: String
        /// 负责人(可能为空)。
        var owner: String?
        /// 截止日期原文(LLM 给的自然语言,如 "下周五" / "2026-06-20";可能为空)。
        var dueText: String?
        /// 解析出的具体截止日期(可能为空 —— 没给或解析不出)。
        var dueDate: Date?

        /// 拼一条人类可读的标题(写进提醒/日历用)。
        var reminderTitle: String {
            var s = task.trimmingCharacters(in: .whitespacesAndNewlines)
            if let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
                s += "(\(owner))"
            }
            return s
        }
    }

    var isEmpty: Bool {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && decisions.isEmpty && actionItems.isEmpty
    }
}
