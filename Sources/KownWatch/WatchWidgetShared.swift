import Foundation
import WidgetKit

/// 表盘复杂功能(Complication)与 watch app 共享的快照数据:经 watch 端 App Group UserDefaults 传递。
/// 此文件**同时编进** KownWatch app 与 KownWatchWidgets 扩展(见 ios/project.yml 两个 target 的 sources)。
/// 注意:App Group 容器不跨 iPhone/Watch 设备,这里是 **watch 内部** app ↔ widget 扩展的共享,合法可用。
enum WatchWidgetShared {
    static let appGroupID = "group.com.xiaobo.kown"
    static let answerKey = "kown.watch.widget.lastAnswerSummary"
    static let modelKey = "kown.watch.widget.modelName"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    /// 最近一次回答的一句话摘要(写入时已去换行、截断),没有则 nil。
    static var answerSummary: String? {
        (defaults?.string(forKey: answerKey)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 当前同步的模型名,没有则 nil。
    static var modelName: String? {
        (defaults?.string(forKey: modelKey)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// watch app 收到完整回答后调用:写一句摘要并刷新表盘复杂功能。
    static func updateAnswer(_ answer: String) {
        let summary = summarize(answer)
        guard !summary.isEmpty else { return }
        defaults?.set(summary, forKey: answerKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// watch app 收到手机推送的配置(或清空)后调用:写模型名并刷新表盘复杂功能。
    static func updateModel(_ model: String?) {
        if let model, !model.isEmpty {
            defaults?.set(model, forKey: modelKey)
        } else {
            defaults?.removeObject(forKey: modelKey)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 压成适合 accessoryRectangular 第二行的一句话:换行变空格,截 60 字。
    static func summarize(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > 60 else { return oneLine }
        return String(oneLine.prefix(60)) + "…"
    }
}
