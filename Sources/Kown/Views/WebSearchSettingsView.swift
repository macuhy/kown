import SwiftUI

struct WebSearchSettingsView: View {
    @Bindable var viewModel: AppViewModel

    @State private var apiKey: String = ""
    @State private var keyDirty: Bool = false
    @State private var lastError: String?
    @State private var lastSuccess: String?
    @State private var testing: Bool = false

    private let tint = Color(red: 0.16, green: 0.48, blue: 0.94)
    private let secondaryTint = Color(red: 0.08, green: 0.70, blue: 0.78)

    var body: some View {
        #if os(iOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                heroCard
                configCard
                keyCard
                statusBar
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(mobileSettingsBackground.ignoresSafeArea())
        .scrollIndicators(.hidden)
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                configCard
                keyCard
                statusBar
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .topLeading)
        }
        #endif
    }

    private var heroCard: some View {
        let enabled = viewModel.webSearchConfig.enabled
        let keyReady = viewModel.hasWebSearchKey
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                iconTile("globe", tint: tint, secondary: secondaryTint)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("Web Search · Firecrawl")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        statusBadge(enabled ? "已启用" : "未启用",
                                    icon: enabled ? "checkmark.seal.fill" : "power",
                                    color: enabled ? .green : .secondary)
                    }
                    Text("配置 Firecrawl 后,在输入栏点亮 🌐 即可让模型按需调用 `web_search` 工具。仅在 OpenAI 兼容 / Anthropic / Gemini 三类 provider 上生效。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                statusBadge(keyReady ? "Key 已保存" : "等待 Key",
                            icon: keyReady ? "key.fill" : "key.slash",
                            color: keyReady ? .green : .orange)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                metricTile(title: "Base URL",
                           value: shortBaseURL,
                           detail: "Firecrawl endpoint",
                           icon: "link",
                           color: tint)
                metricTile(title: "结果上限",
                           value: "\(viewModel.webSearchConfig.resultLimit)",
                           detail: "建议 5-15 条",
                           icon: "number.circle.fill",
                           color: secondaryTint)
                metricTile(title: "默认联网",
                           value: viewModel.alwaysEnableWebSearch ? "开启" : "手动",
                           detail: "新会话自动点亮 🌐",
                           icon: "bolt.fill",
                           color: viewModel.alwaysEnableWebSearch ? .orange : .secondary)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(heroBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.09), radius: 22, x: 0, y: 12)
    }

    private var configCard: some View {
        cardShell(tint: tint) {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("搜索行为", subtitle: "控制工具是否可用,以及新会话是否默认打开联网搜索。", icon: "slider.horizontal.3", color: tint)

                Toggle(isOn: Binding(
                    get: { viewModel.webSearchConfig.enabled },
                    set: { viewModel.webSearchConfig.enabled = $0; viewModel.saveWebSearchConfig() }
                )) {
                    toggleText(title: "启用 Web Search",
                               detail: viewModel.webSearchConfig.enabled ? "输入栏中的 🌐 可以调用 Firecrawl 搜索。" : "关闭后输入栏不会启用 web_search 工具。")
                }
                .toggleStyle(.switch)

                Divider().opacity(0.55)

                Toggle(isOn: Binding(
                    get: { viewModel.alwaysEnableWebSearch },
                    set: { viewModel.alwaysEnableWebSearch = $0 }
                )) {
                    toggleText(title: "新会话默认开启网络搜索",
                               detail: "启动 / 切换会话时自动点亮 🌐,无需每次手动开。手动关只对当次有效。")
                }
                .toggleStyle(.switch)
                .disabled(!viewModel.canEnableWebSearch)

                VStack(alignment: .leading, spacing: 14) {
                    fieldRow(title: "Base URL", detail: "自建 Firecrawl 或官方服务地址。") {
                        TextField("https://api.firecrawl.dev", text: Binding(
                            get: { viewModel.webSearchConfig.baseURL },
                            set: { viewModel.webSearchConfig.baseURL = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .onSubmit { viewModel.saveWebSearchConfig() }
                    }

                    fieldRow(title: "Result Limit", detail: "1-100,Firecrawl 上限。条数越多花的 credit 越多。") {
                        HStack(spacing: 10) {
                            Stepper(value: Binding(
                                get: { viewModel.webSearchConfig.resultLimit },
                                set: {
                                    viewModel.webSearchConfig.resultLimit = max(1, min($0, 100))
                                    viewModel.saveWebSearchConfig()
                                }
                            ), in: 1...100) {
                                Text("\(viewModel.webSearchConfig.resultLimit) 条")
                                    .font(.callout.weight(.semibold))
                                    .monospacedDigit()
                                    .frame(minWidth: 58, alignment: .leading)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var keyCard: some View {
        cardShell(tint: secondaryTint) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .center, spacing: 10) {
                    sectionHeader("Firecrawl API Key", subtitle: "Key 存在 Keychain;留空保存不会覆盖已保存的 Key。", icon: "key.fill", color: secondaryTint)
                    Spacer(minLength: 0)
                    if viewModel.hasWebSearchKey && !keyDirty && apiKey.isEmpty {
                        statusBadge("已保存", icon: "checkmark.circle.fill", color: .green)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        keyField
                        keyButtons
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        keyField
                        keyButtons
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(secondaryTint)
                        .padding(.top, 1)
                    Text("到 firecrawl.dev 注册账号后,在 Dashboard → API Keys 里复制 fc- 开头的 key。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var keyField: some View {
        SecureField(viewModel.hasWebSearchKey ? "已保存 (留空表示不变)" : "fc-...", text: $apiKey)
            .textFieldStyle(.roundedBorder)
            .onChange(of: apiKey) { _, newValue in keyDirty = !newValue.isEmpty }
    }

    private var keyButtons: some View {
        #if os(iOS)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                saveKeyButton
                testKeyButton
                clearKeyButton
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    saveKeyButton
                    testKeyButton
                }
                clearKeyButton
            }
        }
        #else
        HStack(spacing: 8) {
            saveKeyButton
            testKeyButton
            clearKeyButton
        }
        .fixedSize(horizontal: true, vertical: false)
        #endif
    }

    private var saveKeyButton: some View {
        Button {
            saveKey()
        } label: {
            Label("保存", systemImage: "key.fill")
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .disabled(apiKey.isEmpty || !keyDirty)
    }

    private var testKeyButton: some View {
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
        .buttonStyle(.bordered)
        .disabled(!canTest)
    }

    @ViewBuilder
    private var clearKeyButton: some View {
        if viewModel.hasWebSearchKey {
            Button(role: .destructive) {
                viewModel.clearWebSearchKey()
                apiKey = ""
                keyDirty = false
                flash(success: "Key 已清除")
            } label: {
                Label("清除", systemImage: "trash")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .help("清除已保存的 Key")
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if let err = lastError {
            messageBanner(err, icon: "exclamationmark.triangle.fill", color: .red)
        } else if let ok = lastSuccess {
            messageBanner(ok, icon: "checkmark.circle.fill", color: .green)
        }
    }

    // MARK: - Styling helpers

    #if os(iOS)
    private var mobileSettingsBackground: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [tint.opacity(0.13), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 420
            )
            RadialGradient(
                colors: [secondaryTint.opacity(0.10), Color.clear],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 520
            )
        }
    }
    #endif

    private var shortBaseURL: String {
        let raw = viewModel.webSearchConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "未设置" }
        return raw
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private var heroBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.16), secondaryTint.opacity(0.10), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private func iconTile(_ symbol: String, tint: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), secondary.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 58, height: 58)
        .shadow(color: tint.opacity(0.20), radius: 14, x: 0, y: 8)
    }

    private func sectionHeader(_ title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggleText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldRow<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
            content()
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metricTile(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        }
    }

    private func statusBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().strokeBorder(color.opacity(0.18), lineWidth: 1)
            }
            .fixedSize()
    }

    private func messageBanner(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(color.opacity(0.18), lineWidth: 1)
            }
    }

    @ViewBuilder
    private func cardShell<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.08), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 1)
            }
    }

    // MARK: - Actions

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
