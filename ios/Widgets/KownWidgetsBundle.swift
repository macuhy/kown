import SwiftUI
import WidgetKit

/// KownWidgets 扩展入口:三个桌面小组件 + 深入模式 Live Activity。
@main
struct KownWidgetsBundle: WidgetBundle {
    var body: some Widget {
        QuickAskWidget()
        BriefingWidget()
        BudgetWidget()
        #if canImport(ActivityKit)
        DeepTaskLiveActivity()
        #endif
    }
}
