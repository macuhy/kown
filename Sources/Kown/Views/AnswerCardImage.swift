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

/// 把回答渲染成 PNG 卡片并导出(macOS 存盘 / iOS 系统分享)。
enum AnswerImageExporter {
    @MainActor
    static func exportPNG(providerName: String, model: String, text: String, suggestedName: String) {
        // 超长截断,避免生成超大图片
        let capped = text.count > 4000 ? String(text.prefix(4000)) + "\n\n…(已截断)" : text
        let renderer = ImageRenderer(content: AnswerCardImage(providerName: providerName, model: model, text: capped))
        renderer.scale = 2
        let safeName = suggestedName.isEmpty ? "Kown-answer" : suggestedName

        #if os(macOS)
        guard let ns = renderer.nsImage,
              let tiff = ns.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeName + ".png"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? png.write(to: url, options: .atomic)
        }
        #else
        guard let ui = renderer.uiImage, let png = ui.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName + ".png")
        try? png.write(to: url, options: .atomic)
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene.windows.first?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        av.popoverPresentationController?.sourceView = top.view
        av.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(av, animated: true)
        #endif
    }
}
