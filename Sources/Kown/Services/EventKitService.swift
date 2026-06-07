import Foundation
#if canImport(EventKit)
import EventKit
#endif

#if canImport(EventKit)
/// 系统「提醒事项」(Reminders)封装。iOS 17 / macOS 14 起用 `requestFullAccessToReminders`。
///
/// `EKEventStore` 不是 `Sendable`,所以用 `actor` 把它圈起来——store 永不跨隔离边界,
/// 所有读写都在 actor 内串行。授权用 async API,失败一律转成可读中文错误,绝不崩。
actor EventKitService {
    static let shared = EventKitService()

    private let store = EKEventStore()

    /// 一次创建结果(给调用方拼工具回执 / UI 提示用)。
    struct CreateResult: Sendable {
        let title: String
        let due: Date?
    }

    /// 列出提醒时返回的精简条目(EKReminder 非 Sendable,转成值类型再跨边界)。
    struct ReminderItem: Sendable {
        let title: String
        let due: Date?
    }

    /// 一次日历事件创建结果。
    struct EventCreateResult: Sendable {
        let title: String
        let start: Date
    }

    /// 列出日历事件时返回的精简条目(EKEvent 非 Sendable,转成值类型再跨边界)。
    struct EventItem: Sendable {
        let title: String
        let start: Date?
        let end: Date?
        let location: String?
    }

    enum EventKitError: LocalizedError {
        case denied
        case noDefaultList
        case calendarDenied
        case noDefaultCalendar
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .denied:        return "没有「提醒事项」访问权限,请在系统设置 ▸ 隐私 里允许 Kown 访问提醒事项。"
            case .noDefaultList: return "找不到可用的提醒事项列表(请在「提醒事项」App 里至少建一个列表)。"
            case .calendarDenied: return "没有「日历」访问权限,请在系统设置 ▸ 隐私 里允许 Kown 访问日历。"
            case .noDefaultCalendar: return "找不到可用的日历(请在「日历」App 里至少建一个日历)。"
            case .underlying(let m): return m
            }
        }
    }

    /// 当前是否已拿到完全访问权限(同步查询,不弹窗)。
    nonisolated var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    /// 请求完全访问权限。已授权直接返回 true;被拒/出错返回 false(不抛)。
    @discardableResult
    func requestAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return true }
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    /// 新建一条提醒。`due` 非空时同时挂一个到点闹钟。
    func createReminder(title: String, notes: String?, due: Date?) async throws -> CreateResult {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EventKitError.underlying("提醒标题不能为空。") }
        guard await requestAccess() else { throw EventKitError.denied }

        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        if let notes, !notes.isEmpty { reminder.notes = notes }
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw EventKitError.noDefaultList
        }
        reminder.calendar = list

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw EventKitError.underlying(error.localizedDescription)
        }
        return CreateResult(title: trimmed, due: due)
    }

    /// 列出未完成的提醒(最多 `limit` 条)。无权限或出错返回空数组,不抛。
    func listReminders(limit: Int) async -> [ReminderItem] {
        guard await requestAccess() else { return [] }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        let n = max(1, limit)
        return await withCheckedContinuation { (cont: CheckedContinuation<[ReminderItem], Never>) in
            store.fetchReminders(matching: predicate) { found in
                // EKReminder 非 Sendable —— 在闭包内就地转成 ReminderItem,不让它跨越 continuation 边界。
                let items = (found ?? []).prefix(n).map { r in
                    ReminderItem(
                        title: r.title ?? "",
                        due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
                }
                cont.resume(returning: items)
            }
        }
    }

    // MARK: - 日历事件(Calendar)
    //
    // 日历授权与提醒**相互独立**(`.event` ≠ `.reminder`),但共用同一个 store 实例。

    /// 当前是否已拿到日历完全访问权限(同步查询,不弹窗)。
    nonisolated var isEventAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// 请求日历完全访问权限。已授权直接返回 true;被拒/出错返回 false(不抛)。
    @discardableResult
    func requestEventAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// 新建一个日历事件。`end` 为空时默认 1 小时时长。
    func createEvent(title: String, notes: String?, start: Date,
                     end: Date?, location: String?) async throws -> EventCreateResult {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EventKitError.underlying("日程标题不能为空。") }
        guard await requestEventAccess() else { throw EventKitError.calendarDenied }

        let event = EKEvent(eventStore: store)
        event.title = trimmed
        if let notes, !notes.isEmpty { event.notes = notes }
        if let location, !location.isEmpty { event.location = location }
        event.startDate = start
        event.endDate = end ?? start.addingTimeInterval(3600)
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw EventKitError.noDefaultCalendar
        }
        event.calendar = calendar

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw EventKitError.underlying(error.localizedDescription)
        }
        return EventCreateResult(title: trimmed, start: start)
    }

    /// 列出从现在起 `daysAhead` 天内的日历事件(最多 `limit` 条,按开始时间排序)。
    /// 无权限或出错返回空数组,不抛。
    func listEvents(daysAhead: Int, limit: Int) async -> [EventItem] {
        guard await requestEventAccess() else { return [] }
        let now = Date()
        let days = max(1, daysAhead)
        let end = now.addingTimeInterval(TimeInterval(days) * 86_400)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let n = max(1, limit)
        // store.events(matching:) 同步返回;EKEvent 非 Sendable —— 就地转成 EventItem。
        return store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            .prefix(n)
            .map { EventItem(title: $0.title ?? "", start: $0.startDate,
                             end: $0.endDate, location: $0.location) }
    }
}
#endif
