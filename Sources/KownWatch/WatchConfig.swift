import Foundation

/// 手机经 WatchConnectivity 推送、表盘接收并本地缓存的精简 provider 配置(仅 OpenAI 兼容)。
struct WatchProviderConfig: Codable, Equatable {
    var name: String
    var baseURL: String
    var apiKey: String
    var model: String
}

/// 表盘本地缓存(UserDefaults.standard):存最近一次从手机收到的配置,重启后仍在。
/// 注意:**不能**用 App Group 从手机读 —— App Group 容器不跨 iPhone/Watch 设备,必须走 WCSession。
enum WatchConfigStore {
    static let key = "kown.watch.provider.v1"

    static func loadLocal() -> WatchProviderConfig? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cfg = try? JSONDecoder().decode(WatchProviderConfig.self, from: data),
              !cfg.apiKey.isEmpty, !cfg.baseURL.isEmpty
        else { return nil }
        return cfg
    }

    static func saveLocal(_ cfg: WatchProviderConfig?) {
        guard let cfg, let data = try? JSONEncoder().encode(cfg) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// 表盘上可选的「模式」——独立直连 API,只能单模型,所以用 system prompt 预设来体现模式差异。
enum WatchMode: String, CaseIterable, Identifiable {
    case direct
    case concise
    case translate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .direct:    return "直接"
        case .concise:   return "简洁"
        case .translate: return "翻译"
        }
    }

    var systemPrompt: String {
        switch self {
        case .direct:
            return "你是一个有帮助的助手,请准确、清晰地回答问题。回答会被朗读出来,所以避免冗长的代码或表格,用自然语言为主。"
        case .concise:
            return "你是一个简洁的助手。用最精炼的语言回答,通常 1–3 句话,直接给结论。回答会被朗读出来。"
        case .translate:
            return "你是翻译助手。在中文与英文之间智能互译:输入中文就译成地道英文,输入英文就译成地道简体中文。只输出译文本身,不加解释。"
        }
    }
}
