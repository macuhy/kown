import SwiftUI

struct WebSearchSettingsView: View {
    @Bindable var viewModel: AppViewModel

    @State private var apiKey: String = ""
    @State private var keyDirty: Bool = false
    @State private var lastError: String?
    @State private var lastSuccess: String?
    @State private var testing: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro
                configCard
                keyCard
                statusBar
            }
            .padding(18)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.blue)
                Text("Web Search · Firecrawl")
                    .font(.system(.title3, design: .serif).weight(.semibold))
            }
            Text("配置 Firecrawl 后,在输入栏点亮 🌐 即可让模型按需调用 `web_search` 工具。\n仅在 OpenAI 兼容 / Anthropic / Gemini 三类 provider 上生效。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("启用 Web Search", isOn: Binding(
                    get: { viewModel.webSearchConfig.enabled },
                    set: { viewModel.webSearchConfig.enabled = $0; viewModel.saveWebSearchConfig() }
                ))
                .toggleStyle(.switch)
                Spacer()
            }
            // 默认联网 — 开启后每次进/切换会话自动点亮 🌐,免去每次手动开
            Toggle(isOn: Binding(
                get: { viewModel.alwaysEnableWebSearch },
                set: { viewModel.alwaysEnableWebSearch = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("新会话默认开启网络搜索")
                        .font(.body)
                    Text("启动 / 切换会话时自动点亮 🌐 ,无需每次手动开。手动关只对当次有效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(!viewModel.canEnableWebSearch)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    label("Base URL")
                    TextField("https://api.firecrawl.dev", text: Binding(
                        get: { viewModel.webSearchConfig.baseURL },
                        set: { viewModel.webSearchConfig.baseURL = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit { viewModel.saveWebSearchConfig() }
                }
                GridRow {
                    label("Result Limit")
                    HStack(spacing: 10) {
                        Stepper(value: Binding(
                            get: { viewModel.webSearchConfig.resultLimit },
                            set: { viewModel.webSearchConfig.resultLimit = max(1, min($0, 100));
                                   viewModel.saveWebSearchConfig() }
                        ), in: 1...100) {
                            Text("\(viewModel.webSearchConfig.resultLimit) 条")
                                .font(.callout)
                                .monospacedDigit()
                                .frame(minWidth: 50, alignment: .leading)
                        }
                        Text("(1-100,Firecrawl 上限。条数越多花的 credit 越多,5-15 通常够用)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                        Spacer()
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.20), lineWidth: 1)
        )
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                label("Firecrawl API Key")
                Spacer()
                if viewModel.hasWebSearchKey && !keyDirty && apiKey.isEmpty {
                    Label("已保存", systemImage: "key.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.10), in: Capsule())
                }
            }
            HStack(spacing: 8) {
                SecureField(viewModel.hasWebSearchKey ? "已保存 (留空表示不变)" : "fc-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { _, newValue in keyDirty = !newValue.isEmpty }
                Button {
                    saveKey()
                } label: {
                    Label("保存", systemImage: "key.fill")
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
                if viewModel.hasWebSearchKey {
                    Button(role: .destructive) {
                        viewModel.clearWebSearchKey()
                        apiKey = ""
                        keyDirty = false
                        flash(success: "Key 已清除")
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .help("清除已保存的 Key")
                }
            }
            Text("到 firecrawl.dev 注册账号后,在 Dashboard → API Keys 里复制 fc- 开头的 key。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.20), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusBar: some View {
        if let err = lastError {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let ok = lastSuccess {
            Label(ok, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Helpers

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private var canTest: Bool {
        !testing && (!apiKey.isEmpty || viewModel.hasWebSearchKey)
    }

    private func saveKey() {
        do {
            try viewModel.setWebSearchKey(apiKey)
            apiKey = ""
            keyDirty = false
            flash(success: "Firecrawl Key 已保存")
        } catch {
            flash(error: "保存失败: \(error.localizedDescription)")
        }
    }

    private func runTest() {
        lastError = nil
        lastSuccess = nil
        testing = true

        let resolvedKey: String
        do {
            if !apiKey.isEmpty {
                try viewModel.setWebSearchKey(apiKey)
                resolvedKey = apiKey
                apiKey = ""
                keyDirty = false
            } else {
                resolvedKey = try WebSearchKey.load()
            }
        } catch {
            testing = false
            flash(error: "读取 Key 失败: \(error.localizedDescription)")
            return
        }

        let baseURL = viewModel.webSearchConfig.baseURL
        Task { @MainActor in
            do {
                let client = FirecrawlClient(baseURL: baseURL, apiKey: resolvedKey)
                let hits = try await client.search(query: "hello world", limit: 1)
                if let first = hits.first {
                    flash(success: "连接成功 · \"\(first.title.prefix(48))\"")
                } else {
                    flash(success: "连接成功 · 0 条结果")
                }
            } catch {
                flash(error: error.localizedDescription)
            }
            testing = false
        }
    }

    private func flash(success: String) { lastSuccess = success; lastError = nil }
    private func flash(error: String)   { lastError = error; lastSuccess = nil }
}
