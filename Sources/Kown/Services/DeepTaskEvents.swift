import Foundation

/// 深入模式(多步 Agent)的生命周期事件 — Live Activity(灵动岛)的「极薄挂钩」。
///
/// Sources/Kown 同时被 SwiftPM / mac / iOS 编译,不能直接 import ActivityKit 驱动灵动岛。
/// 所以这里只用 NotificationCenter 发结构化事件;真正的 Live Activity 控制器
/// (`LiveActivityController`,ObjC 名 `KownLiveActivityController`)放在 ios/Widgets/Shared/,
/// 只编进 iOS 主 app target,由它订阅这些事件并 start / update / end Activity。
///
/// 事件流:
/// - `started`(userInfo: title, totalRounds)— 深入模式发送开始;
/// - `toolStep`(userInfo: round, displayName, status)— 每步工具调用 running/done/error;
/// - `ended`(userInfo: success)— 本轮完成 / 取消 / 被系统挂起。
enum DeepTaskEvents {
    static let started = Notification.Name("kown.deepTask.started")
    static let toolStep = Notification.Name("kown.deepTask.toolStep")
    static let ended = Notification.Name("kown.deepTask.ended")

    @MainActor
    static func postStarted(title: String, totalRounds: Int) {
        NotificationCenter.default.post(name: started, object: nil,
                                        userInfo: ["title": title, "totalRounds": totalRounds])
    }

    @MainActor
    static func postToolStep(round: Int, displayName: String, status: String) {
        NotificationCenter.default.post(name: toolStep, object: nil,
                                        userInfo: ["round": round, "displayName": displayName,
                                                   "status": status])
    }

    /// 没有进行中的 Activity 时是 no-op,所以取消/挂起路径可以无条件调用。
    @MainActor
    static func postEnded(success: Bool) {
        NotificationCenter.default.post(name: ended, object: nil, userInfo: ["success": success])
    }

    /// App 启动时调用一次:经 ObjC runtime 查找 iOS target 侧的 LiveActivityController 并激活
    /// (注册 NotificationCenter 观察者)。SwiftPM / mac 下查无此类 → 静默 no-op,
    /// 这样 Sources/Kown 对 ios/Widgets/Shared/ 没有任何编译期依赖。
    @MainActor
    static func activateLiveActivityControllerIfAvailable() {
        #if os(iOS)
        guard let cls = NSClassFromString("KownLiveActivityController") as? NSObject.Type else { return }
        _ = (cls as AnyObject).perform(NSSelectorFromString("activate"))
        #endif
    }
}
