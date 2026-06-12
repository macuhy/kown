import XCTest
@testable import Kown

/// 覆盖定时任务增量记忆新增字段:
///  - lastRunDate / lastRunDigest / incrementalMode 的 Codable 往返
///  - 旧存档(缺新键)向后兼容(incrementalMode 默认 true,日期/摘要为 nil)
///  - incrementalPromptBlock 的注入条件(增量开 + 有摘要才出块)
final class ScheduledTaskIncrementalTests: XCTestCase {

    func testNewFieldsRoundTrip() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let task = ScheduledTask(title: "盯更新", prompt: "看看有什么新进展",
                                 lastRunDate: when, lastRunDigest: "上次报告了 A、B 两点",
                                 incrementalMode: true)
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: data)
        XCTAssertEqual(decoded.lastRunDate, when)
        XCTAssertEqual(decoded.lastRunDigest, "上次报告了 A、B 两点")
        XCTAssertTrue(decoded.incrementalMode)
    }

    func testDecodesLegacyJSONWithoutNewKeys() throws {
        // 旧 scheduled-tasks.json 没有增量字段 → 不应整份解码失败丢任务。
        let json = """
        {"id":"\(UUID().uuidString)","title":"旧任务","prompt":"做点事","kind":"plainPrompt",
         "mode":"direct","hour":9,"minute":0,"repeatsDaily":true,"enabled":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: json)
        XCTAssertEqual(decoded.title, "旧任务")
        XCTAssertNil(decoded.lastRunDate)
        XCTAssertNil(decoded.lastRunDigest)
        XCTAssertTrue(decoded.incrementalMode, "缺字段时增量模式默认开")
    }

    func testIncrementalBlockEmittedWhenEnabledWithDigest() {
        var task = ScheduledTask(title: "t", prompt: "p", incrementalMode: true)
        task.lastRunDigest = "上次结论:进度 50%"
        task.lastRunDate = Date(timeIntervalSince1970: 1_700_000_000)
        let block = task.incrementalPromptBlock
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("上次结论:进度 50%"))
        XCTAssertTrue(block!.contains("新增与变化"))
    }

    func testIncrementalBlockNilWhenDisabled() {
        var task = ScheduledTask(title: "t", prompt: "p", incrementalMode: false)
        task.lastRunDigest = "有摘要但关了增量"
        XCTAssertNil(task.incrementalPromptBlock)
    }

    func testIncrementalBlockNilOnFirstRun() {
        let task = ScheduledTask(title: "t", prompt: "p", incrementalMode: true)
        XCTAssertNil(task.incrementalPromptBlock, "首跑没摘要不出块")
    }

    func testMakeDigestTruncates() {
        let long = String(repeating: "字", count: 1200)
        let digest = SchedulerService.makeDigest(long, maxChars: 800)
        XCTAssertLessThanOrEqual(digest.count, 801)
        XCTAssertTrue(digest.hasSuffix("…"))
        // 短文本原样返回。
        XCTAssertEqual(SchedulerService.makeDigest("短摘要"), "短摘要")
    }
}
