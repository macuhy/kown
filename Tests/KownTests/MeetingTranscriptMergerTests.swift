import XCTest
@testable import Kown

/// 覆盖会议双轨时间线合并(纯函数 `MeetingTranscriptMerger`):
/// 乱序时间戳排序、说话人标注保持、相邻同说话人折叠、清洗、渲染。
final class MeetingTranscriptMergerTests: XCTestCase {

    private func u(_ speaker: MeetingUtterance.Speaker, _ text: String,
                   _ start: TimeInterval, _ end: TimeInterval) -> MeetingUtterance {
        MeetingUtterance(speaker: speaker, text: text, start: start, end: end)
    }

    // MARK: - 排序

    func testMergeSortsByStartTimeAcrossTracks() {
        let mine = [u(.me, "我先说", 5, 7)]
        let theirs = [u(.them, "对方先说", 1, 3)]
        let merged = MeetingTranscriptMerger.merge(mine: mine, theirs: theirs)
        XCTAssertEqual(merged.map(\.text), ["对方先说", "我先说"])
        XCTAssertEqual(merged.map(\.speaker), [.them, .me])
    }

    func testMergeHandlesOutOfOrderInputWithinTrack() {
        // 同一轨内乱序(start 不单调)也要排好。用足够大的间隔避免被折叠。
        let mine = [
            u(.me, "第三句", 20, 21),
            u(.me, "第一句", 0, 1),
            u(.me, "第二句", 10, 11),
        ]
        let merged = MeetingTranscriptMerger.merge(mine: mine, theirs: [])
        XCTAssertEqual(merged.map(\.text), ["第一句", "第二句", "第三句"])
    }

    func testSpeakerLabelsPreservedAfterSort() {
        let mine = [u(.me, "A", 0, 1), u(.me, "C", 30, 31)]
        let theirs = [u(.them, "B", 15, 16)]
        let merged = MeetingTranscriptMerger.merge(mine: mine, theirs: theirs)
        XCTAssertEqual(merged.map(\.speaker), [.me, .them, .me])
        XCTAssertEqual(merged.map(\.text), ["A", "B", "C"])
    }

    // MARK: - 折叠

    func testCollapsesAdjacentSameSpeakerWithinGap() {
        // 同说话人、间隔 ≤ defaultCollapseGap(2s)→ 折叠成一条。
        let mine = [
            u(.me, "你好", 0, 1),
            u(.me, "今天开会", 2, 4),   // 2 - 1 = 1s ≤ 2s
        ]
        let merged = MeetingTranscriptMerger.merge(mine: mine, theirs: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 4)
        XCTAssertTrue(merged[0].text.contains("你好"))
        XCTAssertTrue(merged[0].text.contains("今天开会"))
    }

    func testDoesNotCollapseWhenGapTooLarge() {
        let mine = [
            u(.me, "你好", 0, 1),
            u(.me, "稍后再说", 10, 11),  // 间隔 9s > 2s
        ]
        let merged = MeetingTranscriptMerger.merge(mine: mine, theirs: [])
        XCTAssertEqual(merged.count, 2)
    }

    func testDoesNotCollapseDifferentSpeakers() {
        let mine = [u(.me, "你好", 0, 1)]
        let theirs = [u(.them, "你好", 1, 2)]  // 紧挨着但不同说话人
        let merged = MeetingTranscriptMerger.merge(mine: mine, theirs: theirs)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.speaker), [.me, .them])
    }

    func testInterleavedSpeakersNotCollapsed() {
        let mine = [u(.me, "问题一", 0, 2), u(.me, "问题二", 6, 8)]
        let theirs = [u(.them, "回答一", 3, 5)]
        let merged = MeetingTranscriptMerger.merge(mine: mine, theirs: theirs)
        // 我-对方-我 交错,不应被折叠。
        XCTAssertEqual(merged.map(\.speaker), [.me, .them, .me])
        XCTAssertEqual(merged.count, 3)
    }

    // MARK: - 清洗

    func testNormalizeDropsEmptyText() {
        let mine = [u(.me, "   ", 0, 1), u(.me, "有内容", 2, 3)]
        let merged = MeetingTranscriptMerger.merge(mine: mine, theirs: [])
        XCTAssertEqual(merged.map(\.text), ["有内容"])
    }

    func testNormalizeClampsIllegalTimes() {
        let weird = MeetingUtterance(speaker: .me, text: "x", start: -5, end: -10)
        let n = MeetingTranscriptMerger.normalize(weird)
        XCTAssertNotNil(n)
        XCTAssertEqual(n?.start, 0)
        XCTAssertEqual(n?.end, 0)
    }

    func testNormalizeTrimsWhitespace() {
        let n = MeetingTranscriptMerger.normalize(u(.them, "  你好  ", 1, 2))
        XCTAssertEqual(n?.text, "你好")
    }

    // MARK: - 渲染

    func testRenderTranscriptFormat() {
        let merged = [
            u(.me, "大家好", 5, 6),
            u(.them, "好的开始吧", 12, 14),
        ]
        let rendered = MeetingTranscriptMerger.renderTranscript(merged)
        XCTAssertEqual(rendered, "[00:05] 我:大家好\n[00:12] 对方:好的开始吧")
    }

    func testTimestampLabelHoursFormat() {
        XCTAssertEqual(MeetingTranscriptMerger.timestampLabel(0), "00:00")
        XCTAssertEqual(MeetingTranscriptMerger.timestampLabel(65), "01:05")
        XCTAssertEqual(MeetingTranscriptMerger.timestampLabel(3661), "1:01:01")
        XCTAssertEqual(MeetingTranscriptMerger.timestampLabel(-3), "00:00")
    }

    func testJoinedTextPunctuation() {
        // 前段没标点 → 补逗号;有标点 → 直接续。
        XCTAssertEqual(MeetingTranscriptMerger.joinedText("你好", "再见"), "你好,再见")
        XCTAssertEqual(MeetingTranscriptMerger.joinedText("你好。", "再见"), "你好。再见")
        XCTAssertEqual(MeetingTranscriptMerger.joinedText("", "再见"), "再见")
        XCTAssertEqual(MeetingTranscriptMerger.joinedText("你好", ""), "你好")
    }

    // MARK: - 综合

    func testFullMergeScenario() {
        // 乱序、跨轨、含碎气泡折叠的综合场景。
        let mine = [
            u(.me, "我们开始吧", 0, 2),
            u(.me, "对的", 3, 4),          // 与上一条间隔 1s → 折叠
        ]
        let theirs = [
            u(.them, "稍等一下", 8, 10),
            u(.them, "好了", 11, 12),       // 折叠
            u(.them, "  ", 13, 14),         // 空 → 丢弃
        ]
        let merged = MeetingTranscriptMerger.merge(mine: mine, theirs: theirs)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].speaker, .me)
        XCTAssertEqual(merged[1].speaker, .them)
        XCTAssertTrue(merged[0].text.contains("我们开始吧"))
        XCTAssertTrue(merged[0].text.contains("对的"))
        XCTAssertTrue(merged[1].text.contains("稍等一下"))
        XCTAssertTrue(merged[1].text.contains("好了"))
    }
}
