import Foundation

/// Deterministic, offline-first generator for Deliverable Studio MVP.
/// It wraps existing answers/research/meeting notes into editable text outputs.
enum DeliverableStudioService {
    static func generate(
        title: String,
        sourceKind: DeliverableSourceKind = .answer,
        targetKind: DeliverableKind,
        sourceText: String,
        audience: String = "",
        goal: String = "",
        createdAt: Date = Date()
    ) -> Deliverable {
        generate(DeliverableRequest(
            title: title,
            sourceKind: sourceKind,
            targetKind: targetKind,
            sourceText: sourceText,
            audience: audience,
            goal: goal,
            createdAt: createdAt
        ))
    }

    static func generate(_ request: DeliverableRequest) -> Deliverable {
        let title = normalizedTitle(request.title, sourceKind: request.sourceKind)
        let source = cleaned(request.sourceText)
        let context = Context(
            title: title,
            sourceKind: request.sourceKind,
            sourceText: source,
            audience: cleaned(request.audience),
            goal: cleaned(request.goal),
            summary: summary(from: source, fallbackTitle: title),
            bullets: bullets(from: source),
            sections: sections(from: source, fallbackTitle: title),
            createdAt: request.createdAt
        )

        let content: String
        switch request.targetKind {
        case .markdown:
            content = markdown(context)
        case .html:
            content = htmlDocument(context)
        case .pdfOutline:
            content = pdfOutline(context)
        case .pptOutline:
            content = pptOutline(context)
        case .webpage:
            content = webpage(context)
        }

        return Deliverable(
            title: title,
            kind: request.targetKind,
            sourceKind: request.sourceKind,
            content: content,
            summary: context.summary,
            createdAt: request.createdAt
        )
    }
}

private extension DeliverableStudioService {
    struct Context {
        let title: String
        let sourceKind: DeliverableSourceKind
        let sourceText: String
        let audience: String
        let goal: String
        let summary: String
        let bullets: [String]
        let sections: [Section]
        let createdAt: Date
    }

    struct Section: Equatable {
        let title: String
        let body: String
    }

    static func markdown(_ context: Context) -> String {
        var lines: [String] = [
            "# \(context.title)",
            "",
            metadataLine(context),
            "",
            "## 摘要",
            context.summary,
            "",
            "## 关键要点"
        ]

        lines.append(contentsOf: context.bullets.map { "- \($0)" })
        lines.append(contentsOf: ["", "## 正文"])
        for section in context.sections {
            lines.append(contentsOf: ["", "### \(section.title)", section.body])
        }
        lines.append(contentsOf: ["", "## 下一步", "- 补充事实、数据或引用来源。", "- 确认受众、交付格式和截止时间。", "- 根据反馈迭代为最终版本。"])
        return lines.joined(separator: "\n")
    }

    static func htmlDocument(_ context: Context) -> String {
        let sectionHTML = context.sections.map { section in
            """
            <section>
              <h2>\(escapeHTML(section.title))</h2>
              \(paragraphsHTML(section.body))
            </section>
            """
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Kown Deliverable Studio">
        <title>\(escapeHTML(context.title))</title>
        <style>
        \(baseCSS)
        </style>
        </head>
        <body>
        <main class="document">
          <header>
            <p class="eyebrow">\(escapeHTML(context.sourceKind.displayName)) · Deliverable</p>
            <h1>\(escapeHTML(context.title))</h1>
            <p class="summary">\(escapeHTML(context.summary))</p>
            \(metaHTML(context))
          </header>
          <section>
            <h2>关键要点</h2>
            <ul>
              \(context.bullets.map { "<li>\(escapeHTML($0))</li>" }.joined(separator: "\n              "))
            </ul>
          </section>
          \(sectionHTML)
        </main>
        </body>
        </html>
        """
    }

    static func pdfOutline(_ context: Context) -> String {
        var lines: [String] = [
            "# \(context.title) · PDF 大纲",
            "",
            metadataLine(context),
            "",
            "## 文档定位",
            "- 受众：\(context.audience.isEmpty ? "待补充" : context.audience)",
            "- 目标：\(context.goal.isEmpty ? "把素材整理为可阅读、可分享的正式文档" : context.goal)",
            "- 摘要：\(context.summary)",
            "",
            "## 页面结构",
            "1. 封面：标题、副标题、来源类型和日期。",
            "2. 执行摘要：用 3-5 条要点快速说明结论。",
            "3. 正文章节：按主题拆分,每章保留事实、判断和证据。",
            "4. 行动/建议：明确下一步、负责人和时间节点。",
            "5. 附录：放原始回答、研究摘录或会议转写。",
            "",
            "## 核心章节"
        ]
        for (index, section) in context.sections.enumerated() {
            lines.append("\(index + 1). \(section.title)：\(oneLine(section.body, limit: 140))")
        }
        lines.append(contentsOf: ["", "## 版式建议", "- 每页只保留一个主信息,重要结论放在页首。", "- 数据、引用、待确认事项用统一标注区分。", "- 导出 PDF 前检查标题层级、分页和链接可读性。"])
        return lines.joined(separator: "\n")
    }

    static func pptOutline(_ context: Context) -> String {
        var lines: [String] = [
            "# \(context.title) · PPT 大纲",
            "",
            metadataLine(context),
            "",
            "## 演示目标",
            context.goal.isEmpty ? "让听众快速理解背景、结论和下一步。" : context.goal,
            "",
            "## 幻灯片结构",
            "1. 封面｜\(context.title)",
            "   - 副标题：\(context.sourceKind.displayName)转交付物",
            "   - 讲述重点：为什么现在要看这份材料",
            "2. 摘要｜一句话结论",
            "   - \(context.summary)"
        ]

        for (index, bullet) in context.bullets.enumerated() {
            lines.append("\(index + 3). 要点 \(index + 1)｜\(bullet)")
            lines.append("   - 证据/展开：从原始素材中补入数据、例子或引用")
            lines.append("   - 视觉建议：使用图标、流程图或对比卡片")
        }

        lines.append(contentsOf: [
            "\(context.bullets.count + 3). 行动页｜下一步",
            "   - 确认决策、负责人和截止时间",
            "   - 收集反馈并迭代最终版本",
            "\(context.bullets.count + 4). 附录｜原始素材",
            "   - 保留关键摘录,便于现场追问时回溯"
        ])
        return lines.joined(separator: "\n")
    }

    static func webpage(_ context: Context) -> String {
        let cards = context.bullets.map { bullet in
            "<article class=\"card\"><span>要点</span><p>\(escapeHTML(bullet))</p></article>"
        }.joined(separator: "\n        ")
        let sections = context.sections.map { section in
            """
            <section class="content-section">
              <h2>\(escapeHTML(section.title))</h2>
              \(paragraphsHTML(section.body))
            </section>
            """
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Kown Deliverable Studio">
        <title>\(escapeHTML(context.title))</title>
        <style>
        \(webpageCSS)
        </style>
        </head>
        <body>
          <main>
            <section class="hero">
              <div class="badge">\(escapeHTML(context.sourceKind.displayName)) → 网页交付物</div>
              <h1>\(escapeHTML(context.title))</h1>
              <p>\(escapeHTML(context.summary))</p>
              \(metaHTML(context))
            </section>
            <section class="cards">
              \(cards)
            </section>
            \(sections)
          </main>
        </body>
        </html>
        """
    }

    static func normalizedTitle(_ raw: String, sourceKind: DeliverableSourceKind) -> String {
        let title = cleaned(raw)
        return title.isEmpty ? sourceKind.defaultTitle : title
    }

    static func cleaned(_ raw: String?) -> String {
        (raw ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summary(from source: String, fallbackTitle: String) -> String {
        let candidates = meaningfulLines(source)
        if let first = candidates.first {
            return oneLine(first, limit: 180)
        }
        return "围绕「\(fallbackTitle)」整理出的交付物草稿,等待补充原始素材。"
    }

    static func bullets(from source: String) -> [String] {
        let lines = meaningfulLines(source)
        var result: [String] = []
        for line in lines {
            let fragments = splitSentences(line)
            for fragment in fragments where !fragment.isEmpty {
                let cleaned = stripMarkdownPrefix(fragment)
                guard cleaned.count >= 6 else { continue }
                if !result.contains(cleaned) { result.append(oneLine(cleaned, limit: 120)) }
                if result.count == 5 { return result }
            }
        }
        if result.isEmpty {
            return ["补充背景和问题定义", "提炼关键发现或决策", "明确下一步行动"]
        }
        return result
    }

    static func sections(from source: String, fallbackTitle: String) -> [Section] {
        let lines = source.components(separatedBy: "\n")
        var sections: [Section] = []
        var currentTitle: String?
        var currentBody: [String] = []

        func flush() {
            guard let title = currentTitle else { return }
            let body = cleaned(currentBody.joined(separator: "\n"))
            sections.append(Section(title: title, body: body.isEmpty ? "待补充。" : body))
            currentBody.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    flush()
                    currentTitle = String(title)
                    continue
                }
            }
            if currentTitle != nil {
                currentBody.append(line)
            }
        }
        flush()

        if !sections.isEmpty { return Array(sections.prefix(6)) }
        let body = source.isEmpty ? "请在左侧粘贴回答、研究摘录或会议内容。" : source
        return [Section(title: fallbackTitle, body: body)]
    }

    static func meaningfulLines(_ source: String) -> [String] {
        source.components(separatedBy: "\n")
            .map { stripMarkdownPrefix($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
    }

    static func splitSentences(_ line: String) -> [String] {
        var fragments: [String] = []
        var current = ""
        let stops = Set<Character>(["。", "！", "？", ".", "!", "?"])
        for character in line {
            current.append(character)
            if stops.contains(character) {
                fragments.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll()
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { fragments.append(tail) }
        return fragments
    }

    static func stripMarkdownPrefix(_ line: String) -> String {
        var value = line
        while value.hasPrefix("#") { value.removeFirst() }
        value = value.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "> "] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if let dot = value.firstIndex(of: ".") {
            let number = value[..<dot]
            if !number.isEmpty && number.allSatisfy({ $0.isNumber }) {
                return value[value.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        let value = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > limit else { return value }
        return String(value.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func metadataLine(_ context: Context) -> String {
        var pieces = ["来源：\(context.sourceKind.displayName)"]
        if !context.audience.isEmpty { pieces.append("受众：\(context.audience)") }
        if !context.goal.isEmpty { pieces.append("目标：\(context.goal)") }
        return "> " + pieces.joined(separator: " · ")
    }

    static func metaHTML(_ context: Context) -> String {
        var items = ["<span>来源：\(escapeHTML(context.sourceKind.displayName))</span>"]
        if !context.audience.isEmpty { items.append("<span>受众：\(escapeHTML(context.audience))</span>") }
        if !context.goal.isEmpty { items.append("<span>目标：\(escapeHTML(context.goal))</span>") }
        return "<div class=\"meta\">\(items.joined(separator: ""))</div>"
    }

    static func paragraphsHTML(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if paragraphs.isEmpty { return "<p>待补充。</p>" }
        return paragraphs.map { "<p>\(escapeHTML(stripMarkdownPrefix($0)))</p>" }.joined(separator: "\n")
    }

    static func escapeHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static let baseCSS = """
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; line-height: 1.72; background: #f6f3ed; color: #24211d; }
    .document { width: min(860px, calc(100% - 32px)); margin: 0 auto; padding: 48px 0 72px; }
    header, section { background: rgba(255,255,255,.78); border: 1px solid rgba(70,55,35,.12); border-radius: 22px; padding: 24px; margin: 18px 0; box-shadow: 0 18px 50px rgba(70,55,35,.08); }
    h1 { margin: 0; font-size: clamp(2rem, 6vw, 4rem); line-height: 1; letter-spacing: -.04em; }
    h2 { margin: 0 0 12px; font-size: 1.35rem; }
    p { margin: .55em 0; }
    ul { padding-left: 1.2rem; }
    li { margin: .4rem 0; }
    .eyebrow { color: #a35420; font-weight: 800; text-transform: uppercase; letter-spacing: .12em; font-size: .78rem; }
    .summary { font-size: 1.08rem; color: #5b5147; }
    .meta { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 16px; }
    .meta span { border: 1px solid rgba(163,84,32,.25); color: #8a461b; padding: 6px 10px; border-radius: 999px; font-size: .85rem; font-weight: 700; }
    @media (prefers-color-scheme: dark) { body { background: #181614; color: #f6f1ea; } header, section { background: rgba(40,36,31,.86); border-color: rgba(255,255,255,.12); } .summary { color: #d3c7b8; } }
    """

    static let webpageCSS = """
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: Georgia, "Songti SC", serif; background: radial-gradient(circle at top left, #ffe7bd, transparent 34rem), linear-gradient(135deg, #10251f, #0a1115); color: #fffaf0; }
    main { width: min(1080px, calc(100% - 32px)); margin: 0 auto; padding: 56px 0 88px; }
    .hero { min-height: 46vh; display: grid; align-content: center; gap: 18px; }
    .badge { width: fit-content; border: 1px solid rgba(255,250,240,.35); border-radius: 999px; padding: 7px 12px; font: 700 .82rem ui-sans-serif, sans-serif; letter-spacing: .08em; color: #f7c56a; }
    h1 { max-width: 980px; margin: 0; font-size: clamp(2.6rem, 8vw, 6.8rem); line-height: .9; letter-spacing: -.06em; }
    .hero p { max-width: 720px; font-size: clamp(1.1rem, 2vw, 1.45rem); color: rgba(255,250,240,.78); }
    .meta { display: flex; flex-wrap: wrap; gap: 10px; }
    .meta span { background: rgba(255,255,255,.1); border: 1px solid rgba(255,255,255,.14); border-radius: 999px; padding: 8px 12px; font: 700 .88rem ui-sans-serif, sans-serif; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 14px; margin: 24px 0; }
    .card, .content-section { backdrop-filter: blur(18px); background: rgba(255,255,255,.10); border: 1px solid rgba(255,255,255,.16); border-radius: 26px; padding: 22px; box-shadow: 0 24px 80px rgba(0,0,0,.24); }
    .card span { color: #f7c56a; font: 800 .78rem ui-sans-serif, sans-serif; text-transform: uppercase; letter-spacing: .12em; }
    .card p { font-size: 1.05rem; line-height: 1.55; }
    .content-section { margin-top: 16px; }
    .content-section h2 { margin-top: 0; font-size: clamp(1.6rem, 3vw, 2.4rem); }
    .content-section p { color: rgba(255,250,240,.82); line-height: 1.75; }
    """
}
