import Foundation

/// A user-facing export shape that Deliverable Studio can generate without model calls.
enum DeliverableKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case markdown
    case html
    case pdfOutline
    case pptOutline
    case webpage
    case docx
    case pptx
    case pdf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .pdfOutline: return "PDF 大纲"
        case .pptOutline: return "PPT 大纲"
        case .webpage: return "网页"
        case .docx: return "Word 文档"
        case .pptx: return "PowerPoint"
        case .pdf: return "PDF 文件"
        }
    }

    var shortDescription: String {
        switch self {
        case .markdown: return "结构化文本,适合继续编辑或粘贴到文档。"
        case .html: return "可离线打开的只读 HTML 文档。"
        case .pdfOutline: return "面向报告/PDF 的章节、页面和版式大纲。"
        case .pptOutline: return "面向演示文稿的逐页幻灯片大纲。"
        case .webpage: return "带基础样式的单页网页草稿。"
        case .docx: return "生成可直接打开编辑的 .docx 文件。"
        case .pptx: return "生成可直接打开编辑的 .pptx 幻灯片。"
        case .pdf: return "生成可分享的分页 PDF 文件。"
        }
    }

    var defaultFileExtension: String {
        switch self {
        case .markdown, .pdfOutline, .pptOutline: return "md"
        case .html, .webpage: return "html"
        case .docx: return "docx"
        case .pptx: return "pptx"
        case .pdf: return "pdf"
        }
    }

    var systemImage: String {
        switch self {
        case .markdown: return "doc.plaintext"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .pdfOutline: return "doc.richtext"
        case .pptOutline: return "rectangle.on.rectangle.angled"
        case .webpage: return "globe"
        case .docx: return "doc.text"
        case .pptx: return "rectangle.on.rectangle.angled"
        case .pdf: return "doc.richtext.fill"
        }
    }

    var isBinaryExport: Bool {
        switch self {
        case .docx, .pptx, .pdf: return true
        default: return false
        }
    }
}

/// The original material being transformed into a deliverable.
enum DeliverableSourceKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case answer
    case research
    case meeting
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .answer: return "回答"
        case .research: return "研究"
        case .meeting: return "会议"
        case .custom: return "自定义"
        }
    }

    var defaultTitle: String {
        switch self {
        case .answer: return "回答交付物"
        case .research: return "研究交付物"
        case .meeting: return "会议交付物"
        case .custom: return "交付物"
        }
    }
}

/// A generated deliverable preview/export payload.
struct Deliverable: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var kind: DeliverableKind
    var sourceKind: DeliverableSourceKind
    var content: String
    var summary: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        kind: DeliverableKind,
        sourceKind: DeliverableSourceKind,
        content: String,
        summary: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.sourceKind = sourceKind
        self.content = content
        self.summary = summary
        self.createdAt = createdAt
    }

    var suggestedFileName: String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: illegal)
            .joined(separator: "-")
        let base = cleaned.isEmpty ? sourceKind.defaultTitle : String(cleaned.prefix(80))
        return "\(base).\(kind.defaultFileExtension)"
    }
}

/// Input contract for the deterministic MVP generator.
struct DeliverableRequest: Equatable, Sendable {
    var title: String
    var sourceKind: DeliverableSourceKind
    var targetKind: DeliverableKind
    var sourceText: String
    var audience: String
    var goal: String
    var createdAt: Date

    init(
        title: String = "",
        sourceKind: DeliverableSourceKind = .answer,
        targetKind: DeliverableKind = .markdown,
        sourceText: String = "",
        audience: String = "",
        goal: String = "",
        createdAt: Date = Date()
    ) {
        self.title = title
        self.sourceKind = sourceKind
        self.targetKind = targetKind
        self.sourceText = sourceText
        self.audience = audience
        self.goal = goal
        self.createdAt = createdAt
    }
}
