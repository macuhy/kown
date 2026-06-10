import SwiftUI
import WidgetKit

/// 晨间简报小组件:显示最近一份晨报的标题 + 前几条要点。
/// 数据来自 App Group 容器里的 JSON 快照(主 app 的 WidgetBridge 在晨报生成后写入)。
struct BriefingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KownBriefing", provider: BriefingProvider()) { entry in
            BriefingView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("晨间简报")
        .description("最近一份晨报的要点,一眼看完今天的重点。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct BriefingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetBridge.BriefingSnapshot?
}

struct BriefingProvider: TimelineProvider {
    func placeholder(in context: Context) -> BriefingEntry {
        BriefingEntry(date: .now, snapshot: WidgetBridge.BriefingSnapshot(
            title: "今日晨报", points: ["09:30 产品周会,提前备好进度页", "订阅话题:Swift 6.2 发布要点"],
            generatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (BriefingEntry) -> Void) {
        completion(BriefingEntry(date: .now, snapshot: WidgetBridge.loadBriefing()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BriefingEntry>) -> Void) {
        // 主要靠主 app 写完快照后 reloadAllTimelines;这里再兜底每小时自刷一次。
        let entry = BriefingEntry(date: .now, snapshot: WidgetBridge.loadBriefing())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

private struct BriefingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BriefingEntry

    private var maxPoints: Int { family == .systemLarge ? 6 : 3 }

    var body: some View {
        if let snap = entry.snapshot {
            content(snap)
        } else {
            empty
        }
    }

    private func content(_ snap: WidgetBridge.BriefingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.orange)
                Text(snap.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(snap.generatedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Divider()
            ForEach(Array(snap.points.prefix(maxPoints).enumerated()), id: \.offset) { _, point in
                HStack(alignment: .top, spacing: 5) {
                    Text("•")
                        .foregroundStyle(.tint)
                    Text(point)
                        .font(.caption)
                        .lineLimit(family == .systemLarge ? 2 : 1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "sun.haze")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("还没有晨间简报")
                .font(.subheadline)
            Text("在 App 的「定时任务」里设置一份晨报")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
