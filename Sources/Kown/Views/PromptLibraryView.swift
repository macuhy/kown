import SwiftUI

/// Prompt 库 / 模板管理界面(设置里的一个 Tab)。
/// 列表 + 新建/编辑/删除;模板正文支持 `{{变量}}` 占位符;
/// 可「填充变量并复制到剪贴板」。macOS / iOS 通用。
struct PromptLibraryView: View {
    @Bindable var viewModel: PromptLibraryStore

    private static let tint = Color(red: 0.56, green: 0.40, blue: 0.86)

    @State private var editing: PromptTemplate?      // 正在编辑(非空即弹编辑器)
    @State private var isCreating = false            // 编辑器是「新建」还是「修改」
    @State private var filling: PromptTemplate?      // 正在填充变量并复制

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if viewModel.templates.isEmpty {
                    emptyCard
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.templates) { template in
                            templateCard(template)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1040, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $editing) { template in
            PromptTemplateEditor(
                template: template,
                isCreating: isCreating,
                onSave: { result in
                    if isCreating {
                        viewModel.add(title: result.title, body: result.body)
                    } else {
                        viewModel.update(result)
                    }
                    editing = nil
                }
            )
        }
        .sheet(item: $filling) { template in
            PromptFillSheet(store: viewModel, template: template)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("模板")
                    .font(.headline)
                Text("用 {{变量}} 写可复用的 Prompt,填充后一键复制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                isCreating = true
                editing = PromptTemplate(title: "", body: "")
            } label: {
                Label("新建模板", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.tint)
        }
    }

    private func templateCard(_ template: PromptTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Self.tint.opacity(0.22), Self.tint.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "text.quote")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Self.tint)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(template.title.isEmpty ? "未命名模板" : template.title)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .lineLimit(1)
                    Text(template.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Menu {
                    Button {
                        filling = template
                    } label: {
                        Label("填充变量并复制", systemImage: "doc.on.doc")
                    }
                    Button {
                        isCreating = false
                        editing = template
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        viewModel.remove(template)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if !template.variableNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(template.variableNames, id: \.self) { name in
                            Text(name)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Self.tint.opacity(0.13), in: Capsule(style: .continuous))
                                .foregroundStyle(Self.tint)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    filling = template
                } label: {
                    Label("填充并复制", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Self.tint)

                Button {
                    isCreating = false
                    editing = template
                } label: {
                    Label("编辑", systemImage: "pencil")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Self.tint.opacity(0.16), lineWidth: 1)
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Self.tint)
                .frame(width: 68, height: 68)
                .background(Self.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("还没有模板")
                .font(.headline)
            Text("把常用的 Prompt 存成模板,用 {{变量}} 标记可替换的部分,下次填一填就能复用。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                isCreating = true
                editing = PromptTemplate(title: "", body: "")
            } label: {
                Label("新建模板", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.tint)
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

private struct PromptTemplateEditor: View {
    let template: PromptTemplate
    let isCreating: Bool
    let onSave: (PromptTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String

    private static let tint = Color(red: 0.56, green: 0.40, blue: 0.86)

    init(template: PromptTemplate, isCreating: Bool, onSave: @escaping (PromptTemplate) -> Void) {
        self.template = template
        self.isCreating = isCreating
        self.onSave = onSave
        _title = State(initialValue: template.title)
        _bodyText = State(initialValue: template.body)
    }

    private var variableNames: [String] {
        PromptLibraryStore.extractVariables(from: bodyText)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("模板名", text: $title)
                }
                Section("正文") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 180)
                        .font(.body)
                    Text("用 {{变量}} 标记可替换的部分,例如:你好 {{名字}}。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !variableNames.isEmpty {
                    Section("检测到的变量") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(variableNames, id: \.self) { name in
                                    Text(name)
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Self.tint.opacity(0.13), in: Capsule(style: .continuous))
                                        .foregroundStyle(Self.tint)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isCreating ? "新建模板" : "编辑模板")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var result = template
                        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        result.body = bodyText
                        onSave(result)
                    }
                    .disabled(!canSave)
                }
            }
            .frame(minWidth: 480, minHeight: 460)
        }
    }
}

// MARK: - 填充变量并复制

private struct PromptFillSheet: View {
    let store: PromptLibraryStore
    let template: PromptTemplate

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var copied = false

    private static let tint = Color(red: 0.56, green: 0.40, blue: 0.86)

    private var rendered: String {
        store.render(template, values: values)
    }

    var body: some View {
        NavigationStack {
            Form {
                if template.variableNames.isEmpty {
                    Section {
                        Text("这个模板没有 {{变量}},可直接复制。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("填充变量") {
                        ForEach(template.variableNames, id: \.self) { name in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                TextField("填入 \(name)", text: Binding(
                                    get: { values[name] ?? "" },
                                    set: { values[name] = $0 }
                                ))
                            }
                        }
                    }
                }

                Section("预览") {
                    Text(rendered)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(template.title.isEmpty ? "填充模板" : template.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Platform.copyText(rendered)
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .tint(Self.tint)
                }
            }
            .frame(minWidth: 480, minHeight: 420)
        }
    }
}
