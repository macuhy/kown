import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings → 「评测台」tab。
///
/// 评测台(回归 / Eval harness):保存一组「问题 + 期望关键词」,在选定的模型上逐个重跑,
/// 把实际输出与期望并排比对、出简易合否。用于在模型版本更新后检测「漂移」。
///
/// 自包含:评测集编辑 + 模型选择 + 运行 / 取消 + 结果矩阵 + CSV / Markdown 导出全在本文件,
/// 不与其它批量执行功能耦合。
struct EvalView: View {
    @Bindable var viewModel: AppViewModel

    @State private var store = EvalSuiteStore()
    @State private var runner = EvalRunner()

    @State private var selectedSuiteID: UUID?
    /// 勾选参与运行的模型(provider id)。
    @State private var selectedProviderIDs: Set<UUID> = []

    #if os(iOS)
    @State private var shareSheet: EvalShareSheetPayload?
    #endif

    private let tint = Color(red: 0.40, green: 0.52, blue: 0.92)
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var isCompact: Bool {
        #if os(iOS)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }

    /// 可参与评测的模型:已启用;iOS 排除 CLI(沙箱起不了子进程)。
    private var evalProviders: [ProviderConfig] {
        viewModel.providers.filter { cfg in
            guard cfg.enabled else { return false }
            #if os(iOS)
            return !cfg.kind.isCLI
            #else
            return true
            #endif
        }
    }

    private var selectedSuite: EvalSuite? {
        guard let id = selectedSuiteID else { return store.suites.first }
        return store.suites.first(where: { $0.id == id }) ?? store.suites.first
    }

    private var chosenProviders: [ProviderConfig] {
        evalProviders.filter { selectedProviderIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                suitePicker
                if let suite = selectedSuite {
                    casesEditor(suite)
                    modelSelector
                    runControls(suite)
                    if runner.totalCount > 0 {
                        resultMatrix(suite)
                    }
                } else {
                    emptyState
                }
            }
            .padding(isCompact ? 14 : 20)
            .frame(maxWidth: 1040, alignment: .topLeading)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onAppear {
            if selectedSuiteID == nil { selectedSuiteID = store.suites.first?.id }
            if selectedProviderIDs.isEmpty {
                selectedProviderIDs = Set(evalProviders.map(\.id))
            }
        }
        #if os(iOS)
        .sheet(item: $shareSheet) { payload in
            EvalShareSheet(activityItems: [payload.url])
        }
        #endif
    }

    // MARK: - 评测集选择

    private var suitePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    suitePickerCopy
                    Spacer()
                    addSuiteButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    suitePickerCopy
                    addSuiteButton
                }
            }

            if !store.suites.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.suites) { suite in
                            suitePill(suite)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suitePickerCopy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("评测集")
                .font(.headline)
            Text("保存一组「问题 + 期望关键词」,在多个模型上重跑,检测版本更新后的回归漂移。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addSuiteButton: some View {
        Button {
            let suite = store.addSuite()
            selectedSuiteID = suite.id
            runner.clear()
        } label: {
            Label("新建评测集", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 66, height: 66)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("还没有评测集")
                .font(.headline)
            Text("点「新建评测集」后,添加几道带期望关键词的题目,即可在多个模型上重跑比对。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(34)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - 用例编辑

    private func casesEditor(_ suite: EvalSuite) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    suiteNameField(suite)
                        .frame(maxWidth: 280)
                    Spacer()
                    deleteSuiteButton(suite)
                }
                VStack(alignment: .leading, spacing: 10) {
                    suiteNameField(suite)
                    deleteSuiteButton(suite)
                }
            }

            if suite.cases.isEmpty {
                Text("还没有题目。点下面的「添加题目」开始。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(suite.cases) { c in
                    caseRow(suite: suite, evalCase: c)
                }
            }

            Button {
                store.addCase(toSuite: suite.id)
            } label: {
                Label("添加题目", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func suiteNameField(_ suite: EvalSuite) -> some View {
        TextField("评测集名称", text: Binding(
            get: { suite.name },
            set: { store.renameSuite(suite.id, to: $0) }
        ))
        .textFieldStyle(.roundedBorder)
    }

    private func deleteSuiteButton(_ suite: EvalSuite) -> some View {
        Button(role: .destructive) {
            store.removeSuite(suite.id)
            selectedSuiteID = store.suites.first?.id
            runner.clear()
        } label: {
            Label("删除评测集", systemImage: "trash")
        }
        .buttonStyle(.bordered)
    }

    private func caseRow(suite: EvalSuite, evalCase: EvalCase) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    caseFields(suite: suite, evalCase: evalCase)
                    removeCaseButton(suite: suite, evalCase: evalCase)
                }
                VStack(alignment: .leading, spacing: 8) {
                    caseFields(suite: suite, evalCase: evalCase)
                    removeCaseButton(suite: suite, evalCase: evalCase)
                }
            }
        }
        .padding(10)
        .background(Color.platformControlBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func caseFields(suite: EvalSuite, evalCase: EvalCase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("题目 / Prompt", text: bindingForPrompt(suite: suite, caseID: evalCase.id), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    expectedField(suite: suite, caseID: evalCase.id)
                    noteField(suite: suite, caseID: evalCase.id)
                        .frame(maxWidth: 200)
                }
                VStack(alignment: .leading, spacing: 4) {
                    expectedField(suite: suite, caseID: evalCase.id)
                    noteField(suite: suite, caseID: evalCase.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func expectedField(suite: EvalSuite, caseID: UUID) -> some View {
        TextField("期望关键词(留空=不判合否)", text: bindingForExpected(suite: suite, caseID: caseID))
            .textFieldStyle(.roundedBorder)
    }

    private func noteField(suite: EvalSuite, caseID: UUID) -> some View {
        TextField("备注(可选)", text: bindingForNote(suite: suite, caseID: caseID))
            .textFieldStyle(.roundedBorder)
    }

    private func removeCaseButton(suite: EvalSuite, evalCase: EvalCase) -> some View {
        Button {
            store.removeCase(evalCase.id, fromSuite: suite.id)
        } label: {
            Group {
                if isCompact {
                    Label("删除题目", systemImage: "minus.circle.fill")
                        .labelStyle(.titleAndIcon)
                } else {
                    Label("删除题目", systemImage: "minus.circle.fill")
                        .labelStyle(.iconOnly)
                }
            }
            .foregroundStyle(.red.opacity(0.85))
            .frame(minWidth: isCompact ? 0 : 30, minHeight: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("删除这道评测题目")
    }

    private func suitePill(_ suite: EvalSuite) -> some View {
        let selected = selectedSuite?.id == suite.id
        return Button {
            selectedSuiteID = suite.id
            runner.clear()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.caption.weight(.bold))
                Text(suite.name)
                    .font(.callout.weight(selected ? .semibold : .medium))
                    .lineLimit(1)
                Text("\(suite.cases.count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background((selected ? tint : Color.secondary).opacity(0.18), in: Capsule())
            }
            .foregroundStyle(selected ? tint : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background((selected ? tint : Color.secondary).opacity(selected ? 0.12 : 0.06), in: Capsule())
            .overlay {
                Capsule().strokeBorder((selected ? tint : Color.secondary).opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func bindingForPrompt(suite: EvalSuite, caseID: UUID) -> Binding<String> {
        Binding(
            get: { suite.cases.first(where: { $0.id == caseID })?.prompt ?? "" },
            set: { newValue in
                guard var c = suite.cases.first(where: { $0.id == caseID }) else { return }
                c.prompt = newValue
                store.updateCase(c, inSuite: suite.id)
            }
        )
    }

    private func bindingForExpected(suite: EvalSuite, caseID: UUID) -> Binding<String> {
        Binding(
            get: { suite.cases.first(where: { $0.id == caseID })?.expected ?? "" },
            set: { newValue in
                guard var c = suite.cases.first(where: { $0.id == caseID }) else { return }
                c.expected = newValue
                store.updateCase(c, inSuite: suite.id)
            }
        )
    }

    private func bindingForNote(suite: EvalSuite, caseID: UUID) -> Binding<String> {
        Binding(
            get: { suite.cases.first(where: { $0.id == caseID })?.note ?? "" },
            set: { newValue in
                guard var c = suite.cases.first(where: { $0.id == caseID }) else { return }
                c.note = newValue.isEmpty ? nil : newValue
                store.updateCase(c, inSuite: suite.id)
            }
        )
    }

    // MARK: - 模型选择

    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("参与模型")
                    .font(.headline)
                Spacer()
                if !evalProviders.isEmpty {
                    Button(selectedProviderIDs.count == evalProviders.count ? "全不选" : "全选") {
                        if selectedProviderIDs.count == evalProviders.count {
                            selectedProviderIDs = []
                        } else {
                            selectedProviderIDs = Set(evalProviders.map(\.id))
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }

            if evalProviders.isEmpty {
                Label("没有可用模型 — 先在「厂商」里启用至少一个非 CLI 模型。", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                    ForEach(evalProviders) { cfg in
                        providerToggle(cfg)
                    }
                }
            }
        }
    }

    private func providerToggle(_ cfg: ProviderConfig) -> some View {
        let selected = selectedProviderIDs.contains(cfg.id)
        return Button {
            if selected { selectedProviderIDs.remove(cfg.id) }
            else { selectedProviderIDs.insert(cfg.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? tint : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cfg.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(cfg.model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background((selected ? tint : Color.secondary).opacity(selected ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder((selected ? tint : Color.secondary).opacity(0.20), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 运行控制

    private func runControls(_ suite: EvalSuite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if runner.isRunning {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        cancelRunButton
                        runProgressView
                            .frame(maxWidth: 220)
                        runProgressLabel
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        cancelRunButton
                            .frame(maxWidth: isCompact ? .infinity : nil)
                        runProgressView
                        runProgressLabel
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        runButton(suite)
                        if runner.totalCount > 0 {
                            exportResultsMenu(suite)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        runButton(suite)
                            .frame(maxWidth: isCompact ? .infinity : nil)
                        if runner.totalCount > 0 {
                            exportResultsMenu(suite)
                                .frame(maxWidth: isCompact ? .infinity : nil)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cancelRunButton: some View {
        Button(role: .destructive) {
            runner.cancel()
        } label: {
            Label("取消", systemImage: "stop.circle")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(isCompact ? .large : .regular)
    }

    private var runProgressView: some View {
        ProgressView(value: Double(runner.completedCount), total: Double(max(1, runner.totalCount)))
    }

    private var runProgressLabel: some View {
        Text("\(runner.completedCount)/\(runner.totalCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func runButton(_ suite: EvalSuite) -> some View {
        Button {
            runner.run(cases: suite.cases, providers: chosenProviders)
        } label: {
            Label("运行评测", systemImage: "play.fill")
                .frame(maxWidth: isCompact ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(isCompact ? .large : .regular)
        .disabled(chosenProviders.isEmpty || suite.cases.allSatisfy {
            $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        .accessibilityHint("使用当前评测集和已选择模型运行回归评测")
    }

    private func exportResultsMenu(_ suite: EvalSuite) -> some View {
        Menu {
            Button("导出 CSV") { exportCSV(suite) }
            Button("导出 Markdown") { exportMarkdown(suite) }
        } label: {
            Label("导出结果", systemImage: "square.and.arrow.up")
                .frame(maxWidth: isCompact ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .controlSize(isCompact ? .large : .regular)
        .fixedSize(horizontal: !isCompact, vertical: false)
        .accessibilityHint("将当前评测结果导出为 CSV 或 Markdown")
    }

    // MARK: - 结果矩阵

    private func resultMatrix(_: EvalSuite) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("结果矩阵")
                .font(.headline)

            resultSummaryStrip

            if isCompact {
                compactResultCards
            } else {
                matrixResultTable
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var resultSummaryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(runner.runProviders) { p in
                    let s = runner.score(for: p.id)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.displayName)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(s.judged > 0 ? "\(s.pass)/\(s.judged) 通过" : "无判定")
                            .font(.caption2)
                            .foregroundStyle(s.judged > 0 && s.pass == s.judged ? .green : .secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 120, alignment: .leading)
                    .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var matrixResultTable: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    matrixCellFrame { Text("题目").font(.caption.weight(.bold)) }
                        .frame(width: 220)
                    ForEach(runner.runProviders) { p in
                        matrixCellFrame {
                            Text(p.displayName)
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(width: 160)
                    }
                }
                Divider()
                ForEach(runner.runCases) { c in
                    HStack(spacing: 0) {
                        matrixCellFrame {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.prompt)
                                    .font(.caption)
                                    .lineLimit(2)
                                if !c.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("期望: \(c.expected)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(width: 220)
                        ForEach(runner.runProviders) { p in
                            matrixCellFrame { resultCell(caseID: c.id, providerID: p.id) }
                                .frame(width: 160)
                        }
                    }
                    Divider()
                }
            }
        }
        .frame(maxHeight: 420)
    }

    private var compactResultCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("按题目分组查看,每张卡片展示模型状态、输出和耗时。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(runner.runCases.enumerated()), id: \.element.id) { index, evalCase in
                compactCaseResultGroup(index: index, evalCase: evalCase)
            }
        }
    }

    private func compactCaseResultGroup(index: Int, evalCase: EvalCase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("第 \(index + 1) 题")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.12), in: Capsule())

                Text(caseProgressText(evalCase))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(evalCase.prompt)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if !evalCase.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("期望: \(evalCase.expected)", systemImage: "target")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("未设置期望关键词,仅记录输出", systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let note = evalCase.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(runner.runProviders) { provider in
                    compactProviderResultCard(evalCase: evalCase, provider: provider)
                }
            }
        }
        .padding(12)
        .background(Color.platformControlBackground.opacity(0.50), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func compactProviderResultCard(evalCase: EvalCase, provider: ProviderConfig) -> some View {
        let cell = runner.cell(caseID: evalCase.id, providerID: provider.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(provider.model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if let cell {
                    cellBadge(cell.phase)
                } else {
                    label("未开始", "clock", .secondary)
                }
            }

            if let cell {
                compactCellBody(cell)
            } else {
                Text("尚未生成结果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(phaseBackground(cell), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(phaseBorder(cell), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.displayName) 评测结果")
    }

    @ViewBuilder
    private func compactCellBody(_ cell: EvalRunner.Cell) -> some View {
        if case .failed = cell.phase {
            resultOutputBlock(title: "错误", text: cell.errorText ?? "失败", titleColor: .red, bodyColor: .red)
        } else if !cell.output.isEmpty {
            resultOutputBlock(title: "输出", text: cell.output, titleColor: .secondary, bodyColor: .primary)
        } else {
            Text(emptyResultText(for: cell.phase))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if cell.elapsed > 0 {
            Label(String(format: "耗时 %.1fs", cell.elapsed), systemImage: "timer")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func resultOutputBlock(title: String, text: String, titleColor: Color, bodyColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(titleColor)
            Text(text)
                .font(.caption)
                .foregroundStyle(bodyColor)
                .lineLimit(8)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emptyResultText(for phase: EvalRunner.CellPhase) -> String {
        switch phase {
        case .pending: return "等待运行"
        case .running: return "正在生成输出..."
        case .done: return "无输出"
        case .failed: return "失败"
        }
    }

    private func caseProgressText(_ evalCase: EvalCase) -> String {
        let cells = runner.runProviders.compactMap { runner.cell(caseID: evalCase.id, providerID: $0.id) }
        let done = cells.filter { cell in
            switch cell.phase {
            case .done, .failed: return true
            case .pending, .running: return false
            }
        }.count
        return "\(done)/\(runner.runProviders.count)"
    }

    private func phaseBackground(_ cell: EvalRunner.Cell?) -> Color {
        guard let cell else { return Color.secondary.opacity(0.05) }
        switch cell.phase {
        case .done(let pass):
            if let pass { return (pass ? Color.green : Color.red).opacity(0.08) }
            return tint.opacity(0.07)
        case .failed:
            return Color.red.opacity(0.08)
        case .running:
            return tint.opacity(0.08)
        case .pending:
            return Color.secondary.opacity(0.05)
        }
    }

    private func phaseBorder(_ cell: EvalRunner.Cell?) -> Color {
        guard let cell else { return Color.primary.opacity(0.06) }
        switch cell.phase {
        case .done(let pass):
            if let pass { return (pass ? Color.green : Color.red).opacity(0.22) }
            return tint.opacity(0.18)
        case .failed:
            return Color.red.opacity(0.22)
        case .running:
            return tint.opacity(0.22)
        case .pending:
            return Color.primary.opacity(0.06)
        }
    }

    private func matrixCellFrame<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func resultCell(caseID: UUID, providerID: UUID) -> some View {
        if let cell = runner.cell(caseID: caseID, providerID: providerID) {
            VStack(alignment: .leading, spacing: 4) {
                cellBadge(cell.phase)
                if case .failed = cell.phase {
                    Text(cell.errorText ?? "失败")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if !cell.output.isEmpty {
                    Text(cell.output)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if cell.elapsed > 0 {
                    Text(String(format: "%.1fs", cell.elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func cellBadge(_ phase: EvalRunner.CellPhase) -> some View {
        switch phase {
        case .pending:
            label("等待", "clock", .secondary)
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("运行中").font(.caption2).foregroundStyle(.secondary)
            }
        case .done(let pass):
            if let pass {
                label(pass ? "通过" : "未通过", pass ? "checkmark.seal.fill" : "xmark.seal.fill", pass ? .green : .red)
            } else {
                label("已完成", "circle.dashed", .secondary)
            }
        case .failed:
            label("失败", "exclamationmark.triangle.fill", .red)
        }
    }

    private func label(_ text: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - 导出

    private func exportCSV(_ suite: EvalSuite) {
        let text = buildCSV(suite)
        let name = sanitizedFileName(suite.name) + "-eval.csv"
        saveText(text, fileName: name)
    }

    private func exportMarkdown(_ suite: EvalSuite) {
        let text = buildMarkdown(suite)
        let name = sanitizedFileName(suite.name) + "-eval.md"
        saveText(text, fileName: name)
    }

    private func sanitizedFileName(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "评测集" : cleaned
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safe = base.components(separatedBy: illegal).joined(separator: "-")
        return safe.count > 60 ? String(safe.prefix(60)) : safe
    }

    private func phaseText(_ phase: EvalRunner.CellPhase) -> String {
        switch phase {
        case .pending: return "等待"
        case .running: return "运行中"
        case .failed:  return "失败"
        case .done(let pass):
            if let pass { return pass ? "通过" : "未通过" }
            return "已完成"
        }
    }

    private func buildCSV(_ suite: EvalSuite) -> String {
        var rows: [String] = []
        var header = ["题目", "期望"]
        for p in runner.runProviders { header.append("\(p.displayName) 合否"); header.append("\(p.displayName) 输出") }
        rows.append(header.map(csvField).joined(separator: ","))
        for c in runner.runCases {
            var cols = [c.prompt, c.expected]
            for p in runner.runProviders {
                if let cell = runner.cell(caseID: c.id, providerID: p.id) {
                    cols.append(phaseText(cell.phase))
                    cols.append(cell.errorText ?? cell.output)
                } else {
                    cols.append("—"); cols.append("")
                }
            }
            rows.append(cols.map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private func csvField(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func buildMarkdown(_ suite: EvalSuite) -> String {
        var out = "# 评测台报告 · \(suite.name)\n\n"
        out += "- 模型: \(runner.runProviders.map(\.displayName).joined(separator: ", "))\n"
        out += "- 题目数: \(runner.runCases.count)\n\n"

        // 汇总
        out += "## 合否汇总\n\n"
        out += "| 模型 | 通过 / 判定 |\n|---|---|\n"
        for p in runner.runProviders {
            let s = runner.score(for: p.id)
            out += "| \(p.displayName) | \(s.judged > 0 ? "\(s.pass)/\(s.judged)" : "无判定") |\n"
        }
        out += "\n"

        // 逐题
        for (i, c) in runner.runCases.enumerated() {
            out += "## 第 \(i + 1) 题\n\n"
            out += "**题目**: \(c.prompt)\n\n"
            if !c.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out += "**期望关键词**: \(c.expected)\n\n"
            }
            for p in runner.runProviders {
                out += "### \(p.displayName)\n\n"

                if let cell = runner.cell(caseID: c.id, providerID: p.id) {
                    out += "- 合否: \(phaseText(cell.phase))"
                    if cell.elapsed > 0 { out += String(format: " · %.1fs", cell.elapsed) }
                    out += "\n\n"

                    if let err = cell.errorText {
                        out += "> 错误: \(err)\n\n"
                    } else {
                        out += "\(cell.output.isEmpty ? "_(无输出)_" : cell.output)\n\n"
                    }
                }
            }
            out += "---\n\n"
        }
        return out
    }

    /// 存文本到文件:macOS 弹 NSSavePanel,iOS 落临时文件后系统分享。
    /// 作法对齐 `MainContentView.saveText`。
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
        shareSheet = EvalShareSheetPayload(url: url)
        #endif
    }
}

#if os(iOS)
/// iOS 导出分享载荷(Identifiable 驱动 .sheet(item:))。
private struct EvalShareSheetPayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct EvalShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
