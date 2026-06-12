import SwiftUI

/// Persona(Agent 档案)管理界面(设置 ▸ Persona)。
/// Persona = 系统提示词 + 可选模型覆盖 + 默认工具开关 + 绑定技能/知识库,按会话一键切换。
/// 列表 + 新建/编辑/删除,风格对齐 `SkillsLibraryView`。macOS / iOS 通用。
struct PersonaSettingsView: View {
    @Bindable var viewModel: AppViewModel

    static let tint = Color(red: 0.72, green: 0.34, blue: 0.62)

    @State private var editing: Persona?
    @State private var isCreating = false

    private var store: PersonaStore { viewModel.personaStore }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if store.personas.isEmpty {
                    emptyCard
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(store.personas) { persona in
                            personaCard(persona)
                        }
                    }
                }
            }
            #if os(iOS)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            #else
            .padding(20)
            #endif
            .frame(maxWidth: 1040, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $editing) { persona in
            PersonaEditor(persona: persona, isCreating: isCreating, viewModel: viewModel) { result in
                if isCreating { viewModel.personaStore.add(result) }
                else { viewModel.personaStore.update(result) }
                editing = nil
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                headerText
                Spacer(minLength: 12)
                newButton
            }
            VStack(alignment: .leading, spacing: 10) {
                headerText
                newButton
            }
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Persona(Agent 档案)")
                .font(.headline)
            Text("把「系统提示词 + 默认模型 + 工具/技能/知识库」打包成档案,在输入栏按会话一键切换。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var newButton: some View {
        Button {
            isCreating = true
            editing = Persona(name: "", systemPrompt: "")
        } label: {
            Label("新建 Persona", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(Self.tint)
    }

    private func personaCard(_ persona: Persona) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    PersonaIconView(persona: persona, side: 38, tint: Self.tint)
                    personaText(persona)
                    Spacer(minLength: 8)
                    personaMenu(persona)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        PersonaIconView(persona: persona, side: 38, tint: Self.tint)
                        personaText(persona)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        personaMenu(persona)
                    }
                }
            }
            featureChips(persona)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Self.tint.opacity(0.16), lineWidth: 1)
        }
    }

    private func personaText(_ persona: Persona) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(persona.name.isEmpty ? "未命名 Persona" : persona.name)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(persona.summary.isEmpty ? persona.systemPrompt : persona.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一行特性 chips:模型覆盖 / 工具开关 / 技能数 / 知识库。
    @ViewBuilder
    private func featureChips(_ persona: Persona) -> some View {
        let chips = featureChipTexts(persona)
        if !chips.isEmpty {
            WrappingHStack(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(chips, id: \.text) { chip in
                    Label(chip.text, systemImage: chip.icon)
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Self.tint.opacity(0.13), in: Capsule(style: .continuous))
                        .foregroundStyle(Self.tint)
                }
            }
        }
    }

    private func featureChipTexts(_ persona: Persona) -> [(text: String, icon: String)] {
        var chips: [(String, String)] = []
        if let pid = persona.providerID,
           let cfg = viewModel.providers.first(where: { $0.id == pid }) {
            let model = (persona.modelOverride?.isEmpty == false) ? persona.modelOverride! : cfg.model
            chips.append(("\(cfg.displayName) · \(model)", "cpu"))
        }
        if persona.enableWebSearch { chips.append(("联网搜索", "globe")) }
        if persona.enableDeviceTools { chips.append(("设备工具", "wrench.and.screwdriver")) }
        if persona.enableMCP { chips.append(("MCP", "powerplug")) }
        let skillNames = persona.skillIDs.compactMap { viewModel.skillsStore.skill(id: $0)?.name }
        if !skillNames.isEmpty { chips.append(("技能 ×\(skillNames.count)", "wand.and.stars")) }
        if let fid = persona.knowledgeFolderID,
           let folder = viewModel.knowledgeFolders.first(where: { $0.id == fid }) {
            chips.append(("知识库:\(folder.name)", "books.vertical"))
        }
        return chips
    }

    private func personaMenu(_ persona: Persona) -> some View {
        Menu {
            Button {
                isCreating = false
                editing = persona
            } label: { Label("编辑", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) {
                store.remove(persona)
            } label: { Label("删除", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Persona 操作")
    }

    private var emptyCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "theatermasks")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Self.tint)
                .frame(width: 68, height: 68)
                .background(Self.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("还没有 Persona")
                .font(.headline)
            Text("把常用的「人设 + 模型 + 工具组合」存成档案,输入栏一键切换。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            newButton
        }
        .padding(34)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

// MARK: - Persona 图标(emoji / SF Symbol 自适应)

struct PersonaIconView: View {
    let persona: Persona
    var side: CGFloat = 38
    var tint: Color = PersonaSettingsView.tint

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.32, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if persona.icon.isEmpty {
                Image(systemName: "theatermasks")
                    .font(.system(size: side * 0.42, weight: .bold))
                    .foregroundStyle(tint)
            } else if persona.iconIsSystemSymbol {
                Image(systemName: persona.icon)
                    .font(.system(size: side * 0.42, weight: .bold))
                    .foregroundStyle(tint)
            } else {
                Text(persona.icon)
                    .font(.system(size: side * 0.5))
            }
        }
        .frame(width: side, height: side)
        .fixedSize()
    }
}

// MARK: - 新建 / 编辑

private struct PersonaEditor: View {
    let persona: Persona
    let isCreating: Bool
    @Bindable var viewModel: AppViewModel
    let onSave: (Persona) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var icon: String
    @State private var summary: String
    @State private var systemPrompt: String
    @State private var providerID: UUID?
    @State private var modelOverride: String
    @State private var enableWebSearch: Bool
    @State private var enableDeviceTools: Bool
    @State private var enableMCP: Bool
    @State private var selectedSkillIDs: Set<UUID>
    @State private var knowledgeFolderID: UUID?
    @State private var memoryEnabled: Bool
    /// 展开「该 Persona 的专属记忆」面板。
    @State private var showingMemory = false

    private static let tint = PersonaSettingsView.tint
    /// 图标快捷选项(emoji)。
    private static let iconPresets = ["🎭", "🌐", "🧐", "📊", "💰", "🧑‍💻", "✍️", "🧪", "📚", "🩺", "⚖️", "🎨"]

    init(persona: Persona, isCreating: Bool, viewModel: AppViewModel, onSave: @escaping (Persona) -> Void) {
        self.persona = persona
        self.isCreating = isCreating
        self.viewModel = viewModel
        self.onSave = onSave
        _name = State(initialValue: persona.name)
        _icon = State(initialValue: persona.icon)
        _summary = State(initialValue: persona.summary)
        _systemPrompt = State(initialValue: persona.systemPrompt)
        _providerID = State(initialValue: persona.providerID)
        _modelOverride = State(initialValue: persona.modelOverride ?? "")
        _enableWebSearch = State(initialValue: persona.enableWebSearch)
        _enableDeviceTools = State(initialValue: persona.enableDeviceTools)
        _enableMCP = State(initialValue: persona.enableMCP)
        _selectedSkillIDs = State(initialValue: Set(persona.skillIDs))
        _knowledgeFolderID = State(initialValue: persona.knowledgeFolderID)
        _memoryEnabled = State(initialValue: persona.memoryEnabled)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 可选作模型覆盖的 provider(非 CLI;不要求 enabled — Persona 可点名专用模型)。
    private var candidateProviders: [ProviderConfig] {
        viewModel.providers.filter { !$0.kind.isCLI }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("Persona 名,如 翻译官", text: $name)
                }
                Section("图标") {
                    TextField("emoji 或 SF Symbol 名", text: $icon)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.iconPresets, id: \.self) { preset in
                                Button {
                                    icon = preset
                                } label: {
                                    Text(preset)
                                        .font(.title3)
                                        .frame(width: 34, height: 34)
                                        .background(
                                            (icon == preset ? Self.tint.opacity(0.18) : Color.primary.opacity(0.05)),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section("一句话说明") {
                    TextField("它是干什么的(列表/菜单里展示)", text: $summary)
                }
                Section("系统提示词") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 140)
                        .font(.body)
                    Text("激活该 Persona 的会话发送时,这段会注入 system prompt 最前段。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("默认模型(可选)") {
                    modelPicker
                    Text("设置后,Direct / Translate 单模型会话改用该模型发送;多模型模式不受影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("默认开启的工具") {
                    Toggle("联网搜索", isOn: $enableWebSearch)
                        .tint(Self.tint)
                    Toggle("设备工具(提醒 / 备忘录)", isOn: $enableDeviceTools)
                        .tint(Self.tint)
                    Toggle("MCP 工具", isOn: $enableMCP)
                        .tint(Self.tint)
                    Text("激活时自动点亮(与输入栏开关取「或」)。联网搜索仍需在设置里配好 Firecrawl。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("绑定技能") {
                    if viewModel.skillsStore.skills.isEmpty {
                        Text("还没有技能,可先到「设置 ▸ 技能」创建。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.skillsStore.skills) { skill in
                            Toggle(skill.name, isOn: Binding(
                                get: { selectedSkillIDs.contains(skill.id) },
                                set: { on in
                                    if on { selectedSkillIDs.insert(skill.id) }
                                    else { selectedSkillIDs.remove(skill.id) }
                                }
                            ))
                            .tint(Self.tint)
                        }
                        Text("勾选的技能指示与其工具白名单随 Persona 一并生效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("绑定知识库") {
                    Picker("资料夹", selection: $knowledgeFolderID) {
                        Text("不绑定").tag(UUID?.none)
                        ForEach(viewModel.knowledgeFolders) { folder in
                            Text(folder.name).tag(UUID?.some(folder.id))
                        }
                    }
                    Text("发送时按问题从该资料夹检索片段注入上下文;会话自己绑了资料夹时以会话为准。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("长期记忆") {
                    Toggle("启用专属长期记忆", isOn: $memoryEnabled)
                    Text("开着时,该 Persona 的会话会沉淀专属记忆,发送时注入「全局 + 该 Persona」的记忆;关掉则不抽取、也不注入它的专属记忆(全局记忆仍按「设置 ▸ 记忆」总开关生效)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !isCreating {
                        Button {
                            showingMemory = true
                        } label: {
                            HStack {
                                Label("查看专属记忆", systemImage: "brain")
                                Spacer()
                                Text("\(MemoryStore.shared.items(ownedBy: persona.id).count) 条")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .disabled(!memoryEnabled)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isCreating ? "新建 Persona" : "编辑 Persona")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var result = persona
                        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        result.icon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
                        result.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                        result.systemPrompt = systemPrompt
                        result.providerID = providerID
                        let m = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
                        result.modelOverride = (providerID != nil && !m.isEmpty) ? m : nil
                        result.enableWebSearch = enableWebSearch
                        result.enableDeviceTools = enableDeviceTools
                        result.enableMCP = enableMCP
                        // 保持技能库的稳定顺序。
                        result.skillIDs = viewModel.skillsStore.skills.map(\.id).filter { selectedSkillIDs.contains($0) }
                        result.knowledgeFolderID = knowledgeFolderID
                        result.memoryEnabled = memoryEnabled
                        onSave(result)
                    }
                    .disabled(!canSave)
                }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #else
            .frame(minHeight: 460)
            #endif
            .sheet(isPresented: $showingMemory) {
                PersonaMemorySheet(
                    personaID: persona.id,
                    personaName: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? persona.name : name.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    /// 模型选择 — 仿 ActiveProviderBar 的「厂商 → 模型列表」菜单:
    /// nil = 跟随会话当前模型;已知厂商展开 knownModels ∪ 配置的 model。
    private var modelPicker: some View {
        Menu {
            Button {
                providerID = nil
                modelOverride = ""
            } label: {
                if providerID == nil { Label("跟随会话当前模型", systemImage: "checkmark") }
                else { Text("跟随会话当前模型") }
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
            .foregroundStyle(Self.tint)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .fixedSize()
        #endif
    }

    private func modelChoiceButton(cfg: ProviderConfig, model: String, fullLabel: Bool) -> some View {
        let picked = providerID == cfg.id
            && (modelOverride.isEmpty ? model == cfg.model : model == modelOverride)
        let label = fullLabel ? "\(cfg.displayName) · \(model)" : model
        return Button {
            providerID = cfg.id
            modelOverride = model
        } label: {
            if picked { Label(label, systemImage: "checkmark") }
            else { Text(label) }
        }
    }

    private var currentModelLabel: String {
        guard let pid = providerID,
              let cfg = viewModel.providers.first(where: { $0.id == pid }) else {
            return "跟随会话当前模型"
        }
        let model = modelOverride.isEmpty ? cfg.model : modelOverride
        return "\(cfg.displayName) · \(model)"
    }

    private func uniqueOrdered(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
