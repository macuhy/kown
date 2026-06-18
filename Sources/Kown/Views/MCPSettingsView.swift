import SwiftUI

/// MCP 设置(设置 ▸ MCP)。挂载外部 MCP server,把其工具暴露给模型。
/// 总开关 + server 列表(启用 / 测试连接 / 删除)+ 新增。macOS / iOS 通用(stdio 仅 macOS)。
struct MCPSettingsView: View {
    @Bindable var viewModel: AppViewModel

    private static let tint = Color(red: 0.26, green: 0.54, blue: 0.80)

    enum TestOutcome { case success(Int); case failure(String) }

    @State private var showAdd = false
    @State private var editing: MCPServerConfig?
    /// 测试连接结果:serverID → (成功工具数 / 错误文案)。
    @State private var testResults: [UUID: TestOutcome] = [:]
    @State private var testing: Set<UUID> = []
    @State private var kownServerStatus: String?
    @State private var kownConfigCopied = false

    private var store: MCPStore { viewModel.mcpStore }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                kownMCPServerCard
                if store.servers.isEmpty {
                    emptyCard
                } else {
                    ForEach(store.servers) { server in
                        serverCard(server)
                    }
                }
                usageCard
            }
            #if os(iOS)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            #else
            .padding(20)
            #endif
            .frame(maxWidth: 760, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .sheet(isPresented: $showAdd) {
            MCPServerEditSheet(server: nil) { store.add($0) }
        }
        .sheet(item: $editing) { server in
            MCPServerEditSheet(server: server) { store.update($0) }
        }
    }

    private var kownMCPServerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    kownServerTitle
                    Spacer(minLength: 10)
                    kownServerActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    kownServerTitle
                    kownServerActions
                }
            }
            Text("把 Kown 自己暴露成 MCP Server,让 Claude Desktop、Cursor、Codex 等外部工具读取你的会话、长期记忆和项目上下文。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("数据目录: \(KownMCPServerService.dataDir.path)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let kownServerStatus {
                Label(kownServerStatus, systemImage: kownServerStatus.hasPrefix("失败") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(kownServerStatus.hasPrefix("失败") ? .orange : .green)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Self.tint.opacity(0.18), lineWidth: 1)
        }
    }

    private var kownServerTitle: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.title3.weight(.bold))
                .foregroundStyle(Self.tint)
                .frame(width: 38, height: 38)
                .background(Self.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Kown MCP Server")
                    .font(.headline)
                Text("把 Kown 作为个人上下文中枢接给外部 AI 工具")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var kownServerActions: some View {
        HStack(spacing: 8) {
            Button {
                do {
                    let url = try KownMCPServerService.installOrUpdate()
                    kownServerStatus = "已安装: \(url.lastPathComponent)"
                } catch {
                    kownServerStatus = "失败: \(error.localizedDescription)"
                }
            } label: {
                Label("安装/更新", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.tint)

            Button {
                Platform.copyText(KownMCPServerService.claudeConfigSnippet())
                withAnimation { kownConfigCopied = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation { kownConfigCopied = false }
                }
            } label: {
                Label(kownConfigCopied ? "已复制配置" : "复制配置", systemImage: kownConfigCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Button {
                Platform.revealInExplorer(KownMCPServerService.scriptURL)
            } label: {
                Label("定位脚本", systemImage: "folder")
            }
            .buttonStyle(.borderless)
        }
        .font(.caption.weight(.semibold))
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    heroTitle
                    Spacer(minLength: 16)
                    masterSwitch
                }
                VStack(alignment: .leading, spacing: 12) {
                    heroTitle
                    masterSwitch
                }
            }
            HStack(spacing: 8) {
                statusChip(
                    title: viewModel.mcpEnabledForNextSend ? "发送时可用" : "发送时关闭",
                    icon: viewModel.mcpEnabledForNextSend ? "checkmark.seal.fill" : "power",
                    color: viewModel.mcpEnabledForNextSend ? Self.tint : .secondary
                )
                statusChip(title: "已启用 \(store.enabledServers.count)/\(store.servers.count)",
                           icon: "powerplug", color: Self.tint)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var heroTitle: some View {
        HStack(spacing: 12) {
            Image(systemName: "powerplug.fill")
                .font(.title2)
                .foregroundStyle(Self.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP 工具").font(.headline)
                Text("挂载外部 server,把它的工具交给模型用").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var masterSwitch: some View {
        Toggle(isOn: $viewModel.mcpEnabledForNextSend) {
            Text("本次发送启用").font(.subheadline)
        }
        .toggleStyle(.switch)
        .tint(Self.tint)
        .fixedSize()
    }

    // MARK: - Cards

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("还没有挂载任何 MCP server").font(.subheadline.weight(.medium))
            Text("点下方「新增 server」,填一个远程 HTTP/SSE 端点;macOS 还可以填本地命令(如 npx)。")
                .font(.caption).foregroundStyle(.secondary)
            addButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func serverCard(_ server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: server.transport.isStdio ? "terminal" : "globe")
                    .foregroundStyle(Self.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name).font(.subheadline.weight(.semibold))
                    Text(server.transport.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                    Text("命名空间 mcp__\(server.slug)__*").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { store.setEnabled(server.id, $0) }
                ))
                .labelsHidden().toggleStyle(.switch).tint(Self.tint)
            }

            if let result = testResults[server.id] {
                switch result {
                case .success(let n):
                    Label("连接成功 · 发现 \(n) 个工具", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case .failure(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task { await test(server) }
                } label: {
                    if testing.contains(server.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("测试连接", systemImage: "bolt.horizontal.circle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(testing.contains(server.id))

                Button { editing = server } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(role: .destructive) {
                    testResults[server.id] = nil
                    store.remove(server)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.servers.isEmpty { addButton }
            Text("怎么用").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("开启总开关后,发送时会连接已启用的 server,把它们的工具并入模型可用工具集。"
                 + "工具名带 mcp__ 前缀,在回答上方的步骤树里可见调用过程。连不上的 server 会被自动跳过。")
                .font(.caption).foregroundStyle(.secondary)
            #if os(macOS)
            Text("本地 stdio 命令通过 /usr/bin/env 解析,已自动补上 Homebrew / npm 常见路径。")
                .font(.caption2).foregroundStyle(.tertiary)
            #else
            Text("iOS 仅支持远程 HTTP/SSE server(沙箱不能启动本地子进程)。")
                .font(.caption2).foregroundStyle(.tertiary)
            #endif
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var addButton: some View {
        Button { showAdd = true } label: {
            Label("新增 server", systemImage: "plus.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(Self.tint)
    }

    private func statusChip(title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - 测试连接

    private func test(_ server: MCPServerConfig) async {
        testing.insert(server.id)
        testResults[server.id] = nil
        defer { testing.remove(server.id) }
        let conn = MCPConnection(config: server)
        do {
            let (tools, _) = try await withTimeout(seconds: 25) {
                try await conn.connectAndListTools()
            }
            testResults[server.id] = .success(tools.count)
        } catch {
            testResults[server.id] = .failure(error.localizedDescription)
        }
        await conn.close()
    }
}

// MARK: - 新增 / 编辑 sheet

private struct MCPServerEditSheet: View {
    let server: MCPServerConfig?
    let onSave: (MCPServerConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable { case http, stdio; var id: String { rawValue } }

    @State private var name: String
    @State private var kind: Kind
    @State private var url: String
    @State private var headersText: String
    @State private var command: String
    @State private var argsText: String
    @State private var envText: String

    init(server: MCPServerConfig?, onSave: @escaping (MCPServerConfig) -> Void) {
        self.server = server
        self.onSave = onSave
        _name = State(initialValue: server?.name ?? "")
        switch server?.transport {
        case .http(let u, let h):
            _kind = State(initialValue: .http)
            _url = State(initialValue: u)
            _headersText = State(initialValue: h.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
            _command = State(initialValue: "")
            _argsText = State(initialValue: "")
            _envText = State(initialValue: "")
        case .stdio(let c, let a, let e):
            _kind = State(initialValue: .stdio)
            _url = State(initialValue: "")
            _headersText = State(initialValue: "")
            _command = State(initialValue: c)
            _argsText = State(initialValue: a.joined(separator: "\n"))
            _envText = State(initialValue: e.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        case nil:
            _kind = State(initialValue: .http)
            _url = State(initialValue: "")
            _headersText = State(initialValue: "")
            _command = State(initialValue: "")
            _argsText = State(initialValue: "")
            _envText = State(initialValue: "")
        }
    }

    private var availableKinds: [Kind] {
        #if os(macOS)
        return Kind.allCases
        #else
        return [.http]
        #endif
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .http: return !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .stdio: return !command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var tint: Color { Color(red: 0.26, green: 0.54, blue: 0.80) }

    private var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "先给这个 server 起个名字。" }
        switch kind {
        case .http:
            return url.trimmingCharacters(in: .whitespaces).isEmpty ? "远程 server 需要填写 HTTP/SSE 端点 URL。" : nil
        case .stdio:
            return command.trimmingCharacters(in: .whitespaces).isEmpty ? "本地 stdio server 需要填写启动命令。" : nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sheetHero
                    basicCard
                    if kind == .http { httpCard } else { stdioCard }
                    helpCard
                }
                .padding(20)
                .frame(maxWidth: 680, alignment: .topLeading)
            }
            .background(Color.platformWindowBackground.opacity(0.35))
            .navigationTitle(server == nil ? "新增 MCP server" : "编辑 server")
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
        }
        #if os(macOS)
        .frame(width: 640, height: 680)
        #else
        .presentationDetents([.large])
        #endif
    }

    private var sheetHero: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: server == nil ? "plus.circle.fill" : "pencil.circle.fill")
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(server == nil ? "新增 MCP server" : "编辑 MCP server")
                    .font(.headline.weight(.bold))
                Text("连接远程 HTTP/SSE 端点,或在 macOS 上启动本地 stdio 命令。保存后可先测试连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
    }

    private var basicCard: some View {
        sheetCard(title: "基本信息", icon: "tag.fill") {
            VStack(alignment: .leading, spacing: 12) {
                inputLabel("名称")
                plainField("例如 Filesystem、Browser、My API", text: $name)

                if availableKinds.count > 1 {
                    inputLabel("传输方式")
                    Picker("传输方式", selection: $kind) {
                        Label("远程 HTTP/SSE", systemImage: "globe").tag(Kind.http)
                        Label("本地 stdio", systemImage: "terminal").tag(Kind.stdio)
                    }
                    .pickerStyle(.segmented)
                } else {
                    Label("iOS 仅支持远程 HTTP/SSE server", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var httpCard: some View {
        sheetCard(title: "远程 HTTP/SSE", icon: "globe") {
            VStack(alignment: .leading, spacing: 12) {
                inputLabel("端点 URL")
                plainField("https://example.com/mcp", text: $url, monospaced: true)
                    .textContentType(.URL)

                inputLabel("请求头(可选,每行 key: value)")
                codeEditor($headersText, minHeight: 92, placeholder: "Authorization: Bearer ...\nX-API-Key: ...")

                Text("如果 server 不需要鉴权,请求头可以留空。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var stdioCard: some View {
        sheetCard(title: "本地 stdio 命令", icon: "terminal") {
            VStack(alignment: .leading, spacing: 12) {
                inputLabel("命令")
                plainField("例如 npx", text: $command, monospaced: true)

                inputLabel("参数(每行一个)")
                codeEditor($argsText, minHeight: 104, placeholder: "-y\n@modelcontextprotocol/server-filesystem\n/Users/me/project")

                inputLabel("环境变量(可选,每行 KEY=VALUE)")
                codeEditor($envText, minHeight: 86, placeholder: "API_KEY=...\nNODE_ENV=production")

                Text("命令会通过 /usr/bin/env 解析,已补上 Homebrew / npm 常见路径。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("保存后会出现在 MCP 列表中。先点「测试连接」确认能发现工具,再打开总开关发送。", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("取消") { dismiss() }
                .buttonStyle(.bordered)
            Spacer()
            Button {
                save()
            } label: {
                Label("保存", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private func sheetCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func inputLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func plainField(_ placeholder: String, text: Binding<String>, monospaced: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .font(monospaced ? .body.monospaced() : .body)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .textFieldStyle(.plain)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Color.platformTextBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }
    }

    private func codeEditor(_ text: Binding<String>, minHeight: CGFloat, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.caption.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: minHeight)
        }
        .background(Color.platformTextBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }

    private func save() {
        let transport: MCPTransport
        switch kind {
        case .http:
            transport = .http(url: url.trimmingCharacters(in: .whitespaces),
                              headers: Self.parsePairs(headersText, separator: ":"))
        case .stdio:
            let args = argsText.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            transport = .stdio(command: command.trimmingCharacters(in: .whitespaces),
                               args: args,
                               env: Self.parsePairs(envText, separator: "="))
        }
        let saved = MCPServerConfig(
            id: server?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            enabled: server?.enabled ?? true,
            transport: transport,
            createdAt: server?.createdAt ?? Date()
        )
        onSave(saved)
        dismiss()
    }

    /// 把多行 "key<sep>value" 解析成字典。sep 是第一个出现的分隔符。
    static func parsePairs(_ text: String, separator: Character) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard let idx = s.firstIndex(of: separator) else { continue }
            let key = String(s[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}
