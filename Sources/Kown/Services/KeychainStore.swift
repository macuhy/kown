import Foundation

enum KeychainError: Error, LocalizedError {
    case missing
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .missing:             return "未配置 API Key，请在设置中填入"
        case .saveFailed(let msg): return "保存失败: \(msg)"
        }
    }
}

/// Stores API keys as JSON in [syncedDataDir]/apikeys.json (permissions 0600).
/// 同步开启时跟随其他配置一起进 iCloud 容器(对 Files app 隐藏);关闭时落本地。
@MainActor
enum KeychainStore {
    private static var storeURL: URL {
        Platform.syncedDataDir.appendingPathComponent("apikeys.json")
    }

    private static func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func saveAll(_ dict: [String: String]) throws {
        let data = try JSONEncoder().encode(dict)
        try data.write(to: storeURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600 as NSNumber], ofItemAtPath: storeURL.path
        )
    }

    static func save(id: UUID, apiKey: String) throws {
        var all = loadAll()
        all[id.uuidString] = apiKey
        do { try saveAll(all) } catch {
            throw KeychainError.saveFailed(error.localizedDescription)
        }
    }

    static func load(id: UUID) throws -> String {
        let all = loadAll()
        guard let key = all[id.uuidString], !key.isEmpty else {
            throw KeychainError.missing
        }
        return key
    }

    static func delete(id: UUID) {
        var all = loadAll()
        all.removeValue(forKey: id.uuidString)
        try? saveAll(all)
    }

    static func hasKey(id: UUID) -> Bool {
        (try? load(id: id)) != nil
    }
}
