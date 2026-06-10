import SwiftUI
import WidgetKit

// 表盘复杂功能:点按打开 watch app 直达提问界面(widgetURL kown://ask)。
// 数据来自 watch app 写入 App Group UserDefaults 的快照(WatchWidgetShared,
// 该文件由 project.yml 同时编进本扩展)。

struct KownComplicationEntry: TimelineEntry {
    let date: Date
    /// 最近一次回答的一句摘要(无则 nil)。
    let answerSummary: String?
    /// 当前同步的模型名(无则 nil)。
    let modelName: String?
}

struct KownComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> KownComplicationEntry {
        KownComplicationEntry(date: .now, answerSummary: "今天多云转晴,21–26℃。", modelName: "Kown")
    }

    func getSnapshot(in context: Context, completion: @escaping (KownComplicationEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KownComplicationEntry>) -> Void) {
        // 数据只在 watch app 写入时变化,app 侧调 WidgetCenter reload 主动刷新,这里不排未来时间线。
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> KownComplicationEntry {
        KownComplicationEntry(date: .now,
                              answerSummary: WatchWidgetShared.answerSummary,
                              modelName: WatchWidgetShared.modelName)
    }
}

struct KownComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var entry: KownComplicationEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            // app 图标风格的圆形入口。
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
            }
        case .accessoryCorner:
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .widgetLabel("问 Kown")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2.weight(.bold))
                    Text("问 Kown")
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(secondLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Text("问 Kown")
        default:
            Image(systemName: "sparkles")
        }
    }

    /// 矩形第二行:最近回答摘要 > 模型名 > 「点按提问」。
    private var secondLine: String {
        if let summary = entry.answerSummary { return summary }
        if let model = entry.modelName { return model }
        return "点按提问"
    }
}

struct KownComplication: Widget {
    let kind = "KownComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: KownComplicationProvider()) { entry in
            KownComplicationView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
                // 点按直达 watch app 提问界面(主界面即提问界面,app 侧 onOpenURL 处理)。
                .widgetURL(URL(string: "kown://ask"))
        }
        .configurationDisplayName("问 Kown")
        .description("表盘一点即问:语音提问,朗读回答。")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct KownWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        KownComplication()
    }
}
