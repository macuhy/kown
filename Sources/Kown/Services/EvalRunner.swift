import Foundation
import Observation

/// 评测台执行器:把一个 `EvalSuite` 在选定的若干模型上跑一遍,逐格(case × model)保存
/// 状态 / 输出 / 所要 / 合否。
///
/// 设计:
/// - **逐次**执行(一个格子接一个格子,串行)。避免同时打多个模型把 API 限速 / 把成本一下打爆,
///   也让进度条直观。
/// - 合否 = `expected` 关键词是否出现在模型输出里(忽略大小写、忽略首尾空白);空 `expected` 跳过判定。
/// - 走标准 LLM 作法:`ProviderRegistry.client(for:).stream(...)`,token 用量计入 `UsageStore.shared.record`。
/// - 支持进度查询与取消。
@Observable
@MainActor
final class EvalRunner {
    /// 单个格子(某道题在某个模型上)的执行状态。
    enum CellPhase: Equatable, Sendable {
        case pending
        case running
        case done(pass: Bool?)   // nil = 未判定(空 expected)
        case failed              // 流式出错 / 取消
    }

    /// 一个格子的完整结果。`caseID` × `providerID` 唯一定位。
    struct Cell: Identifiable, Sendable {
        let caseID: UUID
        let providerID: UUID
        var phase: CellPhase = .pending
        var output: String = ""
        var errorText: String?
        var elapsed: TimeInterval = 0

        var id: String { "\(caseID.uuidString):\(providerID.uuidString)" }
    }

    /// 是否正在跑。
    private(set) var isRunning = false
    /// 本次运行的结果格子(key = "caseID:providerID")。
    private(set) var cells: [String: Cell] = [:]
    /// 本次运行涉及的模型(快照,运行期间固定)。
    private(set) var runProviders: [ProviderConfig] = []
    /// 本次运行涉及的用例(快照)。
    private(set) var runCases: [EvalCase] = []
    /// 进度:已完成格子数 / 总格子数。
    private(set) var completedCount = 0
    private(set) var totalCount = 0

    private var task: Task<Void, Never>?

    static func cellKey(caseID: UUID, providerID: UUID) -> String {
        "\(caseID.uuidString):\(providerID.uuidString)"
    }

    func cell(caseID: UUID, providerID: UUID) -> Cell? {
        cells[Self.cellKey(caseID: caseID, providerID: providerID)]
    }

    // MARK: - 合否聚合(给 UI 汇总用)

    /// 某个模型在本次运行里通过 / 判定总数(空 expected 的不计入分母)。
    func score(for providerID: UUID) -> (pass: Int, judged: Int) {
        var pass = 0, judged = 0
        for c in runCases {
            guard let cell = cell(caseID: c.id, providerID: providerID) else { continue }
            if case .done(let p) = cell.phase, let p {
                judged += 1
                if p { pass += 1 }
            }
        }
        return (pass, judged)
    }

    // MARK: - 运行 / 取消

    /// 跑一个评测集:`cases` × `providers` 逐格串行执行。已在跑则忽略。
    func run(cases: [EvalCase], providers: [ProviderConfig]) {
        guard !isRunning else { return }
        let validCases = cases.filter { !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validCases.isEmpty, !providers.isEmpty else { return }

        runCases = validCases
        runProviders = providers
        cells = [:]
        for c in validCases {
            for p in providers {
                let key = Self.cellKey(caseID: c.id, providerID: p.id)
                cells[key] = Cell(caseID: c.id, providerID: p.id)
            }
        }
        totalCount = validCases.count * providers.count
        completedCount = 0
        isRunning = true

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            outer: for c in validCases {
                for p in providers {
                    if Task.isCancelled { break outer }
                    await self.runCell(evalCase: c, provider: p)
                    self.completedCount += 1
                }
            }
            // 取消时把仍 pending 的格子标失败,避免界面停在「等待中」。
            if Task.isCancelled {
                for (key, var cell) in self.cells where cell.phase == .pending || cell.phase == .running {
                    cell.phase = .failed
                    cell.errorText = cell.errorText ?? "已取消"
                    self.cells[key] = cell
                }
            }
            self.isRunning = false
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// 清空上次结果(切换评测集时)。
    func clear() {
        guard !isRunning else { return }
        cells = [:]
        runProviders = []
        runCases = []
        completedCount = 0
        totalCount = 0
    }

    // MARK: - 单格执行

    private func runCell(evalCase: EvalCase, provider: ProviderConfig) async {
        let key = Self.cellKey(caseID: evalCase.id, providerID: provider.id)
        guard var cell = cells[key] else { return }
        cell.phase = .running
        cells[key] = cell

        let start = Date()
        var collected = ""
        var failure: String?

        do {
            let apiKey = provider.kind.needsAPIKey ? (try KeychainStore.load(id: provider.id)) : ""
            let client = ProviderRegistry.client(for: provider.kind)
            let options = ChatOptions(
                systemPrompt: nil,
                temperature: provider.temperature,
                maxTokens: provider.maxTokens
            )
            for try await chunk in client.stream(prompt: evalCase.prompt, options: options, config: provider, apiKey: apiKey) {
                if Task.isCancelled { break }
                switch chunk {
                case .text(let t):
                    collected += t
                case .usage(let input, let output, let cached):
                    UsageStore.shared.record(
                        providerKind: provider.kind,
                        model: provider.model,
                        inputTokens: input,
                        outputTokens: output,
                        cachedTokens: cached
                    )
                default:
                    break
                }
            }
            if Task.isCancelled {
                failure = "已取消"
            }
        } catch is CancellationError {
            failure = "已取消"
        } catch {
            failure = error.localizedDescription
        }

        // 回写结果格子(过程中可能被 clear / 新一轮覆盖,定位不到就放弃)。
        guard var finalCell = cells[key] else { return }
        finalCell.output = collected
        finalCell.elapsed = Date().timeIntervalSince(start)
        if let failure {
            finalCell.phase = .failed
            finalCell.errorText = failure
        } else {
            finalCell.phase = .done(pass: Self.judge(expected: evalCase.expected, output: collected))
        }
        cells[key] = finalCell
    }

    /// 简易合否:`expected` 关键词(忽略大小写、忽略首尾空白)是否出现在 `output` 里。
    /// 空 `expected` 返回 nil(不判定)。
    nonisolated static func judge(expected: String, output: String) -> Bool? {
        let key = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return output.range(of: key, options: [.caseInsensitive]) != nil
    }
}
