import SwiftUI
import UniformTypeIdentifiers

/// 知识库管理 + 当前会话绑定。作为 sheet 从输入栏「资料夹」按钮弹出。
struct KnowledgeView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newFolderName = ""
    @State private var confirmDeleteFolderID: UUID?
    private let tint = Color(red: 0.10, green: 0.58, blue: 0.52)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroCard
                    bindingCard
                    foldersSection
                    createFolderCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .background(KnowledgeBackdrop())
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
        .confirmationDialog(
            "删除资料夹「\(folderName(confirmDeleteFolderID))」?",
            isPresented: Binding(
                get: { confirmDeleteFolderID != nil },
                set: { if !$0 { confirmDeleteFolderID = nil } }
            )
        ) {
            Button("删除资料夹", role: .destructive) {
                if let id = confirmDeleteFolderID {
                    viewModel.deleteKnowledgeFolder(id)
                }
                confirmDeleteFolderID = nil
            }
            Button("取消", role: .cancel) { confirmDeleteFolderID = nil }
        } message: {
            Text("其中的文档也会一起移除。此操作不可恢复。")
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var heroCard: some View {
        let folders = viewModel.knowledgeFolders.count
        let docs = viewModel.knowledgeFolders.reduce(0) { $0 + $1.docs.count }
        let chars = viewModel.knowledgeFolders.reduce(0) { $0 + $1.totalChars }

        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    knowledgeHeroIcon
                    heroCopy
                }
                VStack(alignment: .leading, spacing: 10) {
                    knowledgeHeroIcon
                    heroCopy
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                statPill(title: "资料夹", value: "\(folders)", icon: "folder.fill", color: tint)
                statPill(title: "文档", value: "\(docs)", icon: "doc.text.fill", color: .blue)
                statPill(title: "字数", value: chars.formatted(), icon: "text.alignleft", color: .orange)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.08), radius: 18, x: 0, y: 10)
    }

    private var knowledgeHeroIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.28), Color.orange.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: 58, height: 58)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
        }
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("把资料变成当前会话的离线大脑")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text("导入文档后,Kown 会在本地检索相关片段,随每次提问一起注入上下文。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statPill(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.callout.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .monospacedDigit()
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.56), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var bindingCard: some View {
        if viewModel.selectedConversationID != nil {
            cardContainer {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("当前会话", icon: "bubble.left.and.text.bubble.right.fill", color: tint)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 14) {
                            bindingCopy
                            Spacer(minLength: 12)
                            folderPicker
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            bindingCopy
                            folderPicker
                        }
                    }
                }
            }
        } else {
            cardContainer {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("当前会话", icon: "bubble.left.and.text.bubble.right.fill", color: .secondary)
                    Text("先选中或新建一个会话,再把资料夹绑定到会话上。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var bindingCopy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.currentKnowledgeFolder == nil ? "未绑定资料夹" : "已绑定「\(viewModel.currentKnowledgeFolder?.name ?? "")」")
                .font(.headline.weight(.semibold))
            Text("绑定后,本会话每次提问都会检索相关片段,作为「相关资料」注入。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var folderPicker: some View {
        Picker("绑定资料夹", selection: Binding(
            get: { viewModel.currentKnowledgeFolder?.id },
            set: { viewModel.setKnowledgeFolder($0) }
        )) {
            Text("不绑定").tag(UUID?.none)
            ForEach(viewModel.knowledgeFolders) { folder in
                Text(folder.name).tag(UUID?.some(folder.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 128, alignment: .trailing)
    }

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("资料夹", icon: "folder.fill", color: tint)
                Spacer()
                Text("\(viewModel.knowledgeFolders.count) 个")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.10), in: Capsule(style: .continuous))
            }

            if viewModel.knowledgeFolders.isEmpty {
                emptyFoldersCard
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.knowledgeFolders) { folder in
                        HStack(spacing: 8) {
                            NavigationLink {
                                KnowledgeFolderDetail(viewModel: viewModel, folderID: folder.id)
                            } label: {
                                KnowledgeFolderCard(folder: folder, tint: tint)
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                confirmDeleteFolderID = folder.id
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.red)
                                    .frame(width: 34, height: 44)
                                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("删除资料夹")
                            .accessibilityLabel("删除资料夹 \(folder.name)")
                        }
                    }
                }
            }
        }
    }

    private var emptyFoldersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("还没有资料夹")
                        .font(.headline.weight(.bold))
                    Text("先创建一个资料夹,再把常用文档拖进来或粘贴进去。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider().opacity(0.45)
            HStack(spacing: 8) {
                Label("本地检索", systemImage: "lock.fill")
                Label("随会话绑定", systemImage: "link")
                Label("自动注入", systemImage: "sparkles")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(tint.opacity(0.13), lineWidth: 1)
        }
    }

    private var createFolderCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("新建资料夹", icon: "plus.rectangle.on.folder.fill", color: tint)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        folderNameField
                        createFolderButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        folderNameField
                        createFolderButton
                    }
                }
            }
        }
    }

    private var folderNameField: some View {
        TextField("例如: 产品手册 / API 规范", text: $newFolderName)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.platformControlBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity)
            .onSubmit(createFolder)
    }

    private var createFolderButton: some View {
        Button {
            createFolder()
        } label: {
            Label("新建", systemImage: "plus")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func sectionTitle(_ text: String, icon: String, color: Color) -> some View {
        Label {
            Text(text)
                .font(.headline.weight(.bold))
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
        }
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = viewModel.createKnowledgeFolder(name: trimmed)
        newFolderName = ""
    }

    private func folderName(_ id: UUID?) -> String {
        guard let id,
              let folder = viewModel.knowledgeFolders.first(where: { $0.id == id }) else {
            return "资料夹"
        }
        return folder.name
    }
}

private struct KnowledgeFolderCard: View {
    let folder: KnowledgeFolder
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(folder.docs.count) 份文档 · \(folder.totalChars.formatted()) 字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.56), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.12), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// 单个资料夹详情:改名 + 文档增删。
private struct KnowledgeFolderDetail: View {
    @Bindable var viewModel: AppViewModel
    let folderID: UUID

    @State private var name = ""
    @State private var showAddDoc = false
    @State private var showImporter = false
    @State private var showPDFImporter = false
    @State private var showFolderImporter = false
    @State private var showAddURL = false
    @State private var urlDraft = ""
    @State private var scrapingURL = false
    @State private var urlError: String?

    // 大文档 / 文件夹分块入库进度。
    @State private var ingesting = false
    @State private var ingestStatus = ""
    @State private var ingestProgress = 0.0
    @State private var ingestSummary: String?

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
                        Text(docSubtitle(doc)).font(.caption2).foregroundStyle(.secondary)
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
                    Label("从文件导入", systemImage: "doc")
                }
                .disabled(ingesting)
                Button {
                    showPDFImporter = true
                } label: {
                    Label("导入 PDF(按页分块)", systemImage: "doc.richtext")
                }
                .disabled(ingesting)
                Button {
                    showFolderImporter = true
                } label: {
                    Label("导入整个文件夹", systemImage: "folder.badge.plus")
                }
                .disabled(ingesting)
                Button {
                    urlError = nil; urlDraft = ""; showAddURL = true
                } label: {
                    Label(scrapingURL ? "正在抓取网页…" : "从网页链接导入", systemImage: scrapingURL ? "hourglass" : "link")
                }
                .disabled(scrapingURL || ingesting)
                if ingesting {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: ingestProgress)
                        Text(ingestStatus.isEmpty ? "正在分块入库…" : ingestStatus)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
                if let ingestSummary {
                    Text(ingestSummary).font(.caption2).foregroundStyle(.secondary)
                }
                if let urlError {
                    Text(urlError).font(.caption2).foregroundStyle(.red)
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
        .fileImporter(isPresented: $showPDFImporter,
                      allowedContentTypes: [.pdf],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                ingestURLs(urls, kind: .files)
            }
        }
        .fileImporter(isPresented: $showFolderImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let folder = urls.first {
                ingestURLs([folder], kind: .folder)
            }
        }
        .alert("从网页链接导入", isPresented: $showAddURL) {
            TextField("https://…", text: $urlDraft)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            Button("取消", role: .cancel) {}
            Button("抓取") { scrapeURL() }
        } message: {
            Text("用 Firecrawl 抓取网页正文,作为一篇文档加入本资料夹。需已配置 Web Search。")
        }
    }

    private func scrapeURL() {
        let u = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        scrapingURL = true
        urlError = nil
        Task {
            let err = await viewModel.addKnowledgeDocFromURL(folderID: folderID, urlString: u)
            await MainActor.run {
                scrapingURL = false
                urlError = err
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

    private func docSubtitle(_ doc: KnowledgeDoc) -> String {
        var parts = ["\(doc.charCount) 字"]
        if let p = doc.pageCount { parts.append("\(p) 页") }
        if let c = doc.chunks, !c.isEmpty { parts.append("\(c.count) 块") }
        return parts.joined(separator: " · ")
    }

    private enum IngestKind { case files, folder }

    /// 大文档 / 文件夹分块入库:抽取 + 切块放后台(DocumentIngestor 是纯计算 nonisolated),
    /// 完成后回主线程批量插入 + 落盘,过程中更新进度条。
    private func ingestURLs(_ urls: [URL], kind: IngestKind) {
        guard !urls.isEmpty, !ingesting else { return }
        ingesting = true
        ingestSummary = nil
        ingestStatus = ""
        ingestProgress = 0

        Task.detached(priority: .userInitiated) {
            // 安全作用域:沙盒下需在读取期间持有访问权。
            let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer { for (u, ok) in scoped where ok { u.stopAccessingSecurityScopedResource() } }

            var docs: [KnowledgeDoc] = []
            var failures: [(name: String, reason: String)] = []

            switch kind {
            case .folder:
                let folderURL = urls[0]
                let result = DocumentIngestor.ingestFolder(at: folderURL) { done, total, current in
                    let frac = total > 0 ? Double(done) / Double(total) : 0
                    Task { @MainActor in
                        ingestProgress = frac
                        ingestStatus = current.isEmpty ? "整理中…" : "处理 \(current)(\(done)/\(total))"
                    }
                }
                docs = result.docs
                failures = result.failures
            case .files:
                let total = urls.count
                for (i, url) in urls.enumerated() {
                    let nm = url.lastPathComponent
                    await MainActor.run {
                        ingestProgress = total > 0 ? Double(i) / Double(total) : 0
                        ingestStatus = "处理 \(nm)(\(i + 1)/\(total))"
                    }
                    do {
                        docs.append(try DocumentIngestor.ingestFile(at: url))
                    } catch {
                        let reason = (error as? DocumentIngestor.IngestError)?.message
                            ?? error.localizedDescription
                        failures.append((name: nm, reason: reason))
                    }
                }
            }

            let insertedDocs = docs
            let fails = failures
            await MainActor.run {
                viewModel.addKnowledgeDocs(folderID: folderID, docs: insertedDocs)
                ingesting = false
                ingestProgress = 1
                ingestStatus = ""
                var msg = "已入库 \(insertedDocs.count) 份文档"
                if !fails.isEmpty {
                    let head = fails.prefix(3).map { "\($0.name)(\($0.reason))" }.joined(separator: "、")
                    msg += ";跳过 \(fails.count) 个:\(head)\(fails.count > 3 ? "…" : "")"
                }
                ingestSummary = msg
            }
        }
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

private struct KnowledgeBackdrop: View {
    var body: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [
                    Color(red: 0.10, green: 0.58, blue: 0.52).opacity(0.18),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 440
            )
            RadialGradient(
                colors: [
                    Color.orange.opacity(0.12),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 60,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}
