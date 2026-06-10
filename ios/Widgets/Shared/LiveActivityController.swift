#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

/// 深入模式 → Live Activity(灵动岛 / 锁屏卡片)控制器。
///
/// **只编进 iOS 主 app target**(ios/project.yml 把本文件加进 Kown 的 sources;
/// KownWidgets 用 excludes 排除它)。Sources/Kown(SwiftPM / mac 也编)不能 import ActivityKit,
/// 所以那边只通过 `DeepTaskEvents` 发 NotificationCenter 事件 + 启动时经
/// `NSClassFromString("KownLiveActivityController")` 调用 `activate()` 激活本类 —
/// 编译期零依赖,运行期单向桥接。
@objc(KownLiveActivityController)
@MainActor
final class LiveActivityController: NSObject {
    static let shared = LiveActivityController()

    private var installed = false
    /// 进行中的 Activity 的 id。`Activity` 非 Sendable,不能跨 Task 捕获;
    /// 这里只存 id(String,Sendable),更新/结束时在 detached Task 里按 id 查回实例。
    private var activityID: String?
    private var totalRounds = 12

    /// Sources/Kown 在 app 启动时经 ObjC runtime 调用(KownApp.task → DeepTaskEvents)。
    /// 启动 .task 在主线程上跑,这里直接 assumeIsolated 安装观察者。
    @objc static func activate() {
        MainActor.assumeIsolated {
            shared.installIfNeeded()
        }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        // queue: .main 保证回调在主线程,assumeIsolated 接回 MainActor。
        center.addObserver(forName: DeepTaskEvents.started, object: nil, queue: .main) { note in
            let title = note.userInfo?["title"] as? String ?? ""
            let total = note.userInfo?["totalRounds"] as? Int ?? 12
            MainActor.assumeIsolated {
                LiveActivityController.shared.start(title: title, totalRounds: total)
            }
        }
        center.addObserver(forName: DeepTaskEvents.toolStep, object: nil, queue: .main) { note in
            let round = note.userInfo?["round"] as? Int ?? 0
            let name = note.userInfo?["displayName"] as? String ?? ""
            let status = note.userInfo?["status"] as? String ?? ""
            MainActor.assumeIsolated {
                LiveActivityController.shared.update(round: round, displayName: name, status: status)
            }
        }
        center.addObserver(forName: DeepTaskEvents.ended, object: nil, queue: .main) { note in
            let success = note.userInfo?["success"] as? Bool ?? true
            MainActor.assumeIsolated {
                LiveActivityController.shared.end(success: success)
            }
        }
    }

    // MARK: - Activity 生命周期

    private func start(title: String, totalRounds: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // 防重:上一个还挂着就先立即收掉。
        if let oldID = activityID {
            activityID = nil
            Self.endActivity(id: oldID, state: nil, dismissAfterSeconds: nil)
        }
        self.totalRounds = totalRounds
        let attrs = DeepTaskActivityAttributes(title: title.isEmpty ? "深入任务" : title)
        let state = DeepTaskActivityAttributes.ContentState(
            phase: "规划中…", round: 0, totalRounds: totalRounds, completed: false)
        let activity = try? Activity.request(
            attributes: attrs,
            content: ActivityContent(state: state, staleDate: nil))
        activityID = activity?.id
    }

    private func update(round: Int, displayName: String, status: String) {
        guard let activityID else { return }
        let phase: String
        switch status {
        case "running": phase = "\(displayName)…"
        case "error":   phase = "\(displayName) 失败,继续推进"
        default:        phase = "\(displayName) ✓"
        }
        let state = DeepTaskActivityAttributes.ContentState(
            phase: phase, round: max(round, 0), totalRounds: totalRounds, completed: false)
        Self.updateActivity(id: activityID, state: state)
    }

    private func end(success: Bool) {
        guard let activityID else { return }
        self.activityID = nil
        let state = DeepTaskActivityAttributes.ContentState(
            phase: success ? "已完成,回 App 查看结果" : "已停止",
            round: totalRounds, totalRounds: totalRounds, completed: true)
        Self.endActivity(id: activityID, state: state, dismissAfterSeconds: 10)
    }

    // MARK: - 跨 Task 的 Activity 操作(按 id 查回实例,绕开 Activity 非 Sendable)

    private nonisolated static func updateActivity(
        id: String, state: DeepTaskActivityAttributes.ContentState
    ) {
        Task.detached {
            for act in Activity<DeepTaskActivityAttributes>.activities where act.id == id {
                await act.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    /// `state == nil` → 直接立即移除(防重路径);否则按 `dismissAfterSeconds` 延迟消失。
    private nonisolated static func endActivity(
        id: String, state: DeepTaskActivityAttributes.ContentState?, dismissAfterSeconds: Double?
    ) {
        Task.detached {
            for act in Activity<DeepTaskActivityAttributes>.activities where act.id == id {
                let content = state.map { ActivityContent(state: $0, staleDate: nil) }
                let policy: ActivityUIDismissalPolicy =
                    dismissAfterSeconds.map { .after(.now + $0) } ?? .immediate
                await act.end(content, dismissalPolicy: policy)
            }
        }
    }
}
#endif
