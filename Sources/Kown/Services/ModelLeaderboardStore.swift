import Foundation
import Observation

/// 模型胜率榜 — Compare 模式裁判判定确定后,按「胜者/败者」累计各模型的 win / loss / draw。
///
/// 模型键 = `providerKind::model`(与 `UsageStore` 的 key 同构,方便对照),
/// 这样同一个 model 不管用哪个 provider 配置发都归到一类。
///
/// 持久化:`Platform.syncedDataDir/leaderboard.json`(随 iCloud 同步),
/// @MainActor + JSONEncoder + .atomic,与 `ConversationFolderStore` / `UsageStore` 一致。
@Observable
@MainActor
final class ModelLeaderboardStore {
    static let shared = ModelLeaderboardStore()

    /// 模型键(`providerKind::model`)→ 战绩
    private(set) var records: [String: Record]

    private init() {
        self.records = Self.load()
    }

    /// 拼模型键:`providerKind::model`。与 `UsageStore` 保持一致。
    static func key(providerKind: ProviderKind, model: String) -> String {
        "\(providerKind.rawValue)::\(model)"
    }

    /// 拆模型键回 (providerKind 原始值, model)。
    static func splitKey(_ key: String) -> (providerKind: String, model: String) {
        let parts = key.components(separatedBy: "::")
        if parts.count >= 2 { return (parts[0], parts.dropFirst().joined(separator: "::")) }
        return ("unknown", key)
    }

    /// 记一场胜负。winner / loser 用模型键(`providerKind::model`)。
    /// winner == loser(同一模型对自己)时忽略,避免脏数据。
    func record(winnerKey: String, loserKey: String) {
        guard winnerKey != loserKey else { return }
        var w = records[winnerKey] ?? Record()
        w.wins += 1
        records[winnerKey] = w
        var l = records[loserKey] ?? Record()
        l.losses += 1
        records[loserKey] = l
        persist()
    }

    /// 记一场平局(两家都 +1 draw)。
    func recordDraw(_ aKey: String, _ bKey: String) {
        guard aKey != bKey else { return }
        var a = records[aKey] ?? Record()
        a.draws += 1
        records[aKey] = a
        var b = records[bKey] ?? Record()
        b.draws += 1
        records[bKey] = b
        persist()
    }

    /// 抹掉全部战绩。
    func reset() {
        records = [:]
        persist()
    }

    /// 重新扫盘加载(iCloud 同步刷新时调用)。
    func reload() {
        records = Self.load()
    }

    // MARK: - 聚合查询(给 UI 用)

    /// 按胜率降序、再按对战数降序排出的榜单行(只含至少打过一场的模型)。
    var standings: [Standing] {
        records.compactMap { key, rec -> Standing? in
            guard rec.total > 0 else { return nil }
            let (providerRaw, model) = Self.splitKey(key)
            return Standing(
                key: key,
                providerKind: ProviderKind(rawValue: providerRaw),
                model: model,
                record: rec
            )
        }
        .sorted { lhs, rhs in
            if lhs.record.winRate != rhs.record.winRate {
                return lhs.record.winRate > rhs.record.winRate
            }
            return lhs.record.total > rhs.record.total
        }
    }

    /// 参与统计的模型数(至少打过一场)。
    var modelCount: Int {
        records.values.filter { $0.total > 0 }.count
    }

    /// 累计裁判判定场次(每场判定算一次:胜者+败者各记一笔,这里取胜场总和=判定场数)。
    var totalMatches: Int {
        records.values.reduce(0) { $0 + $1.wins }
    }

    // MARK: - 持久化

    private static var fileURL: URL {
        Platform.syncedDataDir.appendingPathComponent("leaderboard.json")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private static func load() -> [String: Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

extension ModelLeaderboardStore {
    /// 单个模型的累计战绩。
    struct Record: Codable, Hashable, Sendable {
        var wins: Int = 0
        var losses: Int = 0
        var draws: Int = 0

        var total: Int { wins + losses + draws }
        /// 胜率(平局不计入分母)。无胜负场时为 0。
        var winRate: Double {
            let decisive = wins + losses
            return decisive == 0 ? 0 : Double(wins) / Double(decisive)
        }

        init(wins: Int = 0, losses: Int = 0, draws: Int = 0) {
            self.wins = wins
            self.losses = losses
            self.draws = draws
        }

        // 旧 JSON 缺键时容错(否则整份榜单解码失败被清空)。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.wins = try c.decodeIfPresent(Int.self, forKey: .wins) ?? 0
            self.losses = try c.decodeIfPresent(Int.self, forKey: .losses) ?? 0
            self.draws = try c.decodeIfPresent(Int.self, forKey: .draws) ?? 0
        }
    }

    /// 排好序、带展示信息的一行榜单。
    struct Standing: Identifiable, Hashable, Sendable {
        let key: String
        let providerKind: ProviderKind?
        let model: String
        let record: Record

        var id: String { key }
    }
}
