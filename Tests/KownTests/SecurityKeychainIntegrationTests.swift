import Foundation
import XCTest
@testable import Kown

#if canImport(Security)
import Security

@MainActor
final class SecurityKeychainIntegrationTests: XCTestCase {
    func testRealKeychainFixtureRequiresExplicitEnvironmentOptIn() throws {
        guard ProcessInfo.processInfo.environment["KOWN_RUN_KEYCHAIN_INTEGRATION"] != "1" else {
            throw XCTSkip("Keychain integration opt-in is enabled for this run.")
        }

        XCTAssertThrowsError(try SecurityKeychainIntegrationFixture()) { error in
            XCTAssertTrue(error is XCTSkip)
        }
    }

    func testSecurityKeychainBackendRoundTripsAgainstRealKeychain() throws {
        let fixture = try SecurityKeychainIntegrationFixture()
        defer { fixture.cleanUp() }
        let first = UUID()
        let second = UUID()

        let initiallyLoaded = try fixture.backend.loadAll()
        XCTAssertEqual(initiallyLoaded, [:])

        try fixture.backend.saveAll([
            first.uuidString: "key-one-\(UUID().uuidString)",
            second.uuidString: "key-two-\(UUID().uuidString)"
        ])

        let loaded = try fixture.backend.loadAll()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[first.uuidString]?.hasPrefix("key-one-"), true)
        XCTAssertEqual(loaded[second.uuidString]?.hasPrefix("key-two-"), true)
    }

    func testSecurityKeychainBackendUpdatesAndPrunesAgainstRealKeychain() throws {
        let fixture = try SecurityKeychainIntegrationFixture()
        defer { fixture.cleanUp() }
        let kept = UUID()
        let removed = UUID()
        let updatedValue = "updated-\(UUID().uuidString)"

        try fixture.backend.saveAll([
            kept.uuidString: "old-\(UUID().uuidString)",
            removed.uuidString: "remove-\(UUID().uuidString)"
        ])
        try fixture.backend.saveAll([kept.uuidString: updatedValue])

        let loadedAfterUpdate = try fixture.backend.loadAll()
        XCTAssertEqual(loadedAfterUpdate, [kept.uuidString: updatedValue])

        try fixture.backend.saveAll([:])

        let loadedAfterDelete = try fixture.backend.loadAll()
        XCTAssertEqual(loadedAfterDelete, [:])
    }

    func testKeychainStoreFacadeCanUseSecurityBackendAgainstRealKeychain() throws {
        let fixture = try SecurityKeychainIntegrationFixture()
        let restoreBackend = KeychainStore.useBackendForTesting(
            fixture.backend,
            legacyStoreURLProvider: { nil }
        )
        defer {
            restoreBackend()
            fixture.cleanUp()
        }
        let providerID = UUID()
        let apiKey = "facade-\(UUID().uuidString)"

        try KeychainStore.save(id: providerID, apiKey: apiKey)
        KeychainStore.reload()

        XCTAssertEqual(try KeychainStore.load(id: providerID), apiKey)
        XCTAssertTrue(KeychainStore.hasKey(id: providerID))

        KeychainStore.delete(id: providerID)
        KeychainStore.reload()

        XCTAssertFalse(KeychainStore.hasKey(id: providerID))
    }
}

@MainActor
private struct SecurityKeychainIntegrationFixture {
    let service: String
    let backend: SecurityKeychainBackend

    init() throws {
        try Self.skipUnlessOptedIn()

        service = "com.xiaobo.kown.tests.\(UUID().uuidString.lowercased())"
        backend = SecurityKeychainBackend(service: service)

        try assertKeychainIsUsable()
    }

    func cleanUp(file: StaticString = #filePath, line: UInt = #line) {
        let status = SecItemDelete(serviceQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            XCTFail(
                "Failed to clean Keychain test service \(service): \(Self.message(for: status))",
                file: file,
                line: line
            )
            return
        }
    }

    private static func skipUnlessOptedIn() throws {
        guard ProcessInfo.processInfo.environment["KOWN_RUN_KEYCHAIN_INTEGRATION"] == "1" else {
            throw XCTSkip(
                "Real Keychain integration tests are opt-in; set KOWN_RUN_KEYCHAIN_INTEGRATION=1 to run."
            )
        }
    }

    private func assertKeychainIsUsable() throws {
        let account = "preflight-\(UUID().uuidString)"
        var addQuery = serviceQuery(account: account)
        addQuery[kSecAttrGeneric as String] = Data("kown-keychain-integration-preflight".utf8)
        addQuery[kSecValueData as String] = Data("probe".utf8)

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        defer {
            _ = SecItemDelete(serviceQuery(account: account) as CFDictionary)
        }

        if status == errSecSuccess || status == errSecDuplicateItem {
            return
        }
        if Self.isUnsupportedStatus(status) {
            throw XCTSkip("Keychain is unavailable on this runner: \(Self.message(for: status))")
        }
        throw SecurityKeychainIntegrationError.unexpectedStatus(
            operation: "preflight SecItemAdd",
            status: status,
            message: Self.message(for: status)
        )
    }

    private func serviceQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    private static func isUnsupportedStatus(_ status: OSStatus) -> Bool {
        [
            errSecInteractionNotAllowed,
            errSecMissingEntitlement,
            errSecNotAvailable,
            errSecUnimplemented
        ].contains(status)
    }

    private static func message(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (OSStatus \(status))"
        }
        return "OSStatus \(status)"
    }
}

private enum SecurityKeychainIntegrationError: Error, LocalizedError {
    case unexpectedStatus(operation: String, status: OSStatus, message: String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(operation, status, message):
            return "\(operation) failed with \(message) (status \(status))"
        }
    }
}
#else
final class SecurityKeychainIntegrationTests: XCTestCase {
    func testSecurityFrameworkUnavailableOnThisPlatform() throws {
        throw XCTSkip("Security framework is unavailable on this platform.")
    }
}
#endif
