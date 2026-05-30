import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 输入区附件：文本文件或图片
enum Attachment: Identifiable, Hashable, Sendable {
    case file(FilePayload)
    case image(ImagePayload)

    var id: UUID {
        switch self {
        case .file(let f): return f.id
        case .image(let i): return i.id
        }
    }

    var displayName: String {
        switch self {
        case .file(let f): return f.name
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

    enum LoadError: LocalizedError {
        case fileTooLarge(Int)
        case readFailed(String)
        case notText
        case imageTooLarge(Int)
        case imageDecode

        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let n): return "文件超过 \(maxFileBytes / 1024)KB（实际 \(n / 1024)KB）"
            case .readFailed(let m):   return "读取失败：\(m)"
            case .notText:             return "无法解析为文本（请选 .txt/.md/.json 等纯文本文件）"
            case .imageTooLarge(let n): return "图片超过 \(maxImageBytes / 1024 / 1024)MB（实际 \(n / 1024 / 1024)MB）"
            case .imageDecode:         return "图片解码失败"
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
        guard let content = String(data: data, encoding: .utf8) else {
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
