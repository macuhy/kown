import Foundation
import Observation

/// 个人口味偏好画像 —— 由「盲测」(`BlindTasteTestView`)累积:同一问题两个**匿名**模型各出答案,
/// **用户**亲自选更好的那个,按任务类别(`TaskCategory`)记成 win / loss。
///
/// 与 `ModelLeaderboardStore`(裁判模型判定的客观胜率)是两套并行数据:
/// 这里记的是**用户主观偏好**,数据源是人的盲选,落在单独的文件,互不污染。
/// 模型键 = `providerKind::model`(与 `ModelLeaderboardStore` / `UsageStore` 同构)。
///
/// 持久化:`Platform.syncedDataDir/preference-profile.json`(随 iCloud 同步),
/// @MainActor + JSONEncoder + .atomic,与 `ModelLeaderboardStore` 完全一致的范式。
@Observable
@MainActor
final class PreferenceProfileStore {
    static let shared = PreferenceProfileStore()

    /// 分类别偏好:任务类别 rawValue → (模型键 → 偏好战绩)。
    private(set) var categoryRecords: [String: [String: Record]]

    private init() {
        self.categoryRecords = Self.load()
    }

    /// 拼模型键:`providerKind::model`。与 `ModelLeaderboardStore` 保持一致。
    static func key(providerKind: ProviderKind, model: String) -> String {
        "\(providerKind.rawValue)::\(model)"
    }

    /// 拆模型键回 (providerKind 原始值, model)。
    static func splitKey(_ key: String) -> (providerKind: String, model: String) {
        let parts = key.components(separatedBy: "::")
        if parts.count >= 2 { return (parts[0], parts.dropFirst().joined(separator: "::")) }
        return ("unknown", key)
    }

    /// 记一次盲测裁决:用户在某类别下选了 winnerKey 胜过 loserKey。
    /// winner == loser 时忽略(脏数据)。
    func recordVote(winnerKey: String, loserKey: String, category: TaskCategory) {
        guard winnerKey != loserKey else { return }
        var bucket = categoryRecords[category.rawValue] ?? [:]
        var w = bucket[winnerKey] ?? Record()
        w.wins += 1
        bucket[winnerKey] = w
        var l = bucket[loserKey] ?? Record()
        l.losses += 1
        bucket[loserKey] = l
        categoryRecords[category.rawValue] = bucket
        persist()
    }

    /// 记一次「难分伯仲」(两家都 +1 draw)。
    func recordTie(_ aKey: String, _ bKey: String, category: TaskCategory) {
        guard aKey != bKey else { return }
        var bucket = categoryRecords[category.rawValue] ?? [:]
        var a = bucket[aKey] ?? Record()
        a.draws += 1
        bucket[aKey] = a
        var b = bucket[bKey] ?? Record()
        b.draws += 1
        bucket[bKey] = b
        categoryRecords[category.rawValue] = bucket
        persist()
    }

    /// 查某 (模型, 类别) 对的偏好战绩;没投过返回 nil。
    func record(forModelKey key: String, category: TaskCategory) -> Record? {
        categoryRecords[category.rawValue]?[key]
    }

    /// 某类别下、给定候选模型键集合里,按偏好胜率挑「用户最偏好」的一个。
    /// 仅在样本量达到 `minSamples` 的候选里挑;没有够样本的候选返回 nil(调用方据此回退默认行为)。
    func preferredKey(category: TaskCategory, among candidateKeys: [String], minSamples: Int) -> String? {
        let bucket = categoryRecords[category.rawValue] ?? [:]
        var best: (key: String, rate: Double, total: Int)? = nil
        for key in candidateKeys {
            guard let rec = bucket[key], rec.total >= minSamples, rec.wins + rec.losses > 0 else { continue }
            let rate = rec.preferenceRate
            if best == nil || rate > best!.rate || (rate == best!.rate && rec.total > best!.total) {
                best = (key, rate, rec.total)
            }
        }
        return best?.key
    }

    /// 抹掉全部偏好数据。
    func reset() {
        categoryRecords = [:]
        persist()
    }

    /// 重新扫盘加载(iCloud 同步刷新时调用)。
    func reload() {
        categoryRecords = Self.load()
    }

    // MARK: - 聚合查询(给 UI 用)

    /// 累计盲测裁决场数(每次裁决 winner+loser 各记一笔,这里取所有类别 wins 之和 = 裁决次数)。
    var totalVotes: Int {
        categoryRecords.values.reduce(0) { acc, bucket in
            acc + bucket.values.reduce(0) { $0 + $1.wins }
        }
    }

    /// 某类别按偏好胜率降序、再按场数降序排出的榜单行(只含至少投过一次的模型)。
    func standings(category: TaskCategory) -> [Standing] {
        let bucket = categoryRecords[category.rawValue] ?? [:]
        return bucket.compactMap { key, rec -> Standing? in
            guard rec.total > 0 else { return nil }
            let (providerRaw, model) = Self.splitKey(key)
            return Standing(key: key, providerKind: ProviderKind(rawValue: providerRaw),
                            model: model, record: rec)
        }
        .sorted { lhs, rhs in
            if lhs.record.preferenceRate != rhs.record.preferenceRate {
                return lhs.record.preferenceRate > rhs.record.preferenceRate
            }
            return lhs.record.total > rhs.record.total
        }
    }

    /// 参与统计的类别(至少有一条记录)。
    var nonEmptyCategories: [TaskCategory] {
        TaskCategory.allCases.filter { !(categoryRecords[$0.rawValue]?.isEmpty ?? true) }
    }

    // MARK: - 持久化

    private static var fileURL: URL {
        Platform.syncedDataDir.appendingPathComponent("preference-profile.json")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(categoryRecords) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private static func load() -> [String: [String: Record]] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String: Record]].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

extension PreferenceProfileStore {
    /// 单个模型在某类别下的偏好战绩。
    struct Record: Codable, Hashable, Sendable {
        var wins: Int = 0
        var losses: Int = 0
        var draws: Int = 0

        var total: Int { wins + losses + draws }
        /// 偏好胜率(平局不计入分母)。无胜负场时为 0。
        var preferenceRate: Double {
            let decisive = wins + losses
            return decisive == 0 ? 0 : Double(wins) / Double(decisive)
        }

        init(wins: Int = 0, losses: Int = 0, draws: Int = 0) {
            self.wins = wins
            self.losses = losses
            self.draws = draws
        }

        // 旧 JSON 缺键时容错。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.wins = try c.decodeIfPresent(Int.self, forKey: .wins) ?? 0
            self.losses = try c.decodeIfPresent(Int.self, forKey: .losses) ?? 0
            self.draws = try c.decodeIfPresent(Int.self, forKey: .draws) ?? 0
        }
    }

    /// 排好序、带展示信息的一行偏好榜单。
    struct Standing: Identifiable, Hashable, Sendable {
        let key: String
        let providerKind: ProviderKind?
        let model: String
        let record: Record

        var id: String { key }
    }
}

/// 个人偏好路由 —— 与 `CostRouter`(客观胜率 + 省钱)并列的**主观偏好**路由层。
/// 在当前 provider 所属 vendor 的已知模型里,按**本人盲测画像**(`PreferenceProfileStore`)挑
/// 「在该任务类别下我最偏爱」的那个 model。样本不足((模型,类别) 对不满 `minSamples` 票)时
/// 返回原 config(reason = nil),保证开关行为可回退。
enum PreferenceRouter {
    /// (模型, 类别) 对至少要投满的票数,不够不参与个人路由(避免一两票就改判)。
    static let minSamples = 3

    struct Decision {
        var config: ProviderConfig
        var category: TaskCategory
        var changed: Bool
        /// 非 nil 表示本次按个人画像做了选择(中文理由,落进 `Turn.routeNote` 展示)。
        var reason: String?
    }

    /// 按个人画像 + 类别选模型。
    @MainActor
    static func route(_ config: ProviderConfig, prompt: String) -> Decision {
        let category = TaskCategory.classify(prompt)
        // 候选 = 该 vendor 已知模型 ∪ 当前 model(确保当前 model 也在候选里参与比较)。
        var models = ProviderModelCatalog.knownModels(for: config)
        if !models.contains(config.model) { models.append(config.model) }
        guard models.count > 1 else {
            return Decision(config: config, category: category, changed: false, reason: nil)
        }
        let keys = models.map { PreferenceProfileStore.key(providerKind: config.kind, model: $0) }
        guard let preferredKey = PreferenceProfileStore.shared.preferredKey(
            category: category, among: keys, minSamples: minSamples) else {
            return Decision(config: config, category: category, changed: false, reason: nil)
        }
        let (_, preferredModel) = PreferenceProfileStore.splitKey(preferredKey)
        let rec = PreferenceProfileStore.shared.record(forModelKey: preferredKey, category: category)
        let ratePct = Int(((rec?.preferenceRate ?? 0) * 100).rounded())
        let reason = "个人偏好:\(category.label) · 你更常选 \(preferredModel)(盲测偏好 \(ratePct)%,\(rec?.total ?? 0) 票)"

        guard preferredModel != config.model else {
            return Decision(config: config, category: category, changed: false, reason: reason)
        }
        var copy = config
        copy.model = preferredModel
        return Decision(config: copy, category: category, changed: true, reason: reason)
    }
}
