import XCTest
@testable import Kown

/// 覆盖「上下文窗口用量条 + 一键压缩历史 + 全新上下文截断」:
/// - token 启发式估算与窗口表(前缀匹配 / 未知模型回退 128k / 多模型取最小);
/// - `Conversation` 新字段(compressedContextSummary / compressedThroughTurnCount /
///   contextCutoffTurnID)的 Codable 向后兼容与往返;
/// - `ConversationSummarizer.summaryForNextSend` / `priorTurnsForReplay` 对压缩水位与截断点的注入。
final class ContextWindowTests: XCTestCase {

    // MARK: - token 估算 / 窗口表

    func testEstimateTokensHeuristic() {
        XCTAssertEqual(ContextWindowEstimator.estimateTokens(""), 0)
        // 10 个中文字符 ×0.6 = 6
        XCTAssertEqual(ContextWindowEstimator.estimateTokens("一二三四五六七八九十"), 6)
        // 8 个英文字符 /4 = 2
        XCTAssertEqual(ContextWindowEstimator.estimateTokens("abcdefgh"), 2)
        // 混合:10 中文(6)+ 8 英文(2)
        XCTAssertEqual(ContextWindowEstimator.estimateTokens("一二三四五六七八九十abcdefgh"), 8)
    }

    func testContextWindowLookup() {
        XCTAssertEqual(ContextWindowEstimator.contextWindow(forModel: "claude-sonnet-4-6"), 200_000)
        XCTAssertEqual(ContextWindowEstimator.contextWindow(forModel: "gemini-2.5-pro"), 1_000_000)
        XCTAssertEqual(ContextWindowEstimator.contextWindow(forModel: "moonshot-v1-8k"), 8_000)
        // 最长前缀优先:moonshot-v1-128k 命中专属条目而非 8k/32k。
        XCTAssertEqual(ContextWindowEstimator.contextWindow(forModel: "moonshot-v1-128k"), 128_000)
        // 未知模型回退保守默认 128k。
        XCTAssertEqual(ContextWindowEstimator.contextWindow(forModel: "totally-unknown-model"),
                       ContextWindowEstimator.defaultContextWindow)
    }

    func testUsageTakesSmallestWindowAcrossModels() throws {
        let usage = try XCTUnwrap(ContextWindowEstimator.usage(
            systemPrompt: "",
            contextSummary: nil,
            priorTurns: [],
            draftPrompt: "hello",
            models: ["gemini-2.5-pro", "moonshot-v1-8k", "claude-sonnet-4-6"]
        ))
        XCTAssertEqual(usage.windowTokens, 8_000)
        XCTAssertEqual(usage.limitingModel, "moonshot-v1-8k")
        XCTAssertGreaterThan(usage.estimatedTokens, 0)
    }

    func testUsagePercentAndFractionClamping() throws {
        // 8k 窗口 + 远超窗口的中文文本 → percent 如实 >100,fraction 夹紧到 1。
        let big = String(repeating: "很", count: 20_000)   // ≈ 12k tokens
        let usage = try XCTUnwrap(ContextWindowEstimator.usage(
            systemPrompt: "", contextSummary: nil, priorTurns: [],
            draftPrompt: big, models: ["moonshot-v1-8k"]
        ))
        XCTAssertGreaterThan(usage.percent, 100)
        XCTAssertEqual(usage.fraction, 1.0)
    }

    // MARK: - Conversation 新字段 Codable

    func testDecodesLegacyJSONWithoutContextFields() throws {
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
        XCTAssertNil(conv.compressedContextSummary)
        XCTAssertEqual(conv.compressedThroughTurnCount, 0)
        XCTAssertNil(conv.contextCutoffTurnID)
    }

    func testContextFieldsRoundTrip() throws {
        var conv = Conversation(title: "新", mode: .direct)
        let cutoffID = UUID()
        conv.compressedContextSummary = "早期摘要"
        conv.compressedThroughTurnCount = 5
        conv.contextCutoffTurnID = cutoffID

        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Conversation.self, from: enc.encode(conv))

        XCTAssertEqual(back.compressedContextSummary, "早期摘要")
        XCTAssertEqual(back.compressedThroughTurnCount, 5)
        XCTAssertEqual(back.contextCutoffTurnID, cutoffID)
    }

    // MARK: - 发送注入(summaryForNextSend / priorTurnsForReplay)

    private func makeTurn(_ i: Int) -> Turn {
        Turn(prompt: "问题\(i)", systemPrompt: "",
             responses: ["p": "回答\(i)"], errors: [:],
             providerSnapshot: [:], panelOrder: ["p"])
    }

    private func makeConv(turnCount: Int) -> Conversation {
        Conversation(title: "t", mode: .direct, turns: (0..<turnCount).map(makeTurn))
    }

    func testCompressedSummaryReplacesEarlyTurns() {
        var conv = makeConv(turnCount: 6)
        conv.compressedContextSummary = "压缩摘要"
        conv.compressedThroughTurnCount = 3   // 前 3 轮已并入摘要

        // 摘要被发送(滚动摘要为空 → 用压缩摘要)。
        XCTAssertEqual(ConversationSummarizer.summaryForNextSend(conv), "压缩摘要")
        // 原文只带压缩水位之后的最近轮(lookback 3 → 第 3、4、5 轮)。
        let prior = ConversationSummarizer.priorTurnsForReplay(conv)
        XCTAssertEqual(prior.map(\.userText), ["问题3", "问题4", "问题5"])
    }

    func testCompressedFloorTrimsLookbackWindow() {
        var conv = makeConv(turnCount: 4)
        conv.compressedContextSummary = "压缩摘要"
        conv.compressedThroughTurnCount = 2   // lookback 窗口(1..3)与压缩范围(0..1)有交叠

        let prior = ConversationSummarizer.priorTurnsForReplay(conv)
        // 第 1 轮虽在 lookback 窗口内,但已被压缩 → 不再发原文。
        XCTAssertEqual(prior.map(\.userText), ["问题2", "问题3"])
    }

    func testRollingSummaryWinsOnceItCoversMoreTurns() {
        var conv = makeConv(turnCount: 8)
        conv.compressedContextSummary = "压缩摘要"
        conv.compressedThroughTurnCount = 3
        conv.contextSummary = "滚动摘要"
        conv.summarizedThroughTurnCount = 6   // 滚动摘要已覆盖更多轮(且内容是超集)
        XCTAssertEqual(ConversationSummarizer.summaryForNextSend(conv), "滚动摘要")
    }

    func testCutoffDropsSummaryAndEarlierTurns() {
        var conv = makeConv(turnCount: 6)
        conv.contextSummary = "滚动摘要"
        conv.summarizedThroughTurnCount = 3
        conv.contextCutoffTurnID = conv.turns[3].id   // 截断点 = 第 3 轮

        // 截断生效:摘要不再发送。
        XCTAssertNil(ConversationSummarizer.summaryForNextSend(conv))
        // 只带截断点之后的轮(第 4、5 轮)。
        let prior = ConversationSummarizer.priorTurnsForReplay(conv)
        XCTAssertEqual(prior.map(\.userText), ["问题4", "问题5"])
    }

    func testCutoffAtLastTurnSendsNothing() {
        var conv = makeConv(turnCount: 3)
        conv.contextCutoffTurnID = conv.turns[2].id
        XCTAssertNil(ConversationSummarizer.summaryForNextSend(conv))
        XCTAssertTrue(ConversationSummarizer.priorTurnsForReplay(conv).isEmpty)
    }

    func testStaleCutoffIDIsIgnored() {
        var conv = makeConv(turnCount: 3)
        conv.contextSummary = "滚动摘要"
        conv.contextCutoffTurnID = UUID()   // 指向已删除的轮 → 截断自动失效
        XCTAssertEqual(ConversationSummarizer.summaryForNextSend(conv), "滚动摘要")
        XCTAssertEqual(ConversationSummarizer.priorTurnsForReplay(conv).count, 3)
    }

    func testCompressedWatermarkClampedWhenTurnsDeleted() {
        var conv = makeConv(turnCount: 2)
        conv.compressedContextSummary = "压缩摘要"
        conv.compressedThroughTurnCount = 5   // 编辑历史删轮后水位越过当前轮数
        // 不越界、不崩;原文全部被水位盖住 → 不发原文,只发摘要。
        XCTAssertTrue(ConversationSummarizer.priorTurnsForReplay(conv).isEmpty)
        XCTAssertEqual(ConversationSummarizer.summaryForNextSend(conv), "压缩摘要")
    }
}
