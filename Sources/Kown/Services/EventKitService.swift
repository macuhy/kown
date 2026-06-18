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

    private var store = EKEventStore()

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
        Self.hasFullOrLegacyAccess(EKEventStore.authorizationStatus(for: .reminder))
    }

    /// 请求完全访问权限。已授权直接返回 true;被拒/出错返回 false(不抛)。
    @discardableResult
    func requestAccess() async -> Bool {
        if Self.hasFullOrLegacyAccess(EKEventStore.authorizationStatus(for: .reminder)) {
            rebuildStore()
            return true
        }

        let granted = await EventKitAccessRequester.requestFullAccessToReminders()
        if granted || Self.hasFullOrLegacyAccess(EKEventStore.authorizationStatus(for: .reminder)) {
            rebuildStore()
            return true
        }
        return false
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

    /// 当前日历授权状态(同步查询,不弹窗)。
    nonisolated var eventAccessState: AccessState {
        Self.accessState(for: EKEventStore.authorizationStatus(for: .event), entity: .event)
    }

    /// 当前是否已拿到日历完全访问权限(同步查询,不弹窗)。
    nonisolated var isEventAuthorized: Bool {
        Self.hasFullOrLegacyAccess(EKEventStore.authorizationStatus(for: .event))
    }

    /// 请求日历完全访问权限。已授权直接返回 true;被拒/出错返回 false(不抛)。
    @discardableResult
    func requestEventAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if Self.hasFullOrLegacyAccess(status) {
            rebuildStore()
            return true
        }
        guard status == .notDetermined else {
            return false
        }

        let granted = await EventKitAccessRequester.requestFullAccessToEvents()
        if granted || Self.hasFullOrLegacyAccess(EKEventStore.authorizationStatus(for: .event)) {
            rebuildStore()
            return true
        }
        return false
    }

    /// 请求日历写入权限。只创建新日程时,系统的「仅添加事件」权限也足够。
    @discardableResult
    func requestEventWriteAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if Self.canWriteEvents(status) {
            rebuildStore()
            return true
        }
        guard status == .notDetermined else {
            return false
        }

        let granted = await EventKitAccessRequester.requestFullAccessToEvents()
        if granted || Self.canWriteEvents(EKEventStore.authorizationStatus(for: .event)) {
            rebuildStore()
            return true
        }
        return false
    }

    /// 新建一个日历事件。`end` 为空时默认 1 小时时长。
    func createEvent(title: String, notes: String?, start: Date,
                     end: Date?, location: String?) async throws -> EventCreateResult {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EventKitError.underlying("日程标题不能为空。") }
        guard await requestEventWriteAccess() else { throw EventKitError.calendarDenied }

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

    // MARK: - 会议事件(给「日历到点自动开会捕获」用)

    /// 一个「像会议」的日历事件(带稳定标识符 + 探测到的视频会议链接)。
    /// `eventIdentifier` 用于稍后把纪要写回**这条**事件(EKEvent 非 Sendable,只带标识符出来)。
    struct UpcomingMeeting: Sendable, Identifiable {
        var id: String { eventIdentifier }
        let eventIdentifier: String
        let title: String
        let start: Date
        let end: Date?
        /// 探测到的视频会议链接(Zoom/Teams/Meet/腾讯会议等);可能为 nil(靠「有与会者」判定的会议)。
        let videoURL: String?

        var startsWithin: TimeInterval { start.timeIntervalSinceNow }
    }

    /// 列出从现在起 `withinMinutes` 分钟内**即将开始**的「会议型」事件。
    /// 判定「会议」:含视频会议链接(URL / notes / location 里出现 zoom/meet/teams/腾讯会议等),
    /// 或有一名以上与会者(`hasAttendees`)。全天事件、已结束的、已开始很久的排除。
    /// 无权限或出错返回空数组,不抛。
    func upcomingMeetings(withinMinutes: Int) async -> [UpcomingMeeting] {
        guard await requestEventAccess() else { return [] }
        let now = Date()
        let window = TimeInterval(max(1, withinMinutes) * 60)
        // 往前留 1 分钟容差(刚到点的也算),往后看 window。
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(window),
            calendars: nil)
        return store.events(matching: predicate)
            .filter { ev in
                guard !ev.isAllDay, let start = ev.startDate else { return false }
                // 还没结束(或没结束时间);开始时间不早于「1 分钟前」。
                if let end = ev.endDate, end < now { return false }
                if start < now.addingTimeInterval(-60) { return false }
                return Self.looksLikeMeeting(ev)
            }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            .compactMap { ev in
                guard let id = ev.eventIdentifier, let start = ev.startDate else { return nil }
                return UpcomingMeeting(
                    eventIdentifier: id,
                    title: ev.title ?? "(无标题会议)",
                    start: start,
                    end: ev.endDate,
                    videoURL: Self.detectVideoURL(ev))
            }
    }

    /// 把一段纪要文本**追加**到指定事件的备注(notes)里(原有备注保留,空行分隔)。
    /// 找不到事件 / 无权限 / 保存失败时抛可读错误。
    @discardableResult
    func appendNotes(toEventIdentifier id: String, append text: String) async throws -> EventItem {
        guard await requestEventAccess() else { throw EventKitError.calendarDenied }
        guard let event = store.event(withIdentifier: id) else {
            throw EventKitError.underlying("找不到对应的日历事件(可能已被删除或修改)。")
        }
        let addition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else {
            throw EventKitError.underlying("纪要内容为空,未写入。")
        }
        let existing = (event.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        event.notes = existing.isEmpty ? addition : (existing + "\n\n" + addition)
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw EventKitError.underlying(error.localizedDescription)
        }
        return EventItem(title: event.title ?? "", start: event.startDate,
                         end: event.endDate, location: event.location)
    }

    // MARK: - 授权状态兼容

    /// 给设置页展示用的轻量授权状态。
    enum AccessState: Sendable, Equatable {
        case notDetermined
        case fullAccess
        case writeOnly
        case denied
        case restricted
        case unknown

        var isDeniedOrRestricted: Bool {
            self == .denied || self == .restricted
        }
    }

    nonisolated static func accessState(for status: EKAuthorizationStatus, entity: EKEntityType) -> AccessState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .fullAccess
        case .fullAccess: return .fullAccess
        case .writeOnly where entity == .event: return .writeOnly
        case .writeOnly: return .restricted
        @unknown default: return .unknown
        }
    }

    /// macOS 14 / iOS 17 引入 `.fullAccess`,但旧系统升级或历史授权仍可能返回 `.authorized`。
    nonisolated static func hasFullOrLegacyAccess(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    /// 创建新日程只需要 full / legacy / write-only 中任一种可写权限。
    nonisolated static func canWriteEvents(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return true
        default:
            return false
        }
    }

    private func rebuildStore() {
        store = EKEventStore()
    }

    // MARK: - 会议判定(纯函数,不依赖 store 实例外的状态)

    /// 常见视频会议域名/关键字(小写)。
    private static let meetingKeywords = [
        "zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "meeting.tencent.com", "voovmeeting.com", "腾讯会议", "tencent meeting",
        "feishu.cn/j", "larksuite.com", "whereby.com", "gotomeeting.com"
    ]

    /// 事件是否「像会议」:有视频链接,或有与会者。
    private static func looksLikeMeeting(_ ev: EKEvent) -> Bool {
        if detectVideoURL(ev) != nil { return true }
        if ev.hasAttendees, (ev.attendees?.count ?? 0) >= 1 { return true }
        return false
    }

    /// 从事件的 url / notes / location 里探测一个视频会议链接。命中关键字优先,
    /// 否则退回 `ev.url`(纯 http(s) 链接也算)。找不到返回 nil。
    private static func detectVideoURL(_ ev: EKEvent) -> String? {
        // 1) 结构化 URL 字段。
        if let u = ev.url?.absoluteString, !u.isEmpty {
            let lower = u.lowercased()
            if meetingKeywords.contains(where: { lower.contains($0) }) { return u }
        }
        // 2) notes / location 里抓第一个含会议关键字的 http(s) 链接。
        let haystacks = [ev.notes, ev.location].compactMap { $0 }
        for text in haystacks {
            if let url = firstMeetingURL(in: text) { return url }
        }
        // 3) 退回结构化 URL(即便不含关键字,日历事件的 url 多半就是会议入口)。
        if let u = ev.url?.absoluteString, u.lowercased().hasPrefix("http") { return u }
        return nil
    }

    /// 在文本里找第一个「含会议关键字」的 http(s) 链接。
    private static func firstMeetingURL(in text: String) -> String? {
        let lower = text.lowercased()
        guard meetingKeywords.contains(where: { lower.contains($0) }) else { return nil }
        // 用 NSDataDetector 抽 http(s) 链接,挑第一个命中关键字的。
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url?.absoluteString else { continue }
            let l = url.lowercased()
            if meetingKeywords.contains(where: { l.contains($0) }) { return url }
        }
        return nil
    }
}

@MainActor
private enum EventKitAccessRequester {
    static func requestFullAccessToReminders() async -> Bool {
        do {
            return try await EKEventStore().requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    static func requestFullAccessToEvents() async -> Bool {
        do {
            return try await EKEventStore().requestFullAccessToEvents()
        } catch {
            return false
        }
    }
}
#endif
