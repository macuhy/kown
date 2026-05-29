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
