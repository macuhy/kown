import XCTest
@testable import Kown

/// 隐私脱敏(PIIRedactor):区间合并(NER × 正则)、占位符 ↔ 还原 roundtrip、类别开关。
///
/// 依赖 NLTagger 真实识别的端到端用例都带「探活 skip」:先用 `detectEntities` 在同形输入上
/// 探一次,本机系统语言模型识别不出就 `XCTSkip`(不同 OS 版本 NER 行为有差异,避免假红)。
/// 区间合并 / roundtrip / 开关语义本身全部用确定性输入,不依赖 NER 行为。
final class PIIRedactorTests: XCTestCase {

    // MARK: - 工具

    private func hit(_ loc: Int, _ len: Int,
                     _ cat: PIIRedactor.Category,
                     _ src: PIIRedactor.Hit.Source) -> PIIRedactor.Hit {
        .init(range: NSRange(location: loc, length: len), category: cat, source: src)
    }

    /// 全开(除 NER 外按需)的设置。
    private func settings(phone: Bool = false, email: Bool = false,
                          idCard: Bool = false, bank: Bool = false,
                          name: Bool = false, place: Bool = false,
                          org: Bool = false) -> PIIRedactor.Settings {
        .init(enabled: true, phone: phone, email: email, idCard: idCard,
              bank: bank, name: name, place: place, org: org)
    }

    /// NER 探活:本机 NLTagger 识别不出给定输入里的实体时跳过(调用处 `try`)。
    private func skipUnlessNER(_ text: String, name: Bool = true, place: Bool = false,
                               org: Bool = false, atLeast: Int = 1) throws {
        let found = PIIRedactor.detectEntities(text, name: name, place: place, org: org)
        try XCTSkipIf(found.count < atLeast,
                      "本机 NLTagger 未识别出「\(text)」里的实体(\(found.count)/\(atLeast)),跳过 NER 端到端用例")
    }

    // MARK: - 区间合并:NER × 正则

    func testMergeNERPartialOverlapRegexUnionKeepsRegexType() {
        // NER (5,10) 与正则电话 (10,8) 交叠 → 并集 (5,13),类别 / 来源都保留正则。
        let merged = PIIRedactor.mergeHits([
            hit(10, 8, .phone, .regex),
            hit(5, 10, .name, .ner)
        ])
        XCTAssertEqual(merged, [hit(5, 13, .phone, .regex)])
    }

    func testMergeNERNestedInsideRegexKeepsRegexRange() {
        // NER 完全嵌在正则邮箱内 → 并集就是正则区间,原样保留。
        let merged = PIIRedactor.mergeHits([
            hit(10, 10, .email, .regex),
            hit(12, 3, .name, .ner)
        ])
        XCTAssertEqual(merged, [hit(10, 10, .email, .regex)])
    }

    func testMergeRegexNestedInsideNERExpandsToNERRangeKeepsRegexType() {
        // 正则电话嵌在更大的 NER 区间里 → 区间取 NER 的并集,类别仍是正则(更确定)。
        let merged = PIIRedactor.mergeHits([
            hit(12, 3, .phone, .regex),
            hit(10, 10, .name, .ner)
        ])
        XCTAssertEqual(merged, [hit(10, 10, .phone, .regex)])
    }

    func testMergeNERBridgesTwoRegexHits() {
        // 一个 NER 横跨电话 + 邮箱两个正则命中 → 桥接成一个,类别取结构化优先级更高的邮箱。
        let merged = PIIRedactor.mergeHits([
            hit(0, 5, .phone, .regex),
            hit(10, 5, .email, .regex),
            hit(3, 9, .name, .ner)
        ])
        XCTAssertEqual(merged, [hit(0, 15, .email, .regex)])
    }

    func testMergeRegexRegexOverlapKeepsStrongerNoUnion() {
        // 正则 × 正则重叠:身份证 > 电话,弱者整个丢弃、区间不扩(保持旧串行管线语义)。
        let merged = PIIRedactor.mergeHits([
            hit(5, 11, .phone, .regex),
            hit(0, 18, .idCard, .regex)
        ])
        XCTAssertEqual(merged, [hit(0, 18, .idCard, .regex)])
    }

    func testMergeNERNEROverlapUnionLongerTypeWins() {
        // NER × NER 重叠:并集,类别取更长的那个(上下文更完整)。
        let merged = PIIRedactor.mergeHits([
            hit(0, 5, .name, .ner),
            hit(3, 6, .place, .ner)
        ])
        XCTAssertEqual(merged, [hit(0, 9, .place, .ner)])
    }

    // MARK: - 区间合并:相邻

    func testMergeAdjacentSameCategoryJoined() {
        // NLTagger 偶尔把中文姓名拆成相邻单字 token → 相邻同类合并。
        let merged = PIIRedactor.mergeHits([
            hit(0, 3, .name, .ner),
            hit(3, 2, .name, .ner)
        ])
        XCTAssertEqual(merged, [hit(0, 5, .name, .ner)])
    }

    func testMergeAdjacentChainJoined() {
        let merged = PIIRedactor.mergeHits([
            hit(4, 2, .name, .ner),
            hit(0, 2, .name, .ner),
            hit(2, 2, .name, .ner)
        ])
        XCTAssertEqual(merged, [hit(0, 6, .name, .ner)])
    }

    func testMergeAdjacentDifferentCategoryNotJoined() {
        let merged = PIIRedactor.mergeHits([
            hit(0, 3, .name, .ner),
            hit(3, 2, .place, .ner)
        ])
        XCTAssertEqual(merged, [hit(0, 3, .name, .ner), hit(3, 2, .place, .ner)])
    }

    func testMergeAdjacentPromotesRegexSource() {
        // 相邻同类、一边是正则 → 合并结果标记为正则(更确定的来源)。
        let merged = PIIRedactor.mergeHits([
            hit(0, 3, .phone, .ner),     // 合成输入:真实 NER 不产电话,这里只验证合并机制
            hit(3, 4, .phone, .regex)
        ])
        XCTAssertEqual(merged, [hit(0, 7, .phone, .regex)])
    }

    // MARK: - 区间合并:杂项

    func testMergeDisjointSortedAscending() {
        let merged = PIIRedactor.mergeHits([
            hit(20, 3, .phone, .regex),
            hit(0, 5, .email, .regex),
            hit(10, 2, .name, .ner)
        ])
        XCTAssertEqual(merged, [hit(0, 5, .email, .regex),
                                hit(10, 2, .name, .ner),
                                hit(20, 3, .phone, .regex)])
    }

    func testMergeFiltersInvalidRanges() {
        let merged = PIIRedactor.mergeHits([
            .init(range: NSRange(location: NSNotFound, length: 3), category: .name, source: .ner),
            hit(5, 0, .phone, .regex)
        ])
        XCTAssertTrue(merged.isEmpty)
    }

    func testMergeEmptyAndSinglePassthrough() {
        XCTAssertTrue(PIIRedactor.mergeHits([]).isEmpty)
        XCTAssertEqual(PIIRedactor.mergeHits([hit(2, 4, .email, .regex)]),
                       [hit(2, 4, .email, .regex)])
    }

    // MARK: - 正则脱敏 + 还原 roundtrip(确定性,不依赖 NER)

    func testRedactRegexCategoriesRoundtrip() {
        let original = "联系 13812345678 或 zhang.wei@example.com,证件 11010519491231002X,卡号 4111111111111111。"
        let (redacted, map) = PIIRedactor.redact(original,
                                                 settings: settings(phone: true, email: true,
                                                                    idCard: true, bank: true))
        XCTAssertTrue(redacted.contains("[电话1]"))
        XCTAssertTrue(redacted.contains("[邮箱1]"))
        XCTAssertTrue(redacted.contains("[身份证1]"))
        XCTAssertTrue(redacted.contains("[银行卡1]"))
        XCTAssertFalse(redacted.contains("13812345678"))
        XCTAssertFalse(redacted.contains("zhang.wei@example.com"))
        XCTAssertEqual(PIIRedactor.restore(redacted, map: map), original)
    }

    func testRedactSameOriginalReusesPlaceholder() {
        let original = "先打 13812345678,占线再打 13812345678。"
        let (redacted, map) = PIIRedactor.redact(original, settings: settings(phone: true))
        XCTAssertEqual(redacted.components(separatedBy: "[电话1]").count - 1, 2)
        XCTAssertFalse(redacted.contains("[电话2]"))
        XCTAssertEqual(map.placeholderToOriginal.count, 1)
        XCTAssertEqual(PIIRedactor.restore(redacted, map: map), original)
    }

    func testRedactCounterContinuesAcrossSharedMap() {
        // 同一份 map 跨多段复用(prompt → system → 历史):编号接续不重号。
        let s = settings(phone: true)
        let first = PIIRedactor.redact("我的电话 13812345678", settings: s)
        XCTAssertTrue(first.text.contains("[电话1]"))
        let second = PIIRedactor.redact("备用电话 13900000000", settings: s, map: first.map)
        XCTAssertTrue(second.text.contains("[电话2]"))
        XCTAssertEqual(second.map.placeholderToOriginal.count, 2)
        // 两段各自还原都正确。
        XCTAssertEqual(PIIRedactor.restore(second.text, map: second.map), "备用电话 13900000000")
    }

    func testRegexCategoryToggle() {
        let original = "电话 13812345678,邮箱 a@b.com。"
        let (redacted, map) = PIIRedactor.redact(original, settings: settings(phone: true, email: false))
        XCTAssertTrue(redacted.contains("[电话1]"))
        XCTAssertTrue(redacted.contains("a@b.com"), "邮箱开关关着,不该被脱敏")
        XCTAssertEqual(PIIRedactor.restore(redacted, map: map), original)
    }

    func testInactivePassthrough() {
        let original = "电话 13812345678"
        // 总开关关。
        var s = settings(phone: true); s.enabled = false
        var out = PIIRedactor.redact(original, settings: s)
        XCTAssertEqual(out.text, original)
        XCTAssertTrue(out.map.isEmpty)
        // 总开关开但所有类别全关。
        out = PIIRedactor.redact(original, settings: settings())
        XCTAssertEqual(out.text, original)
        XCTAssertTrue(out.map.isEmpty)
    }

    // MARK: - Settings:NER 类别开关与缺省

    func testSettingsDefaultsPlaceOrgOff() {
        // 老构造点不传 place/org → 视为关闭(memberwise 默认值)。
        let s = PIIRedactor.Settings(enabled: true, phone: true, email: true,
                                     idCard: true, bank: true, name: true)
        XCTAssertFalse(s.place)
        XCTAssertFalse(s.org)
        XCTAssertTrue(s.anyNEROn)
        XCTAssertTrue(s.active)
    }

    func testSettingsAnyNEROnCombinations() {
        XCTAssertFalse(settings(phone: true).anyNEROn)
        XCTAssertTrue(settings(name: true).anyNEROn)
        XCTAssertTrue(settings(place: true).anyNEROn)
        XCTAssertTrue(settings(org: true).anyNEROn)
        // NER 全关时 anyCategoryOn 仍可由正则类别撑起。
        XCTAssertTrue(settings(phone: true).anyCategoryOn)
        XCTAssertFalse(settings().anyCategoryOn)
    }

    func testPlaceOrgOffProducesNoPlaceholders() {
        // 开关语义:place/org 关闭时,无论 NLTagger 识别出什么都不产生对应占位符(确定性,不依赖 NER 行为)。
        let original = "我下周去北京出差,客户在阿里巴巴。"
        let (redacted, _) = PIIRedactor.redact(original, settings: settings(name: true))
        XCTAssertFalse(redacted.contains("[地名"))
        XCTAssertFalse(redacted.contains("[机构名"))
        XCTAssertTrue(redacted.contains("北京"), "地名开关关着,北京应原样保留")
    }

    // MARK: - NER 端到端(依赖本机 NLTagger,探活不中则跳过)

    func testNEREnglishNameRoundtrip() throws {
        try skipUnlessNER("Please email John Smith about the report.")
        let original = "Please email John Smith at john.smith@example.com."
        let (redacted, map) = PIIRedactor.redact(original, settings: settings(email: true, name: true))
        XCTAssertTrue(redacted.contains("[人名1]"), "实际输出:\(redacted)")
        XCTAssertTrue(redacted.contains("[邮箱1]"))
        XCTAssertFalse(redacted.contains("John Smith"))
        XCTAssertEqual(PIIRedactor.restore(redacted, map: map), original)
    }

    func testNERChineseNameWithPhoneRoundtrip() throws {
        try skipUnlessNER("帮我把合同发给张伟,他明天出差。")
        let original = "帮我把合同发给张伟,他的电话是13812345678,谢谢。"
        let (redacted, map) = PIIRedactor.redact(original, settings: settings(phone: true, name: true))
        XCTAssertTrue(redacted.contains("[人名1]"), "实际输出:\(redacted)")
        XCTAssertTrue(redacted.contains("[电话1]"))
        XCTAssertFalse(redacted.contains("张伟"))
        XCTAssertFalse(redacted.contains("13812345678"))
        XCTAssertEqual(PIIRedactor.restore(redacted, map: map), original)
    }

    func testNERSurvivesEmbeddedEmailViaMasking() throws {
        // 设计动机:句中夹长邮箱会让 NLTagger 整句失灵;redact 先把正则命中等长遮蔽再跑 NER。
        // 探活用「邮箱已遮蔽」的同形输入(等长空格),与 redact 内部喂给 NER 的文本一致。
        let original = "把方案发给刘强东和马云,抄送 john.smith@example.com,谢谢。"
        let maskedProbe = original.replacingOccurrences(of: "john.smith@example.com",
                                                        with: String(repeating: " ", count: 22))
        try skipUnlessNER(maskedProbe, atLeast: 2)
        let (redacted, map) = PIIRedactor.redact(original, settings: settings(email: true, name: true))
        XCTAssertTrue(redacted.contains("[人名1]"), "实际输出:\(redacted)")
        XCTAssertTrue(redacted.contains("[人名2]"))
        XCTAssertTrue(redacted.contains("[邮箱1]"))
        XCTAssertFalse(redacted.contains("刘强东"))
        XCTAssertFalse(redacted.contains("马云"))
        XCTAssertEqual(PIIRedactor.restore(redacted, map: map), original)
    }

    func testNERPlaceToggleOnRedactsPlace() throws {
        // 注:NLTagger 对孤句「我下周去北京出差。」识别不出地名,长句才出 —— 这正是地名默认关的原因之一。
        let original = "我下周去北京出差,顺便到上海见客户,再回深圳。"
        try skipUnlessNER(original, name: false, place: true)
        let (redacted, map) = PIIRedactor.redact(original, settings: settings(place: true))
        XCTAssertTrue(redacted.contains("[地名1]"), "实际输出:\(redacted)")
        XCTAssertFalse(redacted.contains("北京"))
        XCTAssertEqual(PIIRedactor.restore(redacted, map: map), original)
    }

    func testNEROrgToggleOnRedactsOrg() throws {
        // 注:同上,孤句「我在阿里巴巴工作。」识别不出;且本句里腾讯 / 字节跳动漏报是已知现状,
        // 只断言识别出的部分被正确替换 + roundtrip 不破。
        let original = "我在阿里巴巴工作,之前在腾讯,客户是字节跳动。"
        try skipUnlessNER(original, name: false, org: true)
        let (redacted, map) = PIIRedactor.redact(original, settings: settings(org: true))
        XCTAssertTrue(redacted.contains("[机构名1]"), "实际输出:\(redacted)")
        XCTAssertFalse(redacted.contains("阿里巴巴"))
        XCTAssertEqual(PIIRedactor.restore(redacted, map: map), original)
    }

    func testNERNameOnPlaceOffMixedSentence() throws {
        try skipUnlessNER("帮我把合同发给张伟,他明天出差。")
        let original = "张伟明天从北京出发。"
        let (redacted, map) = PIIRedactor.redact(original, settings: settings(name: true))
        XCTAssertFalse(redacted.contains("张伟"), "实际输出:\(redacted)")
        XCTAssertTrue(redacted.contains("[人名1]"))
        XCTAssertFalse(redacted.contains("[地名"))
        XCTAssertEqual(PIIRedactor.restore(redacted, map: map), original)
    }

    // MARK: - 流式还原(NER 占位符跨 chunk)

    func testStreamingRestorerSplitsNERPlaceholderAcrossChunks() {
        var map = PIIRedactor.RedactionMap()
        var counter = 0
        let ph = map.placeholder(for: "张伟", category: .name, counter: &counter)
        XCTAssertEqual(ph, "[人名1]")

        let restorer = PIIRedactor.StreamingRestorer(map: map)
        var out = restorer.push("你好,[人")
        out += restorer.push("名1],再见")
        out += restorer.flush()
        XCTAssertEqual(out, "你好,张伟,再见")
    }

    func testStreamingRestorerLeavesUnknownPlaceholderAlone() {
        var map = PIIRedactor.RedactionMap()
        var counter = 0
        _ = map.placeholder(for: "张伟", category: .name, counter: &counter)

        let restorer = PIIRedactor.StreamingRestorer(map: map)
        let text = "下标 [人名9] 不在映射里。"
        let out = restorer.push(text) + restorer.flush()
        XCTAssertEqual(out, text)
    }

    func testRestoreMixedCategoriesIncludingNER() {
        var map = PIIRedactor.RedactionMap()
        var nameCnt = 0, phoneCnt = 0, placeCnt = 0
        _ = map.placeholder(for: "张伟", category: .name, counter: &nameCnt)
        _ = map.placeholder(for: "13812345678", category: .phone, counter: &phoneCnt)
        _ = map.placeholder(for: "北京", category: .place, counter: &placeCnt)
        let restored = PIIRedactor.restore("[人名1]在[地名1],电话[电话1]。", map: map)
        XCTAssertEqual(restored, "张伟在北京,电话13812345678。")
    }
}
