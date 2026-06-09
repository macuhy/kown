import SwiftUI

/// 技能库管理界面(设置 ▸ 技能)。技能 = 系统提示 + 可用工具白名单 + 自动触发关键词。
/// 列表 + 新建/编辑/删除(预设只能禁用)+ 自动触发总开关。macOS / iOS 通用。
struct SkillsLibraryView: View {
    @Bindable var store: SkillsStore
    @Bindable var viewModel: AppViewModel

    private static let tint = Color(red: 0.48, green: 0.36, blue: 0.90)

    @State private var editing: Skill?
    @State private var isCreating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                autoTriggerToggle

                if store.skills.isEmpty {
                    emptyCard
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(store.skills) { skill in
                            skillCard(skill)
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
        .sheet(item: $editing) { skill in
            SkillEditor(skill: skill, isCreating: isCreating) { result in
                if isCreating { store.add(result) } else { store.update(result) }
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
            Text("技能")
                .font(.headline)
            Text("一段系统提示 + 允许调用的工具。命中关键词时自动启用,也可在输入栏手动绑定。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var newButton: some View {
        Button {
            isCreating = true
            editing = Skill(name: "", instructions: "")
        } label: {
            Label("新建技能", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(Self.tint)
    }

    private var autoTriggerToggle: some View {
        Toggle(isOn: $viewModel.skillAutoTriggerEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("按输入自动匹配技能")
                    .font(.subheadline.weight(.semibold))
                Text("关掉后只用手动绑定的技能。纯本地关键词匹配,不额外调模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Self.tint)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Self.tint.opacity(0.16), lineWidth: 1)
        }
    }

    private func skillCard(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    skillIcon
                    skillText(skill)
                    Spacer(minLength: 8)
                    skillActions(skill, includeLabel: false)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        skillIcon
                        skillText(skill)
                    }
                    skillActions(skill, includeLabel: true)
                }
            }

            if !skill.allowedTools.isEmpty {
                toolChips(skill)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(skill.enabled ? 1 : 0.55)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Self.tint.opacity(0.16), lineWidth: 1)
        }
    }

    private var skillIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Self.tint.opacity(0.22), Self.tint.opacity(0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Self.tint)
        }
        .frame(width: 38, height: 38)
        .fixedSize()
    }

    private func skillText(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(skill.name.isEmpty ? "未命名技能" : skill.name)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if skill.isPreset {
                    Text("内置")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Text(skill.summary.isEmpty ? skill.instructions : skill.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func skillActions(_ skill: Skill, includeLabel: Bool) -> some View {
        HStack(spacing: 10) {
            if includeLabel {
                Toggle(isOn: Binding(
                    get: { skill.enabled },
                    set: { store.setEnabled(skill.id, $0) }
                )) {
                    Text(skill.enabled ? "已启用" : "已停用")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .tint(Self.tint)
            } else {
                Toggle("", isOn: Binding(
                    get: { skill.enabled },
                    set: { store.setEnabled(skill.id, $0) }
                ))
                .labelsHidden()
                .tint(Self.tint)
            }
            Spacer(minLength: includeLabel ? 0 : 4)
            skillMenu(skill)
        }
        .fixedSize(horizontal: !includeLabel, vertical: false)
    }

    private func skillMenu(_ skill: Skill) -> some View {
        Menu {
            Button {
                isCreating = false
                editing = skill
            } label: { Label("编辑", systemImage: "pencil") }
            if !skill.isPreset {
                Divider()
                Button(role: .destructive) {
                    store.remove(skill)
                } label: { Label("删除", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("技能操作")
    }

    private func toolChips(_ skill: Skill) -> some View {
        WrappingHStack(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(skill.allowedTools, id: \.self) { name in
                Label(SkillEditor.toolLabel(name), systemImage: "hammer")
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Self.tint.opacity(0.13), in: Capsule(style: .continuous))
                    .foregroundStyle(Self.tint)
            }
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Self.tint)
                .frame(width: 68, height: 68)
                .background(Self.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("还没有技能")
                .font(.headline)
            Text("把常用的「人设 + 工具」存成技能,命中关键词时自动启用。")
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

// MARK: - 新建 / 编辑

private struct SkillEditor: View {
    let skill: Skill
    let isCreating: Bool
    let onSave: (Skill) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var summary: String
    @State private var instructions: String
    @State private var keywordsText: String
    @State private var selectedTools: Set<String>

    private static let tint = Color(red: 0.48, green: 0.36, blue: 0.90)

    /// 可供技能勾选的工具(名 → 展示名)。与 ToolCatalog 对齐。
    static let selectableTools: [(name: String, label: String)] = [
        ("web_search", "联网搜索"),
        ("create_reminder", "创建提醒"),
        ("list_reminders", "查看提醒"),
        ("create_note", "写入备忘录"),
    ]

    static func toolLabel(_ name: String) -> String {
        selectableTools.first { $0.name == name }?.label ?? name
    }

    init(skill: Skill, isCreating: Bool, onSave: @escaping (Skill) -> Void) {
        self.skill = skill
        self.isCreating = isCreating
        self.onSave = onSave
        _name = State(initialValue: skill.name)
        _summary = State(initialValue: skill.summary)
        _instructions = State(initialValue: skill.instructions)
        _keywordsText = State(initialValue: skill.keywords.joined(separator: "、"))
        _selectedTools = State(initialValue: Set(skill.allowedTools))
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var parsedKeywords: [String] {
        keywordsText
            .split(whereSeparator: { $0 == "、" || $0 == "," || $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("技能名,如 提醒助手", text: $name)
                }
                Section("一句话说明") {
                    TextField("它干什么(也参与自动匹配)", text: $summary)
                }
                Section("系统提示") {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 150)
                        .font(.body)
                    Text("可用 {{变量}} 占位。这段会作为系统提示注入选中技能的会话。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("可用工具") {
                    ForEach(Self.selectableTools, id: \.name) { tool in
                        Toggle(tool.label, isOn: Binding(
                            get: { selectedTools.contains(tool.name) },
                            set: { on in
                                if on { selectedTools.insert(tool.name) }
                                else { selectedTools.remove(tool.name) }
                            }
                        ))
                        .tint(Self.tint)
                    }
                    Text("勾选后,该技能生效时这些工具会自动开放给模型(联网搜索仍需在设置里配好 Firecrawl)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("自动触发关键词") {
                    TextField("用、或逗号分隔,如 提醒、记得、别忘", text: $keywordsText, axis: .vertical)
                        .lineLimit(1...3)
                    if !parsedKeywords.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(parsedKeywords, id: \.self) { kw in
                                    Text(kw)
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Self.tint.opacity(0.13), in: Capsule(style: .continuous))
                                        .foregroundStyle(Self.tint)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isCreating ? "新建技能" : "编辑技能")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var result = skill
                        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        result.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                        result.instructions = instructions
                        result.keywords = parsedKeywords
                        // 保持与 selectableTools 一致的稳定顺序。
                        result.allowedTools = Self.selectableTools.map(\.name).filter { selectedTools.contains($0) }
                        onSave(result)
                    }
                    .disabled(!canSave)
                }
            }
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 520)
            #else
            .frame(minHeight: 460)
            #endif
        }
    }
}
