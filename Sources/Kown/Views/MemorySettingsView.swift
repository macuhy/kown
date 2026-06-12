import SwiftUI

/// 设置 ▸ 记忆:跨会话长期记忆管理。
/// - 注入开关(默认关,隐私优先):开后发送时回灌相关记忆 + 会话进行中抽取新记忆。
/// - 按归属分组浏览(全局 / 各 Persona):查看、编辑、删除、置顶。
/// - 手动添加一条记忆(可选归属 Persona)。
/// - 一键去重:本地归一化 / 高相似合并,无模型调用。
struct MemorySettingsView: View {
    @Bindable var viewModel: AppViewModel
    private var store = MemoryStore.shared

    @State private var confirmClear = false
    @State private var newMemoryText = ""
    /// 手动添加的归属(nil = 全局)。
    @State private var newMemoryPersonaID: UUID?
    @State private var editingItem: MemoryItem?
    @State private var dedupRunning = false
    @State private var dedupMessage: String?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                toggleCard
                addCard
                listSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .confirmationDialog("清空全部长期记忆?不可恢复。", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { store.clear() }
            Button("取消", role: .cancel) { }
        }
        .sheet(item: $editingItem) { item in
            MemoryEditSheet(item: item)
        }
    }

    // MARK: - 注入开关

    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $viewModel.memoryInjectionEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用跨会话长期记忆")
                        .font(.callout.weight(.semibold))
                    Text("开启后:发送时把相关的长期记忆注入上下文,并在会话进行中自动抽取新的长期记忆。默认关闭(隐私优先)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if viewModel.memoryInjectionEnabled {
                Label("绑定了 Persona 的会话,新记忆会归属该 Persona;回灌时注入「全局 + 当前 Persona」的记忆,置顶条目永远优先。", systemImage: "person.text.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("当前关闭:不会注入,也不会抽取新记忆。已存的记忆保留,可在下方查看 / 删除。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 2)
            Toggle(isOn: $viewModel.recallEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用跨对话语义召回")
                        .font(.callout.weight(.semibold))
                    Text("开启后:发送时自动从你过去的会话里捞与当前问题相关的片段,作为参考注入上下文。默认关闭(隐私优先)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: - 手动添加

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动添加一条记忆")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("如:我偏好简洁、直接的回答", text: $newMemoryText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManual)
                attributionMenu
                Button {
                    addManual()
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    /// 归属选择:全局 / 某个 Persona(新记忆只注入到对应 Persona 的会话)。
    private var attributionMenu: some View {
        Menu {
            Button {
                newMemoryPersonaID = nil
            } label: {
                if newMemoryPersonaID == nil { Label("全局", systemImage: "checkmark") }
                else { Text("全局") }
            }
            if !viewModel.personaStore.personas.isEmpty {
                Divider()
                ForEach(viewModel.personaStore.personas) { persona in
                    Button {
                        newMemoryPersonaID = persona.id
                    } label: {
                        if newMemoryPersonaID == persona.id { Label(persona.name, systemImage: "checkmark") }
                        else { Text(persona.name) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: newMemoryPersonaID == nil ? "globe" : "person.text.rectangle")
                    .font(.caption2.weight(.bold))
                Text(attributionLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .fixedSize()
        #endif
    }

    private var attributionLabel: String {
        guard let pid = newMemoryPersonaID,
              let persona = viewModel.personaStore.persona(id: pid) else { return "全局" }
        return persona.name
    }

    private func addManual() {
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 归属的 Persona 可能已被删除 → 落回全局。
        let pid = viewModel.personaStore.persona(id: newMemoryPersonaID)?.id
        store.add(text: text, personaID: pid)
        newMemoryText = ""
    }

    // MARK: - 分组列表

    /// 一个归属分组:全局 / 某 Persona / 已删除 Persona 的遗留组。
    private struct MemoryGroup: Identifiable {
        let id: String
        let title: String
        let icon: String
        let items: [MemoryItem]
    }

    /// 先全局,再按 PersonaStore 顺序列出有记忆的 Persona,最后是「已删除 Persona」的遗留组。
    private var groups: [MemoryGroup] {
        let byOwner = Dictionary(grouping: store.items, by: { $0.personaID })
        var out: [MemoryGroup] = []
        out.append(MemoryGroup(id: "global", title: "全局记忆", icon: "globe",
                               items: byOwner[UUID?.none] ?? []))
        var seen = Set<UUID>()
        for persona in viewModel.personaStore.personas {
            seen.insert(persona.id)
            let owned = byOwner[persona.id] ?? []
            guard !owned.isEmpty else { continue }
            out.append(MemoryGroup(id: persona.id.uuidString,
                                   title: persona.name.isEmpty ? "未命名 Persona" : persona.name,
                                   icon: "person.text.rectangle", items: owned))
        }
        let orphans = byOwner.keys.compactMap { $0 }.filter { !seen.contains($0) }
        for key in orphans.sorted(by: { $0.uuidString < $1.uuidString }) {
            out.append(MemoryGroup(id: key.uuidString, title: "已删除的 Persona",
                                   icon: "person.slash", items: byOwner[key] ?? []))
        }
        return out
    }

    @ViewBuilder
    private var listSection: some View {
        if store.items.isEmpty {
            emptyState
        } else {
            HStack(spacing: 10) {
                Text("\(store.items.count) / \(MemoryStore.maxItems) 条记忆")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    runDedup()
                } label: {
                    Label(dedupRunning ? "去重中…" : "一键去重", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(dedupRunning || store.items.count < 2)
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("清空", systemImage: "trash").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
            if let msg = dedupMessage {
                Label(msg, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(groups.filter { !$0.items.isEmpty }) { group in
                    groupSection(group)
                }
            }
        }
    }

    private func groupSection(_ group: MemoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: group.icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.purple)
                Text(group.title)
                    .font(.caption.weight(.bold))
                Text("\(group.items.count) 条")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            ForEach(group.items) { item in
                MemoryItemRowView(
                    item: item,
                    onPin: { store.setPinned(item.id, !item.pinned) },
                    onEdit: { editingItem = item },
                    onDelete: { store.remove(item.id) }
                )
            }
        }
    }

    /// 一键去重:计划在后台算(MemoryStore.deduplicate 内部 Task.detached),结果回主线程应用。
    private func runDedup() {
        dedupRunning = true
        dedupMessage = nil
        Task { @MainActor in
            let merged = await MemoryStore.shared.deduplicate()
            dedupRunning = false
            dedupMessage = merged > 0 ? "已合并 \(merged) 条重复记忆" : "没有发现重复记忆"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 62, height: 62)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("还没有长期记忆").font(.headline.weight(.bold))
            Text("开启上方开关后,会话进行中会自动沉淀长期有用的事实与偏好;也可以在上面手动添加。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 单条记忆行(设置页 / Persona 记忆面板共用)

struct MemoryItemRowView: View {
    let item: MemoryItem
    let onPin: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: item.pinned ? "pin.fill" : "brain")
                    .font(.caption2)
                    .foregroundStyle(item.pinned ? .orange : .purple)
                if item.pinned {
                    badge("置顶", color: .orange)
                }
                if item.sourceConversationID == nil {
                    badge("手动", color: .secondary)
                }
                Spacer(minLength: 6)
                Text(Self.dateFmt.string(from: item.createdAt)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(item.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Spacer()
                Button {
                    onPin()
                } label: {
                    Label(item.pinned ? "取消置顶" : "置顶", systemImage: item.pinned ? "pin.slash" : "pin")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                Button {
                    onEdit()
                } label: {
                    Label("编辑", systemImage: "pencil").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(item.pinned ? Color.orange.opacity(0.25) : Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - 编辑一条记忆

struct MemoryEditSheet: View {
    let item: MemoryItem
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(item: MemoryItem) {
        self.item = item
        _text = State(initialValue: item.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("记忆内容") {
                    TextEditor(text: $text)
                        .frame(minHeight: 110)
                        .font(.body)
                    Text("一句话事实 / 偏好,发送时按相关性注入上下文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑记忆")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        MemoryStore.shared.updateText(item.id, text: text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 280)
            #endif
        }
    }
}

// MARK: - 某个 Persona 的专属记忆面板(PersonaSettingsView 入口)

struct PersonaMemorySheet: View {
    let personaID: UUID
    let personaName: String
    @Environment(\.dismiss) private var dismiss
    private var store = MemoryStore.shared

    @State private var editingItem: MemoryItem?
    @State private var newText = ""

    init(personaID: UUID, personaName: String) {
        self.personaID = personaID
        self.personaName = personaName
    }

    private var owned: [MemoryItem] {
        store.items(ownedBy: personaID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("给「\(personaName)」添加一条专属记忆", text: $newText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addNew)
                        Button {
                            addNew()
                        } label: {
                            Label("添加", systemImage: "plus").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if owned.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "brain")
                                .font(.system(size: 26, weight: .semibold)).foregroundStyle(.secondary)
                            Text("该 Persona 还没有专属记忆")
                                .font(.callout.weight(.semibold))
                            Text("它的会话进行中会自动沉淀;也可以在上面手动添加。")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(owned) { item in
                                MemoryItemRowView(
                                    item: item,
                                    onPin: { store.setPinned(item.id, !item.pinned) },
                                    onEdit: { editingItem = item },
                                    onDelete: { store.remove(item.id) }
                                )
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle("\(personaName) 的记忆(\(owned.count) 条)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editingItem) { item in
                MemoryEditSheet(item: item)
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 420)
            #endif
        }
    }

    private func addNew() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.add(text: text, personaID: personaID)
        newText = ""
    }
}
