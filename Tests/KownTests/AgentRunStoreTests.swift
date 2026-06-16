import XCTest
@testable import Kown

@MainActor
final class AgentRunStoreTests: XCTestCase {
    func testCreateAppendStepAndTransition() {
        let store = AgentRunStore.inMemory()
        let run = store.create(kind: .deepResearch, title: "研究 SwiftUI Observation", prompt: "输出结论")

        let step = store.appendStep(to: run.id, title: "制定计划", status: .running)
        XCTAssertNotNil(step)
        XCTAssertEqual(store.run(id: run.id)?.status, .running)
        XCTAssertEqual(store.run(id: run.id)?.steps.count, 1)

        XCTAssertTrue(store.updateStep(runID: run.id, stepID: step!.id, status: .done, resultSummary: "计划完成"))
        XCTAssertTrue(store.transition(run.id, to: .succeeded, reason: "完成"))
        XCTAssertEqual(store.run(id: run.id)?.status, .succeeded)
        XCTAssertEqual(store.run(id: run.id)?.summary, "完成")
        XCTAssertNotNil(store.run(id: run.id)?.finishedAt)
    }

    func testRejectsInvalidTerminalTransition() {
        let store = AgentRunStore.inMemory()
        let run = store.create(kind: .longTask, title: "已完成任务", status: .running)
        XCTAssertTrue(store.transition(run.id, to: .succeeded))
        XCTAssertFalse(store.transition(run.id, to: .running), "终态不应直接回到 running,重跑应创建新 run")
    }

    func testToolCallAddsCostAndPersists() throws {
        let url = try temporaryURL()
        let store = AgentRunStore(fileURL: url)
        let run = store.create(kind: .toolCall, title: "搜索", status: .running)
        let call = AgentRun.ToolCall(
            name: "web_search",
            displayName: "联网搜索",
            argumentsSummary: "query: Kown",
            status: .done,
            cost: .init(inputTokens: 100, outputTokens: 20, estimatedUSD: 0.001)
        )
        XCTAssertNotNil(store.appendToolCall(to: run.id, call))
        XCTAssertEqual(store.run(id: run.id)?.cost.totalTokens, 120)
        XCTAssertTrue(store.updateToolCall(
            runID: run.id,
            callID: call.id,
            cost: .init(inputTokens: 140, outputTokens: 30, estimatedUSD: 0.002)
        ))
        XCTAssertEqual(store.run(id: run.id)?.toolCalls.first?.cost.totalTokens, 170)
        XCTAssertEqual(store.run(id: run.id)?.cost.totalTokens, 170)

        let reloaded = AgentRunStore(fileURL: url)
        XCTAssertEqual(reloaded.runs.count, 1)
        XCTAssertEqual(reloaded.runs.first?.toolCalls.first?.name, "web_search")
        XCTAssertEqual(reloaded.runs.first?.cost.totalTokens, 170)
    }

    func testRerunCreatesQueuedCopyWithRetryLink() {
        let store = AgentRunStore.inMemory()
        let run = store.create(kind: .scheduledTask, title: "日报", prompt: "总结", status: .running)
        XCTAssertTrue(store.transition(run.id, to: .failed, reason: "网络错误"))

        let retry = store.rerun(run.id)
        XCTAssertNotNil(retry)
        XCTAssertEqual(retry?.status, .queued)
        XCTAssertEqual(retry?.retryOf, run.id)
        XCTAssertEqual(retry?.prompt, "总结")
        XCTAssertNotEqual(retry?.id, run.id)
        XCTAssertEqual(retry?.steps.first?.title, "重跑已排队")
        XCTAssertEqual(retry?.metadata["retryOf"], run.id.uuidString)
    }

    func testApproveMovesPendingRunAndStepsToRunning() {
        let store = AgentRunStore.inMemory()
        let run = store.create(kind: .toolCall, title: "写文件", status: .waitingForApproval, approvalStatus: .pending)
        let step = store.appendStep(to: run.id, title: "等待写入确认", status: .waitingForApproval, approvalStatus: .pending)

        XCTAssertTrue(store.approve(run.id))

        let approved = store.run(id: run.id)
        XCTAssertEqual(approved?.status, .running)
        XCTAssertEqual(approved?.approvalStatus, .approved)
        XCTAssertEqual(approved?.steps.first { $0.id == step?.id }?.status, .running)
        XCTAssertEqual(approved?.steps.first { $0.id == step?.id }?.approvalStatus, .approved)
    }

    func testRejectCancelsPendingRunAndSkipsApprovalSteps() {
        let store = AgentRunStore.inMemory()
        let run = store.create(kind: .toolCall, title: "危险操作", status: .waitingForApproval, approvalStatus: .pending)
        let step = store.appendStep(to: run.id, title: "等待确认", status: .waitingForApproval, approvalStatus: .pending)

        XCTAssertTrue(store.reject(run.id, reason: "不允许"))

        let rejected = store.run(id: run.id)
        XCTAssertEqual(rejected?.status, .cancelled)
        XCTAssertEqual(rejected?.approvalStatus, .rejected)
        XCTAssertEqual(rejected?.errorMessage, "不允许")
        XCTAssertEqual(rejected?.steps.first { $0.id == step?.id }?.status, .skipped)
        XCTAssertEqual(rejected?.steps.first { $0.id == step?.id }?.approvalStatus, .rejected)
    }

    func testAttentionNotificationsPrioritizeApprovalAndRecentResults() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AgentRunStore.inMemory()
        _ = store.create(kind: .toolCall, title: "需要审批", status: .waitingForApproval, approvalStatus: .pending, at: now)
        let done = store.create(kind: .deepResearch, title: "研究完成", status: .running, at: now.addingTimeInterval(-60))
        XCTAssertTrue(store.transition(done.id, to: .succeeded, reason: "完成", at: now))

        let cards = store.attentionNotifications(now: now)

        XCTAssertEqual(cards.first?.level, .approval)
        XCTAssertTrue(cards.contains { $0.level == .success && $0.message == "完成" })
    }

    private func temporaryURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRunStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent_runs.json")
    }
}
