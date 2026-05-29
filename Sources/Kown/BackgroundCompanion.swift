import Foundation
#if os(iOS)
import UIKit
import UserNotifications
#endif

/// iOS 流式发送时的"后台保命 + 完成通知"封装。
/// - macOS 上所有方法都 no-op(macOS app 后台天然能跑,不需要)。
/// - iOS 上 `beginBackgroundTask` 让流式在切走/锁屏后还能撑 ~30s–3min,
///   系统快要 suspend 时回调 onExpiration,业务方应在此 cancel 流并把 turn 标错。
/// - `notifyIfBackgrounded` 在完成时若 app 不在前台,丢一条本地通知敲一下用户。
@MainActor
final class BackgroundCompanion {
    static let shared = BackgroundCompanion()

    #if os(iOS)
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    private var permissionAsked = false
    #endif

    /// 首次需要时申请通知权限(惰性 — 第一次 send 时调,有了上下文用户更愿意同意)。
    func ensureNotificationPermission() {
        #if os(iOS)
        guard !permissionAsked else { return }
        permissionAsked = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
        #endif
    }

    /// 开始一个长流式任务的后台保命。iOS 系统要 suspend 之前会回调 `onExpiration`。
    func beginIfNeeded(onExpiration: @MainActor @escaping () -> Void) {
        #if os(iOS)
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "kown-stream") {
            Task { @MainActor in
                onExpiration()
                BackgroundCompanion.shared.end()
            }
        }
        #endif
    }

    /// 任务结束(无论正常 / 失败 / 取消)时释放后台 token。
    func end() {
        #if os(iOS)
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
        #endif
    }

    /// 完成时如果 app 不在前台就发本地通知,前台时静默(避免在用户眼皮底下叮)。
    func notifyIfBackgrounded(title: String, body: String) {
        #if os(iOS)
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { _ in }
        #endif
    }
}
