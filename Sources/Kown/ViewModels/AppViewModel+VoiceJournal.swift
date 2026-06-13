import Foundation

/// 语音随手记自动归档(跨平台):转写 → LLM 自动打标 → 存进专用知识库资料夹(可被语义召回)。
///
/// 复用 `AppViewModel+Knowledge` 的资料夹 / 文档 CRUD(`createKnowledgeFolder` / `addKnowledgeDoc`,
/// 后者已自动触发后台预索引,入库即可被 RAG 检索),与 `VoiceJournalService` 的打标。
extension AppViewModel {

    /// 语音随手记专用资料夹名(固定;首次保存时按需创建)。
    static let voiceJournalFolderName = "语音随手记"

    /// 随手记问答可用性:有已启用的非 CLI 模型即可打标(没有时也能无标签直接存)。
    var voiceJournalCanTag: Bool {
        chairProvider != nil || providers.contains { $0.enabled && !$0.kind.isCLI }
    }

    /// 当前的语音随手记资料夹(如已存在)。
    var voiceJournalFolder: KnowledgeFolder? {
        knowledgeFolders.first { $0.name == Self.voiceJournalFolderName }
    }

    /// 找到或创建语音随手记资料夹,返回其 ID。
    func ensureVoiceJournalFolder() -> UUID {
        if let existing = voiceJournalFolder { return existing.id }
        return createKnowledgeFolder(name: Self.voiceJournalFolderName)
    }

    /// 保存一条语音随手记:自动打标(失败则无标签)→ 存进专用资料夹。
    /// 返回给 UI 展示的结果:成功时带标题 + 标签;失败时带错误文案。
    struct VoiceJournalSaveResult: Sendable {
        let title: String
        let tags: [String]
        let taggedByLLM: Bool
        let error: String?
    }

    @discardableResult
    func saveVoiceJournal(transcript: String) async -> VoiceJournalSaveResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return VoiceJournalSaveResult(title: "", tags: [], taggedByLLM: false, error: "随手记内容为空。")
        }
        let now = Date()

        // 1) 自动打标(有 provider 才试;失败 / 无 provider → 无标签兜底,绝不丢内容)。
        var tagging = VoiceJournalService.Tagging(
            title: "", tags: [], summary: nil)
        var taggedByLLM = false
        if let provider = voiceJournalProvider() {
            do {
                tagging = try await VoiceJournalService.tag(transcript: trimmed, provider: provider)
                taggedByLLM = true
            } catch {
                // 打标失败不致命:无标签直接存。
            }
        }

        // 2) 入库专用资料夹。
        let folderID = ensureVoiceJournalFolder()
        let name = VoiceJournalService.docName(tagging: tagging, date: now)
        let body = VoiceJournalService.archiveBody(transcript: trimmed, tagging: tagging, date: now)
        addKnowledgeDoc(folderID: folderID, name: name, text: body)

        return VoiceJournalSaveResult(
            title: name, tags: tagging.tags, taggedByLLM: taggedByLLM, error: nil)
    }

    /// 挑随手记打标用的模型:chair 优先(非 CLI),否则第一个已启用非 CLI。
    private func voiceJournalProvider() -> ProviderConfig? {
        if let chair = chairProvider, !chair.kind.isCLI { return chair }
        return providers.first { $0.enabled && !$0.kind.isCLI }
    }
}
