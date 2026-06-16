import XCTest
@testable import Kown

final class MeetingWorkflowTests: XCTestCase {

    func testGenerateFromMeetingNotesBuildsThreePhaseWorkflow() {
        let due = MeetingNotesSummarizer.parseDueDate("2026-06-20")
        let notes = MeetingNotes(
            summary: "团队确认先交付会议闭环 MVP，再接入导航。",
            decisions: ["本周先发布独立 MVP"],
            actionItems: [
                MeetingNotes.ActionItem(
                    task: "补齐会议闭环测试",
                    owner: "小王",
                    dueText: "2026-06-20",
                    dueDate: due
                )
            ]
        )

        let workflow = MeetingWorkflowService.generate(
            title: "会议闭环 2.0",
            attendees: ["小王", "小李"],
            notes: notes,
            now: fixedNow
        )

        XCTAssertEqual(workflow.source, .meetingNotes)
        XCTAssertEqual(workflow.attendees.map(\.name), ["小王", "小李"])
        XCTAssertFalse(workflow.preMeeting.agenda.isEmpty)
        XCTAssertTrue(workflow.preMeeting.agenda.contains { $0.title.contains("复核既有纪要") })
        XCTAssertEqual(workflow.inMeeting.summary, notes.summary)
        XCTAssertEqual(workflow.inMeeting.decisions.map(\.text), ["本周先发布独立 MVP"])
        XCTAssertEqual(workflow.inMeeting.actionItems.first?.owner, "小王")
        XCTAssertEqual(workflow.inMeeting.actionItems.first?.dueText, "2026-06-20")
        XCTAssertTrue(workflow.postMeeting.followUpDrafts.first?.body.contains("本周先发布独立 MVP") == true)
        XCTAssertTrue(workflow.postMeeting.followUpDrafts.first?.body.contains("补齐会议闭环测试") == true)
        XCTAssertTrue(workflow.postMeeting.reminderSuggestions.contains { $0.relatedActionID == workflow.inMeeting.actionItems.first?.id })
        XCTAssertTrue(workflow.postMeeting.trackingSummary.contains("1 个行动项待跟进"))
    }

    func testGenerateFromTranscriptExtractsDecisionRiskAndAction() {
        let transcript = """
        [00:05] 我:我们决定下周发布 MVP
        [00:20] 对方:风险是依赖接口延期，可能会阻塞验收
        [00:35] 我:行动项由小王负责在6月20日完成回归测试
        """

        let workflow = MeetingWorkflowService.generate(
            title: "发布计划会",
            attendees: ["小王", "小李"],
            transcript: transcript,
            now: fixedNow
        )

        XCTAssertEqual(workflow.source, .transcript)
        XCTAssertTrue(workflow.inMeeting.decisions.contains { $0.text.contains("决定下周发布 MVP") })
        XCTAssertTrue(workflow.inMeeting.risks.contains { $0.text.contains("依赖接口延期") && $0.level == .high })
        XCTAssertEqual(workflow.inMeeting.actionItems.first?.owner, "小王")
        XCTAssertEqual(workflow.inMeeting.actionItems.first?.dueText, "6月20日")
        XCTAssertTrue(workflow.postMeeting.followUpDrafts.first?.subject.contains("发布计划会") == true)
        XCTAssertTrue(workflow.postMeeting.reminderSuggestions.contains { $0.title.contains("补齐截止时间") })
    }

    func testManualWorkflowStillProvidesPreparationAndFollowUpScaffold() {
        let workflow = MeetingWorkflowService.generate(
            title: "   ",
            attendees: [],
            now: fixedNow
        )

        XCTAssertEqual(workflow.title, "未命名会议")
        XCTAssertEqual(workflow.source, .manual)
        XCTAssertFalse(workflow.preMeeting.preparationItems.isEmpty)
        XCTAssertFalse(workflow.inMeeting.captureHints.isEmpty)
        XCTAssertTrue(workflow.inMeeting.actionItems.isEmpty)
        XCTAssertTrue(workflow.postMeeting.followUpDrafts.first?.body.contains("暂无明确行动项") == true)
        XCTAssertTrue(workflow.postMeeting.reminderSuggestions.contains { $0.title.contains("补充行动项") })
    }

    func testWorkflowModelIsCodable() throws {
        let workflow = MeetingWorkflowService.generate(
            title: "编码验证",
            attendees: ["小王"],
            transcript: "决定使用结构化模型。行动项小王跟进测试。",
            now: fixedNow
        )

        let data = try JSONEncoder().encode(workflow)
        let decoded = try JSONDecoder().decode(MeetingWorkflow.self, from: data)

        XCTAssertEqual(decoded.title, workflow.title)
        XCTAssertEqual(decoded.source, workflow.source)
        XCTAssertEqual(decoded.preMeeting.agenda.count, workflow.preMeeting.agenda.count)
        XCTAssertEqual(decoded.inMeeting.actionItems.map(\.title), workflow.inMeeting.actionItems.map(\.title))
    }

    private var fixedNow: Date {
        ISO8601DateFormatter().date(from: "2026-06-16T12:00:00Z")!
    }
}
