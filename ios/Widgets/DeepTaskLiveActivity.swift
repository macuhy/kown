#if canImport(ActivityKit)
import ActivityKit
import SwiftUI
import WidgetKit

/// 深入模式 Live Activity 的 UI:锁屏卡片 + 灵动岛(compact / minimal / expanded)。
/// 主 app 侧由 LiveActivityController 驱动 start / update / end。
struct DeepTaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeepTaskActivityAttributes.self) { context in
            // 锁屏 / 横幅卡片
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("深入模式", systemImage: "brain.head.profile")
                        .font(.caption.bold())
                        .foregroundStyle(.purple)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(roundText(context.state))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.phase)
                            .font(.caption)
                            .lineLimit(1)
                        ProgressView(value: progress(context.state))
                            .tint(context.state.completed ? .green : .purple)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.completed ? "checkmark.circle.fill" : "brain.head.profile")
                    .foregroundStyle(context.state.completed ? .green : .purple)
            } compactTrailing: {
                Text(roundText(context.state))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } minimal: {
                Image(systemName: context.state.completed ? "checkmark.circle.fill" : "brain.head.profile")
                    .foregroundStyle(context.state.completed ? .green : .purple)
            }
        }
    }
}

private func roundText(_ state: DeepTaskActivityAttributes.ContentState) -> String {
    state.completed ? "完成" : "\(max(state.round, 1))/\(state.totalRounds)"
}

private func progress(_ state: DeepTaskActivityAttributes.ContentState) -> Double {
    guard !state.completed else { return 1 }
    guard state.totalRounds > 0 else { return 0 }
    return min(1, Double(state.round) / Double(state.totalRounds))
}

private struct LockScreenView: View {
    let context: ActivityViewContext<DeepTaskActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: context.state.completed ? "checkmark.circle.fill" : "brain.head.profile")
                    .foregroundStyle(context.state.completed ? .green : .purple)
                Text("Kown · 深入模式")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(roundText(context.state))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(context.attributes.title)
                .font(.subheadline.bold())
                .lineLimit(1)
            Text(context.state.phase)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ProgressView(value: progress(context.state))
                .tint(context.state.completed ? .green : .purple)
        }
        .padding(12)
    }
}
#endif
