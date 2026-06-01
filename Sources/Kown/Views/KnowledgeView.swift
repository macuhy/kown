import SwiftUI
import UniformTypeIdentifiers

/// 知识库管理 + 当前会话绑定。作为 sheet 从输入栏「资料夹」按钮弹出。
struct KnowledgeView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                bindingSection
                Section("资料夹") {
                    if viewModel.knowledgeFolders.isEmpty {
                        Text("还没有资料夹。新建一个,把常用文档放进去,提问时会自动检索相关片段注入上下文。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.knowledgeFolders) { folder in
                        NavigationLink {
                            KnowledgeFolderDetail(viewModel: viewModel, folderID: folder.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name).font(.body.weight(.semibold))
                                Text("\(folder.docs.count) 份文档 · \(folder.totalChars) 字")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in
                        for i in idx { viewModel.deleteKnowledgeFolder(viewModel.knowledgeFolders[i].id) }
                    }
                    HStack {
                        TextField("新建资料夹名称", text: $newFolderName)
                        Button("新建") {
                            _ = viewModel.createKnowledgeFolder(name: newFolderName)
                            newFolderName = ""
                        }
                        .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("知识库")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var bindingSection: some View {
        if viewModel.selectedConversationID != nil {
            Section("当前会话") {
                Picker("绑定资料夹", selection: Binding(
                    get: { viewModel.currentKnowledgeFolder?.id },
                    set: { viewModel.setKnowledgeFolder($0) }
                )) {
                    Text("不绑定").tag(UUID?.none)
                    ForEach(viewModel.knowledgeFolders) { f in
                        Text(f.name).tag(UUID?.some(f.id))
                    }
                }
                Text("绑定后,本会话每次提问都会按问题在该资料夹里检索最相关的片段,作为「相关资料」注入。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Section {
                Text("先选中或新建一个会话,才能把资料夹绑定到会话上。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 单个资料夹详情:改名 + 文档增删。
private struct KnowledgeFolderDetail: View {
    @Bindable var viewModel: AppViewModel
    let folderID: UUID

    @State private var name = ""
    @State private var showAddDoc = false
    @State private var showImporter = false

    private var folder: KnowledgeFolder? {
        viewModel.knowledgeFolders.first(where: { $0.id == folderID })
    }

    var body: some View {
        List {
            Section("名称") {
                TextField("资料夹名称", text: $name)
                    .onSubmit { viewModel.renameKnowledgeFolder(folderID, name: name) }
                #if os(macOS)
                Button("保存名称") { viewModel.renameKnowledgeFolder(folderID, name: name) }
                #endif
            }
            Section("文档(\(folder?.docs.count ?? 0))") {
                ForEach(folder?.docs ?? []) { doc in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.name).font(.body.weight(.medium)).lineLimit(1)
                        Text("\(doc.charCount) 字").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in
                    guard let docs = folder?.docs else { return }
                    for i in idx { viewModel.removeKnowledgeDoc(folderID: folderID, docID: docs[i].id) }
                }
                Button {
                    showAddDoc = true
                } label: {
                    Label("粘贴文本添加", systemImage: "doc.text")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("从文件导入", systemImage: "folder")
                }
            }
        }
        .navigationTitle(folder?.name ?? "资料夹")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { name = folder?.name ?? "" }
        .onChange(of: name) { _, _ in viewModel.renameKnowledgeFolder(folderID, name: name) }
        .sheet(isPresented: $showAddDoc) {
            AddDocSheet { docName, text in
                viewModel.addKnowledgeDoc(folderID: folderID, name: docName, text: text)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.plainText, .text, .sourceCode, .json, .yaml, .xml, .commaSeparatedText],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { importFile(url) }
            }
        }
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(decoding: data, as: UTF8.self)
        viewModel.addKnowledgeDoc(folderID: folderID, name: url.lastPathComponent, text: text)
    }
}

/// 粘贴文本添加文档的小 sheet。
private struct AddDocSheet: View {
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var docName = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("文档名") { TextField("如 项目说明.md", text: $docName) }
                Section("内容") {
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle("添加文档")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let n = docName.trimmingCharacters(in: .whitespaces)
                        onSave(n.isEmpty ? "文档" : n, text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }
}
