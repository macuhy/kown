#if os(iOS)
import Foundation
import WatchConnectivity

/// 把一个 OpenAI 兼容、已配 key 的 provider 推送给 Apple Watch 独立表盘 app(经 WatchConnectivity)。
///
/// **不能用 App Group** —— App Group 容器不跨 iPhone/Watch 设备(只在同设备的 app+扩展间共享)。
/// 跨设备必须走 `WCSession.updateApplicationContext`:发「最新状态」,表盘下次可用时(含 app 未开)即收到。
@MainActor
final class WatchConnectivityManager: NSObject {
    static let shared = WatchConnectivityManager()

    private var pending: [String: String]?

    private override init() {
        super.init()
        activateIfNeeded()
    }

    func activateIfNeeded() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        if s.delegate == nil { s.delegate = self }
        if s.activationState != .activated { s.activate() }
    }

    /// 发送配置(空字典 = 清空表盘配置)。会话没就绪时挂起,激活后补发。
    func send(_ payload: [String: String]) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else {
            pending = payload
            activateIfNeeded()
            return
        }
        try? s.updateApplicationContext(payload)
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            if activationState == .activated, let p = self.pending {
                self.pending = nil
                try? WCSession.default.updateApplicationContext(p)
            }
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}

@MainActor
enum WatchProvisioning {
    /// 写入指定 provider 的配置。provider 不是 OpenAI 兼容 / 没 key 时推送空配置(表盘显示未配置)。
    @discardableResult
    static func sync(provider: ProviderConfig?) -> Bool {
        guard let p = provider, p.kind == .openAICompatible,
              let key = try? KeychainStore.load(id: p.id), !key.isEmpty else {
            WatchConnectivityManager.shared.send([:])
            return false
        }
        WatchConnectivityManager.shared.send([
            "name": p.displayName,
            "baseURL": p.baseURL,
            "apiKey": key,
            "model": p.model
        ])
        return true
    }
}
#endif
