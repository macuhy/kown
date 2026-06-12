import Foundation
import PDFKit

/// 大文档 / 文件夹分块入库:把整本 PDF(逐页抽文本)、.txt/.md 大文件、整个文件夹的
/// 支持文件抽成 `KnowledgeDoc`,**预切块并带页码 + 来源文件名**,供本地 RAG 检索时给出
/// 「第几页」的引用,且不再受单文档注入字数上限拖累。
///
/// 全部抽取 / 切块是纯计算,放后台跑(`nonisolated`),不钉死主线程。
enum DocumentIngestor {

    /// 入库结果:抽好的文档 + 失败文件原因(给 UI 汇报)。
    struct Result: Sendable {
        var docs: [KnowledgeDoc]
        var failures: [(name: String, reason: String)]
    }

    /// 进度回调:已处理文件数 / 总数 / 当前文件名。
    typealias Progress = @Sendable (_ done: Int, _ total: Int, _ current: String) -> Void

    /// 支持入库的纯文本扩展名(PDF 单独走 PDFKit)。
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "text", "json", "yaml", "yml", "xml", "csv",
        "html", "htm", "rtf", "log", "tex", "swift", "py", "js", "ts", "java",
        "c", "cpp", "h", "go", "rs", "rb", "kt", "sh", "toml", "ini"
    ]

    /// 原始 PDF 文件上限(与附件链路一致,避免一本超大书撑爆内存)。
    static let maxPDFBytes = 50 * 1024 * 1024  // 50MB
    /// 单个纯文本文件上限(分块入库,放宽到 5MB)。
    static let maxTextBytes = 5 * 1024 * 1024
    /// 文件夹递归枚举的最大文件数,避免误选巨大目录。
    static let maxFilesPerFolder = 500

    // MARK: - PDF(逐页抽文本 + 带页码分块)

    /// 用 PDFKit 逐页抽文本,按页切块。每块带 1-based 页码。
    /// 加密 / 损坏 / 全是扫描件(无文本层)→ 抛错。
    nonisolated static func ingestPDF(at url: URL) throws -> KnowledgeDoc {
        let attrs = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = attrs.fileSize ?? 0
        guard size <= maxPDFBytes else {
            throw IngestError.tooLarge(name: url.lastPathComponent, mb: maxPDFBytes / 1024 / 1024)
        }
        guard let doc = PDFDocument(url: url) else {
            throw IngestError.pdfDecodeFailed(name: url.lastPathComponent)
        }
        if doc.isLocked {
            throw IngestError.pdfEncrypted(name: url.lastPathComponent)
        }
        var pageTexts: [String] = []
        var fullText = ""
        for i in 0..<doc.pageCount {
            let pageStr = doc.page(at: i)?.string ?? ""
            pageTexts.append(pageStr)
            if !pageStr.isEmpty {
                fullText += (fullText.isEmpty ? "" : "\n\n") + pageStr
            }
        }
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IngestError.pdfNoText(name: url.lastPathComponent)
        }
        let chunks = LocalRAG.chunkPages(pageTexts)
        let name = url.lastPathComponent
        return KnowledgeDoc(
            name: name,
            text: fullText,
            chunks: chunks.isEmpty ? nil : chunks,
            sourceFile: name,
            pageCount: doc.pageCount
        )
    }

    // MARK: - 纯文本(.txt / .md / …)

    /// 读纯文本文件 → 分块入库(无页码)。预切块到 `chunks`,大文件也能整篇检索。
    nonisolated static func ingestText(at url: URL, displayName: String? = nil) throws -> KnowledgeDoc {
        let attrs = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = attrs.fileSize ?? 0
        guard size <= maxTextBytes else {
            throw IngestError.tooLarge(name: url.lastPathComponent, mb: maxTextBytes / 1024 / 1024)
        }
        let data = try Data(contentsOf: url)
        guard let text = decodeText(data)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw IngestError.notText(name: url.lastPathComponent)
        }
        let name = displayName ?? url.lastPathComponent
        let chunks = LocalRAG.chunk(text).map { DocChunk(text: $0, page: nil) }
        return KnowledgeDoc(
            name: name,
            text: text,
            chunks: chunks.isEmpty ? nil : chunks,
            sourceFile: url.lastPathComponent,
            pageCount: nil
        )
    }

    /// 按扩展名分流:PDF 走 `ingestPDF`,文本扩展名走 `ingestText`,其它抛 unsupported。
    nonisolated static func ingestFile(at url: URL, displayName: String? = nil) throws -> KnowledgeDoc {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            var doc = try ingestPDF(at: url)
            if let displayName { doc = renamed(doc, to: displayName) }
            return doc
        }
        if textExtensions.contains(ext) || ext.isEmpty {
            return try ingestText(at: url, displayName: displayName)
        }
        throw IngestError.unsupported(name: url.lastPathComponent)
    }

    // MARK: - 文件夹(递归枚举支持的文件)

    /// 递归枚举文件夹下所有支持的文件(PDF + 文本扩展名),逐个入库。
    /// `displayPrefix` 用相对路径做文档名(如 `子目录/文件.md`),来源文件名保留纯名。
    /// 进度回调按文件粒度上报。整段在后台跑。
    /// node_modules / build 等依赖、产物目录整棵跳过;循环内响应 `Task` 取消(取消即返回已完成部分)。
    nonisolated static func ingestFolder(at folderURL: URL, progress: Progress? = nil) -> Result {
        let fm = FileManager.default
        var files: [URL] = []
        if let en = fm.enumerator(at: folderURL,
                                  includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let u as URL in en {
                if Task.isCancelled { break }
                let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                // 依赖 / 产物目录不下钻(误选了工程根目录时不再枚举几十万个文件)。
                if v?.isDirectory == true {
                    if WorkspaceManager.excludedDirNames.contains(u.lastPathComponent) {
                        en.skipDescendants()
                    }
                    continue
                }
                let ext = u.pathExtension.lowercased()
                guard ext == "pdf" || textExtensions.contains(ext) else { continue }
                if v?.isRegularFile == true {
                    files.append(u)
                    if files.count >= maxFilesPerFolder { break }
                }
            }
        }

        var docs: [KnowledgeDoc] = []
        var failures: [(name: String, reason: String)] = []
        let total = files.count
        let basePath = folderURL.path
        for (i, file) in files.enumerated() {
            // 用户点了「取消」:立即收手,返回已抽好的部分(由调用方决定是否入库)。
            if Task.isCancelled { break }
            // 用相对路径作展示名,保留目录层级信息。
            var rel = file.path
            if rel.hasPrefix(basePath) {
                rel = String(rel.dropFirst(basePath.count))
                if rel.hasPrefix("/") { rel.removeFirst() }
            }
            let display = rel.isEmpty ? file.lastPathComponent : rel
            progress?(i, total, display)
            do {
                docs.append(try ingestFile(at: file, displayName: display))
            } catch {
                let reason = (error as? IngestError)?.message ?? error.localizedDescription
                failures.append((name: display, reason: reason))
            }
        }
        progress?(total, total, "")
        return Result(docs: docs, failures: failures)
    }

    // MARK: - 辅助

    private nonisolated static func renamed(_ doc: KnowledgeDoc, to name: String) -> KnowledgeDoc {
        KnowledgeDoc(id: doc.id, name: name, text: doc.text, addedAt: doc.addedAt,
                     chunks: doc.chunks, sourceFile: doc.sourceFile, pageCount: doc.pageCount)
    }

    /// 多编码兜底解码(对齐 AttachmentLoader 的策略)。
    private nonisolated static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    enum IngestError: LocalizedError {
        case tooLarge(name: String, mb: Int)
        case notText(name: String)
        case unsupported(name: String)
        case pdfDecodeFailed(name: String)
        case pdfEncrypted(name: String)
        case pdfNoText(name: String)

        var message: String {
            switch self {
            case .tooLarge(_, let mb):   return "超过 \(mb)MB"
            case .notText:               return "无法解析为文本"
            case .unsupported:           return "不支持的文件类型"
            case .pdfDecodeFailed:       return "PDF 解析失败(可能损坏)"
            case .pdfEncrypted:          return "PDF 已加密"
            case .pdfNoText:             return "PDF 无文本层(可能是扫描件)"
            }
        }
        var errorDescription: String? {
            switch self {
            case .tooLarge(let n, _), .notText(let n), .unsupported(let n),
                 .pdfDecodeFailed(let n), .pdfEncrypted(let n), .pdfNoText(let n):
                return "\(n):\(message)"
            }
        }
    }
}
