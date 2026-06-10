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

    /// 存入收到的配置(nil = 清空)。在 MainActor 上跑。
    fileprivate func store(_ cfg: WatchProviderConfig?) {
        config = cfg
        WatchConfigStore.saveLocal(cfg)
        // 把模型名同步给表盘复杂功能(没有回答摘要时矩形复杂功能第二行显示模型名)。
        WatchWidgetShared.updateModel(cfg?.model)
    }

    /// 把 WCSession 的 `[String: Any]` 解析成 Sendable 的 config —— **必须在 nonisolated 上下文同步解析**,
    /// 不能把非 Sendable 的字典送进 @MainActor 闭包(Swift 6 严格并发会判数据竞争)。
    nonisolated static func parse(_ ctx: [String: Any]) -> WatchProviderConfig? {
        guard let name = ctx["name"] as? String,
              let baseURL = ctx["baseURL"] as? String,
              let apiKey = ctx["apiKey"] as? String,
              let model = ctx["model"] as? String,
              !apiKey.isEmpty, !baseURL.isEmpty else {
            return nil
        }
        // 联网搜索配置可选:缺省为 nil,不影响主配置有效性。
        let fcBase = (ctx["firecrawlBaseURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let fcKey = (ctx["firecrawlKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return WatchProviderConfig(name: name, baseURL: baseURL, apiKey: apiKey, model: model,
                                   firecrawlBaseURL: fcBase, firecrawlKey: fcKey)
    }
}

extension WatchConnectivityReceiver: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let cfg = Self.parse(session.receivedApplicationContext)
        Task { @MainActor in self.store(cfg) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let cfg = Self.parse(applicationContext)
        Task { @MainActor in self.store(cfg) }
    }
}
