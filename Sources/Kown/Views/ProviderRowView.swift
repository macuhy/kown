import SwiftUI

struct ProviderRowView: View {
    @Binding var config: ProviderConfig
    let onDelete: () -> Void
    let onSave: () -> Void
    /// Chair 单选语义由父层维护
    let onToggleChair: (Bool) -> Void
    let onToggleSummary: (Bool) -> Void

    @State private var apiKey: String = ""
    @State private var keyDirty: Bool = false
    @State private var lastError: String?
    @State private var lastSuccess: String?
    @State private var showAdvanced: Bool = false
    @State private var testing: Bool = false
    @State private var confirmingDelete: Bool = false
    /// Ollama 拉取到的本地模型名(供 model 选择)。
    @State private var ollamaModels: [String] = []
    @State private var fetchingOllama: Bool = false
    @State private var isHovered: Bool = false
    private let cardCorner: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            fieldsGrid
            advancedDisclosure
            statusBar
        }
        .padding(18)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                kindColor.opacity(isHovered ? 0.15 : 0.09),
                                Color.platformControlBackground.opacity(0.36),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(kindColor.opacity(isHovered ? 0.42 : 0.18), lineWidth: 1)
        }
        .shadow(color: kindColor.opacity(isHovered ? 0.16 : 0.06), radius: isHovered ? 22 : 10, x: 0, y: isHovered ? 12 : 5)
        .opacity(config.enabled ? 1 : 0.78)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
        .onChange(of: config.baseURL) { _, _ in onSave() }
        .onChange(of: config.model)   { _, _ in onSave() }
        .onChange(of: config.displayName) { _, _ in onSave() }
        .confirmationDialog("删除 \(config.displayName)?", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { onDelete() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("该厂商配置会被移除, 对应 API Key 也会从本机 secret store 删除。")
        }
    }

    private var chairButton: some View {
        Button {
            onToggleChair(!config.isChair)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: config.isChair ? "crown.fill" : "crown")
                Text("主席")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(config.isChair ? Color.orange : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill((config.isChair ? Color.orange : .secondary).opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder((config.isChair ? Color.orange : .secondary).opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Council 模式下,主席综合各家答复给出带观点的结论")
    }

    private var summaryButton: some View {
        Button {
            onToggleSummary(!config.isSummary)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: config.isSummary ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                Text("总结")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(config.isSummary ? Color.teal : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill((config.isSummary ? Color.teal : .secondary).opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder((config.isSummary ? Color.teal : .secondary).opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Council 模式下,总结员中立汇总各家答复(共识/分歧/事实),不出立场")
    }

    private var headerRow: some View {
        ViewThatFits(in: .horizontal) {
            providerHeaderWide
            providerHeaderCompact
        }
    }

    private var providerHeaderWide: some View {
        HStack(spacing: 14) {
            providerMark

            VStack(alignment: .leading, spacing: 7) {
                providerChips
                displayNameField
            }
            .layoutPriority(1)

            Spacer()

            providerRoleButtons

            enableToggle

            deleteButton
        }
    }

    private var providerHeaderCompact: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                providerMark
                displayNameField
                    .layoutPriority(1)
                deleteButton
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    providerChips
                    providerRoleButtons
                    enableToggle
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var providerChips: some View {
        HStack(spacing: 6) {
            providerChip(config.kind.displayName, color: kindColor)
            providerChip(config.enabled ? "启用中" : "未启用", color: config.enabled ? .green : .secondary)
            if config.isChair {
                providerChip("Chair", color: .orange)
            }
            if config.isSummary {
                providerChip("Summary", color: .teal)
            }
        }
    }

    private var displayNameField: some View {
        TextField("显示名", text: $config.displayName)
            .textFieldStyle(.roundedBorder)
            .font(.system(.headline, design: .rounded).weight(.semibold))
            .onSubmit { onSave() }
    }

    private var providerRoleButtons: some View {
        HStack(spacing: 8) {
            chairButton
            summaryButton
        }
    }

    private var enableToggle: some View {
        Toggle("启用", isOn: $config.enabled)
            .toggleStyle(.switch)
            .onChange(of: config.enabled) { _, _ in onSave() }
    }

    private var deleteButton: some View {
        Button(role: .destructive) { confirmingDelete = true } label: {
            Image(systemName: "trash")
                .foregroundStyle(.red.opacity(0.75))
        }
        .buttonStyle(.borderless)
        .help("删除厂商")
    }

    private var fieldsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            if config.kind.isCLI {
                cliFieldRows
            } else if config.kind.isAppleFM {
                appleFMFieldRows
            } else {
                httpFieldRows
            }
        }
        .padding(14)
        .background(
            Color.platformTextBackground.opacity(0.28),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var httpFieldRows: some View {
        GridRow {
            label("Base URL")
            TextField(config.kind.defaultBaseURL, text: $config.baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit { onSave() }
        }
        if config.kind == .openAICompatible {
            GridRow {
                label("Vendor")
                ViewThatFits(in: .horizontal) {
                    HStack {
                        vendorPicker
                        vendorHint
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        vendorPicker
                        vendorHint
                    }
                }
            }
        }
        GridRow {
            label("Model")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    modelField
                    modelPickerMenu
                    if config.vendor == "ollama" { ollamaModelButton }
                }
                VStack(alignment: .leading, spacing: 7) {
                    modelField
                    HStack(spacing: 6) {
                        modelPickerMenu
                        if config.vendor == "ollama" { ollamaModelButton }
                    }
                }
            }
        }
        GridRow {
            label("API Key")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    apiKeyField
                    savedKeyBadge
                    keyActionButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    apiKeyField
                    HStack(spacing: 8) {
                        savedKeyBadge
                        keyActionButtons
                    }
                }
            }
        }
    }

    private var vendorPicker: some View {
        Picker("", selection: Binding(
            get: { config.vendor ?? "" },
            set: { newValue in
                config.vendor = newValue.isEmpty ? nil : newValue
                onSave()
            }
        )) {
            Text("(自定义/未指定)").tag("")
            ForEach(ProviderVendor.allCases) { v in
                Text(v.displayName).tag(v.rawValue)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private var vendorHint: some View {
        Text("决定对话里出现哪些可选模型")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var modelField: some View {
        TextField(config.kind.defaultModel, text: $config.model)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .onSubmit { onSave() }
    }

    private var apiKeyField: some View {
        SecureField(keyPlaceholder, text: $apiKey)
            .textFieldStyle(.roundedBorder)
            .onChange(of: apiKey) { _, newValue in keyDirty = !newValue.isEmpty }
    }

    @ViewBuilder
    private var savedKeyBadge: some View {
        if hasStoredKey && !keyDirty && apiKey.isEmpty {
            Label("已保存", systemImage: "key.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.10), in: Capsule())
        }
    }

    private var keyActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                saveKey()
            } label: {
                Label("保存 Key", systemImage: "key.fill")
            }
            .controlSize(.small)
            .disabled(apiKey.isEmpty || !keyDirty)

            Button {
                runTest()
            } label: {
                if testing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("测试中")
                    }
                } else {
                    Label("测试", systemImage: "bolt.horizontal.circle")
                }
            }
            .controlSize(.small)
            .disabled(!canTest)
        }
    }

    @ViewBuilder
    private var cliFieldRows: some View {
        GridRow {
            label("Command")
            TextField("claude / gemini / codex / ...",
                      text: Binding(
                        get: { config.cliCommand ?? "" },
                        set: { config.cliCommand = $0; onSave() }
                      ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .onSubmit { onSave() }
        }
        GridRow {
            label("Args")
            TextField("-p {prompt}",
                      text: Binding(
                        get: { config.cliArgs ?? "" },
                        set: { config.cliArgs = $0; onSave() }
                      ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .onSubmit { onSave() }
        }
        GridRow {
            label("提示")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    cliPromptHint
                    Spacer(minLength: 0)
                    cliTestButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    cliPromptHint
                    cliTestButton
                }
            }
        }
    }

    /// Apple 本地模型:无 URL / 无 Key,只展示说明 + 可用状态 + 测试按钮。
    @ViewBuilder
    private var appleFMFieldRows: some View {
        GridRow {
            label("说明")
            Text("系统内置端侧模型 — 免 API Key、零成本、全离线,数据不出本机。上下文窗口约 4096 token,适合日常问答与短文本处理。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        GridRow {
            label("状态")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    appleFMStatus
                    Spacer(minLength: 0)
                    cliTestButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    appleFMStatus
                    cliTestButton
                }
            }
        }
    }

    /// Apple 本地模型可用性:可用给绿色;不可用直接展示原因(老系统 / 未开 Apple Intelligence / 模型未下载)。
    @ViewBuilder
    private var appleFMStatus: some View {
        if let notice = AppleFMClient.availabilityNotice {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("可用 · 端侧运行", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private var cliPromptHint: some View {
        Text("{prompt} 会被替换成实际输入。不带 {prompt} 则通过 stdin 传入。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cliTestButton: some View {
        Button {
            runTest()
        } label: {
            if testing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("测试中")
                }
            } else {
                Label("测试", systemImage: "bolt.horizontal.circle")
            }
        }
        .controlSize(.small)
        .disabled(testing)
    }

    /// Ollama:拉取本地已安装模型,拉到后用 Menu 选。未运行 / 拉空时给提示。
    @ViewBuilder
    private var ollamaModelButton: some View {
        if ollamaModels.isEmpty {
            Button {
                fetchingOllama = true
                Task {
                    let models = await AppViewModel.fetchOllamaModels(baseURL: config.baseURL)
                    await MainActor.run {
                        ollamaModels = models
                        fetchingOllama = false
                        if models.isEmpty { lastError = "未拉到本地模型(Ollama 是否在运行?)" }
                    }
                }
            } label: {
                if fetchingOllama {
                    ProgressView().controlSize(.small)
                } else {
                    Label("本地模型", systemImage: "arrow.down.circle")
                }
            }
            .controlSize(.small)
            .disabled(fetchingOllama)
        } else {
            Menu {
                ForEach(ollamaModels, id: \.self) { m in
                    Button(m) { config.model = m; onSave() }
                }
                Divider()
                Button("重新拉取") { ollamaModels = [] }
            } label: {
                Label("本地模型", systemImage: "cube.box")
            }
            .controlSize(.small)
        }
    }

    /// 已知 model 列表下拉 — 选了就替换 config.model;允许 TextField 里继续手填自定义值
    @ViewBuilder
    private var modelPickerMenu: some View {
        let models = ProviderModelCatalog.knownModels(for: config)
        if !models.isEmpty {
            Menu {
                ForEach(models, id: \.self) { m in
                    Button {
                        config.model = m
                        onSave()
                    } label: {
                        if m == config.model {
                            Label(m, systemImage: "checkmark")
                        } else {
                            Text(m)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("从已知模型清单选 — 也可直接在文本框里填自定义")
        }
    }

    @ViewBuilder
    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    label("Temperature")
                    HStack {
                        Slider(
                            value: Binding(
                                get: { config.temperature ?? 0.7 },
                                set: { config.temperature = $0; onSave() }
                            ),
                            in: 0...2, step: 0.1
                        )
                        Text(String(format: "%.1f", config.temperature ?? 0.7))
                            .frame(width: 32, alignment: .trailing)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("默认") { config.temperature = nil; onSave() }
                            .buttonStyle(.borderless)
                            .disabled(config.temperature == nil)
                    }
                }
                GridRow {
                    label("Max Tokens")
                    HStack {
                        TextField("不设(默认)", value: Binding(
                            get: { config.maxTokens },
                            set: { config.maxTokens = $0; onSave() }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                        Text(config.kind == .anthropic ? "(Anthropic 必填,默认 32768)" : "")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "dial.low")
                    .foregroundStyle(kindColor)
                Text("高级参数")
                    .font(.caption.weight(.semibold))
                Text(advancedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
        }
        .font(.caption)
        .padding(13)
        .background(
            LinearGradient(
                colors: [kindColor.opacity(0.08), Color.primary.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(kindColor.opacity(0.14), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if let err = lastError {
            resultPill(text: err, icon: "exclamationmark.triangle.fill", color: .red, copyHint: "复制完整错误")
        } else if let ok = lastSuccess {
            resultPill(text: ok, icon: "checkmark.circle.fill", color: .green, copyHint: "复制响应")
        } else if config.enabled && !isEndpointComplete {
            Label("启用前请补全 Base URL 和 Model", systemImage: "info.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
                }
        }
    }

    /// 测试结果展示:**全文 + 可选 + 复制按钮**(成功/失败 共用)。
    /// 之前用 `Label` 会被截断 + 没法复制完整 body,debug provider 配置时不够看。
    private func resultPill(text: String, icon: String, color: Color, copyHint: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
            Text(text)
                .foregroundStyle(color)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Platform.copyText(text)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(copyHint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Helpers

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .gridColumnAlignment(.trailing)
            .foregroundStyle(.secondary)
    }

    private var keyPlaceholder: String {
        hasStoredKey ? "已保存 (留空表示不变)" : "粘贴 API Key"
    }

    private var hasStoredKey: Bool {
        KeychainStore.hasKey(id: config.id)
    }

    private var isEndpointComplete: Bool {
        // Apple 本地模型不需要 Base URL / Key,始终视为配置完整。
        if config.kind.isAppleFM { return true }
        return !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canTest: Bool {
        !testing && isEndpointComplete && (!apiKey.isEmpty || hasStoredKey || !config.kind.needsAPIKey)
    }

    private var advancedSummary: String {
        let temperature = String(format: "T %.1f", config.temperature ?? 0.7)
        let maxTokens = config.maxTokens.map { "\($0) tokens" } ?? "默认 tokens"
        return "\(temperature) · \(maxTokens)"
    }

    private var kindColor: Color {
        config.kownTint
    }

    private var providerMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(kindColor.opacity(0.13))
            Image(systemName: providerSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(kindColor)
        }
        .frame(width: 42, height: 42)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(kindColor.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: kindColor.opacity(0.13), radius: 10, x: 0, y: 5)
    }

    private func providerChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private var providerSymbol: String {
        config.kownSymbol
    }

    private func saveKey() {
        do {
            try KeychainStore.save(id: config.id, apiKey: apiKey)
            apiKey = ""
            keyDirty = false
            onSave()
            flash(success: "API Key 已保存到本机 secret store")
        } catch {
            flash(error: "保存失败: \(error.localizedDescription)")
        }
    }

    private func runTest() {
        lastError = nil
        lastSuccess = nil
        testing = true

        let resolvedKey: String
        if !config.kind.needsAPIKey {
            resolvedKey = ""
        } else {
            do {
                if !apiKey.isEmpty {
                    try KeychainStore.save(id: config.id, apiKey: apiKey)
                    onSave()
                    resolvedKey = apiKey
                    apiKey = ""
                    keyDirty = false
                } else {
                    resolvedKey = try KeychainStore.load(id: config.id)
                }
            } catch {
                testing = false
                flash(error: "读取 Key 失败: \(error.localizedDescription)")
                return
            }
        }

        let snapshot = config
        Task { @MainActor in
            do {
                let sample = try await AppViewModel.testProvider(config: snapshot, apiKey: resolvedKey)
                let preview = sample.isEmpty ? "(空响应)" : "\"\(sample)\""
                flash(success: "连接成功 · 收到 \(preview)")
            } catch {
                flash(error: error.localizedDescription)
            }
            testing = false
        }
    }

    private func flash(success: String) { lastSuccess = success; lastError = nil }
    private func flash(error: String)   { lastError = error; lastSuccess = nil }
}
