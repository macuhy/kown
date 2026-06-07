import XCTest
@testable import Kown

/// 覆盖深入模式相关的 ChatOptions 默认值:不开深入模式时行为与历史一致(6 轮、无 Agent 指令)。
final class ChatOptionsDefaultsTests: XCTestCase {

    func testDefaultMaxToolRoundsIsSix() {
        XCTAssertEqual(ChatOptions().maxToolRounds, 6)
        XCTAssertEqual(ChatOptions.default.maxToolRounds, 6)
    }

    func testDefaultAgentInstructionIsNil() {
        XCTAssertNil(ChatOptions().agentInstruction)
        XCTAssertNil(ChatOptions.default.agentInstruction)
    }

    func testAgentFieldsAreSettable() {
        var opts = ChatOptions()
        opts.maxToolRounds = 12
        opts.agentInstruction = "act like an agent"
        XCTAssertEqual(opts.maxToolRounds, 12)
        XCTAssertEqual(opts.agentInstruction, "act like an agent")
    }

    /// combineSystem 把 agentInstruction 放到最前面;不传时与原行为一致。
    func testCombineSystemPrependsAgentInstruction() {
        let combined = combineSystem(userSystem: "你是助手", summary: nil,
                                     includeCurrentTime: false, agentInstruction: "AGENT")
        XCTAssertEqual(combined?.hasPrefix("AGENT"), true)
        XCTAssertEqual(combined?.contains("你是助手"), true)
    }

    func testCombineSystemWithoutAgentUnchanged() {
        let combined = combineSystem(userSystem: "你是助手", summary: nil)
        XCTAssertEqual(combined, "你是助手")
    }
}
