import Foundation

/// 知识库(本地 RAG)管理:资料夹 CRUD + 文档增删 + 与会话绑定。
extension AppViewModel {

    func saveKnowledge() {
        KnowledgeStore.saveAll(knowledgeFolders)
    }

    @discardableResult
    func createKnowledgeFolder(name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = KnowledgeFolder(name: trimmed.isEmpty ? "新资料夹" : trimmed)
        knowledgeFolders.append(folder)
        saveKnowledge()
        return folder.id
    }

    func renameKnowledgeFolder(_ id: UUID, name: String) {
        guard let idx = knowledgeFolders.firstIndex(where: { $0.id == id }) else { return }
        knowledgeFolders[idx].name = name
        knowledgeFolders[idx].updatedAt = Date()
        saveKnowledge()
    }

    func deleteKnowledgeFolder(_ id: UUID) {
        knowledgeFolders.removeAll { $0.id == id }
        saveKnowledge()
        // 解绑所有引用该资料夹的会话
        for i in conversations.indices where conversations[i].knowledgeFolderID == id {
            conversations[i].knowledgeFolderID = nil
            ConversationStore.save(conversations[i])
        }
        // 解绑所有引用该资料夹的项目空间
        var foldersChanged = false
        for i in conversationFolders.indices where conversationFolders[i].knowledgeFolderID == id {
            conversationFolders[i].knowledgeFolderID = nil
            foldersChanged = true
        }
        if foldersChanged { ConversationFolderStore.save(conversationFolders) }
    }

    func addKnowledgeDoc(folderID: UUID, name: String, text: String) {
        guard let idx = knowledgeFolders.firstIndex(where: { $0.id == folderID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        knowledgeFolders[idx].docs.append(KnowledgeDoc(name: name, text: trimmed))
        knowledgeFolders[idx].updatedAt = Date()
        saveKnowledge()
    }

    /// 从一个 URL 抓取正文(Firecrawl)并作为文档加入资料夹。成功返回 nil,否则返回错误文案。
    /// 需已配置 Web Search(Firecrawl key + baseURL),与 `attachScrapedURL` 同一抓取链路。
    func addKnowledgeDocFromURL(folderID: UUID, urlString: String) async -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "请输入链接" }
        let normalized = trimmed.hasPrefix("http") ? trimmed : "https://" + trimmed
        guard canEnableWebSearch, let key = try? WebSearchKey.load(), !key.isEmpty else {
            return "需先在 设置 ▸ Web Search 配置 Firecrawl Key"
        }
        let client = FirecrawlClient(baseURL: webSearchConfig.baseURL, apiKey: key)
        do {
            let result = try await client.scrape(url: normalized)
            var content = result.markdown
            let maxChars = 200 * 1024
            if content.count > maxChars { content = String(content.prefix(maxChars)) + "\n\n…(网页正文过长已截断)" }
            // 把来源 URL 写进正文头,RAG 检索注入时也能带上出处。
            let docName = result.title.isEmpty ? normalized : result.title
            let body = "来源:\(normalized)\n\n\(content)"
            addKnowledgeDoc(folderID: folderID, name: docName, text: body)
            return nil
        } catch {
            return "抓取失败:\(error.localizedDescription)"
        }
    }

    /// 把一篇已经抽好的文档(可能带预切块 + 页码)整篇加入资料夹。
    /// 大文档 / 文件夹分块入库走这里(`DocumentIngestor` 在后台抽好,主线程只做插入 + 落盘)。
    func addKnowledgeDocs(folderID: UUID, docs: [KnowledgeDoc]) {
        guard !docs.isEmpty,
              let idx = knowledgeFolders.firstIndex(where: { $0.id == folderID }) else { return }
        knowledgeFolders[idx].docs.append(contentsOf: docs)
        knowledgeFolders[idx].updatedAt = Date()
        saveKnowledge()
    }

    func removeKnowledgeDoc(folderID: UUID, docID: UUID) {
        guard let idx = knowledgeFolders.firstIndex(where: { $0.id == folderID }) else { return }
        knowledgeFolders[idx].docs.removeAll { $0.id == docID }
        knowledgeFolders[idx].updatedAt = Date()
        saveKnowledge()
    }

    /// 当前会话绑定的资料夹(如有)。
    var currentKnowledgeFolder: KnowledgeFolder? {
        guard let convID = selectedConversationID,
              let conv = conversations.first(where: { $0.id == convID }),
              let fid = conv.knowledgeFolderID else { return nil }
        return knowledgeFolders.first(where: { $0.id == fid })
    }

    /// 给当前会话绑定 / 解绑资料夹。
    func setKnowledgeFolder(_ folderID: UUID?) {
        guard let convID = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        conversations[idx].knowledgeFolderID = folderID
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }
}
