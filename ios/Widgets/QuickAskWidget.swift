import SwiftUI
import WidgetKit

/// 快捷提问小组件:点击经 `kown://ask` 深链打开 app 并聚焦输入框。
/// 中尺寸额外给一个「新建会话」入口(`kown://new`)。
struct QuickAskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KownQuickAsk", provider: QuickAskProvider()) { _ in
            QuickAskView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("快捷提问")
        .description("一键打开 Kown 并聚焦输入框,马上开问。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickAskEntry: TimelineEntry {
    let date: Date
}

struct QuickAskProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickAskEntry { QuickAskEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (QuickAskEntry) -> Void) {
        completion(QuickAskEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickAskEntry>) -> Void) {
        // 纯静态入口,无需刷新。
        completion(Timeline(entries: [QuickAskEntry(date: .now)], policy: .never))
    }
}

private struct QuickAskView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium: medium
        default: small
        }
    }

    /// 小尺寸:整卡一个「问 Kown」按钮。
    private var small: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            Text("问 Kown")
                .font(.headline)
            Text("点一下,开问")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "kown://ask"))
    }

    /// 中尺寸:快捷提问 + 新建会话两个入口。
    private var medium: some View {
        HStack(spacing: 12) {
            Link(destination: URL(string: "kown://ask")!) {
                entryCard(icon: "bubble.left.and.text.bubble.right.fill",
                          title: "快捷提问", subtitle: "聚焦输入框")
            }
            Link(destination: URL(string: "kown://new")!) {
                entryCard(icon: "plus.bubble.fill",
                          title: "新建会话", subtitle: "开个新话题")
            }
        }
        .padding(.horizontal, 4)
    }

    private func entryCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
