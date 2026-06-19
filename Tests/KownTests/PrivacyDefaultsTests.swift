import XCTest
@testable import Kown

final class PrivacyDefaultsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: ResponseLogger.includeSensitiveContentPrefKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ResponseLogger.includeSensitiveContentPrefKey)
        super.tearDown()
    }

    func testResponseLoggerRedactsBodiesByDefault() {
        let rendered = ResponseLogger.render(logEntry())

        XCTAssertFalse(rendered.contains("VERY_PRIVATE_SYSTEM"))
        XCTAssertFalse(rendered.contains("VERY_PRIVATE_PROMPT"))
        XCTAssertFalse(rendered.contains("VERY_PRIVATE_RESPONSE"))
        XCTAssertTrue(rendered.contains(ResponseLogger.includeSensitiveContentPrefKey))
    }

    func testResponseLoggerIncludesBodiesOnlyAfterOptIn() {
        UserDefaults.standard.set(true, forKey: ResponseLogger.includeSensitiveContentPrefKey)

        let rendered = ResponseLogger.render(logEntry())

        XCTAssertTrue(rendered.contains("VERY_PRIVATE_SYSTEM"))
        XCTAssertTrue(rendered.contains("VERY_PRIVATE_PROMPT"))
        XCTAssertTrue(rendered.contains("VERY_PRIVATE_RESPONSE"))
    }

    @MainActor
    func testBackupOmitsAPIKeysByDefault() throws {
        let provider = ProviderConfig(displayName: "Test", kind: .openAICompatible)
        let data = try BackupStore.makeBackup(
            providers: [provider],
            webSearchConfig: .defaultConfig,
            includeAPIKeys: false,
            preferences: KownBackup.Preferences(
                systemPrompt: nil,
                debateRounds: nil,
                webSearchEnabledForNextSend: nil
            )
        )

        let backup = try BackupStore.parseBackup(data)
        XCTAssertNil(backup.apiKeys)
    }

    func testICloudCopyTreeSkipsAPIKeys() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "kown-privacy-\(UUID().uuidString)",
            isDirectory: true
        )
        let source = root.appendingPathComponent("source", isDirectory: true)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try "provider".write(
            to: source.appendingPathComponent("providers.json"),
            atomically: true,
            encoding: .utf8
        )
        try "secret".write(
            to: source.appendingPathComponent("apikeys.json"),
            atomically: true,
            encoding: .utf8
        )

        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try "conversation".write(
            to: nested.appendingPathComponent("conversation.json"),
            atomically: true,
            encoding: .utf8
        )
        try "nested-secret".write(
            to: nested.appendingPathComponent("apikeys.json"),
            atomically: true,
            encoding: .utf8
        )

        let copied = ICloudSync.copyTree(
            from: source,
            to: dest,
            overwrite: false,
            excluding: ICloudSync.sensitiveFilenamesExcludedFromCloudCopy
        )

        XCTAssertEqual(copied, 2)
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("providers.json").path))
        XCTAssertTrue(fm.fileExists(atPath: dest
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("conversation.json").path))
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("apikeys.json").path))
        XCTAssertFalse(fm.fileExists(atPath: dest
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("apikeys.json").path))
    }

    private func logEntry() -> ResponseLogger.Entry {
        ResponseLogger.Entry(
            roundID: "round-1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            providerName: "Provider",
            providerKind: "openai",
            baseURL: "https://example.test",
            model: "test-model",
            prompt: "VERY_PRIVATE_PROMPT",
            systemPrompt: "VERY_PRIVATE_SYSTEM",
            response: "VERY_PRIVATE_RESPONSE",
            elapsedSeconds: 1.2,
            error: nil,
            conversationTitle: "Test",
            conversationID: UUID().uuidString
        )
    }
}
