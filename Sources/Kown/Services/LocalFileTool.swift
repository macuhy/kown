import Foundation

/// 一条待用户确认的本地文件写入(模型发起、尚未落盘)。
struct PendingFileWrite: Identifiable, Sendable, Hashable {
    let id: UUID
    /// 相对授权目录根的路径。
    var relativePath: String
    /// 现状全文(nil = 新建文件)。用于 diff。
    var oldContent: String?
    /// 模型想写入的新全文。
    var newContent: String
    /// 已落盘。
    var applied: Bool
    /// 落盘失败原因。
    var error: String?

    init(id: UUID = UUID(), relativePath: String, oldContent: String?, newContent: String,
         applied: Bool = false, error: String? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.oldContent = oldContent
        self.newContent = newContent
        self.applied = applied
        self.error = error
    }

    var isNew: Bool { oldContent == nil }
}

/// 全局「本地文件工具」状态(macOS):授权目录 bookmark + 待确认写入暂存。
/// 读 / 列目录工具即时执行;**写工具不直接落盘**,只把改动暂存到 `pendingWrites`,
/// 由用户在界面里看 diff 后点「应用」才真正写盘(用户拍板:写前必须确认)。
@MainActor
@Observable
final class LocalFileToolState {
    static let shared = LocalFileToolState()

    private static let bookmarkKey = "kown.localFileTool.bookmark"
    private static let pathKey = "kown.localFileTool.path"

    private(set) var bookmark: Data?
    private(set) var displayPath: String?
    /// 待用户确认的写入。
    var pendingWrites: [PendingFileWrite] = []

    private init() {
        self.bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey)
        self.displayPath = UserDefaults.standard.string(forKey: Self.pathKey)
    }

    var isAuthorized: Bool { bookmark != nil }

    /// 用户用 NSOpenPanel 选定目录后授权(存 security-scoped bookmark)。
    func setAuthorized(url: URL) {
        guard let data = try? WorkspaceManager.makeBookmark(for: url) else { return }
        bookmark = data
        displayPath = url.path
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        UserDefaults.standard.set(url.path, forKey: Self.pathKey)
    }

    func clearAuthorization() {
        bookmark = nil
        displayPath = nil
        pendingWrites.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.pathKey)
    }

    func stage(_ write: PendingFileWrite) { pendingWrites.append(write) }

    func discard(_ id: UUID) { pendingWrites.removeAll { $0.id == id } }

    func clearApplied() { pendingWrites.removeAll { $0.applied } }

    /// 应用一条暂存写入:解析 bookmark → 进 security scope → 写盘。成功后标记 applied。
    func apply(_ id: UUID) {
        guard let idx = pendingWrites.firstIndex(where: { $0.id == id }), let data = bookmark else { return }
        let w = pendingWrites[idx]
        do {
            let (root, _) = try WorkspaceManager.resolveBookmark(data)
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let url = try LocalFilesystem.resolved(root: root, rel: w.relativePath, forWrite: true)
            try LocalFilesystem.write(at: url, content: w.newContent)
            pendingWrites[idx].applied = true
            pendingWrites[idx].error = nil
        } catch {
            pendingWrites[idx].error = error.localizedDescription
        }
    }
}

/// 纯文件系统操作 + 越权 / 后缀 / 体积守卫。复用 `WorkspaceManager` 的同款安全约束。
/// 调用方负责 `startAccessingSecurityScopedResource()`。
enum LocalFilesystem {
    enum FSError: LocalizedError {
        case outOfRoot, notText, tooLarge, notFound, notReadable, isDirectory

        var errorDescription: String? {
            switch self {
            case .outOfRoot:    return "路径越出授权目录(或含 ..),已拒绝"
            case .notText:      return "文件后缀不在文本白名单内"
            case .tooLarge:     return "文件超过 1MB 上限"
            case .notFound:     return "文件不存在"
            case .notReadable:  return "无法以 UTF-8 读取(可能是二进制)"
            case .isDirectory:  return "目标是目录,不是文件"
            }
        }
    }

    static let maxSize = 1024 * 1024  // 1MB,与 WorkspaceManager 对齐

    /// 解析相对路径到授权目录内的安全绝对 URL,并做越权校验。
    static func resolved(root: URL, rel: String, forWrite: Bool = false) throws -> URL {
        let clean = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
        guard !clean.contains("..") else { throw FSError.outOfRoot }
        let target = clean.isEmpty ? root : root.appendingPathComponent(clean)
        let r = root.standardizedFileURL.resolvingSymlinksInPath()
        let t = target.standardizedFileURL.resolvingSymlinksInPath()
        guard t.path == r.path || t.path.hasPrefix(r.path + "/") else { throw FSError.outOfRoot }
        if forWrite { guard WorkspaceManager.textExtensions.contains(t.pathExtension.lowercased())
            || WorkspaceManager.textExtensions.contains(t.lastPathComponent) else { throw FSError.notText } }
        return target
    }

    /// 读单个文本文件(UTF-8,≤1MB)。
    static func read(at url: URL) throws -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw FSError.notFound }
        guard !isDir.boolValue else { throw FSError.isDirectory }
        guard let data = try? Data(contentsOf: url), data.count <= maxSize else { throw FSError.tooLarge }
        guard let s = String(data: data, encoding: .utf8) else { throw FSError.notReadable }
        return s
    }

    /// 读现状(给写工具做 diff 基线);不存在 / 读不了返回 nil。
    static func tryRead(at url: URL) -> String? {
        (try? read(at: url))
    }

    /// 列目录条目(name + 是否目录 + 文本文件大小)。
    static func list(at url: URL) throws -> [[String: Any]] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw FSError.notFound }
        guard isDir.boolValue else { throw FSError.isDirectory }
        let entries = (try? fm.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { e in
            let v = try? e.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return [
                "name": e.lastPathComponent,
                "type": (v?.isDirectory == true) ? "dir" : "file",
                "size": v?.fileSize ?? 0
            ] as [String: Any]
        }
    }

    /// 写盘(原子,父目录不存在先建)。调用方已做越权 / 后缀校验。
    static func write(at url: URL, content: String) throws {
        guard let data = content.data(using: .utf8), data.count <= maxSize else { throw FSError.tooLarge }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
