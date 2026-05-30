import SwiftUI

/// 更新日志 sheet。两种打开方式:
/// 1. 自动:`KownApp` 检测到 app 版本 > 上次看到版本时弹
/// 2. 手动:设置 → 更新日志 tab(随时翻历史)
struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var service = ChangelogService.shared

    /// 是否是"自动弹出 What's New"模式。
    var autoOpenedForVersion: String? = nil
    /// 嵌在 Settings 里时,外层已经有标题/完成按钮,这里只展示内容。
    var embeddedInSettings: Bool = false

    private var entries: [ChangelogEntry] {
        ChangelogParser.parse(service.fullText ?? "")
    }

    var body: some View {
        ZStack {
            ChangelogBackdrop()
            VStack(spacing: 0) {
                if !embeddedInSettings {
                    header
                    Divider().opacity(0.45)
                }
                content
                #if os(macOS)
                if !embeddedInSettings {
                    Divider().opacity(0.45)
                    footer
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(width: embeddedInSettings ? nil : 780, height: embeddedInSettings ? nil : 660)
        #else
        .navigationTitle("更新日志")
        .toolbar {
            if !embeddedInSettings {
                ToolbarItem(placement: .confirmationAction) {
                    Button("知道了") {
                        service.markCurrentSeen()
                        dismiss()
                    }
                }
            }
        }
        #endif
    }

    private var contentSpacing: CGFloat {
        #if os(iOS)
        return embeddedInSettings ? 12 : 14
        #else
        return 18
        #endif
    }

    private var contentInsets: EdgeInsets {
        #if os(iOS)
        return EdgeInsets(top: embeddedInSettings ? 12 : 14, leading: 14, bottom: 22, trailing: 14)
        #else
        return EdgeInsets(top: 22, leading: embeddedInSettings ? 24 : 22, bottom: 22, trailing: embeddedInSettings ? 24 : 22)
        #endif
    }

    private var contentMaxWidth: CGFloat? {
        #if os(iOS)
        return .infinity
        #else
        return 860
        #endif
    }

    private var latestCardPadding: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 22
        #endif
    }

    private var latestCornerRadius: CGFloat {
        #if os(iOS)
        return 24
        #else
        return 28
        #endif
    }

    private var latestVersionFontSize: CGFloat {
        #if os(iOS)
        return 26
        #else
        return 34
        #endif
    }

    private var entryCardPadding: CGFloat {
        #if os(iOS)
        return 12
        #else
        return 16
        #endif
    }

    private var entryCornerRadius: CGFloat {
        #if os(iOS)
        return 20
        #else
        return 22
        #endif
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.95), Color.teal.opacity(0.86)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "sparkles")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .shadow(color: Color.orange.opacity(0.22), radius: 16, x: 0, y: 8)

            VStack(alignment: .leading, spacing: 5) {
                Text(autoOpenedForVersion.map { "Kown 已更新到 v\($0)" } ?? "Kown 更新日志")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text("当前版本 v\(service.currentVersion) · 每次更新都记录在这里")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            versionBadge("v\(service.currentVersion)", color: .teal)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.thinMaterial)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: contentSpacing) {
                #if os(iOS)
                if embeddedInSettings {
                    settingsIntroCard
                }
                #endif
                if entries.isEmpty {
                    emptyState
                } else {
                    latestCard(entries[0])
                    if entries.count > 1 {
                        historyHeader

                        #if os(iOS)
                        LazyVStack(spacing: 10) {
                            ForEach(Array(entries.dropFirst().enumerated()), id: \.offset) { index, entry in
                                timelineEntryCard(
                                    entry,
                                    index: index,
                                    isLast: index == entries.count - 2
                                )
                            }
                        }
                        #else
                        LazyVStack(spacing: 12) {
                            ForEach(Array(entries.dropFirst().enumerated()), id: \.offset) { _, entry in
                                entryCard(entry)
                            }
                        }
                        #endif
                    }
                }
            }
            .padding(contentInsets)
            .frame(maxWidth: contentMaxWidth, alignment: .topLeading)
        }
        #if os(iOS)
        .scrollIndicators(.hidden)
        #endif
    }

    private var historyHeader: some View {
        HStack {
            Text("历史版本")
                .font(.headline)
            Spacer()
            Text("\(max(entries.count - 1, 0)) 个版本")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.top, 2)
    }

    #if os(iOS)
    private var settingsIntroCard: some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.95), Color.teal.opacity(0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text("版本时间线")
                    .font(.headline.weight(.bold))
                Text("当前 v\(service.currentVersion) · 向下滚动查看每次迭代")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.18), lineWidth: 1)
        }
    }

    private func timelineEntryCard(_ entry: ChangelogEntry, index: Int, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(index == 0 ? Color.orange.opacity(0.18) : Color.teal.opacity(0.14))
                    Circle()
                        .fill(index == 0 ? Color.orange : Color.teal)
                        .frame(width: 8, height: 8)
                }
                .frame(width: 20, height: 20)

                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.16))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22)

            entryCard(entry)
        }
    }
    #endif

    private func latestCard(_ entry: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        versionBadge("最新版本", color: .orange)
                        if let date = entry.date {
                            versionBadge(date, color: .secondary)
                        }
                    }
                    Text("v\(entry.version)")
                        .font(.system(size: latestVersionFontSize, weight: .black, design: .rounded))
                        .monospacedDigit()
                    Text("这次更新包含 \(entry.itemCount) 项改动")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 16)
                Image(systemName: "app.badge.checkmark.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.95))
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(entry.sections.enumerated()), id: \.offset) { _, section in
                    sectionBlock(section, isLatest: true)
                }
            }
        }
        .padding(latestCardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: latestCornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: latestCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.14), Color.teal.opacity(0.10), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: latestCornerRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: Color.orange.opacity(0.08), radius: 22, x: 0, y: 12)
    }

    private func entryCard(_ entry: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("v\(entry.version)")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    if let date = entry.date {
                        Text(date)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text("\(entry.itemCount) 项")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(entry.sections.enumerated()), id: \.offset) { _, section in
                    sectionBlock(section, isLatest: false)
                }
            }
        }
        .padding(entryCardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: entryCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: entryCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func sectionBlock(_ section: ChangelogSection, isLatest: Bool) -> some View {
        let style = sectionStyle(section.title)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: style.icon)
                    .font(.caption.weight(.bold))
                Text(section.title)
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(style.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(style.color.opacity(0.12), in: Capsule())

            VStack(alignment: .leading, spacing: isLatest ? 10 : 8) {
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    changeRow(item, color: style.color, isLatest: isLatest)
                }
            }
        }
    }

    private func changeRow(_ item: ChangelogItem, color: Color, isLatest: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.13))
                Image(systemName: "checkmark")
                    .font(.system(size: isLatest ? 9 : 8, weight: .black))
                    .foregroundStyle(color)
            }
            .frame(width: isLatest ? 22 : 19, height: isLatest ? 22 : 19)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                if let title = item.title {
                    Text(title)
                        .font(isLatest ? .callout.weight(.bold) : .subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.detail.isEmpty {
                    markdownText(item.detail)
                        .font(isLatest ? .callout : .caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func versionBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().strokeBorder(color.opacity(0.18), lineWidth: 1)
            }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 70, height: 70)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("更新日志暂不可用")
                .font(.headline)
            Text("bundle 里找不到 CHANGELOG.md 资源。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    #if os(macOS)
    private var footer: some View {
        HStack {
            Text("已读状态会记录到本机,下次更新后自动弹出 What's New。")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("知道了") {
                service.markCurrentSeen()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }
    #endif

    private func sectionStyle(_ title: String) -> (icon: String, color: Color) {
        if title.contains("修复") {
            return ("wrench.and.screwdriver.fill", Color(red: 0.88, green: 0.35, blue: 0.22))
        }
        if title.contains("改回") {
            return ("arrow.uturn.backward.circle.fill", Color(red: 0.57, green: 0.42, blue: 0.82))
        }
        return ("sparkles", Color(red: 0.10, green: 0.66, blue: 0.56))
    }

    private func markdownText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(markdown: raw) {
            return Text(attributed)
        }
        return Text(raw)
    }
}

private struct ChangelogBackdrop: View {
    var body: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [Color.orange.opacity(0.14), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [Color.teal.opacity(0.12), Color.clear],
                center: .bottomTrailing,
                startRadius: 80,
                endRadius: 560
            )
        }
        .ignoresSafeArea()
    }
}

private struct ChangelogEntry {
    var version: String
    var date: String?
    var sections: [ChangelogSection]

    var itemCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }
}

private struct ChangelogSection {
    var title: String
    var items: [ChangelogItem]
}

private struct ChangelogItem {
    var title: String?
    var detail: String
}

private enum ChangelogParser {
    static func parse(_ text: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var currentEntry: ChangelogEntry?
        var currentSection: ChangelogSection?

        func flushSection() {
            guard let section = currentSection else { return }
            if !section.items.isEmpty {
                currentEntry?.sections.append(section)
            }
            currentSection = nil
        }

        func flushEntry() {
            flushSection()
            guard let entry = currentEntry else { return }
            if !entry.sections.isEmpty {
                entries.append(entry)
            }
            currentEntry = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "# 更新日志" else { continue }

            if line.hasPrefix("## ") {
                flushEntry()
                currentEntry = parseEntryHeader(String(line.dropFirst(3)))
                continue
            }

            if line.hasPrefix("### ") {
                flushSection()
                currentSection = ChangelogSection(
                    title: String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines),
                    items: []
                )
                continue
            }

            if line.hasPrefix("- ") {
                if currentSection == nil {
                    currentSection = ChangelogSection(title: "更新", items: [])
                }
                currentSection?.items.append(parseItem(String(line.dropFirst(2))))
                continue
            }

            if var last = currentSection?.items.popLast() {
                let continuation = line.trimmingCharacters(in: .whitespacesAndNewlines)
                last.detail = [last.detail, continuation]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                currentSection?.items.append(last)
            }
        }

        flushEntry()
        return entries
    }

    private static func parseEntryHeader(_ raw: String) -> ChangelogEntry {
        let parts = raw
            .components(separatedBy: "—")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ChangelogEntry(
            version: parts.first ?? raw.trimmingCharacters(in: .whitespacesAndNewlines),
            date: parts.dropFirst().first,
            sections: []
        )
    }

    private static func parseItem(_ raw: String) -> ChangelogItem {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("**"),
              let end = text.dropFirst(2).range(of: "**")?.lowerBound
        else {
            return ChangelogItem(title: nil, detail: text)
        }

        let titleStart = text.index(text.startIndex, offsetBy: 2)
        let title = String(text[titleStart..<end])
        let detailStart = text.index(end, offsetBy: 2)
        let detail = cleanDetail(String(text[detailStart...]))
        return ChangelogItem(title: title, detail: detail)
    }

    private static func cleanDetail(_ raw: String) -> String {
        var detail = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.hasPrefix("—") {
            detail.removeFirst()
        } else if detail.hasPrefix("-") {
            detail.removeFirst()
        }
        return detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
