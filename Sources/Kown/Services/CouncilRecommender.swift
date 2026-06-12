import Foundation

/// 按胜率推荐 Council 阵容:读 `ModelLeaderboardStore` 的战绩,映射回**已配置且启用**的 provider,
/// 按胜率(再按场次)排序取前 N。纯函数(不碰 store / UserDefaults),便于单测。
///
/// leaderboard 键是 `providerKind::model`(同一 model 不分 provider 配置归一类);
/// 推荐时要映射回具体 ProviderConfig:取 `kind` 相同、且 `model` 命中(== 当前 model 或在其已知模型清单里)的配置。
/// 一个键可能命中多个配置(同 vendor 多份),取第一个;不在配置里的键直接跳过。
enum CouncilRecommender {
    /// 一条推荐结果:推荐启用的 provider + 它依据的战绩。
    struct Recommendation: Identifiable, Hashable, Sendable {
        let providerID: UUID
        let displayName: String
        let model: String
        /// 胜率(0-1)。
        let winRate: Double
        /// 决胜场次(胜+负,不含平)。
        let decisiveMatches: Int
        /// 总场次(胜+负+平)。
        let totalMatches: Int

        var id: UUID { providerID }
    }

    /// 样本门槛:某模型至少打满这么多场(总场次)才纳入推荐,否则数据不足不可信。
    static let minSampleMatches = 5

    /// 一条战绩输入(从 `ModelLeaderboardStore.standings` 投影出来,解耦 store 便于测试)。
    struct StandingInput: Sendable {
        let providerKindRaw: String
        let model: String
        let winRate: Double
        let wins: Int
        let losses: Int
        let draws: Int

        var total: Int { wins + losses + draws }
        var decisive: Int { wins + losses }
    }

    /// 一个可被推荐的候选 provider(从 `providers` 投影,只含已启用、非 CLI)。
    struct ProviderCandidate: Sendable {
        let id: UUID
        let displayName: String
        let kindRaw: String
        let model: String
        /// 该 provider 的已知模型清单(含当前 model);用于把 leaderboard 里别的 model 也映射回这个 provider。
        let knownModels: [String]
    }

    /// 计算推荐阵容。
    /// - standings:已按任意顺序的战绩(本函数自己排序)。
    /// - candidates:已启用、非 CLI 的 provider 候选。
    /// - limit:最多取几个。
    /// 返回按胜率降序(并列再按决胜场次降序)的推荐;样本不足 / 无配置命中的键被过滤。
    /// 同一个 provider 只出现一次(取它命中的最高胜率那条战绩)。
    static func recommend(
        standings: [StandingInput],
        candidates: [ProviderCandidate],
        limit: Int
    ) -> [Recommendation] {
        guard limit > 0 else { return [] }

        // 先把样本足够的战绩按胜率(再按决胜场次)排序。
        let eligible = standings
            .filter { $0.total >= minSampleMatches }
            .sorted { lhs, rhs in
                if lhs.winRate != rhs.winRate { return lhs.winRate > rhs.winRate }
                if lhs.decisive != rhs.decisive { return lhs.decisive > rhs.decisive }
                return lhs.total > rhs.total
            }

        var result: [Recommendation] = []
        var usedProviderIDs = Set<UUID>()

        for s in eligible {
            // 找一个 kind 相同、model 命中(当前 model 或在已知清单里)、尚未被选中的候选。
            guard let cand = candidates.first(where: { c in
                c.kindRaw == s.providerKindRaw
                    && !usedProviderIDs.contains(c.id)
                    && (c.model == s.model || c.knownModels.contains(s.model))
            }) else { continue }

            usedProviderIDs.insert(cand.id)
            result.append(Recommendation(
                providerID: cand.id,
                displayName: cand.displayName,
                model: s.model,
                winRate: s.winRate,
                decisiveMatches: s.decisive,
                totalMatches: s.total
            ))
            if result.count >= limit { break }
        }
        return result
    }
}
