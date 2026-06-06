import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 批量执行 / 提示词队列界面。
///
/// 流程:多行粘贴问题(1 行 = 1 题)→ 勾选执行模型 → 运行 → 结果以
/// 「问题 × 模型」矩阵展示(点格看全文)→ 导出 CSV / Markdown。
/// 逐格串行执行(见 `BatchRunner`),不并发以免触发各家速率限制。
struct BatchView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    /// 引擎随视图生命周期存在(关掉 sheet 即释放;运行中关闭会随 Task 取消)。
    @State private var runner = BatchRunner()

    /// 多行问题输入(每行一条)。
    @State private var promptsText: String = ""
    /// 选中的执行模型 id 集合。
    @State private var selectedProviderIDs: Set<UUID> = []
    /// 统一系统提示(可空)。
    @State private var systemPrompt: String = ""

    /// 点开看全文的格子。
    @State private var detailCell: BatchRunner.Cell?

    #if os(iOS)
    /// iOS 导出分享载荷。
    @State private var shareItem: BatchShareItem?
    #endif

    /// 可选执行模型:已启用;iOS 上排除 CLI(沙箱起不了子进程)。
    private var availableProviders: [ProviderConfig] {
        viewModel.providers.filter { p in
            guard p.enabled else { return false }
            #if os(iOS)
            return !p.kind.isCLI
            #else
            return true
            #endif
        }
    }

    /// 多行文本拆出的有效问题数(去空)。
    private var promptLineCount: Int {
        promptsText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    private var canStart: Bool {
        !runner.isRunning && promptLineCount > 0 && !selectedProviderIDs.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if runner.cells.isEmpty {
                    setupForm
                } else {
                    resultsView
                }
            }
            .navigationTitle("批量执行")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .sheet(item: $detailCell) { cell in
                BatchCellDetailSheet(
                    cell: cell,
                    prompt: runner.prompts[cell.promptIndex],
                    providerName: runner.providersUsed[cell.providerIndex].displayName
                )
            }
            #if os(iOS)
            .sheet(item: $shareItem) { item in
                BatchShareSheet(activityItems: [item.url])
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
        .onAppear {
            // 默认全选可用模型,降低上手成本。
            if selectedProviderIDs.isEmpty {
                selectedProviderIDs = Set(availableProviders.map(\.id))
            }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭") { dismiss() }
        }
        if !runner.cells.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                exportMenu
                    .disabled(runner.isRunning)
            }
            ToolbarItem(placement: .automatic) {
                Button("新一批") { runner.reset() }
                    .disabled(runner.isRunning)
            }
        }
    }

    // MARK: - 配置表单

    private var setupForm: some View {
        Form {
            Section {
                TextEditor(text: $promptsText)
                    .font(.body)
                    .frame(minHeight: 140)
            } header: {
                Text("问题列表(每行一条)")
            } footer: {
                Text("共 \(promptLineCount) 条问题。每条会依次发给下面勾选的每个模型。")
            }

            Section("系统提示(可选,对所有问题生效)") {
                TextField("例如:用简洁中文回答", text: $systemPrompt, axis: .vertical)
                    .lineLimit(1...4)
            }

            Section {
                if availableProviders.isEmpty {
                    Text("没有可用的模型。请先在设置里启用至少一个模型。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableProviders) { p in
                        Button {
                            toggle(p.id)
                        } label: {
                            HStack {
                                Image(systemName: selectedProviderIDs.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedProviderIDs.contains(p.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.displayName)
                                    Text(p.model).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("执行模型(已选 \(selectedProviderIDs.count))")
            } footer: {
                Text("将生成 \(promptLineCount) × \(selectedProviderIDs.count) = \(promptLineCount * selectedProviderIDs.count) 个结果,逐个串行执行以免触发限流。")
            }

            Section {
                Button {
                    startRun()
                } label: {
                    Label("开始批量执行", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
        }
        .formStyle(.grouped)
    }

    private func toggle(_ id: UUID) {
        if selectedProviderIDs.contains(id) {
            selectedProviderIDs.remove(id)
        } else {
            selectedProviderIDs.insert(id)
        }
    }

    private func startRun() {
        let lines = promptsText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 保持配置表里的顺序作为矩阵列顺序。
        let chosen = availableProviders.filter { selectedProviderIDs.contains($0.id) }
        runner.start(prompts: lines, providers: chosen, systemPrompt: systemPrompt)
    }

    // MARK: - 结果视图

    private var resultsView: some View {
        VStack(spacing: 0) {
            progressBar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                matrixGrid
                    .padding(12)
            }
        }
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            HStack {
                if runner.isRunning {
                    ProgressView().controlSize(.small)
                    Text("执行中 \(runner.completedCount)/\(runner.totalCount)")
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("已完成 \(runner.completedCount)/\(runner.totalCount)")
                }
                Spacer()
                if runner.isRunning {
                    Button("取消") { runner.cancel() }
                        .buttonStyle(.bordered)
                }
            }
            ProgressView(value: Double(runner.completedCount), total: Double(max(1, runner.totalCount)))
        }
        .padding(12)
    }

    /// 「问题 × 模型」矩阵:首列问题,各列模型,每格一个状态化按钮。
    private var matrixGrid: some View {
        let providerCount = runner.providersUsed.count
        let columns = [GridItem(.fixed(180), spacing: 8)]
            + Array(repeating: GridItem(.fixed(160), spacing: 8), count: providerCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            // 表头行
            Text("问题").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(runner.providersUsed.enumerated()), id: \.offset) { _, cfg in
                Text(cfg.displayName)
                    .font(.caption.bold())
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            // 数据行
            ForEach(runner.prompts.indices, id: \.self) { p in
                Text(runner.prompts[p])
                    .font(.caption)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(0..<providerCount, id: \.self) { v in
                    if let cell = runner.cell(prompt: p, provider: v) {
                        BatchCellButton(cell: cell) { detailCell = cell }
                    } else {
                        Color.clear.frame(height: 64)
                    }
                }
            }
        }
    }

    // MARK: - 导出

    private var exportMenu: some View {
        Menu {
            Button {
                saveText(runner.exportCSV(), fileName: "Kown-批量结果.csv")
            } label: {
                Label("导出为 CSV", systemImage: "tablecells")
            }
            Button {
                saveText(runner.exportMarkdown(), fileName: "Kown-批量结果.md")
            } label: {
                Label("导出为 Markdown", systemImage: "doc.richtext")
            }
            Divider()
            Button {
                Platform.copyText(runner.exportMarkdown())
            } label: {
                Label("复制为 Markdown", systemImage: "doc.on.doc")
            }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
    }

    /// 存文本:macOS 弹 NSSavePanel,iOS 落临时文件后系统分享。
    /// 与 MainContentView.saveText 同一套管线。
    private func saveText(_ text: String, fileName: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        shareItem = BatchShareItem(url: url)
        #endif
    }
}

// MARK: - 单元格按钮

/// 矩阵里的一格:按状态着色,点击看全文。
private struct BatchCellButton: View {
    @Bindable var cell: BatchRunner.Cell
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    statusIcon
                    if let secs = cell.elapsedSeconds, cell.status == .done {
                        Text(String(format: "%.1fs", secs))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text(previewText)
                    .font(.caption2)
                    .lineLimit(3)
                    .foregroundStyle(cell.status == .failed ? Color.red : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(height: 64, alignment: .top)
            .frame(maxWidth: .infinity)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch cell.status {
        case .pending:   Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:   ProgressView().controlSize(.mini)
        case .done:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var previewText: String {
        switch cell.status {
        case .pending:   return "待执行"
        case .running:   return cell.text.isEmpty ? "执行中…" : cell.text
        case .done:      return cell.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(无内容)" : cell.text
        case .failed:    return cell.error ?? "失败"
        case .cancelled: return "已取消"
        }
    }

    private var background: Color {
        switch cell.status {
        case .failed:   return Color.red.opacity(0.08)
        case .done:     return Color.green.opacity(0.06)
        case .running:  return Color.accentColor.opacity(0.08)
        default:        return Color.secondary.opacity(0.05)
        }
    }
}

// MARK: - 单元格详情

/// 点开一格看全文:问题 + 模型 + 完整回答 / 错误 + 用量。
private struct BatchCellDetailSheet: View {
    @Bindable var cell: BatchRunner.Cell
    let prompt: String
    let providerName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    label("问题")
                    Text(prompt).textSelection(.enabled)
                    Divider()
                    label("模型")
                    Text(providerName).textSelection(.enabled)
                    Divider()
                    if let err = cell.error, cell.status == .failed || cell.status == .cancelled {
                        label("错误")
                        Text(err).foregroundStyle(.red).textSelection(.enabled)
                    } else {
                        if !cell.reasoning.isEmpty {
                            label("思考过程")
                            Text(cell.reasoning)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Divider()
                        }
                        label("回答")
                        Text(cell.text.isEmpty ? "(无内容)" : cell.text).textSelection(.enabled)
                    }
                    if cell.inputTokens > 0 || cell.outputTokens > 0 {
                        Divider()
                        Text("用量:输入 \(cell.inputTokens) · 输出 \(cell.outputTokens) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle("结果详情")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("复制") { Platform.copyText(cell.text) }
                        .disabled(cell.text.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.caption.bold()).foregroundStyle(.secondary)
    }
}

#if os(iOS)
/// iOS 导出分享载荷。
private struct BatchShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController 封装(与 MainContentView 私有 ShareSheet 等价,独立一份避免跨文件耦合)。
private struct BatchShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
