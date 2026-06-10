import SwiftUI
import WidgetKit

/// 用量/预算小组件:本月花费 vs 预算上限的 gauge。
/// 数据来自 App Group 容器里的 JSON 快照(主 app 的 WidgetBridge 在用量更新时写入)。
struct BudgetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KownBudget", provider: BudgetProvider()) { entry in
            BudgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("本月用量")
        .description("本月 API 花费与预算上限,一眼掌握开销。")
        .supportedFamilies([.systemSmall])
    }
}

struct BudgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetBridge.BudgetSnapshot?
}

struct BudgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetEntry {
        BudgetEntry(date: .now, snapshot: WidgetBridge.BudgetSnapshot(
            monthSpendUSD: 3.42, monthlyCapUSD: 10, updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (BudgetEntry) -> Void) {
        completion(BudgetEntry(date: .now, snapshot: WidgetBridge.loadBudget()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetEntry>) -> Void) {
        // 主要靠主 app 用量更新后 reloadAllTimelines;这里兜底每小时自刷一次。
        let entry = BudgetEntry(date: .now, snapshot: WidgetBridge.loadBudget())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

private struct BudgetView: View {
    let entry: BudgetEntry

    var body: some View {
        if let snap = entry.snapshot {
            content(snap)
        } else {
            empty
        }
    }

    @ViewBuilder
    private func content(_ snap: WidgetBridge.BudgetSnapshot) -> some View {
        let spend = max(0, snap.monthSpendUSD)
        let cap = max(0, snap.monthlyCapUSD)
        VStack(spacing: 6) {
            if cap > 0 {
                Gauge(value: min(spend, cap), in: 0...cap) {
                    Text("预算")
                } currentValueLabel: {
                    Text(verbatim: String(format: "%.0f%%", spend / cap * 100))
                        .font(.system(.body, design: .rounded).bold())
                }
                .gaugeStyle(.accessoryCircular)
                .tint(spend >= cap ? .red : (spend >= cap * 0.8 ? .orange : .green))
                Text(verbatim: String(format: "$%.2f / $%.0f", spend, cap))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(verbatim: String(format: "$%.2f", spend))
                    .font(.system(.title3, design: .rounded).bold())
                Text("本月花费 · 未设预算")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.pie")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("暂无用量数据")
                .font(.caption)
            Text("在 App 里发一条消息后生成")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
