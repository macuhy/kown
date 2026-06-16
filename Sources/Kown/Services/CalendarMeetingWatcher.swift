#if os(macOS)
import Foundation
import Combine

/// 日历到点自动开会捕获(macOS 专属)。
///
/// 开启后,定时(每 30s)向 `EventKitService` 查「即将开始的会议型事件」(含视频会议链接或有与会者)。
/// 检测到一个会议即将到点:
///  - 「提示」模式(默认):把它放进 `pendingMeeting`,UI 弹一张卡片让用户一键开始捕获;
///  - 「自动」模式:直接拉起 `MeetingCaptureService`(若麦克风没被语音对话占用)。
/// 捕获停止后,把 `MeetingNotesSummarizer` 提炼的纪要**写回该日历事件的备注**(找不到事件时回退系统备忘录)。
///
/// 隐私 / 互斥:只在用户显式开启后才轮询;自动开会前检查 `MeetingCaptureService.voiceBusy`(与语音对话互斥),
/// 占用时降级为「提示」不强开。轮询定时器仅在 app 运行期间生效(后台常驻受 OS 限制,与 SchedulerService 同)。
///
/// 并发:本类 `@MainActor`(`@Published` 安全发布);定时器回调走 `Task { @MainActor }`;
/// EventKit 通知回调闭包显式 `@Sendable`(本类是 @MainActor,裸闭包继承隔离会在后台队列执行器断言崩溃)。
@MainActor
final class CalendarMeetingWatcher: ObservableObject {
    static let shared = CalendarMeetingWatcher()

    /// 总开关(持久化)。开启即起轮询,关闭即停。
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? startPolling() : stopPolling()
        }
    }
    /// 到点是否**自动**开始捕获(否则只提示)。持久化。
    @Published var autoStart: Bool {
        didSet {
            UserDefaults.standard.set(autoStart, forKey: Self.autoStartKey)
            refreshAfterPreferenceChange()
        }
    }
    /// 提前多少分钟视为「即将开始」(到点前这个窗口内就提示/开会)。1~10。
    @Published var leadMinutes: Int {
        didSet {
            let clamped = min(max(leadMinutes, 1), 10)
            guard clamped == leadMinutes else {
                leadMinutes = clamped
                return
            }
            UserDefaults.standard.set(leadMinutes, forKey: Self.leadKey)
            refreshAfterPreferenceChange()
        }
    }

    /// 当前待处理的会议(UI 弹卡片让用户决定开/忽略)。nil = 没有。
    @Published private(set) var pendingMeeting: EventKitService.UpcomingMeeting?
    /// 最近一次把纪要写回事件的结果文案(成功/失败,给 UI 短暂展示)。
    @Published var lastArchiveResult: String?
    /// 正在生成并写回纪要。
    @Published private(set) var isArchiving = false

    static let enabledKey = "calendarMeetingWatcher.enabled"
    static let autoStartKey = "calendarMeetingWatcher.autoStart"
    static let leadKey = "calendarMeetingWatcher.leadMinutes"

    private weak var viewModel: AppViewModel?
    private var timer: Timer?
    /// 已经处理过(提示过 / 自动开过)的事件标识符,避免同一会议反复弹/反复开。
    private var handledIdentifiers: Set<String> = []
    /// 当前由本 watcher 自动/手动开启、正在捕获的会议——停止后用它把纪要写回。
    private var activeMeeting: EventKitService.UpcomingMeeting?

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.autoStart = UserDefaults.standard.bool(forKey: Self.autoStartKey)
        let lead = UserDefaults.standard.integer(forKey: Self.leadKey)
        self.leadMinutes = lead == 0 ? 2 : min(max(lead, 1), 10)
    }

    // MARK: - 生命周期

    /// 注入 viewModel(用于挑 provider 做纪要)并按开关起轮询。重复调用安全。
    func start(viewModel: AppViewModel) {
        self.viewModel = viewModel
        if isEnabled { startPolling() }
    }

    private func startPolling() {
        stopPolling()
        // 立刻查一次,再每 30s 查。
        Task { @MainActor [weak self] in await self?.poll() }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshAfterPreferenceChange() {
        guard isEnabled else { return }
        Task { @MainActor [weak self] in await self?.poll() }
    }

    // MARK: - 轮询

    /// 查即将到点的会议;取最近一个未处理的:自动模式直接开,否则放进 pendingMeeting 提示。
    private func poll() async {
        guard isEnabled else { return }
        if autoStart, let pending = pendingMeeting,
           !MeetingCaptureService.shared.voiceBusy,
           !MeetingCaptureService.shared.isCapturing {
            await beginCapture(for: pending)
            return
        }

        let meetings = await EventKitService.shared.upcomingMeetings(withinMinutes: leadMinutes)
        // 清掉已经远去(超过 lead 窗口又没在捕获)的 handled 记录,允许同名循环会议下次再触发。
        let liveIDs = Set(meetings.map { $0.eventIdentifier })
        handledIdentifiers.formIntersection(liveIDs.union(activeMeeting.map { [$0.eventIdentifier] } ?? []))

        guard let next = meetings.first(where: { !handledIdentifiers.contains($0.eventIdentifier) }) else { return }
        // 正在捕获别的会议就不打扰。
        guard !MeetingCaptureService.shared.isCapturing else { return }

        handledIdentifiers.insert(next.eventIdentifier)

        if autoStart && !MeetingCaptureService.shared.voiceBusy {
            await beginCapture(for: next)
        } else {
            // 语音占用或非自动:提示用户。
            pendingMeeting = next
        }
    }

    // MARK: - 开始 / 结束捕获

    /// 用户从提示卡片点「开始捕获」时调用(也供自动模式内部调用)。
    func beginCapture(for meeting: EventKitService.UpcomingMeeting) async {
        pendingMeeting = nil
        handledIdentifiers.insert(meeting.eventIdentifier)
        guard !MeetingCaptureService.shared.isCapturing else { return }
        do {
            try await MeetingCaptureService.shared.start()
            activeMeeting = meeting
        } catch {
            lastArchiveResult = (error as? LocalizedError)?.errorDescription
                ?? "无法开始会议捕获:\(error.localizedDescription)"
            activeMeeting = nil
        }
    }

    /// 忽略当前提示(用户点「不用了」)。
    func dismissPending() {
        pendingMeeting = nil
    }

    /// 停止捕获并把纪要写回当前 `activeMeeting` 的日历事件备注。
    /// 没有 activeMeeting(不是 watcher 开的会)时只停,不写回。
    func stopCaptureAndArchive() async {
        let meeting = activeMeeting
        activeMeeting = nil
        await MeetingCaptureService.shared.stop()
        guard let meeting else { return }
        await archive(meeting: meeting)
    }

    /// 生成纪要并写回事件备注(失败回退系统备忘录;再失败给文案)。
    private func archive(meeting: EventKitService.UpcomingMeeting) async {
        let transcript = MeetingCaptureService.shared.renderedTranscript()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            lastArchiveResult = "没有捕获到内容,未写入纪要。"
            return
        }
        guard let provider = pickProvider() else {
            lastArchiveResult = "没有可用模型生成纪要,转写已保留在会议捕获面板。"
            return
        }

        isArchiving = true
        defer { isArchiving = false }

        let notes: MeetingNotes
        do {
            notes = try await MeetingNotesSummarizer.summarizeMeeting(transcript: transcript, provider: provider)
        } catch {
            lastArchiveResult = "生成纪要失败:\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            return
        }

        let body = Self.renderNotesText(meeting: meeting, notes: notes)
        // 先写回日历事件;失败回退系统备忘录。
        do {
            _ = try await EventKitService.shared.appendNotes(toEventIdentifier: meeting.eventIdentifier, append: body)
            lastArchiveResult = "已把会议纪要写回日历事件「\(meeting.title)」的备注。"
        } catch {
            do {
                _ = try NotesService.createNote(title: "会议纪要 · \(meeting.title)", body: body)
                lastArchiveResult = "日历写回失败,纪要已存进系统「备忘录」。"
            } catch {
                lastArchiveResult = "纪要生成成功但写回失败:\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)。转写仍保留在会议捕获面板。"
            }
        }
    }

    // MARK: - 工具

    private func pickProvider() -> ProviderConfig? {
        guard let vm = viewModel else { return nil }
        if let chair = vm.chairProvider, !chair.kind.isCLI { return chair }
        return vm.providers.first { $0.enabled && !$0.kind.isCLI }
    }

    /// 把结构化纪要拼成写进事件备注的纯文本。
    static func renderNotesText(meeting: EventKitService.UpcomingMeeting, notes: MeetingNotes) -> String {
        var lines: [String] = []
        lines.append("【Kown 会议纪要】")
        if !notes.summary.isEmpty {
            lines.append("")
            lines.append("摘要:")
            lines.append(notes.summary)
        }
        if !notes.decisions.isEmpty {
            lines.append("")
            lines.append("关键决议:")
            for d in notes.decisions { lines.append("• \(d)") }
        }
        if !notes.actionItems.isEmpty {
            lines.append("")
            lines.append("行动项:")
            for item in notes.actionItems {
                var l = "• \(item.task)"
                if let owner = item.owner, !owner.isEmpty { l += "(负责人:\(owner))" }
                if let due = item.dueText, !due.isEmpty { l += "(截止:\(due))" }
                lines.append(l)
            }
        }
        return lines.joined(separator: "\n")
    }
}
#endif
