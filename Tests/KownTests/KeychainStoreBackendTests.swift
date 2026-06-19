import XCTest
@testable import Kown

@MainActor
final class KeychainStoreBackendTests: XCTestCase {
    private var restoreBackend: (@MainActor () -> Void)?
    private var restoreBackupStoreFiles: (@MainActor () throws -> Void)?

    override func tearDown() async throws {
        try restoreBackupStoreFiles?()
        restoreBackupStoreFiles = nil
        restoreBackend?()
        restoreBackend = nil
        try await super.tearDown()
    }

    func testFacadeSaveLoadHasKeyLoadManyAndDeleteUseInjectedBackend() throws {
        let backend = InMemorySecretStoreBackend()
        restoreBackend = KeychainStore.useBackendForTesting(backend, legacyStoreURLProvider: { nil })
        let first = UUID()
        let second = UUID()
        let missing = UUID()

        try KeychainStore.save(id: first, apiKey: "key-1")
        try KeychainStore.save(id: second, apiKey: "key-2")

        XCTAssertEqual(try KeychainStore.load(id: first), "key-1")
        XCTAssertTrue(KeychainStore.hasKey(id: second))
        XCTAssertEqual(KeychainStore.loadMany(ids: [first, second, missing]), [
            first: "key-1",
            second: "key-2"
        ])

        KeychainStore.delete(id: first)

        XCTAssertFalse(KeychainStore.hasKey(id: first))
        XCTAssertThrowsError(try KeychainStore.load(id: first)) { error in
            XCTAssertTrue(error is KeychainError)
        }
    }

    func testReloadImportsLegacyJSONIntoPrimaryBackendAndRemovesLegacyFile() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let primaryURL = root.appendingPathComponent("primary/apikeys.json")
        let legacyURL = root.appendingPathComponent("legacy/apikeys.json")
        let providerID = UUID()
        try JSONSecretStoreBackend.writeKeys([providerID.uuidString: "legacy-key"], to: legacyURL)
        restoreBackend = KeychainStore.useBackendForTesting(
            JSONSecretStoreBackend(fileURLProvider: { primaryURL }),
            legacyStoreURLProvider: { legacyURL }
        )

        KeychainStore.reload()

        XCTAssertEqual(try KeychainStore.load(id: providerID), "legacy-key")
        XCTAssertEqual(JSONSecretStoreBackend.readKeys(from: primaryURL)[providerID.uuidString], "legacy-key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testPrimaryValueWinsOverLegacyDuringImport() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let primaryURL = root.appendingPathComponent("primary/apikeys.json")
        let legacyURL = root.appendingPathComponent("legacy/apikeys.json")
        let sharedID = UUID()
        let legacyOnlyID = UUID()
        try JSONSecretStoreBackend.writeKeys([sharedID.uuidString: "local-key"], to: primaryURL)
        try JSONSecretStoreBackend.writeKeys([
            sharedID.uuidString: "legacy-key",
            legacyOnlyID.uuidString: "legacy-only"
        ], to: legacyURL)
        restoreBackend = KeychainStore.useBackendForTesting(
            JSONSecretStoreBackend(fileURLProvider: { primaryURL }),
            legacyStoreURLProvider: { legacyURL }
        )

        KeychainStore.reload()

        XCTAssertEqual(try KeychainStore.load(id: sharedID), "local-key")
        XCTAssertEqual(try KeychainStore.load(id: legacyOnlyID), "legacy-only")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testDeleteRemovesLegacyKeySoReloadDoesNotResurrectIt() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let primaryURL = root.appendingPathComponent("primary/apikeys.json")
        let legacyURL = root.appendingPathComponent("legacy/apikeys.json")
        let providerID = UUID()
        try JSONSecretStoreBackend.writeKeys([providerID.uuidString: "legacy-key"], to: legacyURL)
        restoreBackend = KeychainStore.useBackendForTesting(
            JSONSecretStoreBackend(fileURLProvider: { primaryURL }),
            legacyStoreURLProvider: { legacyURL }
        )

        KeychainStore.delete(id: providerID)
        KeychainStore.reload()

        XCTAssertFalse(KeychainStore.hasKey(id: providerID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testMigrationFailureKeepsLegacyFileForLaterRetry() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("legacy/apikeys.json")
        let providerID = UUID()
        try JSONSecretStoreBackend.writeKeys([providerID.uuidString: "legacy-key"], to: legacyURL)
        let backend = InMemorySecretStoreBackend(saveError: TestError.saveFailed)
        restoreBackend = KeychainStore.useBackendForTesting(backend, legacyStoreURLProvider: { legacyURL })

        KeychainStore.reload()

        XCTAssertEqual(try KeychainStore.load(id: providerID), "legacy-key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testSaveFailsClosedWhenBackendLoadFails() {
        let backend = InMemorySecretStoreBackend(loadError: TestError.loadFailed)
        restoreBackend = KeychainStore.useBackendForTesting(backend, legacyStoreURLProvider: { nil })

        XCTAssertThrowsError(try KeychainStore.save(id: UUID(), apiKey: "new-key"))
        XCTAssertEqual(backend.saveAllCallCount, 0)
    }

    func testDeleteFailsClosedWhenBackendLoadFails() {
        let backend = InMemorySecretStoreBackend(loadError: TestError.loadFailed)
        restoreBackend = KeychainStore.useBackendForTesting(backend, legacyStoreURLProvider: { nil })

        KeychainStore.delete(id: UUID())

        XCTAssertEqual(backend.saveAllCallCount, 0)
    }

    func testBackupIncludesAPIKeysFromInjectedBackend() throws {
        let backend = InMemorySecretStoreBackend()
        restoreBackend = KeychainStore.useBackendForTesting(backend, legacyStoreURLProvider: { nil })
        let keyedProvider = ProviderConfig(displayName: "Keyed", kind: .openAICompatible)
        let cliProvider = ProviderConfig(displayName: "CLI", kind: .cliCommand)

        try KeychainStore.save(id: keyedProvider.id, apiKey: "provider-key")
        try KeychainStore.save(id: cliProvider.id, apiKey: "cli-key")
        try WebSearchKey.save("firecrawl-key")

        let data = try BackupStore.makeBackup(
            providers: [keyedProvider, cliProvider],
            webSearchConfig: .defaultConfig,
            includeAPIKeys: true,
            preferences: KownBackup.Preferences(
                systemPrompt: nil,
                debateRounds: nil,
                webSearchEnabledForNextSend: nil
            )
        )

        let backup = try BackupStore.parseBackup(data)
        XCTAssertEqual(backup.apiKeys, [
            keyedProvider.id.uuidString: "provider-key",
            WebSearchKey.id.uuidString: "firecrawl-key"
        ])
    }

    func testRestoreImportsAPIKeysIntoInjectedBackend() throws {
        let backend = InMemorySecretStoreBackend()
        restoreBackend = KeychainStore.useBackendForTesting(backend, legacyStoreURLProvider: { nil })
        restoreBackupStoreFiles = try preserveBackupStoreFiles()
        let keys = [
            WebSearchKey.id.uuidString: "firecrawl-key",
            GitHubAuth.tokenID.uuidString: "github-token",
            TTSConfig.siliconflowKeyID.uuidString: "siliconflow-key",
            TTSConfig.xunfeiAPIKeyID.uuidString: "xunfei-api-key",
            TTSConfig.xunfeiAPISecretID.uuidString: "xunfei-api-secret"
        ]
        let backup = KownBackup(
            version: KownBackup.currentVersion,
            exportedAt: Date(),
            appVersion: "test",
            providers: [],
            webSearchConfig: .defaultConfig,
            apiKeys: keys,
            preferences: KownBackup.Preferences(
                systemPrompt: nil,
                debateRounds: nil,
                webSearchEnabledForNextSend: nil
            )
        )

        let result = try BackupStore.applyBackup(backup, mode: .replace)

        XCTAssertEqual(result.providers, 0)
        XCTAssertEqual(result.importedKeys, keys.count)
        XCTAssertEqual(backend.storedKeys(), keys)
        XCTAssertEqual(try WebSearchKey.load(), "firecrawl-key")
        XCTAssertEqual(GitHubAuth.token(), "github-token")
        XCTAssertEqual(TTSConfig.siliconflowKey, "siliconflow-key")
        XCTAssertEqual(TTSConfig.xunfeiAPIKey, "xunfei-api-key")
        XCTAssertEqual(TTSConfig.xunfeiAPISecret, "xunfei-api-secret")
    }

    func testFixedFacadeUUIDsAreDistinctAndDoNotOverwriteEachOther() throws {
        let backend = InMemorySecretStoreBackend()
        restoreBackend = KeychainStore.useBackendForTesting(backend, legacyStoreURLProvider: { nil })
        let ids = [
            WebSearchKey.id,
            GitHubAuth.tokenID,
            TTSConfig.siliconflowKeyID,
            TTSConfig.xunfeiAPIKeyID,
            TTSConfig.xunfeiAPISecretID
        ]

        XCTAssertEqual(Set(ids).count, ids.count)

        try WebSearchKey.save("firecrawl-key")
        try GitHubAuth.saveToken("github-token")
        try KeychainStore.save(id: TTSConfig.siliconflowKeyID, apiKey: "siliconflow-key")
        try KeychainStore.save(id: TTSConfig.xunfeiAPIKeyID, apiKey: "xunfei-api-key")
        try KeychainStore.save(id: TTSConfig.xunfeiAPISecretID, apiKey: "xunfei-api-secret")

        XCTAssertEqual(try WebSearchKey.load(), "firecrawl-key")
        XCTAssertEqual(GitHubAuth.token(), "github-token")
        XCTAssertEqual(TTSConfig.siliconflowKey, "siliconflow-key")
        XCTAssertEqual(TTSConfig.xunfeiAPIKey, "xunfei-api-key")
        XCTAssertEqual(TTSConfig.xunfeiAPISecret, "xunfei-api-secret")
        XCTAssertEqual(backend.storedKeys().count, ids.count)
    }

    func testExplicitMigrationCopiesCurrentBackendToTargetWithoutActivatingByDefault() throws {
        let sourceID = UUID()
        let followUpID = UUID()
        let source = InMemorySecretStoreBackend(keys: [sourceID.uuidString: "source-key"])
        let target = InMemorySecretStoreBackend()
        restoreBackend = KeychainStore.useBackendForTesting(source, legacyStoreURLProvider: { nil })

        let result = try KeychainStore.migrateCurrentBackend(to: target)
        try KeychainStore.save(id: followUpID, apiKey: "follow-up-key")

        XCTAssertEqual(result, SecretStoreMigrationResult(
            copiedKeyCount: 1,
            verifiedKeyCount: 1,
            activatedTarget: false
        ))
        XCTAssertEqual(target.storedKeys(), [sourceID.uuidString: "source-key"])
        XCTAssertEqual(source.storedKeys()[followUpID.uuidString], "follow-up-key")
        XCTAssertNil(target.storedKeys()[followUpID.uuidString])
    }

    func testExplicitMigrationCanActivateTargetAfterVerification() throws {
        let sourceID = UUID()
        let followUpID = UUID()
        let source = InMemorySecretStoreBackend(keys: [sourceID.uuidString: "source-key"])
        let target = InMemorySecretStoreBackend()
        restoreBackend = KeychainStore.useBackendForTesting(source, legacyStoreURLProvider: { nil })

        let result = try KeychainStore.migrateCurrentBackend(
            to: target,
            activateTargetOnSuccess: true
        )
        try KeychainStore.save(id: followUpID, apiKey: "follow-up-key")

        XCTAssertEqual(result, SecretStoreMigrationResult(
            copiedKeyCount: 1,
            verifiedKeyCount: 1,
            activatedTarget: true
        ))
        XCTAssertNil(source.storedKeys()[followUpID.uuidString])
        XCTAssertEqual(target.storedKeys()[sourceID.uuidString], "source-key")
        XCTAssertEqual(target.storedKeys()[followUpID.uuidString], "follow-up-key")
    }

    func testExplicitMigrationPreservesExistingTargetKeys() throws {
        let sourceID = UUID()
        let targetID = UUID()
        let source = InMemorySecretStoreBackend(keys: [sourceID.uuidString: "source-key"])
        let target = InMemorySecretStoreBackend(keys: [targetID.uuidString: "target-key"])
        restoreBackend = KeychainStore.useBackendForTesting(source, legacyStoreURLProvider: { nil })

        let result = try KeychainStore.migrateCurrentBackend(to: target)

        XCTAssertEqual(result, SecretStoreMigrationResult(
            copiedKeyCount: 1,
            verifiedKeyCount: 2,
            activatedTarget: false
        ))
        XCTAssertEqual(target.storedKeys()[sourceID.uuidString], "source-key")
        XCTAssertEqual(target.storedKeys()[targetID.uuidString], "target-key")
    }

    func testExplicitMigrationFailureDoesNotActivateTargetOrDeletePrimaryJSON() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let primaryURL = root.appendingPathComponent("primary/apikeys.json")
        let providerID = UUID()
        try JSONSecretStoreBackend.writeKeys([providerID.uuidString: "local-key"], to: primaryURL)
        let target = InMemorySecretStoreBackend(saveError: TestError.saveFailed)
        restoreBackend = KeychainStore.useBackendForTesting(
            JSONSecretStoreBackend(fileURLProvider: { primaryURL }),
            legacyStoreURLProvider: { nil }
        )

        XCTAssertThrowsError(try KeychainStore.migrateCurrentBackend(
            to: target,
            activateTargetOnSuccess: true
        ))

        XCTAssertEqual(JSONSecretStoreBackend.readKeys(from: primaryURL)[providerID.uuidString], "local-key")
        XCTAssertEqual(try KeychainStore.load(id: providerID), "local-key")
    }

    func testExplicitMigrationVerificationFailureDoesNotActivateTarget() throws {
        let sourceID = UUID()
        let followUpID = UUID()
        let source = InMemorySecretStoreBackend(keys: [sourceID.uuidString: "source-key"])
        let target = CorruptingSecretStoreBackend()
        restoreBackend = KeychainStore.useBackendForTesting(source, legacyStoreURLProvider: { nil })

        XCTAssertThrowsError(try KeychainStore.migrateCurrentBackend(
            to: target,
            activateTargetOnSuccess: true
        )) { error in
            guard let error = error as? SecretStoreMigrationVerificationError else {
                return XCTFail("Expected verification error, got \(error)")
            }
            XCTAssertEqual(error.mismatchedKeys, [sourceID.uuidString])
        }
        try KeychainStore.save(id: followUpID, apiKey: "follow-up-key")

        XCTAssertEqual(source.storedKeys()[followUpID.uuidString], "follow-up-key")
        XCTAssertNil(target.storedKeys()[followUpID.uuidString])
    }

    func testExplicitMigrationIncludesLegacyJSONKeys() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let primaryURL = root.appendingPathComponent("primary/apikeys.json")
        let legacyURL = root.appendingPathComponent("legacy/apikeys.json")
        let localID = UUID()
        let legacyID = UUID()
        try JSONSecretStoreBackend.writeKeys([localID.uuidString: "local-key"], to: primaryURL)
        try JSONSecretStoreBackend.writeKeys([legacyID.uuidString: "legacy-key"], to: legacyURL)
        let target = InMemorySecretStoreBackend()
        restoreBackend = KeychainStore.useBackendForTesting(
            JSONSecretStoreBackend(fileURLProvider: { primaryURL }),
            legacyStoreURLProvider: { legacyURL }
        )

        let result = try KeychainStore.migrateCurrentBackend(to: target)

        XCTAssertEqual(result.copiedKeyCount, 2)
        XCTAssertEqual(target.storedKeys()[localID.uuidString], "local-key")
        XCTAssertEqual(target.storedKeys()[legacyID.uuidString], "legacy-key")
        XCTAssertEqual(JSONSecretStoreBackend.readKeys(from: primaryURL)[legacyID.uuidString], "legacy-key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

#if canImport(Security)
    func testSecurityBackendRejectsNonUUIDAccountsBeforeWriting() throws {
        let backend = SecurityKeychainBackend(service: "com.xiaobo.kown.tests.validation")

        XCTAssertThrowsError(try backend.saveAll(["not-a-uuid": "secret"])) { error in
            guard case let KeychainError.saveFailed(message) = error else {
                return XCTFail("Expected saveFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("must be a UUID"))
        }
    }
#endif

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kown-keychain-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func preserveBackupStoreFiles() throws -> @MainActor () throws -> Void {
        let sync = ICloudSync.shared
        let oldICloudEnabled = sync.isEnabled
        sync.isEnabled = false
        let snapshots = try [
            Platform.localDataDir.appendingPathComponent("config.json"),
            Platform.localDataDir.appendingPathComponent("web_search.json")
        ].map(StoreFileSnapshot.init(url:))

        return {
            for snapshot in snapshots {
                try snapshot.restore()
            }
            sync.isEnabled = oldICloudEnabled
        }
    }
}

@MainActor
private final class InMemorySecretStoreBackend: SecretStoreBackend {
    let cacheKey = "memory-\(UUID().uuidString)"
    private var keys: [String: String]
    private let loadError: Error?
    private let saveError: Error?
    private(set) var saveAllCallCount = 0

    init(keys: [String: String] = [:], loadError: Error? = nil, saveError: Error? = nil) {
        self.keys = keys
        self.loadError = loadError
        self.saveError = saveError
    }

    func loadAll() throws -> [String: String] {
        if let loadError { throw loadError }
        return keys
    }

    func saveAll(_ keys: [String: String]) throws {
        saveAllCallCount += 1
        if let saveError { throw saveError }
        self.keys = keys
    }

    func storedKeys() -> [String: String] {
        keys
    }
}

@MainActor
private final class CorruptingSecretStoreBackend: SecretStoreBackend {
    let cacheKey = "corrupting-\(UUID().uuidString)"
    private var keys: [String: String] = [:]

    func loadAll() throws -> [String: String] {
        keys
    }

    func saveAll(_ keys: [String: String]) throws {
        self.keys = keys.mapValues { "\($0)-corrupted" }
    }

    func storedKeys() -> [String: String] {
        keys
    }
}

private enum TestError: Error {
    case loadFailed
    case saveFailed
}

private struct StoreFileSnapshot {
    let url: URL
    let data: Data?

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            self.data = try Data(contentsOf: url)
        } else {
            self.data = nil
        }
    }

    func restore() throws {
        let fm = FileManager.default
        if let data {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}
