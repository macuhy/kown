import SwiftUI

/// 从提示词库选一个模板插入输入栏。无 `{{变量}}` 直接插入正文;有变量则先填值再插入渲染结果。
/// 复用 `PromptLibraryStore`(本地实例化,init 从磁盘载入)与其 `render`。
struct PromptInsertSheet: View {
    /// 插入回调:把最终文本交给调用方填进输入框。
    let onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var library = PromptLibraryStore()
    @State private var filling: PromptTemplate?
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if let template = filling {
                    fillForm(template)
                } else {
                    templateList
                }
            }
            .navigationTitle(filling == nil ? "插入提示词" : "填充变量")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(filling == nil ? "取消" : "返回") {
                        if filling == nil { dismiss() } else { filling = nil }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
    }

    @ViewBuilder
    private var templateList: some View {
        if library.templates.isEmpty {
            ContentUnavailableView("提示词库为空", systemImage: "text.badge.plus",
                                   description: Text("到 设置 ▸ 提示词库 里添加常用 Prompt"))
        } else {
            List(library.templates) { t in
                Button {
                    if t.variableNames.isEmpty {
                        onInsert(t.body)
                        dismiss()
                    } else {
                        values = Dictionary(uniqueKeysWithValues: t.variableNames.map { ($0, "") })
                        filling = t
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.title).font(.body.weight(.semibold))
                        Text(t.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if !t.variableNames.isEmpty {
                            Text("变量:" + t.variableNames.map { "{{\($0)}}" }.joined(separator: " "))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fillForm(_ template: PromptTemplate) -> some View {
        Form {
            Section("填充变量") {
                ForEach(template.variableNames, id: \.self) { name in
                    TextField(name, text: Binding(
                        get: { values[name] ?? "" },
                        set: { values[name] = $0 }
                    ))
                }
            }
            Section("预览") {
                Text(library.render(template, values: values))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Button {
                    onInsert(library.render(template, values: values))
                    dismiss()
                } label: {
                    Label("插入到输入框", systemImage: "text.insert")
                }
            }
        }
        .formStyle(.grouped)
    }
}
