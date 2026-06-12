import SwiftUI

/// 项目空间标识色 → SwiftUI 颜色 / 中文名(模型层 `ProjectColor` 只存 rawValue,渲染映射放这里)。
extension ProjectColor {
    var swiftUIColor: Color {
        switch self {
        case .blue:   return .blue
        case .purple: return .purple
        case .pink:   return .pink
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .teal:   return .teal
        case .gray:   return .gray
        }
    }

    var displayName: String {
        switch self {
        case .blue:   return "蓝"
        case .purple: return "紫"
        case .pink:   return "粉"
        case .red:    return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green:  return "绿"
        case .teal:   return "青"
        case .gray:   return "灰"
        }
    }
}

/// 项目空间配置 sheet:名称 / 图标颜色 / 项目级系统提示 / 知识库 / 默认模型。
/// 项目内新建会话自动继承三项配置;优先级:会话级显式设置 > 项目级 > 全局默认。
struct ProjectSettingsSheet: View {
    @Bindable var viewModel: AppViewModel
    let folderID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var promptDraft = ""
    @State private var knowledgeFolderID: UUID?
    @State private var defaultProviderID: UUID?
    @State private var defaultModel = ""
    @State private var icon = "folder.fill"
    @State private var color: ProjectColor?

    /// 可选图标(SF Symbol)— 覆盖常见项目类型,够用且简单。
    private static let iconOptions: [String] = [
        "folder.fill", "briefcase.fill", "book.fill", "graduationcap.fill",
        "hammer.fill", "flask.fill", "paintpalette.fill", "chart.bar.fill",
        "globe.asia.australia.fill", "lightbulb.fill", "heart.fill", "star.fill"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("项目名称") {
                    TextField("项目名称", text: $name)
                }

                Section {
                    iconRow
                    colorRow
                } header: {
                    Text("图标与颜色")
                }

                Section {
                    TextEditor(text: $promptDraft)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                } header: {
                    Text("项目系统提示")
                } footer: {
                    Text("项目内会话未单独设置系统提示时使用;留空回退全局系统提示。")
                }

                Section {
                    Picker("知识库", selection: $knowledgeFolderID) {
                        Text("不绑定").tag(UUID?.none)
                        ForEach(viewModel.knowledgeFolders) { folder in
                            Text(folder.name).tag(UUID?.some(folder.id))
                        }
                    }
                } header: {
                    Text("项目知识库")
                } footer: {
                    Text("项目内会话未单独绑定知识库时,发送会自动检索该资料夹。")
                }

                Section {
                    modelPicker
                } header: {
                    Text("默认模型")
                } footer: {
                    Text("项目内新建会话自动使用该模型(单模型路径);会话内手动换模型优先于项目默认。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("项目设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let choice: ProviderModelChoice? = defaultProviderID.flatMap { pid in
                            let m = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !m.isEmpty else { return nil }
                            return ProviderModelChoice(providerID: pid, model: m)
                        }
                        viewModel.updateProjectSettings(
                            folderID,
                            name: name,
                            systemPrompt: promptDraft,
                            knowledgeFolderID: knowledgeFolderID,
                            defaultModelChoice: choice,
                            icon: icon == "folder.fill" ? nil : icon,
                            color: color)
                        dismiss()
                    }
                }
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }

    /// 从项目当前配置载入草稿。
    private func load() {
        guard let project = viewModel.conversationFolders.first(where: { $0.id == folderID }) else { return }
        name = project.name
        promptDraft = project.projectSystemPrompt ?? ""
        knowledgeFolderID = project.knowledgeFolderID
        defaultProviderID = project.defaultModelChoice?.providerID
        defaultModel = project.defaultModelChoice?.model ?? ""
        icon = project.icon ?? "folder.fill"
        color = project.color
    }

    // MARK: - 图标 / 颜色

    private var iconRow: some View {
        let columns = [GridItem(.adaptive(minimum: 40), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Self.iconOptions, id: \.self) { symbol in
                Button {
                    icon = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(icon == symbol ? tint : Color.secondary)
                        .frame(width: 38, height: 32)
                        .background(
                            icon == symbol ? tint.opacity(0.14) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(icon == symbol ? tint.opacity(0.5) : Color.clear, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("图标 \(symbol)")
            }
        }
        .padding(.vertical, 2)
    }

    private var colorRow: some View {
        HStack(spacing: 8) {
            // 「跟随模式色」= 不指定颜色
            colorSwatch(nil)
            ForEach(ProjectColor.allCases, id: \.self) { c in
                colorSwatch(c)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func colorSwatch(_ c: ProjectColor?) -> some View {
        let picked = color == c
        return Button {
            color = c
        } label: {
            ZStack {
                if let c {
                    Circle().fill(c.swiftUIColor)
                } else {
                    Circle().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                if picked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(c == nil ? Color.secondary : Color.white)
                }
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(c?.displayName ?? "跟随模式色")
        .accessibilityLabel(c?.displayName ?? "跟随模式色")
    }

    private var tint: Color {
        color?.swiftUIColor ?? viewModel.currentMode.kownTint
    }

    // MARK: - 默认模型

    /// 模型选择 — 仿 Persona 编辑器的「厂商 → 模型列表」菜单:
    /// nil = 不指定(跟随全局默认);已知厂商展开 knownModels ∪ 配置的 model。
    private var modelPicker: some View {
        Menu {
            Button {
                defaultProviderID = nil
                defaultModel = ""
            } label: {
                if defaultProviderID == nil { Label("不指定(跟随全局默认)", systemImage: "checkmark") }
                else { Text("不指定(跟随全局默认)") }
            }
            Divider()
            ForEach(candidateProviders) { cfg in
                let known = ProviderModelCatalog.knownModels(for: cfg)
                let union = uniqueOrdered([cfg.model] + known)
                if union.count <= 1 {
                    modelChoiceButton(cfg: cfg, model: cfg.model, fullLabel: true)
                } else {
                    Menu(cfg.displayName) {
                        ForEach(union, id: \.self) { model in
                            modelChoiceButton(cfg: cfg, model: model, fullLabel: false)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption.weight(.bold))
                Text(currentModelLabel)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(tint)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .fixedSize()
        #endif
    }

    private var candidateProviders: [ProviderConfig] {
        viewModel.providers.filter { $0.enabled && !$0.kind.isCLI }
    }

    private func modelChoiceButton(cfg: ProviderConfig, model: String, fullLabel: Bool) -> some View {
        let picked = defaultProviderID == cfg.id && model == defaultModel
        let label = fullLabel ? "\(cfg.displayName) · \(model)" : model
        return Button {
            defaultProviderID = cfg.id
            defaultModel = model
        } label: {
            if picked { Label(label, systemImage: "checkmark") }
            else { Text(label) }
        }
    }

    private var currentModelLabel: String {
        guard let pid = defaultProviderID,
              let cfg = viewModel.providers.first(where: { $0.id == pid }) else {
            return "不指定(跟随全局默认)"
        }
        let model = defaultModel.isEmpty ? cfg.model : defaultModel
        return "\(cfg.displayName) · \(model)"
    }

    private func uniqueOrdered(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
