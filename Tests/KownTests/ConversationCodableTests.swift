import XCTest
@testable import Kown

/// 覆盖 `Conversation` 的 Codable 向后兼容 —— 这批新增了 systemPrompt/pinned/tags/sources 等字段,
/// 必须保证旧存档(缺字段)能正常解码为默认值,且新字段能往返,否则会破坏已有会话/iCloud 同步。
final class ConversationCodableTests: XCTestCase {

    func testDecodesLegacyJSONMissingNewFields() throws {
        // 一份只含早期字段的会话 JSON(没有 pinned/tags/systemPrompt 等)
        let legacy = #"""
        {
          "id":"\#(UUID().uuidString)",
          "title":"旧会话",
          "mode":"direct",
          "createdAt":"2025-01-01T00:00:00Z",
          "updatedAt":"2025-01-01T00:00:00Z",
          "turns":[],
          "summarizedThroughTurnCount":0,
          "activeProviderIDs":[],
          "activeModelChoices":[]
        }
        """#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let conv = try dec.decode(Conversation.self, from: Data(legacy.utf8))
        XCTAssertEqual(conv.title, "旧会话")
        XCTAssertFalse(conv.pinned)
        XCTAssertTrue(conv.tags.isEmpty)
        XCTAssertNil(conv.systemPrompt)
    }

    func testRoundTripsNewFields() throws {
        var conv = Conversation(title: "新", mode: .council)
        conv.pinned = true
        conv.tags = ["工作", "研究"]
        conv.systemPrompt = "你是助理"

        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Conversation.self, from: enc.encode(conv))

        XCTAssertTrue(back.pinned)
        XCTAssertEqual(back.tags, ["工作", "研究"])
        XCTAssertEqual(back.systemPrompt, "你是助理")
        XCTAssertEqual(back.id, conv.id)
    }

    func testTurnSourcesRoundTrip() throws {
        var turn = Turn(timestamp: Date(), prompt: "q", systemPrompt: "", responses: [:], errors: [:],
                        providerSnapshot: [:], panelOrder: [])
        turn.sources = [SourceRef(title: "T", url: "https://x.com", snippet: "s")]
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Turn.self, from: enc.encode(turn))
        XCTAssertEqual(back.sources?.first?.url, "https://x.com")
    }

    func testLegacyAppliedWriteDecodesWithoutPendingFields() throws {
        let json = #"""
        {
          "id":"\#(UUID().uuidString)",
          "relativePath":"notes.md",
          "action":"update",
          "success":true,
          "oldContent":"old",
          "newContent":"new"
        }
        """#

        let write = try JSONDecoder().decode(AppliedWrite.self, from: Data(json.utf8))

        XCTAssertEqual(write.relativePath, "notes.md")
        XCTAssertNil(write.pendingConfirmation)
        XCTAssertNil(write.warning)
    }
}

@MainActor
final class ConversationSearchIndexTests: XCTestCase {
    func testSearchResultsFollowRebuildOrder() async {
        let firstID = UUID()
        let secondID = UUID()
        let first = Conversation(
            id: firstID,
            title: "最近会话",
            turns: [Turn(prompt: "Swift 并发优化", systemPrompt: "")]
        )
        let second = Conversation(
            id: secondID,
            title: "较早会话",
            turns: [Turn(prompt: "Swift 搜索体验", systemPrompt: "")]
        )

        let index = ConversationSearchIndex()
        await index.rebuild([first, second])

        XCTAssertEqual(index.search("Swift").map(\.id), [firstID, secondID])
    }
}

@MainActor
final class BackupStoreTests: XCTestCase {
    func testBackupOmitsAPIKeysWhenDisabled() throws {
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
}
