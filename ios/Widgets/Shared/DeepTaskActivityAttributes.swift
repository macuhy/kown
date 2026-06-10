#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// 深入模式(多步 Agent)Live Activity 的属性定义。
///
/// 本文件被 **主 app target(Kown)** 和 **widget 扩展(KownWidgets)** 同时编译
/// (见 ios/project.yml 两个 target 的 sources),双方对同一 attributes 类型工作:
/// - 主 app:`LiveActivityController` 负责 start / update / end;
/// - 扩展:`DeepTaskLiveActivity` 负责锁屏卡片 + 灵动岛 UI。
///
/// 不要挪进 Sources/Kown — 那里同时被 SwiftPM / mac 编译,不该带 ActivityKit 依赖。
struct DeepTaskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 当前阶段文案(如「规划中…」「联网搜索…」「已完成」)。
        var phase: String
        /// 第几轮工具(1 起;0 = 还没开始调用工具)。
        var round: Int
        /// 工具轮上限(深入模式 12),用于进度展示。
        var totalRounds: Int
        /// 任务是否已结束。
        var completed: Bool
    }

    /// 任务标题(用户问题截断)。
    var title: String
}
#endif
