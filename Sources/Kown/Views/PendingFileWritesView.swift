import SwiftUI

#if os(macOS)
/// 本地文件工具「待确认写入」托盘:模型用 local_write_file 暂存的改动在这里以 diff 呈现,
/// 用户点「应用」才真正写盘(写前必须确认),或「撤销」丢弃。已应用的显示 ✓。
struct PendingFileWritesView: View {
    @Bindable private var state = LocalFileToolState.shared

    private var tint: Color { Color(red: 0.20, green: 0.56, blue: 0.78) }

    var body: some View {
        if !state.pendingWrites.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header
                ForEach(state.pendingWrites) { write in
                    PendingWriteCard(write: write,
                                     onApply: { state.apply(write.id) },
                                     onDiscard: { state.discard(write.id) })
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "tray.full.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text("待确认的本地文件改动")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text("\(state.pendingWrites.count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if state.pendingWrites.contains(where: { $0.applied }) {
                Button("清除已应用") { state.clearApplied() }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PendingWriteCard: View {
    let write: PendingFileWrite
    let onApply: () -> Void
    let onDiscard: () -> Void
    @State private var expanded = false

    private var diff: [TextDiff.Line] { TextDiff.diff(old: write.oldContent ?? "", new: write.newContent) }
    private var stats: (added: Int, removed: Int) { TextDiff.stats(diff) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: write.applied ? "checkmark.circle.fill" : "doc.badge.ellipsis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(write.applied ? .green : .orange)
                Text(write.relativePath)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                badge(write.isNew ? "新建" : "修改", color: write.isNew ? .blue : .orange)
                Text("+\(stats.added) −\(stats.removed)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let err = write.error {
                Text("应用失败:\(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if expanded {
                diffView
            }

            if !write.applied {
                HStack(spacing: 8) {
                    Button(action: onApply) {
                        Label("应用", systemImage: "checkmark")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(action: onDiscard) {
                        Label("撤销", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
            } else {
                Text("已写入磁盘")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var diffView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diff) { line in
                    HStack(spacing: 6) {
                        Text(prefix(line.kind))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(line.kind))
                            .frame(width: 12)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 4)
                    .background(background(line.kind))
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 240)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func prefix(_ k: TextDiff.Kind) -> String {
        switch k { case .insert: return "+"; case .delete: return "−"; case .equal: return " " }
    }
    private func color(_ k: TextDiff.Kind) -> Color {
        switch k { case .insert: return .green; case .delete: return .red; case .equal: return .secondary }
    }
    private func background(_ k: TextDiff.Kind) -> Color {
        switch k {
        case .insert: return Color.green.opacity(0.10)
        case .delete: return Color.red.opacity(0.10)
        case .equal:  return Color.clear
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}
#endif
