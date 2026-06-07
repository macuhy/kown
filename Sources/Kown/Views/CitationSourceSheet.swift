import SwiftUI

/// 句级溯源:点答案里的 `[n]` 角标后弹出的底部弹层,展示该编号对应的知识库片段原文 + 文档名。
/// 数据来自 `Turn.knowledgeSources`(检索时落盘的来源元数据)。
struct CitationSourceSheet: View {
    let source: KnowledgeSourceRef
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                Text(source.excerpt)
                    .font(.callout)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 320, idealHeight: 420)
        #endif
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Text("[\(source.index)]")
                    .font(.system(.headline, design: .rounded).weight(.black))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("引用来源")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(source.docName)
                    .font(.headline.weight(.bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.platformControlBackground.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

extension View {
    /// 让答卡正文里的 `kown-cite://n` 链接被拦截 → 弹出第 n 条知识库片段的原文弹层。
    /// 其它(http 等)链接照常走系统默认行为。`knowledgeSources` 为空时不安装拦截。
    @ViewBuilder
    func knowledgeCitationHost(_ knowledgeSources: [KnowledgeSourceRef]) -> some View {
        if knowledgeSources.isEmpty {
            self
        } else {
            modifier(KnowledgeCitationHost(knowledgeSources: knowledgeSources))
        }
    }
}

private struct KnowledgeCitationHost: ViewModifier {
    let knowledgeSources: [KnowledgeSourceRef]
    @State private var presented: KnowledgeSourceRef?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "kown-cite",
                      let n = Int(url.host ?? url.lastPathComponent),
                      let match = knowledgeSources.first(where: { $0.index == n }) else {
                    return .systemAction
                }
                presented = match
                return .handled
            })
            .sheet(item: $presented) { CitationSourceSheet(source: $0) }
    }
}
