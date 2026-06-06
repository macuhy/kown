import Foundation
import Observation

/// 批量执行 / 提示词队列引擎。
///
/// 把「多个问题 × 多个模型」展开成一张二维矩阵,**逐格逐条串行**地跑(不并发,
/// 避免一次性打爆各家 API 速率限制 — 夜间批跑场景宁慢勿被封)。
/// 每格记录状态 / 结果文本 / 思考过程 / token 用量 / 耗时,支持中途取消。
///
/// 调用约定与 `AppViewModel+Send.swift` 完全一致:
/// `ProviderRegistry.client(for:).stream(prompt:options:config:apiKey:)`,
/// API key 走 `KeychainStore.load(id:)`,用量计入 `UsageStore.shared.record(...)`。
@Observable
@MainActor
final class BatchRunner {
    /// 单元格状态机。
    enum CellStatus: Sendable, Equatable {
        case pending      // 待执行
        case running      // 执行中(流式接收)
        case done         // 成功完成
        case failed       // 失败(带错误文案)
        case cancelled    // 用户取消(未及执行 / 执行中断)
    }

    /// 矩阵里的一格 = 第 promptIndex 个问题交给第 providerIndex 个模型。
    @Observable
    final class Cell: Identifiable {
        let id = UUID()
        let promptIndex: Int
        let providerIndex: Int
        let providerID: UUID

        var status: CellStatus = .pending
        var text: String = ""
        var reasoning: String = ""
        var error: String? = nil
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cachedInputTokens: Int = 0
        /// 所耗秒数(执行结束后填),供 UI 展示。
        var elapsedSeconds: Double? = nil

        init(promptIndex: Int, providerIndex: Int, providerID: UUID) {
            self.promptIndex = promptIndex
            self.providerIndex = providerIndex
            self.providerID = providerID
        }
    }

    // MARK: - 输入快照(执行期间固定,UI 不可改)

    /// 本次批跑的问题列表(每行一条,已去空)。
    private(set) var prompts: [String] = []
    /// 本次批跑的模型列表(顺序即矩阵列顺序)。
    private(set) var providersUsed: [ProviderConfig] = []
    /// 统一的系统提示(可空)。
    private(set) var systemPrompt: String = ""

    // MARK: - 运行状态

    /// 二维结果矩阵,按 `cellIndex(prompt:provider:)` 线性索引。
    private(set) var cells: [Cell] = []
    /// 是否正在跑。
    private(set) var isRunning = false
    /// 已完成(成功 + 失败 + 取消)的格子数,用于进度条。
    private(set) var completedCount = 0
    /// 总格子数 = prompts.count × providersUsed.count。
    var totalCount: Int { prompts.count * providersUsed.count }

    private var task: Task<Void, Never>? = nil

    // MARK: - 取格子

    /// 线性下标:行优先(同一个问题的各模型相邻),便于「逐题跑完一题再下一题」。
    func cellIndex(prompt p: Int, provider v: Int) -> Int {
        p * providersUsed.count + v
    }

    func cell(prompt p: Int, provider v: Int) -> Cell? {
        let idx = cellIndex(prompt: p, provider: v)
        guard cells.indices.contains(idx) else { return nil }
        return cells[idx]
    }

    // MARK: - 启动 / 取消

    /// 用给定问题集 + 模型集启动批跑。已在运行时忽略(先取消再开)。
    /// - prompts: 多行文本拆出的问题(本方法内部再去空 / 去首尾空白)。
    /// - providers: 执行模型(调用方负责剔除 iOS 上的 CLI provider)。
    func start(prompts rawPrompts: [String], providers: [ProviderConfig], systemPrompt sys: String) {
        guard !isRunning else { return }
        let cleanedPrompts = rawPrompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedPrompts.isEmpty, !providers.isEmpty else { return }

        self.prompts = cleanedPrompts
        self.providersUsed = providers
        self.systemPrompt = sys.trimmingCharacters(in: .whitespacesAndNewlines)

        // 建矩阵:行优先排布。
        var grid: [Cell] = []
        grid.reserveCapacity(cleanedPrompts.count * providers.count)
        for p in cleanedPrompts.indices {
            for (v, cfg) in providers.enumerated() {
                grid.append(Cell(promptIndex: p, providerIndex: v, providerID: cfg.id))
            }
        }
        self.cells = grid
        self.completedCount = 0
        self.isRunning = true

        task = Task { [weak self] in
            await self?.runAll()
        }
    }

    /// 取消批跑:剩余未完成的格子标记为 cancelled,正在跑的流被中断。
    func cancel() {
        task?.cancel()
        task = nil
        for cell in cells where cell.status == .pending || cell.status == .running {
            cell.status = .cancelled
            if cell.error == nil && cell.text.isEmpty {
                cell.error = "已取消"
            }
        }
        completedCount = cells.filter { $0.status != .pending && $0.status != .running }.count
        isRunning = false
    }

    /// 清空全部结果(回到空白态),便于开始新一批。运行中拒绝清空。
    func reset() {
        guard !isRunning else { return }
        prompts = []
        providersUsed = []
        systemPrompt = ""
        cells = []
        completedCount = 0
    }

    // MARK: - 执行循环(串行)

    private func runAll() async {
        defer {
            isRunning = false
            task = nil
        }
        // 预取各模型的 API key(CLI 用空串)。失败留到执行时再报。
        var keyCache: [UUID: String] = [:]
        for cfg in providersUsed where !cfg.kind.isCLI {
            keyCache[cfg.id] = (try? KeychainStore.load(id: cfg.id)) ?? ""
        }

        for cell in cells {
            if Task.isCancelled { break }
            let cfg = providersUsed[cell.providerIndex]
            let prompt = prompts[cell.promptIndex]
            let apiKey = cfg.kind.isCLI ? "" : (keyCache[cfg.id] ?? "")
            await runCell(cell, config: cfg, prompt: prompt, apiKey: apiKey)
            completedCount += 1
        }

        // 收尾:被 Task 取消打断时,把尚未跑的标记为 cancelled。
        if Task.isCancelled {
            for cell in cells where cell.status == .pending || cell.status == .running {
                cell.status = .cancelled
                if cell.error == nil && cell.text.isEmpty { cell.error = "已取消" }
            }
            completedCount = cells.filter { $0.status != .pending && $0.status != .running }.count
        }
    }

    /// 跑一格:流式接收文本 / 思考 / 用量,完成后落 token 用量到 UsageStore。
    private func runCell(_ cell: Cell, config: ProviderConfig, prompt: String, apiKey: String) async {
        cell.status = .running
        let started = Date()

        let options = ChatOptions(
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            temperature: config.temperature,
            maxTokens: config.maxTokens
        )

        do {
            let client = ProviderRegistry.client(for: config.kind)
            for try await chunk in client.stream(prompt: prompt, options: options, config: config, apiKey: apiKey) {
                if Task.isCancelled { break }
                switch chunk {
                case .text(let t):
                    cell.text += t
                case .reasoning(let r):
                    cell.reasoning += r
                case .toolEvent:
                    break
                case .sources:
                    break
                case .usage(let input, let output, let cached):
                    cell.inputTokens = input
                    cell.outputTokens = output
                    cell.cachedInputTokens = cached
                    // 用量计入全局统计(按天分桶),与正常发送一致。
                    UsageStore.shared.record(
                        providerKind: config.kind,
                        model: config.model,
                        inputTokens: input,
                        outputTokens: output,
                        cachedTokens: cached
                    )
                }
            }
            cell.elapsedSeconds = Date().timeIntervalSince(started)
            if Task.isCancelled {
                cell.status = .cancelled
                if cell.error == nil && cell.text.isEmpty { cell.error = "已取消" }
            } else {
                cell.status = .done
            }
        } catch is CancellationError {
            cell.elapsedSeconds = Date().timeIntervalSince(started)
            cell.status = .cancelled
            if cell.error == nil && cell.text.isEmpty { cell.error = "已取消" }
        } catch {
            cell.elapsedSeconds = Date().timeIntervalSince(started)
            cell.status = .failed
            cell.error = error.localizedDescription
        }
    }

    // MARK: - 导出

    /// 把结果矩阵导出成 CSV(列:问题、各模型一列)。
    /// 每格优先填回答文本,失败 / 取消填 `[错误: …]`。RFC 4180 转义(双引号、换行、逗号)。
    func exportCSV() -> String {
        var lines: [String] = []
        // 表头
        var header = ["问题"]
        header.append(contentsOf: providersUsed.map { $0.displayName })
        lines.append(header.map(Self.csvEscape).joined(separator: ","))

        for p in prompts.indices {
            var row = [prompts[p]]
            for v in providersUsed.indices {
                row.append(cellExportText(prompt: p, provider: v))
            }
            lines.append(row.map(Self.csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n")
    }

    /// 把结果矩阵导出成 Markdown 表格(列:问题、各模型一列)。
    /// 单元格内换行转成 `<br>`,管道符转义,避免破表。
    func exportMarkdown() -> String {
        var out = "# Kown 批量执行结果\n\n"
        out += "- 问题数: \(prompts.count)\n"
        out += "- 模型数: \(providersUsed.count)\n"
        if !systemPrompt.isEmpty {
            out += "- 系统提示: \(systemPrompt)\n"
        }
        out += "\n"

        // 表头
        var header = "| 问题 |"
        var divider = "| --- |"
        for cfg in providersUsed {
            header += " \(Self.mdCell(cfg.displayName)) |"
            divider += " --- |"
        }
        out += header + "\n" + divider + "\n"

        for p in prompts.indices {
            var row = "| \(Self.mdCell(prompts[p])) |"
            for v in providersUsed.indices {
                row += " \(Self.mdCell(cellExportText(prompt: p, provider: v))) |"
            }
            out += row + "\n"
        }
        return out
    }

    /// 单格导出文本:成功填回答,失败 / 取消填 `[错误: …]`,空填 `(无内容)`。
    private func cellExportText(prompt p: Int, provider v: Int) -> String {
        guard let cell = cell(prompt: p, provider: v) else { return "" }
        switch cell.status {
        case .failed, .cancelled:
            return "[错误: \(cell.error ?? "未知")]"
        case .done:
            let t = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "(无内容)" : t
        case .pending, .running:
            return "(未完成)"
        }
    }

    /// CSV 字段转义(RFC 4180):含逗号 / 引号 / 换行时整体加引号,内部引号翻倍。
    private static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// Markdown 表格单元格转义:管道符转义,换行转 `<br>`。
    private static func mdCell(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }
}
