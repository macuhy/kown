import Foundation

/// 配置备份文件结构(不包含会话)。
///
/// 设计:
/// - 单个 JSON 文件,扩展名 `.kownbackup`(也兼容 `.json`)
/// - API Key 可选,导出时由用户决定是否包含 — 包含时文件等同于明文凭据,UI 需提示用户保管
/// - 导入支持"覆盖"(替换全部)与"合并"(按 id 增量补充,不删除现有)
/// - 不导出会话(对话历史)— 会话量可能很大,且通常用户期望"配置可移植,对话私有"
struct KownBackup: Codable {
    /// 版本号 — 不向前兼容时递增。当前 = 1。
    let version: Int
    /// 导出时间(信息性)
    let exportedAt: Date
    /// 导出来源 app build(信息性,便于排查)
    let appVersion: String?
    /// Provider 配置列表
    let providers: [ProviderConfig]
    /// Web Search 全局配置
    let webSearchConfig: WebSearchConfig
    /// 每个 provider / Firecrawl 的 API Key — key 是 provider id 的 UUID 字符串。
    /// 包含时整个备份文件等同于明文 secrets,nil 表示未包含。
    let apiKeys: [String: String]?
    /// 本机偏好(systemPrompt / debate 轮数 / web search 开关)
    let preferences: Preferences

    struct Preferences: Codable {
        var systemPrompt: String?
        var debateRounds: Int?
        var webSearchEnabledForNextSend: Bool?
    }

    static let currentVersion = 1
    static let fileExtension = "kownbackup"
}

/// 导入策略。
enum BackupImportMode {
    /// 覆盖:用备份内容完全替换现有 providers / webSearchConfig / preferences。
    /// API Key:备份里有的就用,没的保留现有。
    case replace
    /// 合并:按 id 增量补充新 provider(已存在的保留现版本),不删除任何现有数据。
    case merge
}

// MARK: - 自动备份频率

/// 自动备份频率偏好。
enum BackupFrequency: String, CaseIterable, Identifiable {
    case off
    case daily
    case weekly

    var id: String { rawValue }

    /// 展示名(中文,贴合现有 UI 文案)。
    var displayName: String {
        switch self {
        case .off:    return "关闭"
        case .daily:  return "每日"
        case .weekly: return "每周"
        }
    }

    /// 两次自动备份之间的最小间隔。`.off` 返回 nil(从不触发)。
    var interval: TimeInterval? {
        switch self {
        case .off:    return nil
        case .daily:  return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        }
    }
}

/// 一个已落盘的自动备份文件描述(供 UI 列表展示)。
struct BackupSnapshot: Identifiable, Equatable {
    let url: URL
    let createdAt: Date
    let size: Int64

    var id: URL { url }
    /// 文件名(不含目录)。
    var name: String { url.lastPathComponent }
}

/// 配置备份读写。所有持久化操作通过 AppViewModel 调用此模块。
@MainActor
enum BackupStore {

    // MARK: - Encode / Decode

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 把当前内存里的配置打包成一份完整备份 Data,可写入用户选择的文件。
    /// `includeAPIKeys=true` 时包含明文 API Key — UI 需要提示用户敏感性。
    static func makeBackup(
        providers: [ProviderConfig],
        webSearchConfig: WebSearchConfig,
        includeAPIKeys: Bool,
        preferences: KownBackup.Preferences
    ) throws -> Data {
        var apiKeys: [String: String]? = nil
        if includeAPIKeys {
            var keys: [String: String] = [:]
            for cfg in providers where !cfg.kind.isCLI {
                if let k = try? KeychainStore.load(id: cfg.id), !k.isEmpty {
                    keys[cfg.id.uuidString] = k
                }
            }
            // Firecrawl 用固定 id
            if let firecrawlKey = try? WebSearchKey.load(), !firecrawlKey.isEmpty {
                keys[WebSearchKey.id.uuidString] = firecrawlKey
            }
            apiKeys = keys.isEmpty ? nil : keys
        }

        let backup = KownBackup(
            version: KownBackup.currentVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            providers: providers,
            webSearchConfig: webSearchConfig,
            apiKeys: apiKeys,
            preferences: preferences
        )
        return try encoder.encode(backup)
    }

    /// 解析备份文件。错误包括格式不识别、版本不支持等。
    static func parseBackup(_ data: Data) throws -> KownBackup {
        let backup = try decoder.decode(KownBackup.self, from: data)
        guard backup.version <= KownBackup.currentVersion else {
            throw BackupError.unsupportedVersion(backup.version)
        }
        return backup
    }

    /// 把备份应用到本地存储。AppViewModel 调用完成后需要重新 load 内存。
    /// 返回 (最终 provider 数, 导入的 API Key 数)。
    @discardableResult
    static func applyBackup(_ backup: KownBackup, mode: BackupImportMode) throws -> (providers: Int, importedKeys: Int) {
        // 1) Providers — 走 Store
        let finalProviders: [ProviderConfig]
        switch mode {
        case .replace:
            finalProviders = backup.providers
        case .merge:
            let existing = ProviderConfigStore.load()
            let existingIDs = Set(existing.map { $0.id })
            finalProviders = existing + backup.providers.filter { !existingIDs.contains($0.id) }
        }
        ProviderConfigStore.save(finalProviders)

        // 2) WebSearchConfig — 仅 replace 模式覆盖
        if mode == .replace {
            WebSearchConfigStore.save(backup.webSearchConfig)
        }

        // 3) API Key
        var importedKeys = 0
        if let keys = backup.apiKeys {
            for (idStr, key) in keys {
                guard let id = UUID(uuidString: idStr), !key.isEmpty else { continue }
                if (try? KeychainStore.save(id: id, apiKey: key)) != nil {
                    importedKeys += 1
                }
            }
        }

        // 4) Preferences — 仅 replace 模式覆盖
        if mode == .replace {
            let prefs = backup.preferences
            if let sp = prefs.systemPrompt {
                UserDefaults.standard.set(sp, forKey: "kown.systemPrompt.v1")
            }
            if let dr = prefs.debateRounds {
                UserDefaults.standard.set(max(1, min(4, dr)), forKey: "kown.debate.rounds.v1")
            }
            if let ws = prefs.webSearchEnabledForNextSend {
                UserDefaults.standard.set(ws, forKey: "kown.webSearch.toggle.v1")
            }
        }

        return (finalProviders.count, importedKeys)
    }

    // MARK: - 自动备份:偏好

    /// 偏好键 — 沿用现有 `kown.*.v1` 命名风格。
    private enum AutoKeys {
        static let frequency = "kown.backup.auto.frequency.v1"
        static let keepCount = "kown.backup.auto.keepCount.v1"
        static let lastDate  = "kown.backup.auto.lastDate.v1"
    }

    /// 默认保留份数。
    static let defaultKeepCount = 10

    /// 自动备份频率(持久化)。
    static var autoBackupFrequency: BackupFrequency {
        get {
            UserDefaults.standard.string(forKey: AutoKeys.frequency)
                .flatMap(BackupFrequency.init(rawValue:)) ?? .off
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: AutoKeys.frequency) }
    }

    /// 保留的最近备份份数,超出后自动清理最旧的(持久化)。
    static var autoBackupKeepCount: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: AutoKeys.keepCount)
            return v > 0 ? v : defaultKeepCount
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: AutoKeys.keepCount) }
    }

    /// 最近一次成功自动/手动备份的时间(持久化),用于展示与"是否到期"判断。
    static var lastAutoBackupDate: Date? {
        get { UserDefaults.standard.object(forKey: AutoKeys.lastDate) as? Date }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: AutoKeys.lastDate)
            } else {
                UserDefaults.standard.removeObject(forKey: AutoKeys.lastDate)
            }
        }
    }

    // MARK: - 自动备份:目录 / 文件

    /// 自动备份目录:同步数据目录下的 `backups/`
    /// (默认本地 `~/.kown/backups`,iCloud 同步开启时位于 iCloud 容器内)。
    private static var backupsDir: URL {
        let url = Platform.syncedDataDir.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700 as NSNumber]
        )
        return url
    }

    /// 文件名安全的时间戳:`yyyyMMdd-HHmmss`(与现有导出文件命名风格一致)。
    private static func timestamp(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    // MARK: - 自动备份:写入 / 调度 / 轮转

    /// 立即把一份备份 Data 写入 `backups/`(带时间戳文件名),更新最近备份时间并轮转清理。
    ///
    /// `data` 由调用方用现有导出能力生成(`makeBackup` / `AppViewModel.exportBackup`),
    /// 本方法只负责落盘 + 轮转,不触碰会话与同步逻辑。
    @discardableResult
    static func writeSnapshot(_ data: Data) throws -> BackupSnapshot {
        let now = Date()
        let name = "kown-backup-\(timestamp(for: now)).\(KownBackup.fileExtension)"
        let url = backupsDir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)

        lastAutoBackupDate = now
        pruneOldSnapshots()

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? data.count
        return BackupSnapshot(url: url, createdAt: now, size: Int64(size))
    }

    /// 若已开启自动备份且距上次备份已超过频率间隔,则生成并写入一次备份。
    ///
    /// 由调用方在合适的生命周期点触发(App 启动 / 进入后台 / 打开备份设置)。
    /// `makeData` 用现有导出能力按需生成备份 Data;频率为 `.off` 时不调用它。
    static func runScheduledBackupIfNeeded(makeData: () throws -> Data) {
        guard let interval = autoBackupFrequency.interval else { return }

        if let last = lastAutoBackupDate, Date().timeIntervalSince(last) < interval {
            return
        }

        guard let data = try? makeData() else { return }
        try? writeSnapshot(data)
    }

    /// 列出 `backups/` 目录下的全部快照(最新在前)。
    static func listSnapshots() -> [BackupSnapshot] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: backupsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == KownBackup.fileExtension || $0.pathExtension == "json" }
            .compactMap { url -> BackupSnapshot? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let date = values?.contentModificationDate ?? .distantPast
                let size = Int64(values?.fileSize ?? 0)
                return BackupSnapshot(url: url, createdAt: date, size: size)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 删除指定快照。
    static func deleteSnapshot(_ snapshot: BackupSnapshot) {
        try? FileManager.default.removeItem(at: snapshot.url)
    }

    /// 保留最近 `autoBackupKeepCount` 份,删除多余的旧快照。
    private static func pruneOldSnapshots() {
        let keep = autoBackupKeepCount
        let all = listSnapshots()
        guard keep > 0, all.count > keep else { return }
        for snapshot in all[keep...] {
            try? FileManager.default.removeItem(at: snapshot.url)
        }
    }
}

enum BackupError: Error, LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "备份文件版本 \(v) 不被当前 app 支持,请升级 app 后重试。"
        }
    }
}
