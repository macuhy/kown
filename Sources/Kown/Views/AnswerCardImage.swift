import SwiftUI
import MarkdownUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 用于导出成图片的回答卡片(ImageRenderer 渲染目标)。固定宽度、浅色底。
/// 用 MarkdownUI 渲染完整 markdown(标题/代码块/表格/列表),代码块自动换行不撑宽。
struct AnswerCardImage: View {
    let providerName: String
    let model: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .foregroundStyle(Color.accentColor)
                Text(providerName).font(.headline)
                Text(model).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            Markdown(MD.stylizeMath(text))
                .markdownTheme(MD.exportTheme)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            Text("via Kown").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 600, alignment: .leading)
        .background(Color(white: 0.99))
    }
}

/// 把回答渲染成图片卡片并**直接复制到剪贴板**(不弹保存 / 分享)。
enum AnswerImageExporter {
    /// 渲染并复制到剪贴板。成功返回 true(供 UI 显示「已复制」)。
    @discardableResult @MainActor
    static func copyToClipboard(providerName: String, model: String, text: String) -> Bool {
        // 超长截断,避免生成超大图片
        let capped = text.count > 4000 ? String(text.prefix(4000)) + "\n\n…(已截断)" : text
        let renderer = ImageRenderer(content: AnswerCardImage(providerName: providerName, model: model, text: capped))
        renderer.scale = 2
        #if os(macOS)
        guard let ns = renderer.nsImage else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([ns])
        #else
        guard let ui = renderer.uiImage else { return false }
        UIPasteboard.general.image = ui
        return true
        #endif
    }
}
