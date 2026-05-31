import SwiftUI
import MarkdownUI

/// 模型输出渲染:
/// - **streaming=true**: **只用 SwiftUI 原生 Text**,完全不解析 markdown
///   — 流式期间每个 chunk 都重 parse 整段是 O(N²),responses 长一些就会让 app 卡死。
///   用户看到的中间态是 raw markdown 字符(`**bold**` 显示成两个 `*`),流完瞬间切回 markdown。
/// - **finished**: 双路径:
///   - 默认走 `Text(AttributedString(markdown:))` — **整个回答作为单个 Text view**,
///     支持跨段/跨标题/跨列表的全文拖选。内联格式(粗体/斜体/inline code/链接)保留。
///     代价:H1/H2 标题不放大、列表无缩进 — 对 LLM chat 内容是可接受的取舍。
///   - 含代码块(```或 ~~~)/ 表格 的回答 fallback 到 swift-markdown-ui,保留代码块视觉。
///     这种回答跨块选择本来就少需求(代码块要复制有右上角按钮)。
struct MarkdownText: View {
    let text: String
    var streaming: Bool = false

    var body: some View {
        if streaming {
            // 流式期间故意不开 textSelection — 它走 TextKit2 的 NSTextLayoutManager,
            // 比普通 Text 重很多;且没人会去选还在生成的文本。结束后切回选模式。
            Text(text)
                .font(.body)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if Self.hasBlockLevelExtras(text) {
            // 包含代码块 / 表格时,MarkdownUI 视觉更重要,走老路径
            Markdown(text)
                .textSelection(.enabled)
                .markdownTheme(Self.kownTheme)
        } else if let attr = try? AttributedString(markdown: text, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )) {
            Text(attr)
                .textSelection(.enabled)
                .font(.body)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // 极端 parse 失败时兜底
            Markdown(text)
                .textSelection(.enabled)
                .markdownTheme(Self.kownTheme)
        }
    }

    /// 含代码块 / 表格 / 表头分隔 — 这些 block 用 AttributedString 渲染体验差,继续走 MarkdownUI
    private static func hasBlockLevelExtras(_ text: String) -> Bool {
        text.contains("```")
        || text.contains("~~~")
        || text.range(of: #"^\|.+\|"#, options: [.regularExpression, .anchored]) != nil
        || text.range(of: #"\n\|.+\|"#, options: .regularExpression) != nil
    }

    /// `Theme` 不是 Sendable;计算属性每次实例化,SwiftUI 缓存渲染结果。
    private static var kownTheme: Theme {
        Theme.gitHub
            .text { FontSize(.em(1.0)) }
            // 行内代码:等宽 + 略小字号 + 淡底色,和正文区分开
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                BackgroundColor(Self.inlineCodeBackground)
            }
            // 链接:强调色 + 下划线;MarkdownUI 默认即可点击打开
            .link {
                ForegroundColor(.accentColor)
                UnderlineStyle(.single)
            }
            // 代码块:等宽字体 + 横向滚动不换行 + 右上角复制按钮
            .codeBlock { configuration in
                CodeBlockView(configuration: configuration)
            }
    }

    /// 行内代码底色(深浅色自适应)。
    fileprivate static var inlineCodeBackground: Color {
        Color.primary.opacity(0.08)
    }
}

/// 代码块渲染:等宽字体 + 横向滚动(长行不换行)+ 右上角「复制」按钮。
/// macOS 上指针悬停时按钮高亮,iOS 上常驻可点。复制走 `Platform.copyText`。
private struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration

    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 横向滚动:代码长行保持不换行,溢出可左右滑
            ScrollView(.horizontal, showsIndicators: true) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    // 让短代码块也能撑满宽度,文字左对齐
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .background(Self.blockBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )

            copyButton
                .padding(8)
        }
        .markdownMargin(top: .em(0.6), bottom: .em(0.6))
    }

    private var copyButton: some View {
        Button {
            Platform.copyText(configuration.content)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(copied ? "已复制" : "复制代码")
        .accessibilityLabel(copied ? "已复制" : "复制代码")
    }

    private static var blockBackground: Color {
        Color.primary.opacity(0.05)
    }
}
