import XCTest
@testable import Kown

/// 覆盖「按胜率推荐 Council 阵容」的纯函数排序 / 阈值 / 映射过滤逻辑。
final class CouncilRecommenderTests: XCTestCase {

    private func standing(_ kind: String, _ model: String, w: Int, l: Int, d: Int = 0) -> CouncilRecommender.StandingInput {
        let decisive = w + l
        let rate = decisive == 0 ? 0 : Double(w) / Double(decisive)
        return .init(providerKindRaw: kind, model: model, winRate: rate, wins: w, losses: l, draws: d)
    }

    private func candidate(_ id: UUID, _ name: String, _ kind: String, _ model: String, known: [String] = []) -> CouncilRecommender.ProviderCandidate {
        .init(id: id, displayName: name, kindRaw: kind, model: model, knownModels: known.isEmpty ? [model] : known)
    }

    func testSortsByWinRateThenMatches() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let standings = [
            standing("openAICompatible", "m-a", w: 3, l: 3),   // 50%, 6 场
            standing("openAICompatible", "m-b", w: 6, l: 1),   // 85.7%, 7 场
            standing("openAICompatible", "m-c", w: 5, l: 0),   // 100%, 5 场
        ]
        let candidates = [
            candidate(a, "A", "openAICompatible", "m-a"),
            candidate(b, "B", "openAICompatible", "m-b"),
            candidate(c, "C", "openAICompatible", "m-c"),
        ]
        let recs = CouncilRecommender.recommend(standings: standings, candidates: candidates, limit: 4)
        XCTAssertEqual(recs.map { $0.model }, ["m-c", "m-b", "m-a"])  // 胜率降序
    }

    func testFiltersBelowSampleThreshold() {
        let a = UUID()
        let standings = [
            standing("openAICompatible", "m-a", w: 2, l: 1),   // 仅 3 场 < 5,过滤掉
        ]
        let candidates = [candidate(a, "A", "openAICompatible", "m-a")]
        let recs = CouncilRecommender.recommend(standings: standings, candidates: candidates, limit: 4)
        XCTAssertTrue(recs.isEmpty)
    }

    func testTieBreakByDecisiveMatches() {
        let a = UUID(); let b = UUID()
        let standings = [
            standing("openAICompatible", "m-a", w: 4, l: 2),   // 66.7%, 6 决胜
            standing("openAICompatible", "m-b", w: 8, l: 4),   // 66.7%, 12 决胜 → 并列时排前
        ]
        let candidates = [
            candidate(a, "A", "openAICompatible", "m-a"),
            candidate(b, "B", "openAICompatible", "m-b"),
        ]
        let recs = CouncilRecommender.recommend(standings: standings, candidates: candidates, limit: 4)
        XCTAssertEqual(recs.first?.model, "m-b")
    }

    func testSkipsKeysNotInConfig() {
        // 榜上有 m-x 但没对应已配置 provider → 跳过;只推 m-a。
        let a = UUID()
        let standings = [
            standing("openAICompatible", "m-x", w: 9, l: 0),   // 胜率最高但无配置
            standing("openAICompatible", "m-a", w: 5, l: 2),
        ]
        let candidates = [candidate(a, "A", "openAICompatible", "m-a")]
        let recs = CouncilRecommender.recommend(standings: standings, candidates: candidates, limit: 4)
        XCTAssertEqual(recs.map { $0.model }, ["m-a"])
    }

    func testMapsViaKnownModels() {
        // provider 当前 model 是 m-default,但已知清单含 m-pro;榜上 m-pro 应映射回它。
        let a = UUID()
        let standings = [standing("openAICompatible", "m-pro", w: 6, l: 1)]
        let candidates = [candidate(a, "A", "openAICompatible", "m-default", known: ["m-default", "m-pro"])]
        let recs = CouncilRecommender.recommend(standings: standings, candidates: candidates, limit: 4)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.model, "m-pro")       // 用榜上 model
        XCTAssertEqual(recs.first?.providerID, a)
    }

    func testKindMustMatch() {
        // model 名相同但 kind 不同 → 不映射。
        let a = UUID()
        let standings = [standing("anthropic", "shared-model", w: 6, l: 1)]
        let candidates = [candidate(a, "A", "openAICompatible", "shared-model")]
        let recs = CouncilRecommender.recommend(standings: standings, candidates: candidates, limit: 4)
        XCTAssertTrue(recs.isEmpty)
    }

    func testEachProviderOnlyOnce() {
        // 同一 provider 命中两条战绩(当前 model + 已知 model),只出现一次(更高胜率那条)。
        let a = UUID()
        let standings = [
            standing("openAICompatible", "m-1", w: 9, l: 1),   // 90%
            standing("openAICompatible", "m-2", w: 5, l: 5),   // 50%
        ]
        let candidates = [candidate(a, "A", "openAICompatible", "m-1", known: ["m-1", "m-2"])]
        let recs = CouncilRecommender.recommend(standings: standings, candidates: candidates, limit: 4)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.model, "m-1")          // 取胜率更高那条
    }

    func testRespectsLimit() {
        let ids = (0..<5).map { _ in UUID() }
        let standings = (0..<5).map { i in standing("openAICompatible", "m-\(i)", w: 9 - i, l: 1) }
        let candidates = ids.enumerated().map { i, id in candidate(id, "P\(i)", "openAICompatible", "m-\(i)") }
        let recs = CouncilRecommender.recommend(standings: standings, candidates: candidates, limit: 3)
        XCTAssertEqual(recs.count, 3)
    }

    func testZeroLimitReturnsEmpty() {
        let a = UUID()
        let standings = [standing("openAICompatible", "m-a", w: 5, l: 0)]
        let candidates = [candidate(a, "A", "openAICompatible", "m-a")]
        XCTAssertTrue(CouncilRecommender.recommend(standings: standings, candidates: candidates, limit: 0).isEmpty)
    }
}
