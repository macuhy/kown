#if os(iOS)
import Foundation

/// App Group 收件箱:分享扩展 / 快捷指令把文字写进来,主 app 前台时取走预填到输入框。
enum SharedInbox {
    static let appGroup = "group.com.xiaobo.kown"
    static let pendingKey = "kown.share.pendingText.v1"
    static let pendingModeKey = "kown.share.pendingMode.v1"

    /// 取出并清空待处理文本(没有则 nil)。
    static func takePending() -> String? {
        let d = UserDefaults(suiteName: appGroup)
        guard let t = d?.string(forKey: pendingKey),
              !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        d?.removeObject(forKey: pendingKey)
        return t
    }

    /// 追加一段待处理文本(供 App Intents 用)。
    static func deposit(_ text: String) {
        let d = UserDefaults(suiteName: appGroup)
        var existing = d?.string(forKey: pendingKey) ?? ""
        if !existing.isEmpty { existing += "\n\n" }
        existing += text
        d?.set(existing, forKey: pendingKey)
    }

    /// 指定本次预填使用的模式(App Intents「用某模式问」用)。
    static func depositMode(_ rawMode: String) {
        UserDefaults(suiteName: appGroup)?.set(rawMode, forKey: pendingModeKey)
    }

    /// 取出并清空待处理模式。
    static func takePendingMode() -> String? {
        let d = UserDefaults(suiteName: appGroup)
        let m = d?.string(forKey: pendingModeKey)
        d?.removeObject(forKey: pendingModeKey)
        return m
    }
}
#endif
