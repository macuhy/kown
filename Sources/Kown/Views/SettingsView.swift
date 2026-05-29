import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case providers
        case webSearch
        case sync
        case backup
        case usage
        case performance
        case changelog

        var id: String { rawValue }
        var label: String {
            switch self {
            case .providers:   return "厂商"
            case .webSearch:   return "Web Search"
            case .sync:        return "iCloud 同步"
            case .backup:      return "导入/导出"
            case .usage:       return "Token 用量"
            case .performance: return "性能"
            case .changelog:   return "更新日志"
            }
        }
        var symbol: String {
            switch self {
            case .providers:   return "square.stack.3d.up"
            case .webSearch:   return "globe"
            case .sync:        return "icloud"
            case .backup:      return "square.and.arrow.up.on.square"
            case .usage:       return "chart.bar.xaxis"
            case .performance: return "speedometer"
            case .changelog:   return "sparkles"
            }
        }
    }

    @State private var tab: Tab = .providers

    /// 可添加的 provider 类型 — iOS 排除 CLI(沙箱起不了子进程)
    private var addableKinds: [ProviderKind] {
        #if os(macOS)
        return ProviderKind.allCases
        #else
        return ProviderKind.allCases.filter { $0 != .cliCommand }
        #endif
    }

    var body: some View {
        #if os(iOS)
        mobileBody
        #else
        desktopBody
        #endif
    }

    private var desktopBody: some View {
        ZStack {
            SettingsBackdrop()

            VStack(spacing: 0) {
                header
                tabBar

                switch tab {
                case .providers:
                    providersList
                case .webSearch:
                    WebSearchSettingsView(viewModel: viewModel)
                case .sync:
                    ICloudSyncSettingsView(viewModel: viewModel)
                case .backup:
                    BackupSettingsView(viewModel: viewModel)
                case .usage:
                    UsageSettingsView()
                case .performance:
                    PerformanceSettingsView()
                case .changelog:
                    ChangelogView()
                }
            }
        }
    }

    #if os(iOS)
    private var mobileBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mobileTabBar

                Group {
                    switch tab {
                    case .providers:
                        mobileProvidersList
                    case .webSearch:
                        WebSearchSettingsView(viewModel: viewModel)
                    case .sync:
                        ICloudSyncSettingsView(viewModel: viewModel)
                    case .backup:
                        BackupSettingsView(viewModel: viewModel)
                    case .usage:
                        UsageSettingsView()
                    case .performance:
                        PerformanceSettingsView()
                    case .changelog:
                        ChangelogView()
                    }
                }
            }
            .background(Color.platformWindowBackground)
            .navigationTitle(tab.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                if tab == .providers {
                    ToolbarItem(placement: .primaryAction) {
                        addProviderMenu
                    }
                }
            }
        }
    }

    private var mobileTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Tab.allCases) { t in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                tab = t
                            }
                        } label: {
                            Label {
                                Text(t.label)
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: t.symbol)
                            }
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(tab == t ? Color.white : Color.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(tab == t ? Color.accentColor : Color.secondary.opacity(0.12))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        (tab == t ? Color.accentColor : Color.secondary).opacity(tab == t ? 0.35 : 0.20),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .id(t.id)
                        .accessibilityAddTraits(tab == t ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.bar)
            .onChange(of: tab) { _, newTab in
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(newTab.id, anchor: .center)
                }
            }
        }
    }

    private var mobileProvidersList: some View {
        List {
            Section {
                mobileActiveSummary
            }

            Section {
                ForEach($viewModel.providers) { $cfg in
                    NavigationLink {
                        MobileProviderEditorView(
                            config: $cfg,
                            onDelete: {
                                viewModel.removeProvider(cfg.id)
                            },
                            onSave: {
                                viewModel.saveProviders()
                            },
                            onToggleChair: { newValue in
                                viewModel.setChair(cfg.id, isChair: newValue)
                            },
                            onToggleSummary: { newValue in
                                viewModel.setSummary(cfg.id, isSummary: newValue)
                            }
                        )
                    } label: {
                        MobileProviderSummaryRow(config: cfg)
                    }
                }
            } header: {
                Text("供应商")
            } footer: {
                Text("点进任一家即可编辑 Base URL、模型、API Key 和 Council 角色。")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var mobileActiveSummary: some View {
        let active = viewModel.providers.filter(\.enabled).count
        return HStack(spacing: 12) {
            Image(systemName: active == 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(active == 0 ? .orange : .green)
                .frame(width: 34, height: 34)
                .background((active == 0 ? Color.orange : Color.green).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(active == 0 ? "还没有启用模型" : "\(active) 家模型已启用")
                    .font(.headline)
                Text("共 \(viewModel.providers.count) 家供应商配置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            addProviderMenu
                .labelStyle(.iconOnly)
        }
        .padding(.vertical, 4)
    }
    #endif

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.symbol)
                        Text(t.label)
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tab == t ? Color.accentColor : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill((tab == t ? Color.accentColor : .secondary).opacity(0.10))
                    )
                    .overlay(
                        Capsule().strokeBorder((tab == t ? Color.accentColor : .secondary).opacity(0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var providersList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach($viewModel.providers) { $cfg in
                    ProviderRowView(
                        config: $cfg,
                        onDelete: { viewModel.removeProvider(cfg.id) },
                        onSave:   { viewModel.saveProviders() },
                        onToggleChair: { newValue in viewModel.setChair(cfg.id, isChair: newValue) },
                        onToggleSummary: { newValue in viewModel.setSummary(cfg.id, isSummary: newValue) }
                    )
                }
            }
            .padding(18)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("设置")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if tab == .providers {
                activeBadge

                addProviderMenu
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var headerSubtitle: String {
        switch tab {
        case .providers:   return "管理连接、密钥和每个模型的默认生成参数。"
        case .webSearch:   return "配置 Firecrawl 让模型在需要时调用 web_search。"
        case .sync:        return "iCloud 同步 会话、Provider 配置、Web Search 配置 与 API Key。容器对 Files app 隐藏。"
        case .backup:      return "把当前配置(不含会话)导出成 JSON 文件,或从备份恢复。可作为多设备同步的离线备选。"
        case .usage:       return "按天 + 模型查看 token 用量。input / output 分别计,辅助估算成本。"
        case .performance: return "流式响应的渲染节奏。机器卡可以拉长刷新间隔降 CPU。"
        case .changelog:   return "查看每个版本的新功能、修复和改进。"
        }
    }

    private var activeBadge: some View {
        let active = viewModel.providers.filter(\.enabled).count
        return HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
            Text("\(active)/\(viewModel.providers.count) 已启用")
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(active == 0 ? .orange : .green)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background((active == 0 ? Color.orange : Color.green).opacity(0.10), in: Capsule())
    }

    private var addProviderMenu: some View {
        Menu {
            ForEach(addableKinds, id: \.self) { kind in
                Button("添加 \(kind.displayName)") {
                    viewModel.addProvider(kind: kind)
                }
            }
            Divider()
            Section("国内预设") {
                ForEach(ProviderPreset.allCases) { preset in
                    Button("添加 \(preset.menuLabel)") {
                        viewModel.addPreset(preset)
                    }
                }
            }
        } label: {
            Label("添加", systemImage: "plus")
        }
    }
}

private struct SettingsBackdrop: View {
    var body: some View {
        ZStack {
            Color.platformWindowBackground
            LinearGradient(
                colors: [
                    Color.teal.opacity(0.10),
                    Color.orange.opacity(0.08),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

#if os(iOS)
private struct MobileProviderSummaryRow: View {
    let config: ProviderConfig

    var body: some View {
        HStack(spacing: 12) {
            providerMark
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(config.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if config.isChair {
                        roleChip("主席", color: .orange)
                    }
                    if config.isSummary {
                        roleChip("总结", color: .teal)
                    }
                }
                Text("\(config.kind.displayName) · \(config.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(config.enabled ? "启用" : "关闭")
                .font(.caption.weight(.semibold))
                .foregroundStyle(config.enabled ? .green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((config.enabled ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 4)
    }

    private var providerMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(kindColor.opacity(0.13))
            Image(systemName: providerSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(kindColor)
        }
        .frame(width: 40, height: 40)
    }

    private func roleChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var kindColor: Color {
        switch config.kind {
        case .openAICompatible: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .anthropic:        return Color(red: 0.83, green: 0.38, blue: 0.18)
        case .gemini:           return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .cliCommand:       return Color(red: 0.55, green: 0.45, blue: 0.78)
        }
    }

    private var providerSymbol: String {
        switch config.kind {
        case .openAICompatible: return "sparkles"
        case .anthropic:        return "text.book.closed"
        case .gemini:           return "diamond.fill"
        case .cliCommand:       return "terminal"
        }
    }
}

private struct MobileProviderEditorView: View {
    @Binding var config: ProviderConfig
    let onDelete: () -> Void
    let onSave: () -> Void
    let onToggleChair: (Bool) -> Void
    let onToggleSummary: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
    @State private var keyDirty: Bool = false
    @State private var lastError: String?
    @State private var lastSuccess: String?
    @State private var testing: Bool = false
    @State private var confirmingDelete: Bool = false

    var body: some View {
        Form {
            identitySection
            if config.kind.isCLI {
                cliSection
            } else {
                connectionSection
            }
            roleSection
            advancedSection
            statusSection
            dangerSection
        }
        .navigationTitle(config.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: config.displayName) { _, _ in onSave() }
        .onChange(of: config.enabled) { _, _ in onSave() }
        .onChange(of: config.baseURL) { _, _ in onSave() }
        .onChange(of: config.model) { _, _ in onSave() }
        .confirmationDialog("删除 \(config.displayName)?", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("该供应商配置会被移除, 对应 API Key 也会删除。")
        }
    }

    private var identitySection: some View {
        Section {
            HStack(spacing: 12) {
                providerMark
                VStack(alignment: .leading, spacing: 3) {
                    Text(config.kind.displayName)
                        .font(.headline)
                    Text(config.enabled ? "已启用" : "未启用")
                        .font(.caption)
                        .foregroundStyle(config.enabled ? .green : .secondary)
                }
            }
            TextField("显示名", text: $config.displayName)
            Toggle("启用此供应商", isOn: $config.enabled)
        }
    }

    private var connectionSection: some View {
        Section("连接") {
            TextField("Base URL", text: $config.baseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if config.kind == .openAICompatible {
                Picker("厂商标签", selection: Binding(
                    get: { config.vendor ?? "" },
                    set: { newValue in
                        config.vendor = newValue.isEmpty ? nil : newValue
                        onSave()
                    }
                )) {
                    Text("自定义 / 未指定").tag("")
                    ForEach(ProviderVendor.allCases) { vendor in
                        Text(vendor.displayName).tag(vendor.rawValue)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Model", text: $config.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                        Image(systemName: "chevron.down.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("API Key")
                    Spacer()
                    if hasStoredKey && !keyDirty && apiKey.isEmpty {
                        Label("已保存", systemImage: "key.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                SecureField(keyPlaceholder, text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { _, newValue in
                        keyDirty = !newValue.isEmpty
                    }
                HStack(spacing: 10) {
                    Button {
                        saveKey()
                    } label: {
                        Label("保存 Key", systemImage: "key.fill")
                    }
                    .disabled(apiKey.isEmpty || !keyDirty)

                    Button {
                        runTest()
                    } label: {
                        if testing {
                            Label("测试中", systemImage: "hourglass")
                        } else {
                            Label("测试连接", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .disabled(!canTest)
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }

    private var cliSection: some View {
        Section("命令") {
            TextField("Command", text: Binding(
                get: { config.cliCommand ?? "" },
                set: { config.cliCommand = $0; onSave() }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            TextField("Args", text: Binding(
                get: { config.cliArgs ?? "" },
                set: { config.cliArgs = $0; onSave() }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Text("{prompt} 会被替换成实际输入。不带 {prompt} 则通过 stdin 传入。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var roleSection: some View {
        Section("Council 角色") {
            Toggle("主席：综合判断", isOn: Binding(
                get: { config.isChair },
                set: { onToggleChair($0) }
            ))
            Toggle("总结员：中立汇总", isOn: Binding(
                get: { config.isSummary },
                set: { onToggleSummary($0) }
            ))
        }
    }

    private var advancedSection: some View {
        Section("高级参数") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.1f", config.temperature ?? 0.7))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { config.temperature ?? 0.7 },
                    set: { config.temperature = $0; onSave() }
                ), in: 0...2, step: 0.1)
                Button("恢复默认 Temperature") {
                    config.temperature = nil
                    onSave()
                }
                .font(.caption)
                .disabled(config.temperature == nil)
            }
            TextField("Max Tokens (留空使用默认)", value: Binding(
                get: { config.maxTokens },
                set: { config.maxTokens = $0; onSave() }
            ), format: .number)
            .keyboardType(.numberPad)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let err = lastError {
            Section {
                resultBlock(text: err, icon: "exclamationmark.triangle.fill", color: .red, copyLabel: "复制完整错误")
            }
        } else if let ok = lastSuccess {
            Section {
                resultBlock(text: ok, icon: "checkmark.circle.fill", color: .green, copyLabel: "复制响应")
            }
        } else if config.enabled && !isEndpointComplete {
            Section {
                Label("启用前请补全 Base URL 和 Model", systemImage: "info.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 测试结果块(成功/失败共用):全文展示 + 复制按钮
    private func resultBlock(text: String, icon: String, color: Color, copyLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(text)
                    .foregroundStyle(color)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Platform.copyText(text)
            } label: {
                Label(copyLabel, systemImage: "doc.on.doc")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(color)
        }
    }

    private var dangerSection: some View {
        Section {
            Button("删除供应商", role: .destructive) {
                confirmingDelete = true
            }
        }
    }

    private var providerMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(kindColor.opacity(0.13))
            Image(systemName: providerSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(kindColor)
        }
        .frame(width: 44, height: 44)
    }

    private var keyPlaceholder: String {
        hasStoredKey ? "已保存 (留空表示不变)" : "粘贴 API Key"
    }

    private var hasStoredKey: Bool {
        KeychainStore.hasKey(id: config.id)
    }

    private var isEndpointComplete: Bool {
        !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canTest: Bool {
        !testing && isEndpointComplete && (!apiKey.isEmpty || hasStoredKey)
    }

    private var kindColor: Color {
        switch config.kind {
        case .openAICompatible: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .anthropic:        return Color(red: 0.83, green: 0.38, blue: 0.18)
        case .gemini:           return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .cliCommand:       return Color(red: 0.55, green: 0.45, blue: 0.78)
        }
    }

    private var providerSymbol: String {
        switch config.kind {
        case .openAICompatible: return "sparkles"
        case .anthropic:        return "text.book.closed"
        case .gemini:           return "diamond.fill"
        case .cliCommand:       return "terminal"
        }
    }

    private func saveKey() {
        do {
            try KeychainStore.save(id: config.id, apiKey: apiKey)
            apiKey = ""
            keyDirty = false
            flash(success: "API Key 已保存")
        } catch {
            flash(error: "保存失败: \(error.localizedDescription)")
        }
    }

    private func runTest() {
        lastError = nil
        lastSuccess = nil
        testing = true

        let resolvedKey: String
        if config.kind.isCLI {
            resolvedKey = ""
        } else {
            do {
                if !apiKey.isEmpty {
                    try KeychainStore.save(id: config.id, apiKey: apiKey)
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

    private func flash(success: String) {
        lastSuccess = success
        lastError = nil
    }

    private func flash(error: String) {
        lastError = error
        lastSuccess = nil
    }
}
#endif
