import Foundation
import Observation

/// 评测台(回归 / Eval harness)的数据模型。
///
/// 一个 `EvalSuite` 是一组「问题 + 期望关键词」的测试集。把它在多个模型上跑一遍,
/// 把每个模型的实际输出与期望并排比对、出一个简易合否,用来在模型版本更新后检测「漂移」
/// (同一道题,旧版本能过、新版本答错)。
///
/// 合否判定很轻量:`expected` 作为关键词判断「是否包含在模型输出里」(见 `EvalRunner`),
/// 不追求语义评分 —— 这是回归冒烟,不是 benchmark。空 `expected` 视为「仅记录输出,不判合否」。
struct EvalCase: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// 发给模型的题面 / prompt。
    var prompt: String
    /// 期望命中的关键词(出现在模型输出里即判通过)。空 = 不判合否。
    var expected: String
    /// 备注(给人看的,不参与判定)。
    var note: String?

    init(id: UUID = UUID(), prompt: String = "", expected: String = "", note: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.expected = expected
        self.note = note
    }
}

/// 一组评测用例。
struct EvalSuite: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var cases: [EvalCase]

    init(id: UUID = UUID(), name: String = "新评测集", cases: [EvalCase] = []) {
        self.id = id
        self.name = name
        self.cases = cases
    }
}

/// 评测集持久化 —— 单文件 `eval-suites.json`,放 `Platform.syncedDataDir`(跟得上 iCloud)。
/// 参照 `UsageStore` / `ConversationStore` 的 @MainActor + JSONEncoder + .atomic 写盘作法,
/// 自包含、不依赖其它 store。
@Observable
@MainActor
final class EvalSuiteStore {
    private(set) var suites: [EvalSuite]

    private static let fileName = "eval-suites.json"

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static var fileURL: URL {
        Platform.syncedDataDir.appendingPathComponent(fileName)
    }

    init() {
        self.suites = Self.load()
    }

    private static func load() -> [EvalSuite] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([EvalSuite].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persist() {
        guard let data = try? Self.encoder.encode(suites) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// 重新扫盘(iCloud 同步刷新时可调)。
    func reload() {
        suites = Self.load()
    }

    // MARK: - 增删改

    @discardableResult
    func addSuite(name: String = "新评测集") -> EvalSuite {
        let suite = EvalSuite(name: name)
        suites.append(suite)
        persist()
        return suite
    }

    func removeSuite(_ id: UUID) {
        suites.removeAll { $0.id == id }
        persist()
    }

    func renameSuite(_ id: UUID, to name: String) {
        guard let idx = suites.firstIndex(where: { $0.id == id }) else { return }
        suites[idx].name = name
        persist()
    }

    func addCase(toSuite suiteID: UUID) {
        guard let idx = suites.firstIndex(where: { $0.id == suiteID }) else { return }
        suites[idx].cases.append(EvalCase())
        persist()
    }

    func removeCase(_ caseID: UUID, fromSuite suiteID: UUID) {
        guard let idx = suites.firstIndex(where: { $0.id == suiteID }) else { return }
        suites[idx].cases.removeAll { $0.id == caseID }
        persist()
    }

    /// 用例字段就地更新(编辑 prompt / expected / note 后调用)。
    func updateCase(_ updated: EvalCase, inSuite suiteID: UUID) {
        guard let sIdx = suites.firstIndex(where: { $0.id == suiteID }),
              let cIdx = suites[sIdx].cases.firstIndex(where: { $0.id == updated.id }) else { return }
        suites[sIdx].cases[cIdx] = updated
        persist()
    }

    /// 显式落盘(View 在批量编辑后可主动触发)。
    func save() {
        persist()
    }
}
