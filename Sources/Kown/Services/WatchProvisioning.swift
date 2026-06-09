#if os(iOS)
import Foundation

/// 把一个 OpenAI 兼容、已配 key 的 provider 写进共享 App Group,供 Apple Watch 独立表盘 app 直连调用。
/// 表盘端读同一个 App Group(见 KownWatch/WatchConfig.swift)。仅 iOS 有意义(表盘配对在手机侧)。
@MainActor
enum WatchProvisioning {
    static let appGroup = "group.com.xiaobo.kown"
    static let defaultsKey = "kown.watch.provider.v1"

    /// 写入指定 provider 的配置。provider 不是 OpenAI 兼容 / 没 key 时清空(表盘显示未配置)。
    @discardableResult
    static func sync(provider: ProviderConfig?) -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return false }
        guard let p = provider, p.kind == .openAICompatible,
              let key = try? KeychainStore.load(id: p.id), !key.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return false
        }
        let payload: [String: String] = [
            "name": p.displayName,
            "baseURL": p.baseURL,
            "apiKey": key,
            "model": p.model
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        defaults.set(data, forKey: defaultsKey)
        return true
    }
}
#endif
