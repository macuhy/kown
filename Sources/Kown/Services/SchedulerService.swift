import Foundation
import Observation
import UserNotifications

/// 简易定时任务调度器。**仅在 app 运行(前台或被系统短暂保活)期间发火**:
/// 后台常驻定时受 OS 限制(macOS 可后台跑,iOS 被 suspend 后定时器停摆),
/// 所以本服务定位为「app 运行时每 60 秒检查一次,补跑当天到点且未跑过的任务」。
///
/// 发火 = 用任务里的 prompt + mode 新建一个会话并发送(走 `AppViewModel` 既有发送流程),
/// 更新该任务的 `lastRun`,并发一条本地通知提醒用户。
@Observable
@MainActor
final class SchedulerService {
    static let shared = SchedulerService()

    /// 任务列表(最新添加的在最前)。设置页与本服务共享(同 `MemoryStore.shared` 模式)。
    private(set) var tasks: [ScheduledTask]

    /// 绑定的 AppViewModel(start 时注入)。发火时用它新建会话 + 发送。
    private weak var viewModel: AppViewModel?

    /// 检查定时器(每 60 秒一次)。
    private var timer: Timer?

    /// 是否已申请过通知权限(惰性,首次设置任务时申请)。
    private var permissionAsked = false

    private init() {
        self.tasks = ScheduledTaskStore.load()
    }

    // MARK: - 生命周期

    /// 启动调度:注入 viewModel,跑一次即时检查,并起每 60 秒的定时器。重复调用安全(先停旧定时器)。
    func start(viewModel: AppViewModel) {
        self.viewModel = viewModel
        timer?.invalidate()
        // 启动即检查一次(补跑「app 没开着时错过、但今天还没跑」的到点任务)。
        checkAndFire()
        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAndFire() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - CRUD(设置页用)

    /// 重新从磁盘载入(iCloud 同步拉到新文件后调用)。
    func reload() {
        tasks = ScheduledTaskStore.load()
    }

    private func persist() {
        ScheduledTaskStore.save(tasks)
    }

    /// 添加一条任务(最新在前)。首次添加时申请通知权限。
    func add(_ task: ScheduledTask) {
        ensureNotificationPermission()
        tasks.insert(task, at: 0)
        persist()
    }

    /// 整条覆盖更新(编辑保存用)。
    func update(_ task: ScheduledTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx] = task
        persist()
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    /// 切换启用状态。
    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].enabled = enabled
        persist()
    }

    // MARK: - 调度核心

    /// 检查所有任务,把「启用 + 已到今天的触发时刻 + 当天还没跑过」的逐个发火。
    func checkAndFire() {
        let now = Date()
        let cal = Calendar.current
        for task in tasks where task.enabled {
            guard isDue(task, now: now, calendar: cal) else { continue }
            fire(task, now: now)
        }
    }

    /// 是否到点该发火:当前时间 >= 今天的 HH:mm,且 lastRun 不是今天(或 lastRun 早于今天的触发点)。
    private func isDue(_ task: ScheduledTask, now: Date, calendar cal: Calendar) -> Bool {
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = task.hour
        comps.minute = task.minute
        comps.second = 0
        guard let fireToday = cal.date(from: comps) else { return false }
        // 每周任务:今天的星期几必须匹配,否则跳过。
        if let wd = task.weekday {
            let today = cal.component(.weekday, from: now)
            guard today == wd else { return false }
        }
        // 还没到今天的触发时刻 → 不发。
        guard now >= fireToday else { return false }
        // 今天已经跑过(lastRun 落在今天触发点之后)→ 不重复。
        if let last = task.lastRun, last >= fireToday { return false }
        return true
    }

    /// 真正发火:用任务的 prompt + mode 新建会话并发送;更新 lastRun;发本地通知。
    /// 简报任务(`morningBriefing`)需异步组装(读日历是 async),故整段发送放进 `Task`。
    private func fire(_ task: ScheduledTask, now: Date) {
        // 先标记 lastRun,避免同一分钟内定时器再次触发重复发(即便发送失败也算「今天已尝试」)。
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].lastRun = now
            persist()
        }

        let vm = viewModel
        Task { @MainActor in
            let promptText: String
            switch task.kind {
            case .morningBriefing:
                promptText = await Self.buildBriefingPrompt(task: task)
            case .plainPrompt:
                promptText = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let vm, !promptText.isEmpty {
                // 新建该模式会话 → 填 prompt → 走既有发送流程。
                vm.newConversation(mode: task.mode)
                vm.prompt = promptText
                vm.send()
            }
        }

        notify(task: task)
    }

    // MARK: - 晨间简报组装

    /// 把今日日程 + 长期关注点 + 订阅话题拼成一份简报 prompt。各部分缺失时优雅跳过。
    /// 纯组装,不直接调模型 —— 拼好后交给 `vm.send()` 走既有发送流程。
    static func buildBriefingPrompt(task: ScheduledTask) async -> String {
        var sections: [String] = []

        // 1) 今日日程(读系统日历;未授权/无日程则跳过)。
        #if canImport(EventKit)
        let events = await EventKitService.shared.listEvents(daysAhead: 1, limit: 20)
        if !events.isEmpty {
            let df = DateFormatter()
            df.locale = Locale(identifier: "zh_CN")
            df.dateFormat = "HH:mm"
            let lines = events.map { e -> String in
                let t = e.start.map { df.string(from: $0) } ?? "全天"
                let loc = (e.location?.isEmpty == false) ? " @ \(e.location!)" : ""
                return "- \(t) \(e.title)\(loc)"
            }
            sections.append("【今日日程】\n" + lines.joined(separator: "\n"))
        }
        #endif

        // 2) 长期关注点 / 偏好(来自跨会话沉淀的记忆)。
        let mem = MemoryStore.shared.items.prefix(12).map { "- " + $0.text }
        if !mem.isEmpty {
            sections.append("【我的长期关注点 / 偏好】\n" + mem.joined(separator: "\n"))
        }

        // 3) 订阅话题。
        let topics = task.briefingTopics
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !topics.isEmpty {
            sections.append("【我订阅的话题(请逐条简报最新进展)】\n"
                + topics.map { "- " + $0 }.joined(separator: "\n"))
        }

        // 4) 用户的额外指示(可选)。
        let extra = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            sections.append("【额外指示】\n" + extra)
        }

        let context = sections.isEmpty
            ? "(暂无日程 / 关注点 / 话题数据)"
            : sections.joined(separator: "\n\n")

        return """
        你是我的私人晨间助理。请基于下面的资料,给我写一份简短、可执行的「今日晨报」:
        1. 先用一句话概括今天的重点;
        2. 若有日程,按时间梳理并提醒可能的冲突或需提前准备的事项;
        3. 若有订阅话题,逐条给最新进展 / 值得关注的点(可联网核实);
        4. 结尾给 1-3 条今天的小建议。
        语气简洁友好,用中文,控制在合理篇幅,不要复述原始资料。

        ===== 今日资料 =====
        \(context)
        """
    }

    // MARK: - 本地通知

    /// 首次需要时申请通知权限(惰性,跨平台)。
    func ensureNotificationPermission() {
        guard !permissionAsked else { return }
        permissionAsked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 发一条本地通知,告知该定时任务已触发。
    private func notify(task: ScheduledTask) {
        let content = UNMutableNotificationContent()
        content.title = task.isBriefing ? "晨间简报已生成" : "定时任务已触发"
        let name = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.isBriefing {
            content.body = name.isEmpty
                ? "今日晨报已为你准备好(\(task.timeText))"
                : "「\(name)」已生成(\(task.timeText))"
        } else {
            content.body = name.isEmpty
                ? "已自动发送一条定时提问(\(task.timeText))"
                : "「\(name)」已自动发送(\(task.timeText))"
        }
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }
}
