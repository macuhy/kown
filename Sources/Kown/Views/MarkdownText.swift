import SwiftUI
import MarkdownUI

/// 模型输出渲染:
/// - **streaming=true**: 渲染**节流快照**的 markdown(每 ~150ms 取一次 text),把"每 chunk 重 parse
///   整段"(O(N²))降为按时间节流;未闭合代码围栏临时补全;不开 textSelection 更轻;超长(>6000 字)退回 raw。
/// - **finished**: 双路径:
///   - 默认走 `Text(AttributedString(markdown:))` — **整个回答作为单个 Text view**,
///     支持跨段/跨标题/跨列表的全文拖选。内联格式(粗体/斜体/inline code/链接)保留。
///     代价:H1/H2 标题不放大、列表无缩进 — 对 LLM chat 内容是可接受的取舍。
///   - 含代码块(```或 ~~~)/ 表格 / 任务列表(`- [ ]`)的回答 fallback 到 swift-markdown-ui,
///     保留代码块、表格、checkbox 视觉(`AttributedString` 的 inlineOnly 会把这些渲染成字面字符)。
///     这种回答跨块选择本来就少需求(代码块要复制有右上角按钮)。
struct MarkdownText: View {
    let text: String
    var streaming: Bool = false

    /// 流式期间渲染 markdown 的字符上限 —— 超过就退回 raw,避免重 parse 卡顿(完成后照常完整渲染)。
    private static let maxLiveMarkdownChars = 6000
    /// 流式快照:每 ~150ms 取一次 text,把"每个 chunk 重 parse 整段"(O(N²))降到按时间节流。
    @State private var snapshot: String = ""
    private let tick = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        content
            .onAppear { snapshot = text }
            .onReceive(tick) { _ in if streaming, snapshot != text { snapshot = text } }
            .onChange(of: streaming) { _, s in if !s { snapshot = text } }
    }

    @ViewBuilder
    private var content: some View {
        if streaming {
            let src = snapshot.isEmpty ? text : snapshot
            if src.count > Self.maxLiveMarkdownChars {
                rawText(src)
            } else {
                // 流式期间也渲 markdown(节流快照 + 补全未闭合代码围栏),但不开 textSelection(更轻)。
                rendered(for: Self.balancedFences(src), selectable: false)
            }
        } else {
            rendered(for: text, selectable: true)
        }
    }

    private func rawText(_ s: String) -> some View {
        Text(s)
            .font(.body)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rendered(for src: String, selectable: Bool) -> some View {
        if Self.hasBlockLevelExtras(src) {
            // 含代码块 / 表格 / 任务列表:MarkdownUI 视觉更重要
            Markdown(src)
                .textSelectable(selectable)
                .markdownTheme(Self.kownTheme)
        } else if let attr = try? AttributedString(markdown: src, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )) {
            Text(attr)
                .textSelectable(selectable)
                .font(.body)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Markdown(src)
                .textSelectable(selectable)
                .markdownTheme(Self.kownTheme)
        }
    }

    /// 流式中途若有未闭合的 ``` 代码围栏,临时补一个收尾,避免半个围栏把后文都吞成代码。
    private static func balancedFences(_ s: String) -> String {
        let fences = s.components(separatedBy: "```").count - 1
        return fences % 2 == 1 ? s + "\n```" : s
    }

    /// 含代码块 / 表格 / 表头分隔 / 任务列表 — 这些 block 用 AttributedString 渲染体验差,继续走 MarkdownUI
    private static func hasBlockLevelExtras(_ text: String) -> Bool {
        text.contains("```")
        || text.contains("~~~")
        || text.range(of: #"^\|.+\|"#, options: [.regularExpression, .anchored]) != nil
        || text.range(of: #"\n\|.+\|"#, options: .regularExpression) != nil
        // 任务列表:行首(允许缩进)`- [ ]` / `* [x]`。AttributedString 的 inlineOnly 会原样显示
        // 成 `- [ ]`,只有 MarkdownUI 会渲染成 checkbox。
        || text.range(of: #"(?m)^[ \t]*[-*] \[[ xX]\] "#, options: .regularExpression) != nil
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

private extension View {
    /// 按需开启文本选择(流式期间关掉更轻)。两个 TextSelectability 具体类型不同,不能用三元值,故用此包装。
    @ViewBuilder func textSelectable(_ on: Bool) -> some View {
        if on { self.textSelection(.enabled) } else { self }
    }
}
