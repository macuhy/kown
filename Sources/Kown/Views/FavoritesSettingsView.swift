import SwiftUI

/// 设置 ▸ 收藏:浏览收藏的回答片段,可复制 / 删除 / 清空。
struct FavoritesSettingsView: View {
    @ObservedObject private var store = FavoritesStore.shared
    @State private var confirmClear = false

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if store.items.isEmpty {
                    emptyState
                } else {
                    HStack {
                        Text("\(store.items.count) 条收藏")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("清空", systemImage: "trash").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(store.items) { item in row(item) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .confirmationDialog("清空全部收藏?不可恢复。", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { store.clear() }
            Button("取消", role: .cancel) { }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "star")
                .font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 62, height: 62)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("还没有收藏").font(.headline.weight(.bold))
            Text("在回答卡底部点「收藏 ☆」即可把好答案存到这里。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func row(_ item: FavoriteSnippet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                Text(item.providerName).font(.caption.weight(.bold))
                Text(item.model).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Text(Self.dateFmt.string(from: item.createdAt)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(item.text)
                .font(.callout)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Spacer()
                Button { Platform.copyText(item.text) } label: {
                    Label("复制", systemImage: "doc.on.doc").font(.caption2.weight(.semibold))
                }.buttonStyle(.borderless)
                Button(role: .destructive) { store.remove(item.id) } label: {
                    Label("删除", systemImage: "trash").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                }.buttonStyle(.borderless)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}
