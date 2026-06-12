import SwiftUI
import WidgetKit

/// KownWidgets 扩展入口:三个桌面小组件 + 深入模式 Live Activity + 控制中心控件。
@main
struct KownWidgetsBundle: WidgetBundle {
    var body: some Widget {
        QuickAskWidget()
        BriefingWidget()
        BudgetWidget()
        #if canImport(ActivityKit)
        DeepTaskLiveActivity()
        #endif
        // ControlWidget 是 iOS 18 API,deployment target 是 17 →
        // 用嵌套 bundle + buildLimitedAvailability 按运行时版本挂载。
        if #available(iOS 18.0, *) {
            KownControlWidgets().body
        }
    }
}

/// iOS 18+ 的控制中心控件单独成一个 bundle,供上面按可用性挂载。
@available(iOS 18.0, *)
struct KownControlWidgets: WidgetBundle {
    var body: some Widget {
        VoiceControlWidget()
    }
}
