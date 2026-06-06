import Foundation

/// 一个会话一个 JSON 文件，放在 [syncedDataDir]/conversations/<id>.json
/// (默认本地 `~/.kown`,iCloud 同步开启时位于 iCloud Documents 容器内)。
@MainActor
enum ConversationStore {
    /// 启动时加载到内存的最大条数 — 防止重度用户累积上千条把内存挤爆。
    /// 文件全部保留在磁盘,旧的需要时可显式 `loadOne` 拉回。nonisolated:供后台 loadAll 读取。
    nonisolated static let maxLoadedOnStartup = 100

    private static var dir: URL {
        let url = Platform.syncedDataDir.appendingPathComponent("conversations", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700 as NSNumber]
        )
        return url
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// loadAll 的后台版:主线程先解析 dir(Platform.syncedDataDir 是 @MainActor),再把扫描+解码挪后台。
    /// 冷启动时 init 用它,避免一启动就在主线程 O(N) 解码上百个 JSON(撑出 0.5–1.5s 白屏)。
    static func loadAllAsync() async -> [Conversation] {
        let dirURL = dir
        return await Task.detached(priority: .userInitiated) { loadAll(from: dirURL) }.value
    }

    /// 启动时只加载最近 `maxLoadedOnStartup` 条(按文件 mtime 倒序),其他留在磁盘。
    /// 避免一启动就 O(N) 解码所有 JSON、内存膨胀。
    static func loadAll() -> [Conversation] {
        loadAll(from: dir)
    }

    /// 纯函数实现:给定 conversations 目录,扫描 + 解码 + 去重。
    /// nonisolated:无主线程状态依赖,可在后台线程跑(用局部 decoder,因为共享的 static decoder
    /// 是 @MainActor 隔离的、非 Sendable)。dir 由调用方在主线程解析后传入。
    nonisolated static func loadAll(from dir: URL) -> [Conversation] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }
        let jsonURLs = urls.filter { $0.pathExtension == "json" }
        // 按 mtime 排序 — 比按 updatedAt 排再切快得多(不用先全部 decode)
        let recentURLs = jsonURLs
            .map { url -> (URL, Date) in
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                    .flatMap { $0.contentModificationDate } ?? .distantPast
                return (url, mtime)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(maxLoadedOnStartup)
            .map { $0.0 }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var convs: [Conversation] = []
        for url in recentURLs {
            guard let data = try? Data(contentsOf: url),
                  let conv = try? decoder.decode(Conversation.self, from: data) else { continue }
            convs.append(conv)
        }
        return dedupeByID(convs)
    }

    /// 按 id 去重,保留 `updatedAt` 最新的一份,并按 `updatedAt` 倒序返回。
    ///
    /// iCloud 冲突会生成「`<id> 2.json`」这类副本,同一个 id 会被读到多份。若不去重,
    /// `SidebarView` 的 `ForEach` 拿到重复 Identifiable id,SwiftUI 布局会错乱(行错位 / 大片空白)。
    /// 抽成纯静态函数给单测覆盖。
    nonisolated static func dedupeByID(_ convs: [Conversation]) -> [Conversation] {
        var byID: [UUID: Conversation] = [:]
        for conv in convs {
            if let existing = byID[conv.id], existing.updatedAt >= conv.updatedAt { continue }
            byID[conv.id] = conv
        }
        return byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 按 id 单独加载一条 — 给以后"加载更多"按钮用。
    static func loadOne(id: UUID) -> Conversation? {
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Conversation.self, from: data)
    }

    /// 同一 conversation 的合并写盘缓冲(MainActor 隔离,无需锁)。
    /// Council 一轮里 N 家 provider 各完成一次会触发 N 次 save,
    /// 长会话 80K+ JSON 反复 encode+write 是个真实痛点;
    /// 300ms 内的多次 save 合并成 1 次,落盘前总取最新版本。
    private static var pendingSaves: [UUID: Conversation] = [:]
    private static var pendingFlushTasks: [UUID: Task<Void, Never>] = [:]
    private static let saveDebounceNanos: UInt64 = 300_000_000

    /// 异步 / 节流写盘(普通调用走这里)。同步立即写请用 `saveImmediately(_:)`。
    static func save(_ conv: Conversation) {
        pendingSaves[conv.id] = conv  // 总取最新版本
        if pendingFlushTasks[conv.id] != nil { return } // 已有 pending task
        let id = conv.id
        pendingFlushTasks[id] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: saveDebounceNanos)
            flushPending(id: id)
        }
    }

    /// 立即同步写盘(app 退出 / 关闭会话等关键时刻调用,确保数据落地)。
    static func saveImmediately(_ conv: Conversation) {
        pendingSaves.removeValue(forKey: conv.id)
        pendingFlushTasks.removeValue(forKey: conv.id)?.cancel()
        writeToDisk(conv)
    }

    /// 把指定会话的 pending 内容真正写盘
    private static func flushPending(id: UUID) {
        pendingFlushTasks.removeValue(forKey: id)
        guard let conv = pendingSaves.removeValue(forKey: id) else { return }
        writeToDisk(conv)
    }

    /// 强制把所有 pending 立刻刷盘(app willTerminate / iCloud 切换前)
    static func flushAll() {
        let ids = Array(pendingFlushTasks.keys)
        for id in ids {
            pendingFlushTasks.removeValue(forKey: id)?.cancel()
            if let conv = pendingSaves.removeValue(forKey: id) {
                writeToDisk(conv)
            }
        }
    }

    private static func writeToDisk(_ conv: Conversation) {
        let url = dir.appendingPathComponent("\(conv.id.uuidString).json")
        guard let data = try? encoder.encode(conv) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func delete(_ id: UUID) {
        // 删除前先取消 pending 写入(否则等下 flush 会重建文件)
        pendingFlushTasks.removeValue(forKey: id)?.cancel()
        pendingSaves.removeValue(forKey: id)
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }
}
