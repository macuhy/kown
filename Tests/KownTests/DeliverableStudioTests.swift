import XCTest
@testable import Kown

final class DeliverableStudioTests: XCTestCase {
    func testGeneratesMarkdownWithMetadataAndBullets() {
        let deliverable = DeliverableStudioService.generate(
            title: "路线图",
            sourceKind: .research,
            targetKind: .markdown,
            sourceText: "# 发现\n连接器中心应优先落地。\nAgent 运行中心负责长任务治理。",
            audience: "团队",
            goal: "排优先级",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(deliverable.title, "路线图")
        XCTAssertEqual(deliverable.kind, .markdown)
        XCTAssertTrue(deliverable.content.contains("来源：研究"))
        XCTAssertTrue(deliverable.content.contains("连接器中心应优先落地"))
    }

    func testHTMLIsEscaped() {
        let deliverable = DeliverableStudioService.generate(
            title: "<script>",
            targetKind: .html,
            sourceText: "用户输入 <b>不要执行</b> & 保留文本"
        )

        XCTAssertTrue(deliverable.content.contains("&lt;script&gt;"))
        XCTAssertTrue(deliverable.content.contains("&lt;b&gt;不要执行&lt;/b&gt; &amp; 保留文本"))
        XCTAssertFalse(deliverable.content.contains("<b>不要执行</b>"))
    }

    func testOutlineKindsUseMarkdownExtension() {
        let pdf = DeliverableStudioService.generate(title: "报告", targetKind: .pdfOutline, sourceText: "素材")
        let ppt = DeliverableStudioService.generate(title: "演示", targetKind: .pptOutline, sourceText: "素材")

        XCTAssertEqual(pdf.suggestedFileName, "报告.md")
        XCTAssertEqual(ppt.suggestedFileName, "演示.md")
        XCTAssertTrue(pdf.content.contains("PDF 大纲"))
        XCTAssertTrue(ppt.content.contains("PPT 大纲"))
    }

    func testEmptySourceHasUsefulScaffold() {
        let deliverable = DeliverableStudioService.generate(title: "", sourceKind: .meeting, targetKind: .webpage, sourceText: "")

        XCTAssertEqual(deliverable.title, "会议交付物")
        XCTAssertTrue(deliverable.summary.contains("会议交付物"))
        XCTAssertTrue(deliverable.content.contains("补充背景和问题定义"))
    }
}
