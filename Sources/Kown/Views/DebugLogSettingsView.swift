import SwiftUI

/// 「设置 ▸ 调试日志」:开启后记录每个 LLM HTTP 请求的完整请求体 + 原始返回,点一下复制全文。
/// 用于排查「空响应」等问题。默认关、仅内存最近 50 条、API Key 已脱敏。
struct DebugLogSettingsView: View {
    @AppStorage(DebugLogStore.enabledKey) private var enabled = false
    private var store = DebugLogStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                toggleCard
                if enabled || !store.entries.isEmpty {
                    toolbar
                    if store.entries.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(store.entries) { DebugLogRow(entry: $0) }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $enabled) {
                Text("记录请求 / 返回日志").font(.headline)
            }
            Text("开启后,下一次对话的每个网络请求会记录完整请求体 + 原始返回。仅保留最近 50 条、存在内存中(重启清空),不会同步到 iCloud。请求体含对话原文;API Key 已脱敏。排查完建议关掉。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
    }

    private var toolbar: some View {
        HStack {
            Text("\(store.entries.count) / 50 条")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !store.entries.isEmpty {
                Button(role: .destructive) { store.clear() } label: {
                    Label("清空", systemImage: "trash")
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ladybug").font(.largeTitle).foregroundStyle(.secondary)
            Text("还没有日志").font(.callout)
            Text("打开上面的开关后,下一次对话的请求就会记录到这里。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// 单条日志行:状态徽章 + host·model + 一行摘要 + 展开全文 + 复制全文。
private struct DebugLogRow: View {
    let entry: DebugLogEntry
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                badge
                Text("\(entry.host) · \(entry.model)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(Self.timeFmt.string(from: entry.timestamp))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(entry.summary)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button { withAnimation { expanded.toggle() } } label: {
                    Label(expanded ? "收起" : "展开", systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                Spacer()
                Button {
                    Platform.copyText(entry.fullText)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制全文", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? .green : .accentColor)
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)

            if expanded {
                ScrollView(.vertical) {
                    Text(entry.fullText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
    }

    private var badge: some View {
        Text(entry.statusBadge)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(badgeColor.opacity(0.16), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        if entry.error != nil { return .red }
        guard let s = entry.httpStatus else { return .gray }
        if !(200..<300).contains(s) { return .red }
        return entry.isLikelyEmpty ? .orange : .green
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
