import Foundation

/// 把会话导出成**自包含、可离线打开**的只读 HTML 快照,用于分享。
///
/// - 不依赖任何外部 CDN / JS:CSS 内联,Markdown 在导出时就转成 HTML(`MiniMarkdown`)。
/// - 复用 `ConversationExporter.markdown(for:)` 产出的 Markdown 作为正文源,保证与其它导出口径一致
///   (会话头部、逐轮排版、投票表格都沿用同一份渲染)。
/// - 纯函数,不依赖 view / viewModel。
enum HTMLExporter {

    /// 整会话 → 完整 HTML 文档字符串。
    static func html(for conversation: Conversation) -> String {
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = title.isEmpty ? "Kown 对话" : title
        let bodyHTML = MiniMarkdown.toHTML(ConversationExporter.markdown(for: conversation))
        return document(title: safeTitle, bodyHTML: bodyHTML)
    }

    /// 建议文件名(`.html`)。
    static func suggestedFileName(for conversation: Conversation) -> String {
        let raw = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = raw.isEmpty ? "Conversation" : raw
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safe = cleaned.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = safe.count > 80 ? String(safe.prefix(80)) : safe
        return "\(trimmed).html"
    }

    // MARK: - 文档外壳

    private static func document(title: String, bodyHTML: String) -> String {
        let escTitle = MiniMarkdown.escape(title)
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Kown">
        <title>\(escTitle)</title>
        <style>
        \(css)
        </style>
        </head>
        <body>
        <main class="kown-doc">
        \(bodyHTML)
        <footer class="kown-footer">由 <strong>Kown</strong> 导出 · 只读快照</footer>
        </main>
        </body>
        </html>
        """
    }

    private static let css = """
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; }
    body {
      margin: 0; padding: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
      line-height: 1.7; color: #1d1d1f; background: #f5f5f7;
      -webkit-font-smoothing: antialiased;
    }
    .kown-doc {
      max-width: 820px; margin: 0 auto; padding: 40px 24px 80px;
    }
    h1 { font-size: 1.9em; font-weight: 800; margin: 0.2em 0 0.6em; letter-spacing: -0.01em; }
    h2 { font-size: 1.35em; font-weight: 700; margin: 1.8em 0 0.5em; padding-top: 0.4em; }
    h3 { font-size: 1.12em; font-weight: 700; margin: 1.4em 0 0.4em; color: #0a5; }
    h3, h4 { color: inherit; }
    h4 { font-size: 1.0em; font-weight: 700; margin: 1.1em 0 0.3em; }
    p { margin: 0.6em 0; }
    a { color: #06c; text-decoration: none; }
    a:hover { text-decoration: underline; }
    ul, ol { margin: 0.5em 0; padding-left: 1.5em; }
    li { margin: 0.25em 0; }
    code {
      font-family: "SF Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.88em; background: rgba(135,131,120,0.16);
      padding: 0.15em 0.4em; border-radius: 5px;
    }
    pre {
      background: #1e1e23; color: #e6e6e6; padding: 14px 16px;
      border-radius: 12px; overflow-x: auto; font-size: 0.85em; line-height: 1.55;
    }
    pre code { background: none; padding: 0; color: inherit; }
    blockquote {
      margin: 0.8em 0; padding: 0.4em 1em; border-left: 3px solid #c7c7cc;
      color: #555; background: rgba(120,120,128,0.06); border-radius: 0 8px 8px 0;
    }
    hr { border: none; border-top: 1px solid rgba(120,120,128,0.25); margin: 1.6em 0; }
    table { border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 0.92em; }
    th, td { border: 1px solid rgba(120,120,128,0.3); padding: 7px 10px; text-align: left; }
    th { background: rgba(120,120,128,0.1); font-weight: 700; }
    strong { font-weight: 700; }
    .kown-footer {
      margin-top: 3em; padding-top: 1.2em; border-top: 1px solid rgba(120,120,128,0.2);
      color: #8a8a8e; font-size: 0.82em; text-align: center;
    }
    @media (prefers-color-scheme: dark) {
      body { color: #f5f5f7; background: #1c1c1e; }
      blockquote { color: #b0b0b5; }
      a { color: #6cf; }
      th { background: rgba(120,120,128,0.18); }
    }
    """
}

/// 极简 Markdown → HTML 转换器(零依赖、离线)。
/// 覆盖 Kown 导出用到的语法:标题、列表、引用、分隔线、表格、代码块/行内代码、粗体/斜体、链接、段落。
/// 不追求 CommonMark 完备,只求把模型回答 + 导出 Markdown 渲染得干净可读。
enum MiniMarkdown {

    static func toHTML(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html = ""
        var i = 0

        // 块级状态
        var inCodeFence = false
        var codeBuffer: [String] = []
        var listStack: [String] = []   // "ul" / "ol"
        var paragraphBuffer: [String] = []
        var tableBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: "<br>")
            html += "<p>\(joined)</p>\n"
            paragraphBuffer.removeAll()
        }
        func closeLists() {
            while let last = listStack.popLast() { html += "</\(last)>\n" }
        }
        func flushTable() {
            guard !tableBuffer.isEmpty else { return }
            html += renderTable(tableBuffer)
            tableBuffer.removeAll()
        }
        func flushBlocks() {
            flushParagraph()
            flushTable()
            closeLists()
        }

        while i < lines.count {
            let rawLine = lines[i]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // 代码围栏
            if line.hasPrefix("```") {
                if inCodeFence {
                    html += "<pre><code>" + codeBuffer.map { escape($0) }.joined(separator: "\n") + "</code></pre>\n"
                    codeBuffer.removeAll()
                    inCodeFence = false
                } else {
                    flushBlocks()
                    inCodeFence = true
                }
                i += 1; continue
            }
            if inCodeFence { codeBuffer.append(rawLine); i += 1; continue }

            // 表格行(以 | 开头且含 |)
            if line.hasPrefix("|") && line.contains("|") {
                flushParagraph(); closeLists()
                tableBuffer.append(line)
                i += 1; continue
            } else if !tableBuffer.isEmpty {
                flushTable()
            }

            // 空行 → 段落 / 列表分隔
            if line.isEmpty {
                flushParagraph(); closeLists()
                i += 1; continue
            }

            // 分隔线
            if line == "---" || line == "***" || line == "___" {
                flushBlocks()
                html += "<hr>\n"
                i += 1; continue
            }

            // 标题
            if let (level, text) = heading(line) {
                flushBlocks()
                html += "<h\(level)>\(inline(text))</h\(level)>\n"
                i += 1; continue
            }

            // 引用
            if line.hasPrefix(">") {
                flushParagraph(); closeLists(); flushTable()
                let content = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                html += "<blockquote>\(inline(content))</blockquote>\n"
                i += 1; continue
            }

            // 无序列表
            if let item = unorderedItem(line) {
                flushParagraph(); flushTable()
                if listStack.last != "ul" { closeLists(); html += "<ul>\n"; listStack.append("ul") }
                html += "<li>\(inline(item))</li>\n"
                i += 1; continue
            }
            // 有序列表
            if let item = orderedItem(line) {
                flushParagraph(); flushTable()
                if listStack.last != "ol" { closeLists(); html += "<ol>\n"; listStack.append("ol") }
                html += "<li>\(inline(item))</li>\n"
                i += 1; continue
            }

            // 普通段落行
            closeLists()
            paragraphBuffer.append(inline(line))
            i += 1
        }

        if inCodeFence {
            html += "<pre><code>" + codeBuffer.map { escape($0) }.joined(separator: "\n") + "</code></pre>\n"
        }
        flushBlocks()
        return html
    }

    // MARK: - 块级解析

    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1; idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func unorderedItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> String? {
        // 形如 "1. xxx" / "12) xxx"
        var digits = ""
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber { digits.append(line[idx]); idx = line.index(after: idx) }
        guard !digits.isEmpty, idx < line.endIndex else { return nil }
        let sep = line[idx]
        guard sep == "." || sep == ")" else { return nil }
        let after = line.index(after: idx)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(line[line.index(after: after)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func renderTable(_ rows: [String]) -> String {
        // 过滤分隔行(|---|---|)。第一行当表头。
        func cells(_ row: String) -> [String] {
            var s = row
            if s.hasPrefix("|") { s.removeFirst() }
            if s.hasSuffix("|") { s.removeLast() }
            return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func isSeparator(_ row: String) -> Bool {
            let c = cells(row)
            return !c.isEmpty && c.allSatisfy { cell in
                let t = cell.replacingOccurrences(of: " ", with: "")
                return !t.isEmpty && t.allSatisfy { $0 == "-" || $0 == ":" }
            }
        }
        let dataRows = rows.filter { !isSeparator($0) }
        guard let header = dataRows.first else { return "" }
        var out = "<table>\n<thead><tr>"
        for c in cells(header) { out += "<th>\(inline(c))</th>" }
        out += "</tr></thead>\n<tbody>\n"
        for row in dataRows.dropFirst() {
            out += "<tr>"
            for c in cells(row) { out += "<td>\(inline(c))</td>" }
            out += "</tr>\n"
        }
        out += "</tbody>\n</table>\n"
        return out
    }

    // MARK: - 行内解析

    /// 行内:先转义 HTML,再处理代码`、粗体**、斜体*、链接[](),顺序保证不互相吃。
    static func inline(_ text: String) -> String {
        // 1) 行内代码先抠出来占位,避免里面的 * _ 被当强调。
        var placeholders: [String] = []
        var working = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != "`" { j += 1 }
                if j < chars.count {
                    let code = String(chars[(i + 1)..<j])
                    let token = "\u{0}CODE\(placeholders.count)\u{0}"
                    placeholders.append("<code>\(escape(code))</code>")
                    working += token
                    i = j + 1
                    continue
                }
            }
            working.append(chars[i]); i += 1
        }

        // 2) 转义其余文本
        var html = escape(working)

        // 3) 链接 [text](url)
        html = replaceLinks(html)

        // 4) 粗体 / 斜体
        html = replacePaired(html, marker: "**", tag: "strong")
        html = replacePaired(html, marker: "__", tag: "strong")
        html = replacePaired(html, marker: "*", tag: "em")

        // 5) 还原行内代码
        for (idx, rep) in placeholders.enumerated() {
            html = html.replacingOccurrences(of: "\u{0}CODE\(idx)\u{0}", with: rep)
        }
        return html
    }

    private static func replacePaired(_ text: String, marker: String, tag: String) -> String {
        let parts = text.components(separatedBy: marker)
        // 需要奇数段(偶数个分隔)才成对;不成对原样拼回。
        guard parts.count >= 3, parts.count % 2 == 1 else { return text }
        var out = parts[0]
        var idx = 1
        while idx < parts.count {
            out += "<\(tag)>\(parts[idx])</\(tag)>"
            if idx + 1 < parts.count { out += parts[idx + 1] }
            idx += 2
        }
        return out
    }

    private static func replaceLinks(_ text: String) -> String {
        // 已转义文本里查找 [label](url)。url 不含空格/括号。
        guard text.contains("](") else { return text }
        var result = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "[" {
                // 找 ]
                if let close = indexOf(chars, "]", from: i + 1),
                   close + 1 < chars.count, chars[close + 1] == "(",
                   let paren = indexOf(chars, ")", from: close + 2) {
                    let label = String(chars[(i + 1)..<close])
                    let url = String(chars[(close + 2)..<paren]).trimmingCharacters(in: .whitespaces)
                    if isSafeURL(url) {
                        result += "<a href=\"\(url)\" target=\"_blank\" rel=\"noopener\">\(label)</a>"
                        i = paren + 1
                        continue
                    }
                }
            }
            result.append(chars[i]); i += 1
        }
        return result
    }

    private static func indexOf(_ chars: [Character], _ target: Character, from: Int) -> Int? {
        var i = from
        while i < chars.count { if chars[i] == target { return i }; i += 1 }
        return nil
    }

    private static func isSafeURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") || lower.hasPrefix("#")
    }

    /// HTML 转义。注意:链接 url 是 escape 之后再拼 href 的,故 & 已转 &amp; 不会破坏属性。
    static func escape(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        return s
    }
}
