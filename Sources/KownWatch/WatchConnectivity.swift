import Foundation
import WatchConnectivity

/// 表盘端接收手机经 WCSession 推送的 provider 配置。
/// 激活时先读 `receivedApplicationContext`(手机最近一次推送的最新状态,即使推送时表盘 app 没开也拿得到),
/// 之后 `didReceiveApplicationContext` 实时更新。收到即本地缓存。
@MainActor
final class WatchConnectivityReceiver: NSObject, ObservableObject {
    static let shared = WatchConnectivityReceiver()

    @Published var config: WatchProviderConfig?

    private override init() {
        super.init()
        config = WatchConfigStore.loadLocal()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    fileprivate func apply(_ ctx: [String: Any]) {
        guard let name = ctx["name"] as? String,
              let baseURL = ctx["baseURL"] as? String,
              let apiKey = ctx["apiKey"] as? String,
              let model = ctx["model"] as? String,
              !apiKey.isEmpty, !baseURL.isEmpty else {
            // 手机推了空配置(清空)→ 清掉本地。
            config = nil
            WatchConfigStore.saveLocal(nil)
            return
        }
        let cfg = WatchProviderConfig(name: name, baseURL: baseURL, apiKey: apiKey, model: model)
        config = cfg
        WatchConfigStore.saveLocal(cfg)
    }
}

extension WatchConnectivityReceiver: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let ctx = session.receivedApplicationContext
        Task { @MainActor in self.apply(ctx) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }
}
