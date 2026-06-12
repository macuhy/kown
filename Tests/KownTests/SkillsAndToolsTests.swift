import XCTest
@testable import Kown

/// 覆盖 Skills 自动触发路由、技能 {{变量}} 渲染、ToolCatalog 工具组合,以及 ToolRouter 的 ISO 时间解析。
final class SkillsAndToolsTests: XCTestCase {

    // MARK: - SkillRouter.match

    private func skill(_ name: String, keywords: [String], tools: [String] = [], enabled: Bool = true) -> Skill {
        Skill(name: name, instructions: "x", keywords: keywords, allowedTools: tools, enabled: enabled)
    }

    func testMatchPicksKeywordHit() {
        let skills = [
            skill("提醒助手", keywords: ["提醒", "别忘"]),
            skill("翻译官", keywords: ["翻译"]),
        ]
        let hit = SkillRouter.match(prompt: "明天别忘了交报告", skills: skills)
        XCTAssertEqual(hit?.name, "提醒助手")
    }

    func testMatchPrefersMoreHits() {
        let skills = [
            skill("少命中", keywords: ["报告"]),
            skill("多命中", keywords: ["报告", "明天", "交"]),
        ]
        let hit = SkillRouter.match(prompt: "明天交报告", skills: skills)
        XCTAssertEqual(hit?.name, "多命中", "命中更多关键词的技能得分更高")
    }

    func testMatchReturnsNilWhenNoKeyword() {
        let skills = [skill("提醒助手", keywords: ["提醒"])]
        XCTAssertNil(SkillRouter.match(prompt: "随便聊聊天气", skills: skills))
    }

    func testMatchSkipsDisabledSkills() {
        let skills = [skill("提醒助手", keywords: ["提醒"], enabled: false)]
        XCTAssertNil(SkillRouter.match(prompt: "提醒我喝水", skills: skills),
                     "禁用的技能不参与自动触发")
    }

    func testMatchEmptyPromptReturnsNil() {
        let skills = [skill("提醒助手", keywords: ["提醒"])]
        XCTAssertNil(SkillRouter.match(prompt: "   ", skills: skills))
    }

    // MARK: - SkillsStore 渲染 / 持久化

    @MainActor
    func testRenderFillsVariables() {
        let store = SkillsStore()
        let s = Skill(name: "t", instructions: "把 {{原文}} 翻译成 {{语言}}")
        let out = store.render(s, values: ["原文": "hello", "语言": "中文"])
        XCTAssertEqual(out, "把 hello 翻译成 中文")
    }

    @MainActor
    func testRenderLeavesUnknownVariableUntouched() {
        let store = SkillsStore()
        let s = Skill(name: "t", instructions: "你好 {{名字}}")
        XCTAssertEqual(store.render(s, values: [:]), "你好 {{名字}}")
    }

    func testSkillCodableRoundTrip() throws {
        let s = Skill(name: "提醒助手", summary: "记提醒", instructions: "do it",
                      keywords: ["提醒"], allowedTools: ["create_reminder"], isPreset: true)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Skill.self, from: data)
        XCTAssertEqual(back, s)
    }

    func testVariableNamesDeduped() {
        let s = Skill(name: "t", instructions: "{{a}} 和 {{a}} 还有 {{b}}")
        XCTAssertEqual(s.variableNames, ["a", "b"])
    }

    // MARK: - 触发短语:Codable 容错 / 路由命中 / 解析

    func testSkillTriggerPhrasesCodableRoundTrip() throws {
        let s = Skill(name: "t", instructions: "x",
                      keywords: ["提醒"], triggerPhrases: ["到点叫我", "别让我忘"])
        let back = try JSONDecoder().decode(Skill.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.triggerPhrases, ["到点叫我", "别让我忘"])
    }

    func testSkillDecodesMissingTriggerPhrasesAsEmpty() throws {
        // 旧数据没有 triggerPhrases 字段 → decodeIfPresent 解空数组,不崩。
        let json = #"{"id":"\#(UUID().uuidString)","name":"老技能","instructions":"x"}"#
        let s = try JSONDecoder().decode(Skill.self, from: Data(json.utf8))
        XCTAssertEqual(s.triggerPhrases, [])
        XCTAssertTrue(s.enabled)       // enabled 缺省 true
        XCTAssertEqual(s.keywords, [])
    }

    func testRouterMatchesViaTriggerPhrase() {
        // 关键词没命中,但自动生成的同义触发说法命中也能触发。
        let s = Skill(name: "备忘", instructions: "x",
                      keywords: ["备忘录"], triggerPhrases: ["帮我记一下"])
        let hit = SkillRouter.match(prompt: "帮我记一下这个网址", skills: [s])
        XCTAssertEqual(hit?.name, "备忘")
    }

    func testKeywordOutweighsTriggerPhrase() {
        // 同时命中:显式关键词权重(1.0)高于自动触发说法(0.8),关键词技能胜出。
        let kw = Skill(name: "关键词", instructions: "x", keywords: ["报告"])
        let phrase = Skill(name: "触发说法", instructions: "x", keywords: [], triggerPhrases: ["报告"])
        let hit = SkillRouter.match(prompt: "交报告", skills: [kw, phrase])
        XCTAssertEqual(hit?.name, "关键词")
    }

    func testParsePhrasesCleansAndDedups() {
        let raw = #"```json ["到点叫我", " 到点叫我 ", "", "别忘了", "提醒"] ```"#
        let out = SkillTriggerSynthesizer.parsePhrases(raw, existingKeywords: ["提醒"])
        // trim 后去重("到点叫我"两次留一)、去空、去掉与已有关键词重复的("提醒")。
        XCTAssertEqual(out, ["到点叫我", "别忘了"])
    }

    func testParsePhrasesCapsAtMax() {
        let many = (1...30).map { "短语\($0)" }
        let raw = (try? String(data: JSONEncoder().encode(many), encoding: .utf8)) ?? "[]"
        let out = SkillTriggerSynthesizer.parsePhrases(raw, existingKeywords: [])
        XCTAssertEqual(out?.count, SkillTriggerSynthesizer.maxPhrases)
    }

    func testParsePhrasesFailureReturnsNil() {
        XCTAssertNil(SkillTriggerSynthesizer.parsePhrases("没有数组", existingKeywords: []))
        XCTAssertNil(SkillTriggerSynthesizer.parsePhrases("[]", existingKeywords: []))
        XCTAssertNil(SkillTriggerSynthesizer.parsePhrases(#"["提醒"]"#, existingKeywords: ["提醒"]),
                     "全部与已有关键词重复 → 无新增 → nil")
    }

    @MainActor
    func testTriggerSynthesisSkippedUnderTest() async {
        // 测试不得依赖网络:synthesize 在 XCTest 下一律返回 nil。
        let s = Skill(name: "备忘", summary: "记一下", instructions: "x", keywords: ["备忘"])
        let out = await SkillTriggerSynthesizer.synthesize(for: s)
        XCTAssertNil(out)
    }

    // MARK: - ToolCatalog.enabledTools 组合

    func testNoToolsWhenAllOff() {
        let tools = ToolCatalog.enabledTools(webSearch: nil, deviceTools: false, extraToolNames: [])
        XCTAssertTrue(tools.isEmpty)
    }

    func testDeviceToggleExposesReminderAndNote() {
        let tools = ToolCatalog.enabledTools(webSearch: nil, deviceTools: true, extraToolNames: [])
        let names = Set(tools.map(\.name))
        XCTAssertTrue(names.contains("create_reminder"))
        XCTAssertTrue(names.contains("list_reminders"))
        XCTAssertTrue(names.contains("create_note"))
        XCTAssertFalse(names.contains(ToolCatalog.webSearch.name), "未配置 Firecrawl 不应暴露联网搜索工具")
    }

    func testSkillExtraToolNameExposesToolWithoutGlobalToggle() {
        let tools = ToolCatalog.enabledTools(webSearch: nil, deviceTools: false,
                                             extraToolNames: ["create_reminder"])
        let names = Set(tools.map(\.name))
        XCTAssertEqual(names, ["create_reminder"], "技能点名的工具应在总开关关闭时也暴露")
    }

    // MARK: - ToolRouter.parseDate

    func testParseISODateWithoutZone() {
        let d = ToolRouter.parseDate("2026-06-07T09:00:00")
        XCTAssertNotNil(d)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: d!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 7)
        XCTAssertEqual(comps.hour, 9)
    }

    func testParseDateOnly() {
        XCTAssertNotNil(ToolRouter.parseDate("2026-12-31"))
    }

    func testParseDateRejectsGarbage() {
        XCTAssertNil(ToolRouter.parseDate("not a date"))
        XCTAssertNil(ToolRouter.parseDate(""))
    }
}
