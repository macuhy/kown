import SwiftUI
import Textual

/// 把正文里的 `[n]`(1≤n≤来源数)替换成指向对应来源的 markdown 链接,链接文字仍是 `[n]`。
/// 这样答卡正文里的引用角标可直接点开来源,且复用现有 markdown 链接渲染(不改渲染器)。
/// 来源为空、或序号越界、或非引用(如代码里的 `arr[1]`,序号超出来源数)都原样保留。
///
/// 句级溯源:`knowledgeSources` 非空时,落在知识库编号集合里的 `[n]` 映射到自定义
/// scheme `kown-cite://n`,由 `.knowledgeCitationHost(...)` 拦截弹出原文片段(不走浏览器)。
/// 同一个 `[n]` 优先映射 web 来源(`n <= sources.count`),其余再尝试知识库编号。
///
/// 结果按内容记忆(见 `citationMemo`):静态历史卡的 body 会因父级/兄弟卡刷新被反复求值,
/// 同一段不变正文不必每帧重扫引用正则。
@MainActor
func citationLinkified(_ text: String, sources: [SourceRef], knowledgeSources: [KnowledgeSourceRef] = []) -> String {
    guard (!sources.isEmpty || !knowledgeSources.isEmpty), text.contains("[") else { return text }
    let key = CitationMemoKey(text: text, sources: sources, knowledgeSources: knowledgeSources)
    if let cached = citationMemo[key] { return cached }
    let knowledgeIndices = Set(knowledgeSources.map(\.index))
    let result = text.replacing(/\[(\d{1,3})\]/) { match in
        guard let n = Int(match.1), n >= 1 else { return String(match.0) }
        // 链接文字里的方括号需转义,否则 markdown 解析器会错配嵌套括号。
        if n <= sources.count {
            return "[\\[\(n)\\]](\(sources[n - 1].url))"
        }
        if knowledgeIndices.contains(n) {
            return "[\\[\(n)\\]](kown-cite://\(n))"
        }
        return String(match.0)
    }
    if citationMemo.count >= 128 { citationMemo.removeAll(keepingCapacity: true) }
    citationMemo[key] = result
    return result
}

/// 引用替换的缓存 key:替换结果同时取决于正文与两组来源(序号映射到哪个 url、是否越界都由它们决定),
/// 三者一起做 key 才能保证命中即等价。
private struct CitationMemoKey: Hashable {
    let text: String
    let sources: [SourceRef]
    let knowledgeSources: [KnowledgeSourceRef]
}

/// citationLinkified 记忆表(模式同 `MD.blockExtrasMemo`):切回长会话时一屏几十张历史卡
/// 同帧重扫全文正则很卡。结果直接作为正文渲染,哈希碰撞不可接受,故用完整入参做 key
/// (String / 数组都是 COW,key 只持引用不复制);到 128 条清空封顶,防无限增长。
@MainActor private var citationMemo: [CitationMemoKey: String] = [:]

/// 模型输出渲染:
/// - **streaming=true**: 渲染**节流快照**的 markdown(每 ~150ms 取一次 text),把"每 chunk 重 parse
///   整段"(O(N²))降为按时间节流;未闭合代码围栏临时补全;流式期间不开 textSelection 更轻;超长(>6000 字)退回 raw。
/// - **finished**: 走 Textual 的 SwiftUI 原生 `StructuredText` 管线,保留代码块/表格/列表视觉,
///   同时避免 MarkdownUI/cmark 的重解析和复杂 View 树拖慢长会话滚动。
struct MarkdownText: View {
    let text: String
    var streaming: Bool = false

    var body: some View {
        if streaming {
            // 只有正在生成的卡片才进流式分支(它独占一个节流定时器)。
            StreamingMarkdownText(text: text)
        } else if MD.isLonger(text, than: MD.maxFinishedChars) {
            MarkdownRawTextView(source: text, selectable: true)
                .equatable()  // 防失控:超长走 raw,避开 anchor/布局重路径
        } else {
            // 完成态允许系统文本选择:纯文本路径可跨段拖选,块级 Markdown 路径也能选中
            // 代码/表格/标题里的片段;流式分支仍关闭,避免每个 chunk 触发选择层重布局。
            // stylizeMath 走记忆版:静态历史卡的 body 被反复求值时不再重跑数学正则。
            MarkdownRenderView(source: MD.stylizeMathCached(text), selectable: true)
                .equatable()
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
            if MD.isLonger(src, than: MD.maxLiveChars) {
                MarkdownRawTextView(source: src, selectable: false)
                    .equatable()
            } else {
                // 节流快照 + 数学样式 + 补全未闭合代码围栏;不开 textSelection 更轻。
                // styledSnapshot 为空仅出现在 onAppear 之前的首帧,退化为即时计算一次。
                MarkdownRenderView(source: styledSnapshot.isEmpty ? MD.balancedFences(MD.stylizeMath(src)) : styledSnapshot,
                                   selectable: false)
                    .equatable()
            }
        }
        .onAppear { commitSnapshot(text) }
        .onReceive(tick) { _ in if snapshot != text { commitSnapshot(text) } }
    }

    /// 推进快照并同步重算转换结果(仅在事件回调里,不在 body 内改 @State)。
    private func commitSnapshot(_ newText: String) {
        snapshot = newText
        styledSnapshot = MD.isLonger(newText, than: MD.maxLiveChars)
            ? ""    // 超长走 rawText,不需要 styled
            : MD.balancedFences(MD.stylizeMath(newText))
    }
}

/// Equatable 包装:父视图仍会跟随 live text 高频刷新,但只要节流后的 source 没变,
/// SwiftUI 就不用重新跑 Textual 的 markdown 解析。
private struct MarkdownRenderView: View, Equatable {
    let source: String
    let selectable: Bool

    var body: some View {
        MD.rendered(for: source, selectable: selectable)
    }
}

private struct MarkdownRawTextView: View, Equatable {
    let source: String
    let selectable: Bool

    var body: some View {
        MD.rawText(source, selectable: selectable)
    }
}

/// MarkdownText 的纯函数 + 渲染帮手(无状态,可被流式 / 静态两路共享)。正则编译一次缓存。
@MainActor
enum MD {
    /// 流式期间渲染 markdown 的字符上限 —— 超过退回 raw,避免重 parse 卡顿。
    static let maxLiveChars = 6000
    /// 防失控:超长回答即使已完成也只渲 raw,绝不进 anchor/布局重路径(历史上撑出无限布局循环 + 14GB)。
    static let maxFinishedChars = 40000

    static func isLonger(_ text: String, than limit: Int) -> Bool {
        guard let idx = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) else {
            return false
        }
        return idx < text.endIndex
    }

    @ViewBuilder
    static func rawText(_ s: String, selectable: Bool) -> some View {
        Text(s)
            .textSelectable(selectable)
            .font(.body)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `selectable` 只在完成态开启;流式期间关闭,避免高频刷新时选择层反复重布局。
    @ViewBuilder
    static func rendered(for src: String, selectable: Bool) -> some View {
        let view = StructuredText(markdown: linkifiedMarkdownCached(src))
            .textual.structuredTextStyle(.gitHub)
            .textual.codeBlockStyle(KownTextualCodeBlockStyle())
            .textual.overflowMode(.scroll)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if selectable {
            view.textual.textSelection(.enabled)
        } else {
            view
        }
    }

    /// 分享图/PDF 使用同一原生 Markdown 管线,但关闭横向滚动并隐藏交互按钮,避免导出图片被长代码行撑宽。
    @ViewBuilder
    static func renderedForExport(_ src: String) -> some View {
        StructuredText(markdown: src)
            .textual.structuredTextStyle(.gitHub)
            .textual.overflowMode(.wrap)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// 裸链接补 markdown 语法的记忆版,供 Textual 解析前使用。
    /// 只处理无代码块/表格/任务列表的轻量正文,避免误改代码块里的 URL。
    /// 结果直接作为正文渲染,哈希碰撞不可接受,故用原文做 key(String 为 COW,key 只持引用);
    /// 到 128 条清空封顶。
    private static var linkifiedMarkdownMemo: [String: String] = [:]

    private static func linkifiedMarkdownCached(_ s: String) -> String {
        if hasBlockLevelExtras(s) { return s }
        if let cached = linkifiedMarkdownMemo[s] { return cached }
        let result = linkify(s)
        if linkifiedMarkdownMemo.count >= 128 { linkifiedMarkdownMemo.removeAll(keepingCapacity: true) }
        linkifiedMarkdownMemo[s] = result
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

    /// stylizeMath 记忆表 + 记忆版入口:**仅完成态**走这里(MarkdownText 静态分支),同一段
    /// 不变的历史回答只跑一次数学正则。流式快照每 tick 都在变,缓存只会冲掉历史卡条目,
    /// 仍走 `commitSnapshot` 里的即时计算。key 同样用原文本身,命中即等价。
    private static var stylizeMathMemo: [String: String] = [:]

    static func stylizeMathCached(_ s: String) -> String {
        if let cached = stylizeMathMemo[s] { return cached }
        let result = stylizeMath(s)
        if stylizeMathMemo.count >= 128 { stylizeMathMemo.removeAll(keepingCapacity: true) }
        stylizeMathMemo[s] = result
        return result
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

    /// hasBlockLevelExtras 记忆表:Textual 解析前判断是否能安全 linkify(跑最多 5 条正则整段扫描),
    /// 完成卡折叠/展开会一帧内把所有可见卡重渲一遍 → 同一段文本被反复扫。按内容 hash 记忆最近结果。
    /// 哈希碰撞最坏只让某次渲染走错 inline/block 分支一帧,可接受;到 128 条清空封顶,防无限增长。
    private static var blockExtrasMemo: [Int: Bool] = [:]

    /// 含代码块 / 表格 / 任务列表时不做裸 URL linkify,避免误改 block 内源码。
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
        // 标题 / 分割线交给 Textual 原生结构化渲染。
    }

    private static let headingRe = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$"#
    )
    private static let horizontalRuleRe = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#
    )

    /// 旧单 `Text` 路径的规范化 helper。Textual 渲染不再使用它,保留给单元测试和兼容调用方。
    static func selectableRichMarkdown(_ s: String) -> String {
        var out = replaceCapture(s, headingRe) { "**\($0)**" }
        out = replaceMatches(out, horizontalRuleRe) { _ in "────────" }
        return out
    }

    private static func replaceMatches(_ s: String, _ re: NSRegularExpression?, _ transform: (String) -> String) -> String {
        guard let re else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += transform(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    static var inlineCodeBackground: Color { Color.primary.opacity(0.08) }
}

/// Textual 代码块样式:保留 GitHub 风格语法高亮和横向溢出容器,只叠加语言标签/复制按钮。
/// Textual 不暴露代码块原文给样式层,所以复制走库内置 `CodeBlockProxy` 的原生 pasteboard 支持。
private struct KownTextualCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        KownTextualCodeBlock(configuration: configuration)
    }
}

private struct KownTextualCodeBlock: View {
    let configuration: StructuredText.CodeBlockStyleConfiguration
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Overflow {
                configuration.label
                    .textual.lineSpacing(.fontScaled(0.225))
                    .textual.fontScale(0.85)
                    .monospaced()
                    .padding(.horizontal, 12)
                    .padding(.top, languageTag == nil ? 10 : 24)
                    .padding(.bottom, 10)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }

            if let lang = languageTag {
                Text(lang)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.top, 4)
            }

            copyButton
                .padding(8)
        }
        .textual.blockSpacing(.fontScaled(top: 0.6, bottom: 0.6))
    }

    private var languageTag: String? {
        guard let language = configuration.languageHint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty else { return nil }
        return language.lowercased()
    }

    private var copyButton: some View {
        Button {
            configuration.codeBlock.copyToPasteboard()
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
}

private extension View {
    /// 按需开启文本选择(流式期间关掉更轻)。两个 TextSelectability 具体类型不同,不能用三元值,故用此包装。
    @ViewBuilder func textSelectable(_ on: Bool) -> some View {
        if on { self.textSelection(.enabled) } else { self }
    }
}
