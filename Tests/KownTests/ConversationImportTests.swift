import XCTest
@testable import Kown

/// `ConversationImporter` 的最小单测:手造 ChatGPT / Claude / Kown 三种最小 JSON,
/// 验证解析出的轮数 / 角色配对 / 标题正确,以及坏数据被跳过而不是整体失败。
final class ConversationImportTests: XCTestCase {

    // MARK: - ChatGPT

    /// 最小 ChatGPT 导出:mapping 树 root → user → assistant,current_node 指向 assistant。
    private func chatGPTConversationJSON(title: String = "测试会话") -> String {
        """
        {
          "title": "\(title)",
          "create_time": 1700000000.0,
          "update_time": 1700000100.0,
          "current_node": "node-a1",
          "mapping": {
            "root": { "id": "root", "message": null, "parent": null, "children": ["node-u1"] },
            "node-u1": {
              "id": "node-u1",
              "parent": "root",
              "children": ["node-a1"],
              "message": {
                "id": "m-u1",
                "author": { "role": "user" },
                "create_time": 1700000010.0,
                "content": { "content_type": "text", "parts": ["你好,介绍一下自己"] }
              }
            },
            "node-a1": {
              "id": "node-a1",
              "parent": "node-u1",
              "children": [],
              "message": {
                "id": "m-a1",
                "author": { "role": "assistant" },
                "create_time": 1700000020.0,
                "content": { "content_type": "text", "parts": ["我是 ChatGPT。"] }
              }
            }
          }
        }
        """
    }

    func testChatGPTMinimalImport() throws {
        let json = "[\(chatGPTConversationJSON())]"
        let result = try ConversationImporter.parse(Data(json.utf8), source: .chatGPT)

        XCTAssertEqual(result.conversations.count, 1)
        XCTAssertEqual(result.skipped, 0)

        let conv = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conv.title, "测试会话")
        XCTAssertEqual(conv.mode, .direct)
        XCTAssertEqual(conv.turns.count, 1)

        let turn = try XCTUnwrap(conv.turns.first)
        XCTAssertEqual(turn.prompt, "你好,介绍一下自己")
        XCTAssertEqual(turn.responses.values.first, "我是 ChatGPT。")
        // 时间戳来自 create_time(epoch 秒)
        XCTAssertEqual(conv.createdAt.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
        // panelOrder 与 providerSnapshot 配套,渲染显示名为「ChatGPT(导入)」
        let pid = try XCTUnwrap(turn.panelOrder.first)
        XCTAssertEqual(turn.providerSnapshot[pid]?.displayName, "ChatGPT(导入)")
    }

    func testChatGPTBadEntrySkipped() throws {
        // 第二条缺 mapping → 跳过;第三条 mapping 为空 → 跳过;不影响第一条。
        let json = """
        [\(chatGPTConversationJSON()), { "title": "坏数据,没有 mapping" }, { "title": "空树", "mapping": {} }]
        """
        let result = try ConversationImporter.parse(Data(json.utf8), source: .chatGPT)
        XCTAssertEqual(result.conversations.count, 1)
        XCTAssertEqual(result.skipped, 2)
    }

    func testChatGPTGarbageThrows() {
        XCTAssertThrowsError(try ConversationImporter.parse(Data("\"不是数组\"".utf8), source: .chatGPT))
    }

    // MARK: - Claude

    private let claudeJSON = """
    [
      {
        "uuid": "11111111-1111-1111-1111-111111111111",
        "name": "Claude 测试",
        "created_at": "2024-05-01T08:00:00.123456Z",
        "updated_at": "2024-05-01T09:00:00Z",
        "chat_messages": [
          { "uuid": "m1", "sender": "human", "text": "帮我写首诗", "created_at": "2024-05-01T08:00:01Z" },
          { "uuid": "m2", "sender": "assistant", "text": "好的,这是一首诗。", "created_at": "2024-05-01T08:00:05Z" },
          { "uuid": "m3", "sender": "human", "text": "再来一首", "created_at": "2024-05-01T08:01:00Z" }
        ]
      },
      { "uuid": "bad", "name": "坏数据,没有消息数组" }
    ]
    """

    func testClaudeMinimalImportAndSkip() throws {
        let result = try ConversationImporter.parse(Data(claudeJSON.utf8), source: .claude)

        XCTAssertEqual(result.conversations.count, 1)
        XCTAssertEqual(result.skipped, 1)

        let conv = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conv.title, "Claude 测试")
        XCTAssertEqual(conv.mode, .direct)
        // human+assistant 配成第 1 轮;落单的 human 收尾成第 2 轮(无回答)
        XCTAssertEqual(conv.turns.count, 2)
        XCTAssertEqual(conv.turns[0].prompt, "帮我写首诗")
        XCTAssertEqual(conv.turns[0].responses.values.first, "好的,这是一首诗。")
        XCTAssertEqual(conv.turns[1].prompt, "再来一首")
        XCTAssertTrue(conv.turns[1].responses.isEmpty)

        let pid = try XCTUnwrap(conv.turns[0].panelOrder.first)
        XCTAssertEqual(conv.turns[0].providerSnapshot[pid]?.displayName, "Claude(导入)")
    }

    /// content 数组兜底:顶层 text 缺失时拼 type=text 的段。
    func testClaudeContentArrayFallback() throws {
        let json = """
        [{
          "uuid": "u",
          "name": "content 兜底",
          "chat_messages": [
            { "sender": "human", "content": [ { "type": "text", "text": "问题" } ] },
            { "sender": "assistant", "content": [ { "type": "text", "text": "回答" }, { "type": "tool_use" } ] }
          ]
        }]
        """
        let result = try ConversationImporter.parse(Data(json.utf8), source: .claude)
        let conv = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conv.turns.count, 1)
        XCTAssertEqual(conv.turns[0].prompt, "问题")
        XCTAssertEqual(conv.turns[0].responses.values.first, "回答")
    }

    // MARK: - Kown 单会话 JSON

    func testKownRoundTripRegeneratesIDs() throws {
        // 用导出器产出再导回(对称面),验证内容保留 + id 全部换新。
        let pid = UUID().uuidString
        let turn = Turn(
            prompt: "原始问题",
            systemPrompt: "你是助手",
            responses: [pid: "原始回答"],
            providerSnapshot: [pid: ProviderConfig(displayName: "测试模型", kind: .openAICompatible)],
            panelOrder: [pid]
        )
        let original = Conversation(title: "Kown 导出", mode: .direct, turns: [turn])
        let data = try ConversationExporter.json(for: original)

        let result = try ConversationImporter.parse(data, source: .kown)
        XCTAssertEqual(result.conversations.count, 1)
        XCTAssertEqual(result.skipped, 0)

        let imported = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(imported.title, "Kown 导出")
        XCTAssertEqual(imported.turns.count, 1)
        XCTAssertEqual(imported.turns[0].prompt, "原始问题")
        XCTAssertEqual(imported.turns[0].responses[pid], "原始回答")
        // id 全部重新生成,防止和本机已有会话冲突
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertNotEqual(imported.turns[0].id, original.turns[0].id)
        // providerSnapshot 照搬,显示名仍可还原
        XCTAssertEqual(imported.turns[0].providerSnapshot[pid]?.displayName, "测试模型")
    }

    func testKownGarbageThrows() {
        XCTAssertThrowsError(try ConversationImporter.parse(Data("{ \"foo\": 1 }".utf8), source: .kown))
    }
}
