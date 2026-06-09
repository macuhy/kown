import Foundation

/// 可在预览面板里渲染的 artifact 类型。仅 html / svg / mermaid 三类(v1 范围)。
enum ArtifactKind: Equatable {
    case html
    case svg
    case mermaid

    var displayName: String {
        switch self {
        case .html: return "HTML"
        case .svg: return "SVG"
        case .mermaid: return "Mermaid"
        }
    }

    var symbol: String {
        switch self {
        case .html: return "globe"
        case .svg: return "square.on.circle"
        case .mermaid: return "flowchart"
        }
    }
}

/// 从模型回答的 markdown 里抽出的一段可预览内容。
/// `id` 是它在该条回答里出现的序号(稳定),用于面板里选择/切换。
/// `isClosed=false` 表示流式中途、围栏尚未闭合(仍可边流边预览)。
struct ArtifactBlock: Identifiable, Equatable {
    let id: Int
    let kind: ArtifactKind
    let source: String
    let isClosed: Bool
}
