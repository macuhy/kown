import Foundation

/// Writes each provider response to a separate Markdown file under ~/.kown/logs/
enum ResponseLogger {

    /// 串行队列 — Council 模式一轮会触发 4~6 个 write,以前用 `Task.detached` 全并发抢盘 I/O,
    /// 慢盘(网络盘 / 加密卷)上叠加多次容易拖慢主线程。改成单串行队列,顺序写入,QoS=utility 不抢前台。
    private static let writeQueue = DispatchQueue(label: "app.kown.response-logger", qos: .utility)

    /// 启动时清一次旧日志(保留最近 14 天的 .md 文件)。
    /// 不删空目录(会话还活着的话,目录下次会被重新填),不删非 .md 文件。
    /// 14 天足够回看上下文,又不会让 ~/.kown/logs 无限膨胀。
    static let retentionDays: Int = 14
    // didRotate 只在 writeQueue 这一个串行队列上读写,无并发竞争 — `nonisolated(unsafe)`
    // 是 Swift 6 严格并发下表达"我自己保证序"的标准做法,比加 lock 简单。
    nonisolated(unsafe) private static var didRotate = false

    /// 启动时调用一次。重复调用 no-op。
    /// 在后台 queue 跑,不阻塞 UI;真要清干净也就毫秒级。
    static func rotateOldLogsIfNeeded() {
        writeQueue.async {
            guard !didRotate else { return }
            didRotate = true
            rotateOldLogs()
        }
    }

    private static func rotateOldLogs() {
        let fm = FileManager.default
        let root = logsDirectory
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var removed = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true,
                  let mtime = vals?.contentModificationDate,
                  mtime < cutoff else { continue }
            if (try? fm.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            NSLog("Kown: rotated %d old log file(s) older than %d days", removed, retentionDays)
        }
    }

    /// 异步落盘 — 调用方 fire-and-forget,不要等。
    /// 替换之前各处的 `Task.detached { ResponseLogger.write(entry) }`。
    static func writeAsync(_ entry: Entry) {
        writeQueue.async { write(entry) }
    }

    static var logsDirectory: URL {
        let url = Platform.appDataDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Entry: Sendable {
        let roundID: String           // Shared by all providers in one "send"
        let timestamp: Date
        let providerName: String
        let providerKind: String
        let baseURL: String
        let model: String
        let prompt: String
        let systemPrompt: String
        let response: String
        let elapsedSeconds: Double?
        let error: String?
        /// 会话名（用作子目录）；空则落到 logsDirectory 根
        let conversationTitle: String
        /// 会话 ID（用作子目录后缀，避免重名碰撞）
        let conversationID: String
    }

    /// 给定会话名，返回该会话的日志子目录（必要时创建）
    static func directory(for conversationTitle: String, conversationID: String) -> URL {
        let folder = folderName(title: conversationTitle, id: conversationID)
        let url = logsDirectory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 会话重命名时把对应的日志目录改名（如果已存在）
    static func renameDirectory(oldTitle: String, newTitle: String, conversationID: String) {
        let oldFolder = folderName(title: oldTitle, id: conversationID)
        let newFolder = folderName(title: newTitle, id: conversationID)
        guard oldFolder != newFolder else { return }
        let oldURL = logsDirectory.appendingPathComponent(oldFolder, isDirectory: true)
        let newURL = logsDirectory.appendingPathComponent(newFolder, isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldURL.path) else { return }
        try? fm.moveItem(at: oldURL, to: newURL)
    }

    /// 删除会话时清理对应的日志目录
    static func deleteDirectory(title: String, conversationID: String) {
        let folder = folderName(title: title, id: conversationID)
        let url = logsDirectory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    private static func folderName(title: String, id: String) -> String {
        let slug = slugify(title, max: 40)
        let safeSlug = slug.isEmpty ? "untitled" : slug
        let idPrefix = String(id.prefix(8))
        return "\(safeSlug)_\(idPrefix)"
    }

    static func write(_ entry: Entry) {
        let dir = directory(for: entry.conversationTitle, conversationID: entry.conversationID)
        let url = dir.appendingPathComponent(filename(for: entry))
        let content = render(entry)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Internals

    private static func filename(for e: Entry) -> String {
        let ts = filenameTimestamp(e.timestamp)
        let slug = slugify(e.providerName)
        return "\(ts)_\(slug)_\(e.roundID).md"
    }

    private static func render(_ e: Entry) -> String {
        let elapsed = e.elapsedSeconds.map { String(format: "%.2fs", $0) } ?? "—"
        let status  = e.error == nil ? "✅ 完成" : "❌ 失败"
        var out = """
        # \(e.providerName) — \(e.model)

        - **时间**: \(humanTimestamp(e.timestamp))
        - **耗时**: \(elapsed)
        - **状态**: \(status)
        - **类型**: \(e.providerKind)
        - **端点**: `\(e.baseURL)`
        - **Round**: `\(e.roundID)`
        """

        let trimmedSys = e.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSys.isEmpty {
            out += "\n\n## System Prompt\n\n```\n\(trimmedSys)\n```"
        }

        out += "\n\n## Prompt\n\n\(e.prompt)"

        if let err = e.error {
            out += "\n\n## 错误\n\n```\n\(err)\n```"
        } else {
            out += "\n\n## Response\n\n\(e.response)"
        }

        return out + "\n"
    }

    private static func filenameTimestamp(_ d: Date) -> String {
        let c = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: d
        )
        let ms = (c.nanosecond ?? 0) / 1_000_000
        return String(
            format: "%04d-%02d-%02d_%02d%02d%02d.%03d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms
        )
    }

    private static func humanTimestamp(_ d: Date) -> String {
        let c = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: d
        )
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    private static func slugify(_ name: String, max: Int = .max) -> String {
        // 保留字母数字 + 常见东亚可见字符；其余替换成 -
        var out = ""
        for scalar in name.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(Character(scalar))
            } else if isEastAsian(scalar) {
                out.append(Character(scalar))
            } else if scalar == "-" || scalar == "_" {
                out.append(Character(scalar))
            } else {
                if !out.hasSuffix("-") && !out.isEmpty { out.append("-") }
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > max {
            out = String(out.prefix(max))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out
    }

    /// 中日韩可见字符块（包含 CJK Ext A、Hiragana、Katakana、Hangul 等）
    private static func isEastAsian(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x3040...0x309F).contains(v) ||  // Hiragana
               (0x30A0...0x30FF).contains(v) ||  // Katakana
               (0x3400...0x4DBF).contains(v) ||  // CJK Ext A
               (0x4E00...0x9FFF).contains(v) ||  // CJK Unified
               (0xAC00...0xD7AF).contains(v) ||  // Hangul Syllables
               (0xF900...0xFAFF).contains(v) ||  // CJK Compatibility Ideographs
               (0x20000...0x2A6DF).contains(v)   // CJK Ext B
    }
}
