import Foundation

/// 从(流式)markdown 文本里抽出可预览的 fenced 代码块(```html / ```svg / ```mermaid)。
///
/// 与 `MD.balancedFences`(只补未闭合围栏)互补:这里真正把围栏内容**抽出来**。
/// 最后一个未闭合围栏标 `isClosed=false`,以便流式中途也能边流边预览。
/// 轻量(单次按行扫描),跑在面板的节流快照上,不在每个 chunk 上跑。
enum ArtifactExtractor {
    static func extract(_ text: String) -> [ArtifactBlock] {
        guard text.contains("```") else { return [] }
        var blocks: [ArtifactBlock] = []
        var inFence = false
        var fenceKind: ArtifactKind?
        var buffer: [Substring] = []
        var nextID = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if !inFence {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inFence = true
                    fenceKind = kind(forInfo: info)
                    buffer = []
                }
            } else {
                if trimmed == "```" || trimmed == "~~~" || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    if let k = fenceKind {
                        let src = buffer.map(String.init).joined(separator: "\n").trimmingCharacters(in: .newlines)
                        if !src.isEmpty {
                            blocks.append(ArtifactBlock(id: nextID, kind: k, source: src, isClosed: true))
                            nextID += 1
                        }
                    }
                    inFence = false
                    fenceKind = nil
                    buffer = []
                } else {
                    buffer.append(rawLine)
                }
            }
        }
        // 流式中途:围栏还没闭合,但已有内容 → 当作未闭合 artifact 先预览。
        if inFence, let k = fenceKind {
            let src = buffer.map(String.init).joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !src.isEmpty {
                blocks.append(ArtifactBlock(id: nextID, kind: k, source: src, isClosed: false))
            }
        }
        return blocks
    }

    // MARK: - 「让 AI 修改」支持

    /// 从「让 AI 修改」的回复里抽出修改后的完整代码。
    /// 优先取与原 artifact **同类**的围栏块;退而取第一个围栏块;
    /// 回复完全没有围栏时,整段去空白后作为代码(模型偶尔会裸输出)。
    static func revisedSource(fromReply reply: String, kind: ArtifactKind) -> String? {
        let matching = extract(reply)
        if let block = matching.first(where: { $0.kind == kind }) ?? matching.first {
            return block.source
        }
        // 任意语言围栏(```css、```js 或裸 ```)— extract 只认 html/svg/mermaid,这里兜底。
        if let generic = firstFencedBlock(in: reply) { return generic }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("```") else { return nil }
        return trimmed
    }

    /// 「让 AI 修改」的 system 指令:要求返回完整代码 + 单代码块,便于机器解析。
    static func revisionSystemPrompt(for kind: ArtifactKind) -> String {
        let lang: String
        switch kind {
        case .html: lang = "html"
        case .svg: lang = "svg"
        case .mermaid: lang = "mermaid"
        }
        return """
        你是一个代码画布(Canvas)助手。用户会给你一段 \(kind.displayName) 代码和修改要求。
        规则:
        1) 在保留原有功能与结构的前提下,按要求修改。
        2) 返回**修改后的完整代码**(不是 diff、不是片段),放在**唯一一个** ```\(lang) 围栏代码块里。
        3) 代码块之外不要输出任何解释、前言或总结。
        """
    }

    /// 「让 AI 修改」的 user prompt:当前 artifact 全文 + 修改要求(+ 可选重点片段)。
    static func revisionPrompt(source: String, kind: ArtifactKind,
                               instruction: String, focus: String?) -> String {
        let lang: String
        switch kind {
        case .html: lang = "html"
        case .svg: lang = "svg"
        case .mermaid: lang = "mermaid"
        }
        var lines: [String] = []
        lines.append("【当前 \(kind.displayName) 代码】")
        lines.append("```\(lang)")
        lines.append(source)
        lines.append("```")
        lines.append("")
        if let f = focus?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty {
            lines.append("【重点片段 — 修改主要围绕这段】")
            lines.append(f)
            lines.append("")
        }
        lines.append("【修改要求】")
        lines.append(instruction)
        return lines.joined(separator: "\n")
    }

    /// 第一个闭合的围栏块内容(不限语言)。
    private static func firstFencedBlock(in text: String) -> String? {
        guard text.contains("```") else { return nil }
        var inFence = false
        var buffer: [Substring] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if !inFence {
                if trimmed.hasPrefix("```") { inFence = true; buffer = [] }
            } else {
                if trimmed.hasPrefix("```") {
                    let src = buffer.map(String.init).joined(separator: "\n").trimmingCharacters(in: .newlines)
                    return src.isEmpty ? nil : src
                }
                buffer.append(rawLine)
            }
        }
        return nil
    }

    /// 围栏 info-string(如 "html"、"mermaid"、"svg xml")→ 可预览类型;不可预览返回 nil。
    private static func kind(forInfo info: String) -> ArtifactKind? {
        let lang = info
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            .first
            .map(String.init)?
            .lowercased() ?? ""
        switch lang {
        case "html", "htm": return .html
        case "svg": return .svg
        case "mermaid": return .mermaid
        default: return nil
        }
    }

    // MARK: - 交互工具(生成式 UI)块识别 —— 加性,不动上面的 ArtifactKind / extract 路径

    /// 模型偶尔会在普通回答里直接吐一个「交互工具」围栏块(```kowntool / ```generative-ui),
    /// 内容是 `GenerativeToolSpec` 的 JSON。这里把它**抽出来**(与 html/svg/mermaid 并列识别,
    /// 但走独立返回值,绝不混进 `ArtifactKind` 的三态枚举与其 switch,避免改散预览面板)。
    /// 取第一个匹配的闭合围栏内容;没有返回 nil。
    static func generativeToolSource(in text: String) -> String? {
        guard text.contains("```") else { return nil }
        var inFence = false
        var isToolFence = false
        var buffer: [Substring] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if !inFence {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inFence = true
                    isToolFence = isGenerativeToolInfo(info)
                    buffer = []
                }
            } else {
                if trimmed == "```" || trimmed == "~~~" || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    if isToolFence {
                        let src = buffer.map(String.init).joined(separator: "\n").trimmingCharacters(in: .newlines)
                        if !src.isEmpty { return src }
                    }
                    inFence = false
                    isToolFence = false
                    buffer = []
                } else {
                    buffer.append(rawLine)
                }
            }
        }
        return nil
    }

    /// 围栏 info-string 是不是「交互工具」块。
    private static func isGenerativeToolInfo(_ info: String) -> Bool {
        let lang = info
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            .first
            .map(String.init)?
            .lowercased() ?? ""
        return lang == "kowntool" || lang == "generative-ui" || lang == "generativeui" || lang == "kown-tool"
    }
}
