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
    }

    func addKnowledgeDoc(folderID: UUID, name: String, text: String) {
        guard let idx = knowledgeFolders.firstIndex(where: { $0.id == folderID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        knowledgeFolders[idx].docs.append(KnowledgeDoc(name: name, text: trimmed))
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
