import SwiftUI
import MarkdownUI

/// 把正文里的 `[n]`(1≤n≤来源数)替换成指向对应来源的 markdown 链接,链接文字仍是 `[n]`。
/// 这样答卡正文里的引用角标可直接点开来源,且复用现有 markdown 链接渲染(不改渲染器)。
/// 来源为空、或序号越界、或非引用(如代码里的 `arr[1]`,序号超出来源数)都原样保留。
func citationLinkified(_ text: String, sources: [SourceRef]) -> String {
    guard !sources.isEmpty, text.contains("[") else { return text }
    return text.replacing(/\[(\d{1,3})\]/) { match in
        guard let n = Int(match.1), n >= 1, n <= sources.count else { return String(match.0) }
        // 链接文字里的方括号需转义,否则 markdown 解析器会错配嵌套括号。
        return "[\\[\(n)\\]](\(sources[n - 1].url))"
    }
}

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

    var body: some View {
        if streaming {
            // 只有正在生成的卡片才进流式分支(它独占一个节流定时器)。
            StreamingMarkdownText(text: text)
        } else if text.count > MD.maxFinishedChars {
            MD.rawText(text)  // 防失控:超长走 raw,避开 anchor/布局重路径
        } else {
            // selectable:true —— 仅作用于「单个 Text」纯文本路径(整段答案=一个 Text=一个
            // SelectionOverlay,可拖选复制任意片段,开销恒定)。块级 Markdown 路径(代码/表格)
            // 仍强制关闭:那条路每段套一个 overlay,滚动时 setFont→失效 intrinsic→重布局自我重入,
            // 答卡一多就烧满一个核(卡死)。代码块有各自的「复制」按钮,整段有底部「复制」兜底。
            MD.rendered(for: MD.stylizeMath(text), selectable: true)
        }
    }
}

/// 流式专用子视图:**只有正在生成的卡片才创建定时器**。
/// 关键性能修复 —— 之前把 Timer.publish 挂在每个 MarkdownText 上,历史会话一屏几十上百个回答卡
/// 就有几十上百个定时器每 150ms 全部触发,渲染和切换都卡。静态历史卡现在零定时器。
private struct StreamingMarkdownText: View {
    let text: String
    /// 节流快照:每 ~200ms 取一次 text,把"每 chunk 重 parse 整段"(O(N²))降为按时间节流。
    @State private var snapshot: String = ""
    /// 对 snapshot 做完 stylizeMath+balancedFences 的结果,**只在快照更新时**(onAppear/onReceive)算一次。
    /// 关键:body 会因父级/兄弟卡片(Council 多列)重渲染而被反复求值;若每次 body 都重跑这条
    /// 转换链(stylizeMath 2 条正则 + balancedFences 整段扫描),N 路并发时主线程被烧满。
    /// 缓存后 body 只读结果,转换频率被钉在节流 tick 上。
    @State private var styledSnapshot: String = ""
    private let tick = Timer.publish(every: 0.20, on: .main, in: .common).autoconnect()

    var body: some View {
        let src = snapshot.isEmpty ? text : snapshot
        return Group {
            if src.count > MD.maxLiveChars {
                MD.rawText(src)
            } else {
                // 节流快照 + 数学样式 + 补全未闭合代码围栏;不开 textSelection 更轻。
                // styledSnapshot 为空仅出现在 onAppear 之前的首帧,退化为即时计算一次。
                MD.rendered(for: styledSnapshot.isEmpty ? MD.balancedFences(MD.stylizeMath(src)) : styledSnapshot,
                            selectable: false)
            }
        }
        .onAppear { commitSnapshot(text) }
        .onReceive(tick) { _ in if snapshot != text { commitSnapshot(text) } }
    }

    /// 推进快照并同步重算转换结果(仅在事件回调里,不在 body 内改 @State)。
    private func commitSnapshot(_ newText: String) {
        snapshot = newText
        styledSnapshot = newText.count > MD.maxLiveChars
            ? ""    // 超长走 rawText,不需要 styled
            : MD.balancedFences(MD.stylizeMath(newText))
    }
}

/// MarkdownText 的纯函数 + 渲染帮手(无状态,可被流式 / 静态两路共享)。正则编译一次缓存。
@MainActor
enum MD {
    /// 流式期间渲染 markdown 的字符上限 —— 超过退回 raw,避免重 parse 卡顿。
    static let maxLiveChars = 6000
    /// 防失控:超长回答即使已完成也只渲 raw,绝不进 anchor/布局重路径(历史上撑出无限布局循环 + 14GB)。
    static let maxFinishedChars = 40000

    @ViewBuilder
    static func rawText(_ s: String) -> some View {
        Text(s)
            .font(.body)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `selectable` 只对「单个 Text」纯文本路径生效(开销恒定,安全)。块级 Markdown 路径
    /// 永远不开选中:每段套一个 SelectionOverlay,滚动重布局自我重入会卡死(见 MarkdownText 注释)。
    @ViewBuilder
    static func rendered(for src: String, selectable: Bool) -> some View {
        if hasBlockLevelExtras(src) {
            Markdown(src)
                .textSelectable(false)
                .markdownTheme(kownTheme)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let attr = try? AttributedString(markdown: linkify(src), options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )) {
            Text(attr)
                .textSelectable(selectable)
                .font(.body)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Markdown(src)
                .textSelectable(false)
                .markdownTheme(kownTheme)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // 裸 URL → markdown 链接。lookbehind 跳过已是 `](url)` / `<url>` / `"url"` 的情况。
    private static let bareURLRe = try? NSRegularExpression(
        pattern: #"(?<![\(<\]"])https?://[^\s<>)\]"，。、;；】)]+"#
    )
    /// 把正文里的裸链接(如来源 URL)转成可点击的 markdown 链接 `[url](url)`。
    /// 仅用于无代码块的 AttributedString 渲染路径(那条路径不会有 ``` 代码,不怕误伤)。
    static func linkify(_ s: String) -> String {
        guard s.contains("http"), let re = bareURLRe else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let url = ns.substring(with: m.range)
            result += "[\(url)](\(url))"
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// 流式中途若有未闭合的 ``` 代码围栏,临时补一个收尾,避免半个围栏把后文都吞成代码。
    static func balancedFences(_ s: String) -> String {
        let fences = s.components(separatedBy: "```").count - 1
        return fences % 2 == 1 ? s + "\n```" : s
    }

    // 正则编译一次缓存(之前每次渲染都 new 一个 NSRegularExpression,切换会话时成百上千个卡一起编译很卡)。
    private static let mathBlockRe = try? NSRegularExpression(pattern: #"\$\$([\s\S]+?)\$\$"#)
    private static let mathInlineRe = try? NSRegularExpression(pattern: #"\$([^\$\n]*[\\^_{}][^\$\n]*)\$"#)

    /// 数学公式(`$...$` / `$$...$$`)→ 等宽样式(块=代码块,行内=行内 code),可复制。
    /// 行内仅当内含 LaTeX 字符(`\ ^ _ { }`)才转,避免把「$5」这类货币误判成公式。
    static func stylizeMath(_ s: String) -> String {
        guard s.contains("$") else { return s }
        var out = replaceCapture(s, mathBlockRe) { "\n```\n\($0)\n```\n" }
        out = replaceCapture(out, mathInlineRe) { "`\($0)`" }
        return out
    }

    private static func replaceCapture(_ s: String, _ re: NSRegularExpression?, _ transform: (String) -> String) -> String {
        guard let re else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 2 else { return }
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += transform(ns.substring(with: m.range(at: 1)))
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// hasBlockLevelExtras 记忆表:MD.rendered 每次渲染都调它(跑最多 5 条正则整段扫描),
    /// 完成卡折叠/展开会一帧内把所有可见卡重渲一遍 → 同一段文本被反复扫。按内容 hash 记忆最近结果。
    /// 哈希碰撞最坏只让某次渲染走错 inline/block 分支一帧,可接受;到 128 条清空封顶,防无限增长。
    private static var blockExtrasMemo: [Int: Bool] = [:]

    /// 含代码块 / 表格 / 任务列表 — 这些 block 用 AttributedString 渲染体验差,继续走 MarkdownUI。
    static func hasBlockLevelExtras(_ text: String) -> Bool {
        let key = text.hashValue
        if let cached = blockExtrasMemo[key] { return cached }
        let result = computeHasBlockLevelExtras(text)
        if blockExtrasMemo.count >= 128 { blockExtrasMemo.removeAll(keepingCapacity: true) }
        blockExtrasMemo[key] = result
        return result
    }

    private static func computeHasBlockLevelExtras(_ text: String) -> Bool {
        text.contains("```")
        || text.contains("~~~")
        || text.range(of: #"^\|.+\|"#, options: [.regularExpression, .anchored]) != nil
        || text.range(of: #"\n\|.+\|"#, options: .regularExpression) != nil
        || text.range(of: #"(?m)^[ \t]*[-*] \[[ xX]\] "#, options: .regularExpression) != nil
        // 标题:行首 `# ` ~ `###### `。AttributedString 的 inlineOnly 不放大标题,走 MarkdownUI 才有层级。
        || text.range(of: #"(?m)^#{1,6} "#, options: .regularExpression) != nil
    }

    /// `Theme` 不是 Sendable;计算属性每次实例化,SwiftUI 缓存渲染结果。
    static var kownTheme: Theme {
        Theme.gitHub
            .text { FontSize(.em(1.0)) }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                BackgroundColor(inlineCodeBackground)
            }
            .link {
                ForegroundColor(.accentColor)
                UnderlineStyle(.single)
            }
            .codeBlock { configuration in
                CodeBlockView(configuration: configuration)
            }
    }

    static var inlineCodeBackground: Color { Color.primary.opacity(0.08) }

    /// 导出图片专用主题:与聊天一致的块级渲染,但代码块**自动换行**(不横滚、不 fixedSize),
    /// 避免 ImageRenderer 下长行把图片撑得过宽。
    static var exportTheme: Theme {
        Theme.gitHub
            .text { FontSize(.em(1.0)) }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(inlineCodeBackground)
            }
            .link { ForegroundColor(.accentColor) }
            .codeBlock { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.82))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .markdownMargin(top: .em(0.5), bottom: .em(0.5))
            }
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
                // 自绘语法高亮(按围栏语言着色),替代 MarkdownUI 的纯色 label。
                Text(SyntaxHighlighter.highlight(configuration.content, language: configuration.language))
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.top, languageTag == nil ? 10 : 24)
                    .padding(.bottom, 10)
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

            if let lang = languageTag {
                Text(lang)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.top, 4)
            }

            copyButton
                .padding(8)
        }
        .markdownMargin(top: .em(0.6), bottom: .em(0.6))
    }

    /// 围栏语言标签(非空才显示)。
    private var languageTag: String? {
        guard let l = configuration.language?.trimmingCharacters(in: .whitespaces), !l.isEmpty else { return nil }
        return l.lowercased()
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
