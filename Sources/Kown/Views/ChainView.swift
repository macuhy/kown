import SwiftUI

/// 链式工作流(Prompt Chains):把多个「模型 + 指示模板」步骤连成一条流水线,
/// 前一步输出用 `{{prev}}` 注入下一步、最初输入用 `{{input}}`。逐步执行并展示每段输出。
struct ChainView: View {
    @State private var chains: [PromptChain] = []
    @State private var selectedID: PromptChain.ID?
    /// 当前可选的 provider(已启用、非 CLI),做模型 picker / 默认模型。
    @State private var providers: [ProviderConfig] = []

    @State private var input: String = ""
    @State private var runner: ChainRunner?

    var body: some View {
        HStack(spacing: 0) {
            chainSidebar
                .frame(width: 220)
            Divider()
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: reload)
    }

    private var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return chains.firstIndex(where: { $0.id == id })
    }

    private func reload() {
        providers = ProviderConfigStore.load()
        if chains.isEmpty {
            chains = PromptChainStore.load()
        }
        if selectedID == nil { selectedID = chains.first?.id }
    }

    // MARK: - 侧栏(工作流列表)

    private var chainSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("工作流")
                    .font(.headline)
                Spacer()
                Button {
                    addChain()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新建工作流")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if chains.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("还没有工作流")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("添加示例") { addSample() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(chains) { chain in
                            chainRow(chain)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private func chainRow(_ chain: PromptChain) -> some View {
        let selected = chain.id == selectedID
        return Button {
            selectedID = chain.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(chain.name.isEmpty ? "未命名工作流" : chain.name)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)
                Text("\(chain.steps.count) 步")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 详情(编辑 + 运行)

    @ViewBuilder
    private var detailPane: some View {
        if let idx = selectedIndex {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    chainHeader(idx: idx)
                    stepsEditor(idx: idx)
                    runSection(idx: idx)
                    if let runner, !runner.runs.isEmpty {
                        outputSection(runner: runner)
                    }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("选择或新建一条工作流")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func chainHeader(idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("工作流名称", text: Binding(
                    get: { chains[idx].name },
                    set: { chains[idx].name = $0; persist() }
                ))
                .textFieldStyle(.plain)
                .font(.system(.title2, design: .rounded).weight(.bold))

                Spacer()

                Button(role: .destructive) {
                    deleteChain(idx: idx)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
            Text("把每个步骤串起来:用 {{input}} 代表最初输入,用 {{prev}} 代表上一步的输出。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stepsEditor(idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("步骤")
                    .font(.headline)
                Spacer()
                Button {
                    chains[idx].steps.append(ChainStep())
                    persist()
                } label: {
                    Label("添加步骤", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            if chains[idx].steps.isEmpty {
                Text("还没有步骤,点「添加步骤」开始。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(chains[idx].steps.enumerated()), id: \.element.id) { (stepIdx, _) in
                    stepCard(chainIdx: idx, stepIdx: stepIdx)
                }
            }
        }
    }

    private func stepCard(chainIdx: Int, stepIdx: Int) -> some View {
        let stepCount = chains[chainIdx].steps.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(stepIdx + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor, in: Circle())

                TextField("步骤标题", text: Binding(
                    get: { chains[chainIdx].steps[stepIdx].title },
                    set: { chains[chainIdx].steps[stepIdx].title = $0; persist() }
                ))
                .textFieldStyle(.roundedBorder)

                Spacer(minLength: 4)

                // 上移 / 下移 / 删除
                Button {
                    moveStep(chainIdx: chainIdx, from: stepIdx, to: stepIdx - 1)
                } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(stepIdx == 0)

                Button {
                    moveStep(chainIdx: chainIdx, from: stepIdx, to: stepIdx + 1)
                } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(stepIdx == stepCount - 1)

                Button(role: .destructive) {
                    chains[chainIdx].steps.remove(at: stepIdx)
                    persist()
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
            }

            modelPicker(chainIdx: chainIdx, stepIdx: stepIdx)

            VStack(alignment: .leading, spacing: 4) {
                Text("指示模板")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { chains[chainIdx].steps[stepIdx].instruction },
                    set: { chains[chainIdx].steps[stepIdx].instruction = $0; persist() }
                ))
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 80)
                .padding(6)
                .background(Color.platformControlBackground.opacity(0.5),
                           in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    /// 模型选择:默认 / 某个 provider 的某个 model。
    private func modelPicker(chainIdx: Int, stepIdx: Int) -> some View {
        let current = chains[chainIdx].steps[stepIdx].providerModelChoice
        return HStack(spacing: 8) {
            Text("模型")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Menu {
                Button {
                    chains[chainIdx].steps[stepIdx].providerModelChoice = nil
                    persist()
                } label: {
                    if current == nil { Label("默认模型", systemImage: "checkmark") }
                    else { Text("默认模型") }
                }
                Divider()
                ForEach(providers.filter { !$0.kind.isCLI }) { cfg in
                    let models = modelOptions(for: cfg)
                    Menu(cfg.displayName) {
                        ForEach(models, id: \.self) { m in
                            Button {
                                chains[chainIdx].steps[stepIdx].providerModelChoice =
                                    ProviderModelChoice(providerID: cfg.id, model: m)
                                persist()
                            } label: {
                                if current?.providerID == cfg.id && current?.model == m {
                                    Label(m, systemImage: "checkmark")
                                } else {
                                    Text(m)
                                }
                            }
                        }
                    }
                }
            } label: {
                Text(modelLabel(for: current))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// 某个 provider 可选的 model 列表(catalog 已知 + 当前配置的 model 兜底)。
    private func modelOptions(for cfg: ProviderConfig) -> [String] {
        var models = ProviderModelCatalog.knownModels(for: cfg)
        if !cfg.model.isEmpty && !models.contains(cfg.model) {
            models.insert(cfg.model, at: 0)
        }
        return models.isEmpty ? [cfg.model] : models
    }

    private func modelLabel(for choice: ProviderModelChoice?) -> String {
        guard let choice else { return "默认模型" }
        if let cfg = providers.first(where: { $0.id == choice.providerID }) {
            return "\(cfg.displayName) · \(choice.model)"
        }
        return choice.model
    }

    // MARK: - 运行区

    private func runSection(idx: Int) -> some View {
        let running = runner?.isRunning ?? false
        return VStack(alignment: .leading, spacing: 10) {
            Text("初始输入")
                .font(.headline)
            TextEditor(text: $input)
                .font(.callout)
                .frame(minHeight: 80)
                .padding(6)
                .background(Color.platformControlBackground.opacity(0.5),
                           in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }

            HStack(spacing: 12) {
                if running {
                    Button(role: .destructive) {
                        runner?.cancel()
                    } label: {
                        Label("取消", systemImage: "stop.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        runChain(idx: idx)
                    } label: {
                        Label("运行", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(chains[idx].steps.isEmpty
                              || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let err = runner?.runError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func outputSection(runner: ChainRunner) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("执行结果")
                .font(.headline)
            ForEach(runner.runs) { run in
                StepOutputCard(run: run)
            }
        }
    }

    // MARK: - 操作

    private func runChain(idx: Int) {
        let r = ChainRunner(providers: providers)
        runner = r
        r.run(chain: chains[idx], input: input)
    }

    private func addChain() {
        let c = PromptChain(steps: [ChainStep()])
        chains.insert(c, at: 0)
        selectedID = c.id
        persist()
    }

    private func addSample() {
        let c = PromptChain.sample()
        chains.insert(c, at: 0)
        selectedID = c.id
        persist()
    }

    private func deleteChain(idx: Int) {
        let removed = chains.remove(at: idx)
        if selectedID == removed.id {
            selectedID = chains.first?.id
        }
        persist()
    }

    private func moveStep(chainIdx: Int, from: Int, to: Int) {
        guard to >= 0, to < chains[chainIdx].steps.count else { return }
        let step = chains[chainIdx].steps.remove(at: from)
        chains[chainIdx].steps.insert(step, at: to)
        persist()
    }

    private func persist() {
        PromptChainStore.save(chains)
    }
}

/// 单步输出卡(可折叠)。
private struct StepOutputCard: View {
    @Bindable var run: ChainStepRun
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(run.title.isEmpty ? "步骤" : run.title)
                        .font(.callout.weight(.semibold))
                    Text(run.modelLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                switch run.phase {
                case .failed(let msg):
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                case .skipped:
                    Text("(已跳过)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .pending:
                    Text("(等待中)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                default:
                    if run.output.isEmpty && run.phase == .running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("生成中…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(run.output)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if run.phase == .finished {
                            Button {
                                Platform.copyText(run.output)
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor.opacity(0.3), lineWidth: 1)
        }
    }

    private var statusIcon: some View {
        Group {
            switch run.phase {
            case .pending:  Image(systemName: "circle").foregroundStyle(.secondary)
            case .running:  ProgressView().controlSize(.small)
            case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:   Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .skipped:  Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }
    }

    private var borderColor: Color {
        switch run.phase {
        case .finished: return .green
        case .failed:   return .red
        case .running:  return .accentColor
        default:        return .secondary
        }
    }
}
