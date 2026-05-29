import Foundation
import Observation

/// Token 用量统计 — 按"日期 + provider+model"维度累计 input / output tokens。
///
/// **跨设备累加,不覆盖**:
/// - 每台设备生成一个 deviceID(UserDefaults 持久化,UUID 字符串)
/// - 每台写自己的 `usage-<deviceID>.json` 文件,放 `syncedDataDir`(iCloud 同步开时 → iCloud Documents)
/// - 读时扫所有 `usage-*.json`,按 (day, model) **累加合并** 出 snapshot 给 UI
/// - 这样另一台设备的记录永远不会被本机的写覆盖,每台都贡献自己的份额
///
/// 设计:
/// - JSON 文件、文本格式,iCloud 同步友好
/// - 单文件容易因为冲突变成 `<name> 2.json`,但**不同设备本来就用不同文件名**,所以零冲突
/// - 旧版本 `usage.json`(无 deviceID 后缀)自动迁移成本机文件
@Observable
@MainActor
final class UsageStore {
    static let shared = UsageStore()

    /// 本机 deviceID(UserDefaults 持久化的 UUID 字符串)— 写文件时用于命名 `usage-<deviceID>.json`
    let deviceID: String

    /// 本机自己产生的记录(可写、可清空)。其他设备的合并进 `othersSnapshot`,本机不动他们的文件。
    private(set) var mineSnapshot: UsageSnapshot

    /// 其他设备的记录(从 iCloud 同步来的 `usage-<otherDeviceID>.json` 文件读出后汇总),
    /// 本机只读,不会写也不会清。reload 时重新扫盘。
    private(set) var othersSnapshot: UsageSnapshot

    /// 给 UI 用的合并 view(mineSnapshot + othersSnapshot 按 day/model 加总)
    var snapshot: UsageSnapshot {
        UsageSnapshot.merging(mineSnapshot, othersSnapshot)
    }

    private static let deviceIDKey = "kown.deviceID.v1"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private init() {
        // 1) 拿/造 deviceID
        if let existing = UserDefaults.standard.string(forKey: Self.deviceIDKey), !existing.isEmpty {
            self.deviceID = existing
        } else {
            let new = UUID().uuidString
            UserDefaults.standard.set(new, forKey: Self.deviceIDKey)
            self.deviceID = new
        }
        // 2) 兼容迁移:旧版本是 usage.json(无后缀),装在 localDataDir。迁到 syncedDataDir/usage-<deviceID>.json
        Self.migrateLegacyIfNeeded(deviceID: deviceID)
        // 3) 加载
        self.mineSnapshot = Self.loadMine(deviceID: deviceID) ?? UsageSnapshot()
        self.othersSnapshot = Self.loadOthers(excludingDeviceID: deviceID)
    }

    /// 记一条用量(发生在 LLM client 流末尾)。只写到本机文件。
    func record(providerKind: ProviderKind, model: String, inputTokens: Int, outputTokens: Int) {
        guard inputTokens > 0 || outputTokens > 0 else { return }
        let day = Self.dateFormatter.string(from: Date())
        let key = "\(providerKind.rawValue)::\(model)"
        var dayBucket = mineSnapshot.days[day] ?? [:]
        var modelEntry = dayBucket[key] ?? UsageEntry()
        modelEntry.input += inputTokens
        modelEntry.output += outputTokens
        modelEntry.callCount += 1
        dayBucket[key] = modelEntry
        mineSnapshot.days[day] = dayBucket
        persistMine()
    }

    /// 抹掉本机的全部历史(其他设备的不动 — 它们的文件不在本机的"管辖范围"内)
    func reset() {
        mineSnapshot = UsageSnapshot()
        persistMine()
    }

    /// 重新扫盘加载所有设备的数据。AppViewModel 在 iCloud 同步刷新时调用。
    func reload() {
        mineSnapshot = Self.loadMine(deviceID: deviceID) ?? UsageSnapshot()
        othersSnapshot = Self.loadOthers(excludingDeviceID: deviceID)
    }

    // MARK: - 聚合查询(给 UI 用)

    /// 查询范围:`.all` 是所有设备汇总,`.thisDevice` 只看本机产生的。
    /// UI 上 Settings → 用量 顶部有个 picker 切换。
    enum Scope: Hashable {
        case all
        case thisDevice
    }

    /// 取对应 scope 下的 snapshot(.all = mine+others 合并,.thisDevice = 仅 mine)
    func snapshot(scope: Scope) -> UsageSnapshot {
        switch scope {
        case .all: return snapshot
        case .thisDevice: return mineSnapshot
        }
    }

    func sortedDays(scope: Scope) -> [String] {
        snapshot(scope: scope).days.keys.sorted(by: >)
    }

    func entries(for day: String, scope: Scope) -> [(key: String, value: UsageEntry)] {
        let bucket = snapshot(scope: scope).days[day] ?? [:]
        return bucket.sorted { $0.value.total > $1.value.total }
    }

    func grandTotal(scope: Scope) -> UsageEntry {
        var sum = UsageEntry()
        for bucket in snapshot(scope: scope).days.values {
            for entry in bucket.values {
                sum.input += entry.input
                sum.output += entry.output
                sum.callCount += entry.callCount
            }
        }
        return sum
    }

    /// 向后兼容(老代码可能还在用,默认 .all 行为不变)
    var sortedDays: [String] { sortedDays(scope: .all) }
    func entries(for day: String) -> [(key: String, value: UsageEntry)] { entries(for: day, scope: .all) }
    var grandTotal: UsageEntry { grandTotal(scope: .all) }

    static func splitKey(_ key: String) -> (providerKind: String, model: String) {
        let parts = key.components(separatedBy: "::")
        if parts.count >= 2 { return (parts[0], parts.dropFirst().joined(separator: "::")) }
        return ("unknown", key)
    }

    /// 参与累加的设备数(包括本机)
    var deviceCount: Int {
        Self.deviceCount(excludingDeviceID: nil)
    }

    private static func deviceCount(excludingDeviceID: String?) -> Int {
        let fm = FileManager.default
        let dir = Platform.syncedDataDir
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return files.filter { $0.hasPrefix("usage-") && $0.hasSuffix(".json") }.count
    }

    // MARK: - 持久化

    private func persistMine() {
        let url = Self.fileURL(deviceID: deviceID)
        guard let data = try? JSONEncoder().encode(mineSnapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL(deviceID: String) -> URL {
        Platform.syncedDataDir.appendingPathComponent("usage-\(deviceID).json")
    }

    private static func loadMine(deviceID: String) -> UsageSnapshot? {
        let url = fileURL(deviceID: deviceID)
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else {
            return nil
        }
        return snap
    }

    /// 扫描 syncedDataDir 里所有 `usage-*.json`,排除本机 deviceID,汇总成 othersSnapshot
    private static func loadOthers(excludingDeviceID excludeID: String) -> UsageSnapshot {
        let fm = FileManager.default
        let dir = Platform.syncedDataDir
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return UsageSnapshot()
        }
        let myFileName = "usage-\(excludeID).json"
        var merged = UsageSnapshot()
        for file in files where file.hasPrefix("usage-") && file.hasSuffix(".json") && file != myFileName {
            let url = dir.appendingPathComponent(file)
            // iCloud 占位文件 — 内容可能为空 / 加载失败,跳过即可(下次 refresh 时再补)
            guard let data = try? Data(contentsOf: url),
                  let snap = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else {
                continue
            }
            merged = UsageSnapshot.merging(merged, snap)
        }
        return merged
    }

    /// 旧版本(0.5.4 / 0.5.5 之前)的 usage.json 是单一文件、放 localDataDir。
    /// 启动时若存在,迁移成本机的 `usage-<deviceID>.json`(放 syncedDataDir,跟得上 iCloud)。
    private static func migrateLegacyIfNeeded(deviceID: String) {
        let fm = FileManager.default
        let legacyURL = Platform.localDataDir.appendingPathComponent("usage.json")
        guard fm.fileExists(atPath: legacyURL.path) else { return }
        let newURL = fileURL(deviceID: deviceID)
        // 若本机已有 usage-<deviceID>.json,优先保留新格式,旧文件备份后删除
        if fm.fileExists(atPath: newURL.path) {
            let backup = legacyURL.deletingPathExtension().appendingPathExtension("legacy.json")
            try? fm.moveItem(at: legacyURL, to: backup)
            return
        }
        if let data = try? Data(contentsOf: legacyURL) {
            try? data.write(to: newURL, options: .atomic)
            // 迁移完成后删除旧文件(避免下次再触发迁移)
            try? fm.removeItem(at: legacyURL)
        }
    }
}

struct UsageSnapshot: Codable {
    /// 日期(yyyy-MM-dd)→ (model key → entry)
    var days: [String: [String: UsageEntry]] = [:]

    /// 把两份 snapshot 按 (day, model) 累加合并
    static func merging(_ a: UsageSnapshot, _ b: UsageSnapshot) -> UsageSnapshot {
        var out = a
        for (day, bBucket) in b.days {
            var outBucket = out.days[day] ?? [:]
            for (key, bEntry) in bBucket {
                var e = outBucket[key] ?? UsageEntry()
                e.input += bEntry.input
                e.output += bEntry.output
                e.callCount += bEntry.callCount
                outBucket[key] = e
            }
            out.days[day] = outBucket
        }
        return out
    }
}

struct UsageEntry: Codable, Hashable, Sendable {
    var input: Int = 0
    var output: Int = 0
    var callCount: Int = 0

    var total: Int { input + output }
}
