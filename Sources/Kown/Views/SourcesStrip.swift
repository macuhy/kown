import SwiftUI

/// 一组「引用来源」卡片 —— web_search 命中的来源结构化留痕。
/// 在 Turn 回答下方展示:标题 + 域名,点击用系统浏览器打开 url。
/// 视觉风格对齐 `AppliedWritesStrip`(regularMaterial + 圆角 + tinted 渐变 + 描边)。
struct SourcesStrip: View {
    let sources: [SourceRef]
    /// 默认收起,点标题展开。
    @State private var expanded = false

    /// 与 AppliedWrites 的 teal 区分开,来源用蓝色。
    private var tint: Color { Color(red: 0.26, green: 0.52, blue: 0.96) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                    Text("引用来源(\(sources.count))")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                    Spacer()
                    Text("Web Search")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.11), in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(sources) { source in
                    SourceCard(source: source, tint: tint)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.10), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
    }
}

/// 紧凑「Sources」小药丸 —— 放回答卡 footer。点开 popover 展示来源列表。
/// 像 ChatGPT/Perplexity 那样:小图标 + Sources + 数量,不占正文空间。
struct SourcesChip: View {
    let sources: [SourceRef]
    @State private var showPopover = false
    private var tint: Color { Color(red: 0.26, green: 0.52, blue: 0.96) }

    var body: some View {
        if !sources.isEmpty {
            Button {
                showPopover = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .bold))
                    Text("Sources \(sources.count)")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.10), in: Capsule())
                .overlay { Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPopover) {
                sourceList
                    .frame(idealWidth: 340)
                    #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                    #endif
            }
        }
    }

    private var sourceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("引用来源(\(sources.count))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                ForEach(sources) { SourceCard(source: $0, tint: tint) }
            }
            .padding(14)
            .frame(maxWidth: 340, alignment: .leading)
        }
        .frame(maxHeight: 360)
    }
}

/// 单条来源卡片:标题 + 域名。整卡可点,用 `Link` 打开 url(跨 macOS / iOS)。
private struct SourceCard: View {
    let source: SourceRef
    let tint: Color

    var body: some View {
        if let url = URL(string: source.url) {
            Link(destination: url) { cardBody }
                .buttonStyle(.plain)
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(tint)
                .font(.body.weight(.semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(domain)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.platformControlBackground.opacity(0.48),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private var displayTitle: String {
        let t = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? source.url : t
    }

    /// 从 url 提取域名展示(去掉 www. 前缀);解析失败回退原始 url。
    private var domain: String {
        guard let host = URL(string: source.url)?.host else { return source.url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
