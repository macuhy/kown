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

    private var store: MCPStore { viewModel.mcpStore }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
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

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如 Filesystem、My API", text: $name)
                }
                if availableKinds.count > 1 {
                    Section("传输方式") {
                        Picker("传输", selection: $kind) {
                            Text("远程 HTTP/SSE").tag(Kind.http)
                            Text("本地 stdio 命令").tag(Kind.stdio)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                if kind == .http {
                    Section("端点 URL") {
                        TextField("https://example.com/mcp", text: $url)
                            .textContentType(.URL)
                            #if os(iOS)
                            .autocapitalization(.none)
                            #endif
                    }
                    Section("请求头(可选,每行 key: value)") {
                        TextEditor(text: $headersText).frame(minHeight: 60).font(.caption.monospaced())
                    }
                } else {
                    Section("命令") {
                        TextField("例如 npx", text: $command).font(.body.monospaced())
                    }
                    Section("参数(每行一个)") {
                        TextEditor(text: $argsText).frame(minHeight: 80).font(.caption.monospaced())
                    }
                    Section("环境变量(可选,每行 KEY=VALUE)") {
                        TextEditor(text: $envText).frame(minHeight: 60).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle(server == nil ? "新增 MCP server" : "编辑 server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
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
