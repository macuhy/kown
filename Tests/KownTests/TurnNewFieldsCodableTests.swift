import XCTest
@testable import Kown

/// 覆盖本次合并中新增到 `Turn` 的字段的 Codable 往返与向后兼容:
/// compareVerdict / consensusAnalysis / tournamentRounds / generatedImagesByProvider / imageGenErrors。
/// 这批字段是手工解决合并冲突后落入 `Turn` 的,必须保证:
///  1) 新字段能编码→解码往返不丢;
///  2) 旧存档(缺这些键)仍能解码,新字段为 nil(不破坏已有会话 / iCloud 同步)。
final class TurnNewFieldsCodableTests: XCTestCase {

    func testNewFieldsRoundTrip() throws {
        let turn = Turn(
            prompt: "比较一下",
            systemPrompt: "",
            tournamentRounds: [
                TournamentRound(index: 1, title: "决赛", matches: [
                    TournamentRound.Match(aProviderID: "p1", bProviderID: "p2",
                                          winnerProviderID: "p1", rationale: "更准确")
                ])
            ],
            compareVerdict: CompareVerdict(winnerProviderID: "p1", rationale: "p1 更好"),
            consensusAnalysis: ConsensusAnalysis(agreements: ["都同意A"], disagreements: ["在B上分歧"]),
            generatedImagesByProvider: [
                "p1": [TurnImage(fileName: "a.jpg", mimeType: "image/jpeg", pixelWidth: 64, pixelHeight: 64)]
            ],
            imageGenErrors: ["p2": "出图失败"]
        )

        let data = try JSONEncoder().encode(turn)
        let decoded = try JSONDecoder().decode(Turn.self, from: data)

        XCTAssertEqual(decoded.compareVerdict, CompareVerdict(winnerProviderID: "p1", rationale: "p1 更好"))
        XCTAssertEqual(decoded.consensusAnalysis?.agreements, ["都同意A"])
        XCTAssertEqual(decoded.consensusAnalysis?.disagreements, ["在B上分歧"])
        XCTAssertEqual(decoded.tournamentRounds?.first?.title, "决赛")
        XCTAssertEqual(decoded.tournamentRounds?.first?.matches.first?.winnerProviderID, "p1")
        XCTAssertEqual(decoded.generatedImagesByProvider?["p1"]?.first?.fileName, "a.jpg")
        XCTAssertEqual(decoded.imageGenErrors?["p2"], "出图失败")
    }

    func testLegacyTurnJSONMissingNewFieldsDecodesToNil() throws {
        // 一份只含早期字段的 Turn JSON(没有任何本次新增字段)。
        let legacy = #"""
        {
          "id":"\#(UUID().uuidString)",
          "timestamp":"2025-01-01T00:00:00Z",
          "prompt":"旧的一轮",
          "systemPrompt":"",
          "responses":{},
          "errors":{},
          "providerSnapshot":{},
          "panelOrder":[]
        }
        """#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let turn = try dec.decode(Turn.self, from: Data(legacy.utf8))

        XCTAssertEqual(turn.prompt, "旧的一轮")
        XCTAssertNil(turn.compareVerdict)
        XCTAssertNil(turn.consensusAnalysis)
        XCTAssertNil(turn.tournamentRounds)
        XCTAssertNil(turn.generatedImagesByProvider)
        XCTAssertNil(turn.imageGenErrors)
    }

    func testTurnInsideConversationRoundTrips() throws {
        // 整条会话(含带新字段的 Turn)往返,确认嵌套层级也不丢。
        var conv = Conversation(mode: .tournament)
        conv.turns = [
            Turn(prompt: "q", systemPrompt: "",
                 compareVerdict: CompareVerdict(winnerProviderID: "x", rationale: "r"))
        ]
        let data = try JSONEncoder().encode(conv)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(decoded.mode, .tournament)
        XCTAssertEqual(decoded.turns.first?.compareVerdict?.winnerProviderID, "x")
    }
}
