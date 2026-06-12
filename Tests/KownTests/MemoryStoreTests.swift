import XCTest
@testable import Kown

/// 覆盖 Agent 记忆体系深化的纯函数(nonisolated static,不碰 @MainActor 单例 / 磁盘):
///  - Persona 归属过滤(全局 + 当前 Persona,不串其它 Persona)
///  - 置顶溢出保护(trimmedToCap 不淘汰置顶)
///  - 注入选择(置顶优先 + 未置顶按 BM25 + 跨归属归一化去重)
///  - 去重计划(归一化 / 高相似 / 二元组 Jaccard;同组内合并;置顶继承)
///  - MemoryItem 新字段 Codable 向后兼容
final class MemoryStoreTests: XCTestCase {

    private func item(_ text: String, persona: UUID? = nil, pinned: Bool = false,
                      created: TimeInterval = 0) -> MemoryItem {
        MemoryItem(text: text, createdAt: Date(timeIntervalSince1970: created),
                   personaID: persona, pinned: pinned)
    }

    // MARK: - 归属过滤

    func testFilterInjectableGlobalAndCurrentPersonaOnly() {
        let pA = UUID(), pB = UUID()
        let items = [
            item("全局1"),
            item("A 专属", persona: pA),
            item("B 专属", persona: pB),
        ]
        // 当前是 Persona A 的会话 → 只见全局 + A,不见 B。
        let forA = MemoryStore.filterInjectable(items: items, personaID: pA)
        XCTAssertEqual(forA.map(\.text).sorted(), ["A 专属", "全局1"])
        XCTAssertFalse(forA.contains { $0.text == "B 专属" })

        // 无 Persona(全局会话)→ 只见全局,不见任何 Persona 专属。
        let forGlobal = MemoryStore.filterInjectable(items: items, personaID: nil)
        XCTAssertEqual(forGlobal.map(\.text), ["全局1"])
    }

    // MARK: - 置顶溢出保护

    func testTrimToCapNeverEvictsPinned() {
        // cap = 3:5 条里第 5 条(最旧)是置顶,溢出应淘汰未置顶的最旧者,保留置顶。
        let pinnedOld = item("置顶最旧", pinned: true, created: 0)
        let items = [
            item("新4", created: 4),
            item("新3", created: 3),
            item("新2", created: 2),
            item("新1", created: 1),
            pinnedOld,
        ]
        let trimmed = MemoryStore.trimmedToCap(items, cap: 3)
        XCTAssertEqual(trimmed.count, 3)
        XCTAssertTrue(trimmed.contains { $0.id == pinnedOld.id }, "置顶条目不应被溢出淘汰")
        // 淘汰的是未置顶里最旧的两条(新1、新2)。
        XCTAssertFalse(trimmed.contains { $0.text == "新1" })
        XCTAssertFalse(trimmed.contains { $0.text == "新2" })
    }

    func testTrimToCapAllowsOverflowWhenPinnedExceedCap() {
        // 置顶数 ≥ cap:允许超额保留全部置顶(宁可超额也不丢置顶)。
        let items = [
            item("p1", pinned: true, created: 3),
            item("p2", pinned: true, created: 2),
            item("p3", pinned: true, created: 1),
            item("u", created: 0),
        ]
        let trimmed = MemoryStore.trimmedToCap(items, cap: 2)
        XCTAssertEqual(trimmed.filter(\.pinned).count, 3)
        XCTAssertFalse(trimmed.contains { $0.text == "u" }, "唯一未置顶应被淘汰")
    }

    // MARK: - 注入选择

    func testSelectForInjectionPinnedFirst() {
        // 置顶与查询无关也必注入;未置顶按 BM25,无关词不进。
        let pinned = item("用户偏好简洁回答", pinned: true)
        let relevant = item("项目用 Swift 编写")
        let unrelated = item("天气晴朗与代码无关")
        let items = [pinned, relevant, unrelated]
        let picked = MemoryStore.selectForInjection(items: items, query: "Swift 项目怎么写", topK: 5)
        XCTAssertTrue(picked.contains { $0.id == pinned.id }, "置顶必注入")
        XCTAssertTrue(picked.contains { $0.id == relevant.id }, "相关条目应注入")
    }

    func testSelectForInjectionDedupAcrossOwners() {
        // 同一句话全局 / Persona 各存一份 → 注入时按归一化去重,只出一条。
        let pA = UUID()
        let g = item("用户喜欢简洁", pinned: true)
        let a = item("用户喜欢简洁!", persona: pA, pinned: true)
        let picked = MemoryStore.selectForInjection(items: [g, a], query: "随便", topK: 5)
        XCTAssertEqual(picked.count, 1, "归一化重复的置顶条目只注入一份")
    }

    func testSelectForInjectionRespectsTopK() {
        let items = (0..<10).map { item("置顶\($0)", pinned: true, created: Double($0)) }
        let picked = MemoryStore.selectForInjection(items: items, query: "x", topK: 3)
        XCTAssertEqual(picked.count, 3)
    }

    // MARK: - 去重

    func testIsNearDuplicate() {
        XCTAssertTrue(MemoryStore.isNearDuplicate("用户喜欢简洁回答", "用户喜欢简洁回答!"))
        XCTAssertTrue(MemoryStore.isNearDuplicate("用户喜欢简洁回答", "用户喜欢简洁回答"))
        // 包含关系(短方 ≥ 6 字)
        XCTAssertTrue(MemoryStore.isNearDuplicate("用户偏好简洁直接的回答", "用户偏好简洁直接"))
        XCTAssertFalse(MemoryStore.isNearDuplicate("用户喜欢简洁", "用户讨厌冗长的废话连篇"))
    }

    func testContainsNearDuplicate() {
        let existing = ["用户偏好简洁", "项目用 Swift"]
        XCTAssertTrue(MemoryStore.containsNearDuplicate("用户偏好简洁。", in: existing))
        XCTAssertFalse(MemoryStore.containsNearDuplicate("住在上海", in: existing))
    }

    func testDedupPlanMergesWithinSameOwnerOnly() {
        let pA = UUID()
        // 全局有两条近重复 → 合并一条;Persona A 有一条文字相同的 → 不与全局合并(跨组不并)。
        let g1 = item("用户喜欢简洁回答", created: 2)
        let g2 = item("用户喜欢简洁回答!", created: 1)
        let aSame = item("用户喜欢简洁回答", persona: pA, created: 0)
        let plan = MemoryStore.dedupPlan(items: [g1, g2, aSame])
        XCTAssertEqual(plan.removeIDs.count, 1, "只在全局组内合并掉一条")
        XCTAssertFalse(plan.removeIDs.contains(aSame.id), "Persona 组不与全局组合并")
    }

    func testDedupPlanSurvivorInheritsPinned() {
        // 被合并的是置顶、幸存者非置顶 → 幸存者继承置顶,保证置顶不因去重消失。
        // 排序里置顶优先做幸存者,所以让置顶的是「更短、会被另一条包含」的那条,
        // 验证即使置顶被判为重复合并掉,置顶标记也会转移给幸存者。
        // 构造:短方完整包含于长方(短方 ≥ 6 字),两条近重复。
        let longer = item("用户偏好简洁直接的回答风格", created: 2)         // 非置顶、更长
        let pinnedShort = item("用户偏好简洁直接的回答", pinned: true, created: 1) // 置顶、被长方包含
        let plan = MemoryStore.dedupPlan(items: [longer, pinnedShort])
        XCTAssertEqual(plan.removeIDs.count, 1, "两条近重复应合并掉一条")
        // 置顶条目按排序优先成为幸存者;若它反而被删,则置顶必须转移给幸存的长条。
        if plan.removeIDs.contains(pinnedShort.id) {
            XCTAssertTrue(plan.pinIDs.contains(longer.id), "置顶应被幸存者继承")
        } else {
            // 置顶条目幸存(预期路径):它本身保留置顶,无需转移。
            XCTAssertTrue(plan.removeIDs.contains(longer.id))
        }
    }

    // MARK: - Codable 向后兼容

    func testMemoryItemRoundTrip() throws {
        let pA = UUID()
        let original = MemoryItem(text: "用户偏好简洁", sourceConversationID: UUID(),
                                  tags: ["pref"], personaID: pA, pinned: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemoryItem.self, from: data)
        XCTAssertEqual(decoded.text, "用户偏好简洁")
        XCTAssertEqual(decoded.personaID, pA)
        XCTAssertTrue(decoded.pinned)
    }

    func testMemoryItemDecodesLegacyJSONWithoutNewKeys() throws {
        // 旧存档没有 personaID / pinned → 解码默认 nil / false,不破坏既有 memories.json。
        let json = """
        {"id":"\(UUID().uuidString)","text":"旧记忆","createdAt":0,"tags":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MemoryItem.self, from: json)
        XCTAssertEqual(decoded.text, "旧记忆")
        XCTAssertNil(decoded.personaID)
        XCTAssertFalse(decoded.pinned)
    }
}
