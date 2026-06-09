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
        var buffer: [String] = []
        var nextID = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
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
                        let src = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
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
            let src = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !src.isEmpty {
                blocks.append(ArtifactBlock(id: nextID, kind: k, source: src, isClosed: false))
            }
        }
        return blocks
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
}
