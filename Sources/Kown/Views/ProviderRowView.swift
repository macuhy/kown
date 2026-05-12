import SwiftUI

struct ProviderRowView: View {
    @Binding var config: ProviderConfig
    let onDelete: () -> Void
    let onSave: () -> Void

    @State private var apiKey: String = ""
    @State private var keyDirty: Bool = false
    @State private var lastError: String?
    @State private var lastSuccess: String?
    @State private var showAdvanced: Bool = false
    @State private var testing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            fieldsGrid
            advancedDisclosure
            statusBar
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))
        .cornerRadius(8)
        .onChange(of: config.baseURL) { _, _ in onSave() }
        .onChange(of: config.model) { _, _ in onSave() }
    }

    private var headerRow: some View {
        HStack {
            Toggle("", isOn: $config.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: config.enabled) { _, _ in onSave() }

            Text(config.kind.displayName)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(4)

            TextField("显示名", text: $config.displayName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSave() }

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private var fieldsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Base URL").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                TextField(config.kind.defaultBaseURL, text: $config.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onSave() }
            }
            GridRow {
                Text("Model").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                TextField(config.kind.defaultModel, text: $config.model)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onSave() }
            }
            GridRow {
                Text("API Key").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    SecureField(keyPlaceholder, text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { _, _ in keyDirty = true }
                    Button("保存 Key") { saveKey() }
                        .disabled(apiKey.isEmpty || !keyDirty)
                    Button {
                        runTest()
                    } label: {
                        if testing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("测试")
                        }
                    }
                    .disabled(testing || (!keyDirty && !KeychainStore.hasKey(id: config.id) && apiKey.isEmpty))
                }
            }
        }
    }

    @ViewBuilder
    private var advancedDisclosure: some View {
        DisclosureGroup("高级参数", isExpanded: $showAdvanced) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Temperature").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack {
                        Slider(
                            value: Binding(
                                get: { config.temperature ?? 0.7 },
                                set: { config.temperature = $0; onSave() }
                            ),
                            in: 0...2,
                            step: 0.1
                        )
                        Text(String(format: "%.1f", config.temperature ?? 0.7))
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("默认") {
                            config.temperature = nil
                            onSave()
                        }
                        .buttonStyle(.borderless)
                        .disabled(config.temperature == nil)
                    }
                }
                GridRow {
                    Text("Max Tokens").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack {
                        TextField("不设(默认)", value: Binding(
                            get: { config.maxTokens },
                            set: { config.maxTokens = $0; onSave() }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                        Text(config.kind == .anthropic ? "(Anthropic 必填,默认 4096)" : "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var statusBar: some View {
        if let err = lastError {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .textSelection(.enabled)
        } else if let ok = lastSuccess {
            Label(ok, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private var keyPlaceholder: String {
        KeychainStore.hasKey(id: config.id) ? "已保存(留空表示不变)" : "粘贴 API Key"
    }

    private func saveKey() {
        do {
            try KeychainStore.save(id: config.id, apiKey: apiKey)
            apiKey = ""
            keyDirty = false
            flash(success: "API Key 已保存到 Keychain")
        } catch {
            flash(error: "保存失败:\(error.localizedDescription)")
        }
    }

    private func runTest() {
        lastError = nil
        lastSuccess = nil
        testing = true

        // 决定用哪把 key:用户当前输入框非空 → 用它(顺手存到 Keychain);否则从 Keychain 读
        let resolvedKey: String
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
            flash(error: "读取 Key 失败:\(error.localizedDescription)")
            return
        }

        let snapshot = config
        Task { @MainActor in
            do {
                let sample = try await CouncilViewModel.testProvider(config: snapshot, apiKey: resolvedKey)
                let preview = sample.isEmpty ? "(空响应)" : "\"\(sample.prefix(24))…\""
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
