import XCTest
@testable import Kown

@MainActor
final class SecretStoreBackendSelectionPersistenceTests: XCTestCase {
    private var restoreBackend: (@MainActor () -> Void)?

    override func tearDown() async throws {
        restoreBackend?()
        restoreBackend = nil
        try await super.tearDown()
    }

    func testJSONLikeBackendSelectionSurvivesFacadeReload() throws {
        let providerID = UUID()
        let jsonBackend = SelectionTestSecretStoreBackend(label: "json")
        restoreBackend = KeychainStore.useBackendForTesting(
            jsonBackend,
            legacyStoreURLProvider: { nil }
        )

        try KeychainStore.save(id: providerID, apiKey: "json-key")
        KeychainStore.reload()

        XCTAssertEqual(try KeychainStore.load(id: providerID), "json-key")
        XCTAssertEqual(jsonBackend.storedKeys()[providerID.uuidString], "json-key")
        XCTAssertGreaterThanOrEqual(jsonBackend.loadAllCallCount, 2)
    }

    func testActivatedSecurityLikeBackendSurvivesReloadAndReceivesFutureWrites() throws {
        let existingID = UUID()
        let followUpID = UUID()
        let jsonBackend = SelectionTestSecretStoreBackend(
            label: "json",
            keys: [existingID.uuidString: "json-key"]
        )
        let securityBackend = SelectionTestSecretStoreBackend(label: "security")
        restoreBackend = KeychainStore.useBackendForTesting(
            jsonBackend,
            legacyStoreURLProvider: { nil }
        )

        let result = try KeychainStore.migrateCurrentBackend(
            to: securityBackend,
            activateTargetOnSuccess: true
        )
        KeychainStore.reload()
        try KeychainStore.save(id: followUpID, apiKey: "security-follow-up")

        XCTAssertEqual(result, SecretStoreMigrationResult(
            copiedKeyCount: 1,
            verifiedKeyCount: 1,
            activatedTarget: true
        ))
        XCTAssertEqual(try KeychainStore.load(id: existingID), "json-key")
        XCTAssertEqual(securityBackend.storedKeys()[existingID.uuidString], "json-key")
        XCTAssertEqual(securityBackend.storedKeys()[followUpID.uuidString], "security-follow-up")
        XCTAssertNil(jsonBackend.storedKeys()[followUpID.uuidString])
    }

    func testMigrationFailureKeepsCurrentBackendActive() throws {
        let existingID = UUID()
        let followUpID = UUID()
        let jsonBackend = SelectionTestSecretStoreBackend(
            label: "json",
            keys: [existingID.uuidString: "json-key"]
        )
        let failingSecurityBackend = SelectionTestSecretStoreBackend(
            label: "security",
            saveError: SelectionTestError.saveFailed
        )
        restoreBackend = KeychainStore.useBackendForTesting(
            jsonBackend,
            legacyStoreURLProvider: { nil }
        )

        XCTAssertThrowsError(try KeychainStore.migrateCurrentBackend(
            to: failingSecurityBackend,
            activateTargetOnSuccess: true
        ))
        KeychainStore.reload()
        try KeychainStore.save(id: followUpID, apiKey: "json-follow-up")

        XCTAssertEqual(try KeychainStore.load(id: existingID), "json-key")
        XCTAssertEqual(jsonBackend.storedKeys()[followUpID.uuidString], "json-follow-up")
        XCTAssertNil(failingSecurityBackend.storedKeys()[followUpID.uuidString])
    }

    func testSwitchingBackToJSONLikeBackendDoesNotDeleteInactiveSecurityKeys() throws {
        let providerID = UUID()
        let jsonBackend = SelectionTestSecretStoreBackend(label: "json")
        let securityBackend = SelectionTestSecretStoreBackend(
            label: "security",
            keys: [providerID.uuidString: "security-key"]
        )
        restoreBackend = KeychainStore.useBackendForTesting(
            securityBackend,
            legacyStoreURLProvider: { nil }
        )

        let result = try KeychainStore.migrateCurrentBackend(
            to: jsonBackend,
            activateTargetOnSuccess: true
        )
        KeychainStore.delete(id: providerID)

        XCTAssertEqual(result, SecretStoreMigrationResult(
            copiedKeyCount: 1,
            verifiedKeyCount: 1,
            activatedTarget: true
        ))
        XCTAssertNil(jsonBackend.storedKeys()[providerID.uuidString])
        XCTAssertEqual(securityBackend.storedKeys()[providerID.uuidString], "security-key")
    }

    func testCopyToSecurityLikeBackendIsExplicitAndDoesNotActivateByDefault() throws {
        let existingID = UUID()
        let followUpID = UUID()
        let jsonBackend = SelectionTestSecretStoreBackend(
            label: "json",
            keys: [existingID.uuidString: "json-key"]
        )
        let securityBackend = SelectionTestSecretStoreBackend(label: "security")
        restoreBackend = KeychainStore.useBackendForTesting(
            jsonBackend,
            legacyStoreURLProvider: { nil }
        )

        let result = try KeychainStore.migrateCurrentBackend(to: securityBackend)
        KeychainStore.reload()
        try KeychainStore.save(id: followUpID, apiKey: "json-follow-up")

        XCTAssertEqual(result, SecretStoreMigrationResult(
            copiedKeyCount: 1,
            verifiedKeyCount: 1,
            activatedTarget: false
        ))
        XCTAssertEqual(securityBackend.storedKeys()[existingID.uuidString], "json-key")
        XCTAssertNil(securityBackend.storedKeys()[followUpID.uuidString])
        XCTAssertEqual(jsonBackend.storedKeys()[followUpID.uuidString], "json-follow-up")
    }
}

@MainActor
private final class SelectionTestSecretStoreBackend: SecretStoreBackend {
    let cacheKey: String
    private var keys: [String: String]
    private let loadError: Error?
    private let saveError: Error?
    private(set) var loadAllCallCount = 0
    private(set) var saveAllCallCount = 0

    init(
        label: String,
        keys: [String: String] = [:],
        loadError: Error? = nil,
        saveError: Error? = nil
    ) {
        self.cacheKey = "\(label)-\(UUID().uuidString)"
        self.keys = keys
        self.loadError = loadError
        self.saveError = saveError
    }

    func loadAll() throws -> [String: String] {
        loadAllCallCount += 1
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

private enum SelectionTestError: Error {
    case saveFailed
}
