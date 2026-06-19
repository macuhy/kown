import Foundation

#if canImport(Security)
import Security
#endif

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

@MainActor
protocol SecretStoreBackend {
    var cacheKey: String { get }
    func loadAll() throws -> [String: String]
    func saveAll(_ keys: [String: String]) throws
}

struct SecretStoreMigrationResult: Equatable {
    let copiedKeyCount: Int
    let verifiedKeyCount: Int
    let activatedTarget: Bool
}

struct SecretStoreMigrationVerificationError: Error, LocalizedError, Equatable {
    let missingKeys: [String]
    let mismatchedKeys: [String]
    let unexpectedKeys: [String]

    var errorDescription: String? {
        var parts: [String] = []
        if !missingKeys.isEmpty {
            let keys = missingKeys.joined(separator: ",")
            parts.append("missing: \(keys)")
        }
        if !mismatchedKeys.isEmpty {
            let keys = mismatchedKeys.joined(separator: ",")
            parts.append("mismatched: \(keys)")
        }
        if !unexpectedKeys.isEmpty {
            let keys = unexpectedKeys.joined(separator: ",")
            parts.append("unexpected: \(keys)")
        }
        let details = parts.joined(separator: "; ")
        return "Secret store migration verification failed (\(details))"
    }
}

enum SecretStoreBackendKind: String, CaseIterable, Identifiable {
    case localJSON
    case securityKeychain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localJSON:
            return "本机 JSON secret store"
        case .securityKeychain:
            return "系统 Keychain"
        }
    }

    var shortLabel: String {
        switch self {
        case .localJSON:
            return "JSON"
        case .securityKeychain:
            return "Keychain"
        }
    }

    var detail: String {
        switch self {
        case .localJSON:
            return "默认存放在 localDataDir/apikeys.json,权限 0600,不随 iCloud 同步。"
        case .securityKeychain:
            return "存放到 Apple Security Keychain,kSecAttrSynchronizable=false,不随 iCloud Keychain 同步。"
        }
    }

    var isAvailableOnThisPlatform: Bool {
        switch self {
        case .localJSON:
            return true
        case .securityKeychain:
            #if canImport(Security)
            return true
            #else
            return false
            #endif
        }
    }
}

@MainActor
struct JSONSecretStoreBackend: SecretStoreBackend {
    private let fileURLProvider: @MainActor () -> URL

    init(fileURLProvider: @escaping @MainActor () -> URL) {
        self.fileURLProvider = fileURLProvider
    }

    var cacheKey: String {
        fileURLProvider().standardizedFileURL.path
    }

    func loadAll() throws -> [String: String] {
        Self.readKeys(from: fileURLProvider())
    }

    func saveAll(_ keys: [String: String]) throws {
        try Self.writeKeys(keys, to: fileURLProvider())
    }

    static func readKeys(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    static func writeKeys(_ keys: [String: String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700 as NSNumber]
        )
        let data = try JSONEncoder().encode(keys)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600 as NSNumber], ofItemAtPath: url.path
        )
    }
}

#if canImport(Security)
@MainActor
struct SecurityKeychainBackend: SecretStoreBackend {
    let service: String
    let accessGroup: String?
    private let marker = Data("com.xiaobo.kown.apikey.v1".utf8)

    init(service: String = "com.xiaobo.kown.apikey.v1", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    var cacheKey: String {
        "security:\(service):\(accessGroup ?? "-"):sync=false"
    }

    func loadAll() throws -> [String: String] {
        var keys: [String: String] = [:]
        for account in try existingAccounts() {
            guard let value = try readValue(account: account) else { continue }
            keys[account] = value
        }
        return keys
    }

    func saveAll(_ keys: [String: String]) throws {
        try validateAccounts(keys.keys)
        let desiredAccounts = Set(keys.keys)
        for (account, value) in keys {
            try upsert(account: account, value: value)
        }
        for account in try existingAccounts().subtracting(desiredAccounts) {
            try delete(account: account)
        }
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrGeneric as String: marker,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func existingAccounts() throws -> Set<String> {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw securityError(status, operation: "列出 Keychain")
        }

        let items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let item = result as? [String: Any] {
            items = [item]
        } else {
            items = []
        }
        return Set(items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  UUID(uuidString: account) != nil else { return nil }
            return account
        })
    }

    private func upsert(account: String, value: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw securityError(updateStatus, operation: "更新 Keychain")
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
            if retryStatus == errSecSuccess { return }
            throw securityError(retryStatus, operation: "更新重复 Keychain 项")
        }
        throw securityError(addStatus, operation: "保存 Keychain")
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw securityError(status, operation: "删除 Keychain")
        }
    }

    private func readValue(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw securityError(status, operation: "读取 Keychain")
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func validateAccounts(_ accounts: Dictionary<String, String>.Keys) throws {
        let invalidAccounts = accounts
            .filter { UUID(uuidString: $0) == nil }
            .sorted()
        guard invalidAccounts.isEmpty else {
            let invalid = invalidAccounts.joined(separator: ",")
            throw KeychainError.saveFailed(
                "Keychain account id must be a UUID: \(invalid)"
            )
        }
    }

    private func securityError(_ status: OSStatus, operation: String) -> KeychainError {
        let detail = SecCopyErrorMessageString(status, nil) as String?
        let message = detail ?? "OSStatus \(status)"
        return .saveFailed("\(operation)失败: \(message)")
    }
}
#endif

/// Secret-store facade for API keys and other tokens.
/// Current default backend is local-only JSON under `Platform.localDataDir`
/// (`apikeys.json`, permissions 0600), so keys do not follow iCloud Drive.
/// Security/Keychain Services backend is optional and not the default.
/// 若旧版本曾把 `apikeys.json` 放进同步目录,首次读取时会导入本地并尽力移除旧副本。
@MainActor
enum KeychainStore {
    static let backendPreferenceKey = "kown.secretStore.backend.v1"

    private static var activeBackendKind = preferredBackendKind()
    private static var backend: any SecretStoreBackend = makeBackend(for: activeBackendKind)
    private static var legacyStoreURLProvider: @MainActor () -> URL? = defaultLegacySyncedStoreURL
    private static var cachedBackendKey: String?
    private static var cachedKeys: [String: String]?

    static var currentBackendKind: SecretStoreBackendKind { activeBackendKind }
    static var currentBackendDescription: String { activeBackendKind.displayName }

    static var supportsSecurityKeychain: Bool {
        SecretStoreBackendKind.securityKeychain.isAvailableOnThisPlatform
    }

    static var localJSONStoreURL: URL {
        Platform.localDataDir.appendingPathComponent("apikeys.json")
    }

    private static func preferredBackendKind() -> SecretStoreBackendKind {
        guard let rawValue = UserDefaults.standard.string(forKey: backendPreferenceKey),
              let kind = SecretStoreBackendKind(rawValue: rawValue),
              kind.isAvailableOnThisPlatform else {
            return .localJSON
        }
        return kind
    }

    private static func makeLocalJSONBackend() -> any SecretStoreBackend {
        JSONSecretStoreBackend(fileURLProvider: { localJSONStoreURL })
    }

    private static func makeBackend(for kind: SecretStoreBackendKind) -> any SecretStoreBackend {
        switch kind {
        case .localJSON:
            return makeLocalJSONBackend()
        case .securityKeychain:
            #if canImport(Security)
            return SecurityKeychainBackend()
            #else
            return makeLocalJSONBackend()
            #endif
        }
    }

    private static func rememberBackendKind(_ kind: SecretStoreBackendKind) {
        activeBackendKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: backendPreferenceKey)
    }

    static func configureBackendFromPreferences() {
        let kind = preferredBackendKind()
        backend = makeBackend(for: kind)
        activeBackendKind = kind
        cachedBackendKey = nil
        cachedKeys = nil
    }

    private static func defaultLegacySyncedStoreURL() -> URL? {
        let syncedURL = Platform.syncedDataDir.appendingPathComponent("apikeys.json")
        let localURL = localJSONStoreURL
        guard syncedURL.standardizedFileURL.path != localURL.standardizedFileURL.path else {
            return nil
        }
        return syncedURL
    }

    private static func loadAll() throws -> [String: String] {
        let key = backend.cacheKey
        if cachedBackendKey == key, let cachedKeys { return cachedKeys }

        var keys = try backend.loadAll()
        if let legacyURL = legacyStoreURLProvider() {
            let legacyKeys = JSONSecretStoreBackend.readKeys(from: legacyURL)
            if !legacyKeys.isEmpty {
                let merged = keys.merging(legacyKeys) { local, _ in local }
                if merged != keys {
                    do {
                        try saveAll(merged)
                        keys = merged
                        removeLegacyStore(at: legacyURL)
                    } catch {
                        keys = merged
                    }
                } else {
                    removeLegacyStore(at: legacyURL)
                }
            }
        }

        cachedBackendKey = key
        cachedKeys = keys
        return keys
    }

    private static func saveAll(_ dict: [String: String]) throws {
        try backend.saveAll(dict)
        cachedBackendKey = backend.cacheKey
        cachedKeys = dict
    }

    static func save(id: UUID, apiKey: String) throws {
        do {
            var all = try loadAll()
            all[id.uuidString] = apiKey
            try saveAll(all)
            removeLegacyKey(id)
        } catch {
            throw KeychainError.saveFailed(error.localizedDescription)
        }
    }

    static func load(id: UUID) throws -> String {
        let all: [String: String]
        do {
            all = try loadAll()
        } catch {
            throw KeychainError.saveFailed(error.localizedDescription)
        }
        guard let key = all[id.uuidString], !key.isEmpty else {
            throw KeychainError.missing
        }
        return key
    }

    static func loadMany(ids: [UUID]) -> [UUID: String] {
        guard let all = try? loadAll() else { return [:] }
        var result: [UUID: String] = [:]
        for id in ids {
            guard result[id] == nil,
                  let key = all[id.uuidString], !key.isEmpty else { continue }
            result[id] = key
        }
        return result
    }

    static func delete(id: UUID) {
        do {
            var all = try loadAll()
            all.removeValue(forKey: id.uuidString)
            try saveAll(all)
            removeLegacyKey(id)
        } catch {
            return
        }
    }

    static func hasKey(id: UUID) -> Bool {
        (try? load(id: id)) != nil
    }

    static func reload() {
        cachedBackendKey = nil
        cachedKeys = nil
        _ = try? loadAll()
    }

    static func keyCountForStatus() throws -> Int {
        try loadAll().values.filter { !$0.isEmpty }.count
    }

    @discardableResult
    static func migrateCurrentBackend(
        to targetBackend: any SecretStoreBackend,
        activateTargetOnSuccess: Bool = false
    ) throws -> SecretStoreMigrationResult {
        let sourceBackend = backend
        let sourceKeys = try loadAll()
        let targetKeys = try targetBackend.loadAll()
        let mergedKeys = targetKeys.merging(sourceKeys) { _, source in source }

        try targetBackend.saveAll(mergedKeys)
        let verifiedKeys = try targetBackend.loadAll()
        let verificationError = migrationVerificationError(
            expected: mergedKeys,
            actual: verifiedKeys
        )
        if let verificationError {
            cachedBackendKey = sourceBackend.cacheKey
            cachedKeys = sourceKeys
            throw verificationError
        }

        if activateTargetOnSuccess {
            backend = targetBackend
            cachedBackendKey = targetBackend.cacheKey
            cachedKeys = verifiedKeys
        } else {
            cachedBackendKey = sourceBackend.cacheKey
            cachedKeys = sourceKeys
        }

        return SecretStoreMigrationResult(
            copiedKeyCount: sourceKeys.count,
            verifiedKeyCount: verifiedKeys.count,
            activatedTarget: activateTargetOnSuccess
        )
    }

    @discardableResult
    static func migrateCurrentBackendToLocalJSON(
        activateTargetOnSuccess: Bool = true
    ) throws -> SecretStoreMigrationResult {
        let result = try migrateCurrentBackend(
            to: makeLocalJSONBackend(),
            activateTargetOnSuccess: activateTargetOnSuccess
        )
        if activateTargetOnSuccess {
            rememberBackendKind(.localJSON)
        }
        return result
    }

#if canImport(Security)
    static func makeSecurityBackend(
        service: String = "com.xiaobo.kown.apikey.v1",
        accessGroup: String? = nil
    ) -> any SecretStoreBackend {
        SecurityKeychainBackend(service: service, accessGroup: accessGroup)
    }

    @discardableResult
    static func migrateCurrentBackendToSecurity(
        service: String = "com.xiaobo.kown.apikey.v1",
        accessGroup: String? = nil,
        activateTargetOnSuccess: Bool = false
    ) throws -> SecretStoreMigrationResult {
        try migrateCurrentBackend(
            to: makeSecurityBackend(service: service, accessGroup: accessGroup),
            activateTargetOnSuccess: activateTargetOnSuccess
        )
    }

    @discardableResult
    static func migrateCurrentBackendToSecurityAndRemember(
        service: String = "com.xiaobo.kown.apikey.v1",
        accessGroup: String? = nil
    ) throws -> SecretStoreMigrationResult {
        let result = try migrateCurrentBackendToSecurity(
            service: service,
            accessGroup: accessGroup,
            activateTargetOnSuccess: true
        )
        rememberBackendKind(.securityKeychain)
        return result
    }
#endif

    @discardableResult
    static func useBackendForTesting(
        _ newBackend: any SecretStoreBackend,
        legacyStoreURLProvider newLegacyStoreURLProvider: (@MainActor () -> URL?)? = nil,
        kind newBackendKind: SecretStoreBackendKind = .localJSON
    ) -> @MainActor () -> Void {
        let oldBackend = backend
        let oldActiveBackendKind = activeBackendKind
        let oldLegacyStoreURLProvider = legacyStoreURLProvider
        let oldCachedBackendKey = cachedBackendKey
        let oldCachedKeys = cachedKeys

        backend = newBackend
        activeBackendKind = newBackendKind
        if let newLegacyStoreURLProvider {
            legacyStoreURLProvider = newLegacyStoreURLProvider
        }
        cachedBackendKey = nil
        cachedKeys = nil

        return {
            backend = oldBackend
            activeBackendKind = oldActiveBackendKind
            legacyStoreURLProvider = oldLegacyStoreURLProvider
            cachedBackendKey = oldCachedBackendKey
            cachedKeys = oldCachedKeys
        }
    }

    private static func migrationVerificationError(
        expected: [String: String],
        actual: [String: String]
    ) -> SecretStoreMigrationVerificationError? {
        let expectedKeys = Set(expected.keys)
        let actualKeys = Set(actual.keys)
        let missing = expectedKeys.subtracting(actualKeys).sorted()
        let unexpected = actualKeys.subtracting(expectedKeys).sorted()
        let mismatched = expectedKeys.intersection(actualKeys)
            .filter { expected[$0] != actual[$0] }
            .sorted()

        guard !missing.isEmpty || !mismatched.isEmpty || !unexpected.isEmpty else {
            return nil
        }
        return SecretStoreMigrationVerificationError(
            missingKeys: missing,
            mismatchedKeys: mismatched,
            unexpectedKeys: unexpected
        )
    }

    private static func removeLegacyStore(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func removeLegacyKey(_ id: UUID) {
        guard let legacyURL = legacyStoreURLProvider() else { return }
        var legacyKeys = JSONSecretStoreBackend.readKeys(from: legacyURL)
        guard legacyKeys.removeValue(forKey: id.uuidString) != nil else { return }
        if legacyKeys.isEmpty {
            removeLegacyStore(at: legacyURL)
        } else {
            try? JSONSecretStoreBackend.writeKeys(legacyKeys, to: legacyURL)
        }
    }
}
