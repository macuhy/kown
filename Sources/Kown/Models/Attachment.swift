import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// 输入区附件：文本文件、PDF(抽出文本)或图片
enum Attachment: Identifiable, Hashable, Sendable {
    case file(FilePayload)
    case pdf(PDFPayload)
    case image(ImagePayload)

    var id: UUID {
        switch self {
        case .file(let f): return f.id
        case .pdf(let p):  return p.id
        case .image(let i): return i.id
        }
    }

    var displayName: String {
        switch self {
        case .file(let f): return f.name
        case .pdf(let p):  return p.name
        case .image(let i): return i.name
        }
    }

    struct FilePayload: Identifiable, Hashable, Sendable {
        let id: UUID
        let name: String
        let content: String
        let byteCount: Int
        let url: URL
    }

    /// PDF 附件:已抽出的纯文本 + 页数。发送时与文件一样并入 prompt 文本。
    struct PDFPayload: Identifiable, Hashable, Sendable {
        let id: UUID
        let name: String
        let extractedText: String
        let pageCount: Int
        let byteCount: Int
        let url: URL
    }

    struct ImagePayload: Identifiable, Hashable, Sendable {
        let id: UUID
        let name: String
        let mimeType: String
        let base64: String
        let pixelWidth: Int
        let pixelHeight: Int
        let url: URL
    }
}

/// 把附件文件读成文本（限大小）
enum AttachmentLoader {
    static let maxFileBytes = 200 * 1024 // 200KB
    static let maxImageBytes = 8 * 1024 * 1024 // 8MB
    static let maxPDFBytes = 10 * 1024 * 1024 // 10MB(原始 PDF 文件)
    static let maxPDFTextChars = 120 * 1024 // 抽出文本上限,超出截断避免撑爆上下文

    enum LoadError: LocalizedError {
        case fileTooLarge(Int)
        case readFailed(String)
        case notText
        case imageTooLarge(Int)
        case imageDecode
        case pdfTooLarge(Int)
        case pdfEncrypted
        case pdfDecodeFailed
        case pdfNoText

        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let n): return "文件超过 \(maxFileBytes / 1024)KB（实际 \(n / 1024)KB）"
            case .readFailed(let m):   return "读取失败：\(m)"
            case .notText:             return "无法解析为文本（请选 .txt/.md/.json 等纯文本文件,或 PDF）"
            case .imageTooLarge(let n): return "图片超过 \(maxImageBytes / 1024 / 1024)MB（实际 \(n / 1024 / 1024)MB）"
            case .imageDecode:         return "图片解码失败"
            case .pdfTooLarge(let n):  return "PDF 超过 \(maxPDFBytes / 1024 / 1024)MB（实际 \(n / 1024 / 1024)MB）"
            case .pdfEncrypted:        return "PDF 已加密 / 受口令保护,无法读取"
            case .pdfDecodeFailed:     return "PDF 解析失败(文件可能损坏)"
            case .pdfNoText:           return "PDF 没有可抽取的文本(可能是扫描件 / 纯图片)"
            }
        }
    }

    static func loadFile(at url: URL) throws -> Attachment.FilePayload {
        let attrs = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = attrs.fileSize ?? 0
        if size > maxFileBytes {
            throw LoadError.fileTooLarge(size)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.readFailed(error.localizedDescription)
        }
        guard let content = decodeText(data) else {
            throw LoadError.notText
        }
        return Attachment.FilePayload(
            id: UUID(),
            name: url.lastPathComponent,
            content: content,
            byteCount: size,
            url: url
        )
    }

    /// 尝试多种编码把字节解成文本:UTF-8 → UTF-16 → GB18030 → ISO Latin-1(有损兜底)。
    /// 优先无损;只有都失败才用 Latin-1(永不失败,可能出现替换字符)。
    private static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        // 简体中文常见 GB18030
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        // Latin-1 不会失败(单字节全覆盖),作为最后兜底,避免直接判 notText
        return String(data: data, encoding: .isoLatin1)
    }

    /// 用 PDFKit 抽取 PDF 全文(跨平台)。加密 / 损坏 / 无文本层各给明确错误。
    static func loadPDF(at url: URL) throws -> Attachment.PDFPayload {
        let attrs = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = attrs.fileSize ?? 0
        if size > maxPDFBytes {
            throw LoadError.pdfTooLarge(size)
        }
        guard let doc = PDFDocument(url: url) else {
            throw LoadError.pdfDecodeFailed
        }
        if doc.isLocked {
            throw LoadError.pdfEncrypted
        }
        var text = doc.string ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw LoadError.pdfNoText
        }
        if text.count > maxPDFTextChars {
            text = String(text.prefix(maxPDFTextChars)) + "\n\n…(PDF 文本过长已截断)"
        }
        return Attachment.PDFPayload(
            id: UUID(),
            name: url.lastPathComponent,
            extractedText: text,
            pageCount: doc.pageCount,
            byteCount: size,
            url: url
        )
    }

    /// 视觉 API 普遍接受的图片格式(Anthropic / OpenAI / Gemini)。HEIC 不在其中。
    private static let webStandardMimes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// 从任意图片 Data 构造附件,必要时把 HEIC / 非标准格式转成 JPEG。
    /// iOS 相册多为 HEIC,而 Anthropic / OpenAI / Gemini 多不收 HEIC → 统一转 JPEG。
    static func loadImageNormalized(data: Data, name: String) throws -> Attachment.ImagePayload {
        let sniffed = sniffMime(data: data)
        if let m = sniffed, webStandardMimes.contains(m) {
            return try loadImage(data: data, name: name, mime: m)
        }
        // HEIC / 未知 → 转 JPEG;转码失败就退回原样,让服务端决定。
        guard let jpeg = transcodeToJPEG(data) else {
            return try loadImage(data: data, name: name, mime: sniffed)
        }
        let base = (name as NSString).deletingPathExtension
        return try loadImage(data: jpeg, name: (base.isEmpty ? "image" : base) + ".jpg", mime: "image/jpeg")
    }

    /// 用 ImageIO 把任意图片转成 JPEG(跨平台,不依赖 UIKit / AppKit)。
    private static func transcodeToJPEG(_ data: Data, quality: CGFloat = 0.9) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 从已有 Data 直接构造图片附件(用于剪贴板 / drop / 其他非文件来源)。
    static func loadImage(data: Data, name: String, mime: String? = nil) throws -> Attachment.ImagePayload {
        if data.count > maxImageBytes {
            throw LoadError.imageTooLarge(data.count)
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw LoadError.imageDecode
        }
        let resolvedMime = mime ?? sniffMime(data: data) ?? "application/octet-stream"
        return Attachment.ImagePayload(
            id: UUID(),
            name: name,
            mimeType: resolvedMime,
            base64: data.base64EncodedString(),
            pixelWidth: w,
            pixelHeight: h,
            url: URL(fileURLWithPath: "/dev/null")  // pasted/dropped 没真实 URL
        )
    }

    /// 通过 ImageIO 读 UTI 反推 MIME。
    private static func sniffMime(data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(src) as String? else { return nil }
        switch uti {
        case "public.png":  return "image/png"
        case "public.jpeg": return "image/jpeg"
        case "com.compuserve.gif": return "image/gif"
        case "org.webmproject.webp": return "image/webp"
        case "public.heic": return "image/heic"
        default: return nil
        }
    }

    static func loadImage(at url: URL) throws -> Attachment.ImagePayload {
        let attrs = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = attrs.fileSize ?? 0
        if size > maxImageBytes {
            throw LoadError.imageTooLarge(size)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.readFailed(error.localizedDescription)
        }
        // 用 ImageIO 跨平台读分辨率(无需 AppKit / UIKit)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw LoadError.imageDecode
        }
        let ext = url.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png":         mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif":         mime = "image/gif"
        case "webp":        mime = "image/webp"
        case "heic":        mime = "image/heic"
        default:            mime = "application/octet-stream"
        }
        let base64 = data.base64EncodedString()
        return Attachment.ImagePayload(
            id: UUID(),
            name: url.lastPathComponent,
            mimeType: mime,
            base64: base64,
            pixelWidth: w,
            pixelHeight: h,
            url: url
        )
    }
}
