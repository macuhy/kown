import Foundation

/// 会话 "Working Folder" 管理:bookmark / 文件树扫描 / 上下文打包 / 写代码块解析 / 自动写盘。
///
/// 设计要点:
/// - **写入边界严控**:`apply` 时 normalize 路径,再校验 `target.resolvingSymlinksInPath().path.hasPrefix(root.path)`,
///   防 `../` 越权写到 workspace 之外。
/// - **后缀白名单**:只读写已知的文本格式(参见 `textExtensions`),避免误读/误写二进制。
/// - **size budget**:整个上下文打包不超过 ~80KB(可调),否则 prompt 容易超 model 上下文。
/// - **kown:write 代码块语法**:
///   ```kown:write 相对路径
///   ...文件全文...
///   ```
///   每个块独立解析。一次响应里可以有多个块,顺序应用。
@MainActor
enum WorkspaceManager {
    // MARK: - 配置

    /// 允许读 / 写的文件后缀(纯文本)
    static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "rst",
        "swift", "py", "js", "ts", "tsx", "jsx", "mjs", "cjs",
        "json", "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss",
        "go", "rs", "java", "kt", "c", "cc", "cpp", "h", "hpp", "m", "mm",
        "sh", "bash", "zsh", "fish", "ps1",
        "rb", "php", "sql", "lua", "pl", "r",
        "vue", "svelte",
        "gitignore", "env", "conf", "cfg", "ini",
        "Dockerfile", "Makefile"
    ]

    /// 总上下文体积上限 — 一次 send 注入到 prompt 的所有文件内容加和
    static let contextSizeBudget = 80 * 1024  // 80KB

    /// 单文件读写大小上限
    static let perFileMaxSize = 1024 * 1024  // 1MB

    // MARK: - Bookmark

    /// 从 NSOpenPanel 拿到 URL 后,创建 security-scoped bookmark 持久化到 Conversation
    static func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        // iOS 用 minimalBookmark,不支持 security scope
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// 解析 bookmark 回 URL。`isStale=true` 时建议提示用户重新选择文件夹。
    /// 调用方拿到 URL 后必须 `startAccessingSecurityScopedResource()`,用完 stop。
    static func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        #if os(macOS)
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #else
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #endif
        return (url, isStale)
    }

    // MARK: - 上下文打包

    /// 把 workspace 内的所有文本文件扫一遍,返回一个能直接塞 system prompt 的 XML-ish 块。
    /// 路径相对 workspace 根。超过 `contextSizeBudget` 时按文件 byte size 升序排,先小后大。
    /// 当前实现:即便 budget 用完,文件树仍然完整列出(只是不带内容)。
    static func buildContext(workspaceURL: URL) -> String? {
        let fm = FileManager.default
        let scoped = workspaceURL.startAccessingSecurityScopedResource()
        defer { if scoped { workspaceURL.stopAccessingSecurityScopedResource() } }

        guard let enumerator = fm.enumerator(
            at: workspaceURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        struct Entry {
            let url: URL
            let relativePath: String
            let size: Int
        }

        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            let size = v?.fileSize ?? 0
            // 显式跳过 .DS_Store / node_modules / .git 等噪音
            let lastComp = url.lastPathComponent
            if lastComp == ".DS_Store" || lastComp.hasPrefix(".git") { continue }
            // 跳过 node_modules / build / .build 等大目录(看路径里有没有)
            let pathStr = url.path
            if pathStr.contains("/node_modules/") || pathStr.contains("/.build/") ||
               pathStr.contains("/build/") || pathStr.contains("/dist/") ||
               pathStr.contains("/.next/") || pathStr.contains("/__pycache__/") {
                continue
            }
            guard isTextExtensionAllowed(url) else { continue }
            guard size <= perFileMaxSize else { continue }
            let rel = relativePath(of: url, from: workspaceURL)
            entries.append(Entry(url: url, relativePath: rel, size: size))
        }

        // 按 size 升序,优先把小文件全塞进去
        entries.sort { $0.size < $1.size }

        var treeLines: [String] = []
        var fileBlocks: [String] = []
        var used = 0
        for e in entries {
            treeLines.append("- \(e.relativePath)  (\(formatBytes(e.size)))")
            if used + e.size <= contextSizeBudget {
                if let data = try? Data(contentsOf: e.url),
                   let text = String(data: data, encoding: .utf8) {
                    fileBlocks.append("""
                    ━━━━━━━━ \(e.relativePath) ━━━━━━━━
                    \(text)
                    """)
                    used += e.size
                }
            }
        }

        var out: [String] = []
        out.append("<workspace path=\"\(workspaceURL.path)\">")
        out.append("<tree>")
        out.append(contentsOf: treeLines)
        out.append("</tree>")
        if !fileBlocks.isEmpty {
            out.append("<files>")
            out.append(contentsOf: fileBlocks)
            out.append("</files>")
        }
        out.append("""
        <write_instructions>
        **重要**:如果用户要求你修改 / 创建 / 编辑 / 重写文件,你 **必须** 输出特定格式的代码块,
        否则改动不会落盘!不要只在聊天里给"建议",真要改文件就用这个格式:

        ```kown:write <相对路径>
        <整个文件的新内容(完整全文,不是 diff)>
        ```

        规则:
        - **第一行必须是** ``` ```kown:write 后面跟一个空格再跟相对路径 ```
        - 路径相对 workspace 根,不能有前导 `/`,不能用 `..` 越界
        - 块里写的是 **整个文件的完整新内容**,不是 diff、不是片段
        - 多个文件 = 多个块
        - 系统会自动落盘,你不需要做任何额外操作

        ✅ 正确示例(创建文件):
        ```kown:write README.md
        # My Project

        This is the new readme.
        ```

        ✅ 正确示例(修改已有 swift 文件):
        ```kown:write src/main.swift
        import Foundation

        @main
        struct App {
            static func main() {
                print("hello")
            }
        }
        ```

        ❌ 错误示例(普通代码块,不会被系统识别):
        ```swift
        // 这只是普通代码块,不会写入文件
        print("hello")
        ```

        ❌ 错误示例(diff 格式,系统不支持):
        ```kown:write src/main.swift
        - print("old")
        + print("new")
        ```

        如果用户只是问问题不要求改文件,正常对话回复即可,不要输出 kown:write 块。
        </write_instructions>
        """)
        out.append("</workspace>")
        return out.joined(separator: "\n")
    }

    // MARK: - kown:write 块解析

    /// 从 model response 文本里抽出所有 ```kown:write <path>``` 代码块。
    /// 容忍变种:
    ///   ```kown:write path/to/file.md          (标准)
    ///   ```kown:write "path with space.md"     (引号包路径)
    ///   ```kown:write src/main.swift swift     (path 后面跟语言提示)
    ///   ```KOWN:WRITE README.md                (大小写不敏感)
    ///   ```kown-write path/to/file             (`-` 代替 `:`)
    ///   ``` 闭围栏后允许尾随空白
    static func parseProposedWrites(_ text: String) -> [PendingWrite] {
        // (?i) 大小写不敏感; kown[:_-]?write 容忍 : 或 - 或 _ 或省略;
        // 路径用 ([^\s"'`\n]+) 抓"非空白非引号"序列,允许 . / - _ ;
        // 同一行 path 后面允许任何字符直到换行 (e.g. 语言名);
        // 内容非贪婪;闭围栏后允许尾随空白
        let pattern = #"(?i)`{3,}\s*kown[:_-]?write[ \t]+"?([^\s"'`\n]+)"?[^\n]*\n([\s\S]*?)\n`{3,}[ \t]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, options: [], range: range)
        var out: [PendingWrite] = []
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let path = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'/"))
            guard !path.isEmpty else { continue }
            let content = ns.substring(with: m.range(at: 2))
            out.append(PendingWrite(relativePath: path, content: content))
        }
        return out
    }

    // MARK: - 应用写入

    /// 把 model 提议的 write 直接写到 workspace。路径必须在 workspace 内,后缀必须允许写。
    /// 返回 AppliedWrite 记录(无论成功失败都返回一条)。
    static func apply(_ write: PendingWrite, workspaceURL: URL) -> AppliedWrite {
        let scoped = workspaceURL.startAccessingSecurityScopedResource()
        defer { if scoped { workspaceURL.stopAccessingSecurityScopedResource() } }

        // 1) 路径规范化 + 越界校验
        let cleanRel = write.relativePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
        guard !cleanRel.isEmpty, !cleanRel.contains("..") else {
            return AppliedWrite(
                relativePath: write.relativePath,
                action: .skipped, success: false,
                error: "路径包含 .. 或为空,拒绝",
                newContent: write.content
            )
        }

        let target = workspaceURL.appendingPathComponent(cleanRel)
        // 解析绝对路径,确保还在 workspace 内
        let workspaceRoot = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedTarget = target.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedTarget.path.hasPrefix(workspaceRoot.path + "/") ||
              resolvedTarget.path == workspaceRoot.path else {
            return AppliedWrite(
                relativePath: cleanRel,
                action: .skipped, success: false,
                error: "路径越出 workspace 根,拒绝",
                newContent: write.content
            )
        }

        // 2) 后缀白名单
        guard isTextExtensionAllowed(resolvedTarget) else {
            return AppliedWrite(
                relativePath: cleanRel,
                action: .skipped, success: false,
                error: "文件后缀不在文本白名单内,拒绝写入",
                newContent: write.content
            )
        }

        // 3) 内容大小校验
        guard let data = write.content.data(using: .utf8), data.count <= perFileMaxSize else {
            return AppliedWrite(
                relativePath: cleanRel,
                action: .skipped, success: false,
                error: "新内容超过 \(perFileMaxSize / 1024) KB 单文件上限",
                newContent: write.content
            )
        }

        // 4) 读旧内容(用于 update 标识 + diff)
        let fm = FileManager.default
        let preexists = fm.fileExists(atPath: resolvedTarget.path)
        var oldContent: String? = nil
        if preexists,
           let oldData = try? Data(contentsOf: resolvedTarget),
           let s = String(data: oldData, encoding: .utf8) {
            oldContent = s.count > 200_000 ? String(s.prefix(200_000)) : s
        }

        // 5) 真正写入(原子写,父目录不存在先建)
        do {
            try fm.createDirectory(
                at: resolvedTarget.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: resolvedTarget, options: .atomic)
            return AppliedWrite(
                relativePath: cleanRel,
                action: preexists ? .update : .create,
                success: true,
                oldContent: oldContent,
                newContent: write.content
            )
        } catch {
            return AppliedWrite(
                relativePath: cleanRel,
                action: preexists ? .update : .create,
                success: false,
                error: error.localizedDescription,
                oldContent: oldContent,
                newContent: write.content
            )
        }
    }

    // MARK: - 撤销

    /// 撤销一次已应用的写入:
    /// - `.create` → 删除新建的文件;
    /// - `.update` → 把 `oldContent` 写回(注:>200KB 的旧文件 oldContent 是截断的,还原会丢尾部,UI 已提示);
    /// - `.skipped` / 失败的写入 → 无可撤销。
    /// 返回 (是否成功, 错误信息)。
    static func revert(_ write: AppliedWrite, workspaceURL: URL) -> (success: Bool, error: String?) {
        guard write.success, write.action != .skipped else {
            return (false, "该改动未落盘,无需撤销")
        }
        let scoped = workspaceURL.startAccessingSecurityScopedResource()
        defer { if scoped { workspaceURL.stopAccessingSecurityScopedResource() } }

        let cleanRel = write.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
        guard !cleanRel.isEmpty, !cleanRel.contains("..") else {
            return (false, "路径非法,拒绝撤销")
        }
        let target = workspaceURL.appendingPathComponent(cleanRel)
        let root = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = target.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") || resolved.path == root.path else {
            return (false, "路径越出 workspace 根,拒绝撤销")
        }

        let fm = FileManager.default
        do {
            switch write.action {
            case .create:
                if fm.fileExists(atPath: resolved.path) {
                    try fm.removeItem(at: resolved)
                }
                return (true, nil)
            case .update:
                guard let old = write.oldContent, let data = old.data(using: .utf8) else {
                    return (false, "没有可还原的旧内容")
                }
                try data.write(to: resolved, options: .atomic)
                return (true, nil)
            case .skipped:
                return (false, "跳过的改动无需撤销")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - 内部

    private static func isTextExtensionAllowed(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) { return true }
        // 文件名本身就是 Dockerfile / Makefile 这类无扩展名的也允许
        let base = url.lastPathComponent
        return textExtensions.contains(base)
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        if urlPath.hasPrefix(rootPath + "/") {
            return String(urlPath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    private static func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return String(format: "%.1fKB", Double(n) / 1024.0) }
        return String(format: "%.1fMB", Double(n) / 1024.0 / 1024.0)
    }
}

/// model 提议待写的文件(还没落盘)。
struct PendingWrite: Sendable {
    let relativePath: String
    let content: String
}
