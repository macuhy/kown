import Foundation

/// 知识库里的一份文档(抽取后的纯文本快照)。
struct KnowledgeDoc: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var text: String
    var addedAt: Date

    init(id: UUID = UUID(), name: String, text: String, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.text = text
        self.addedAt = addedAt
    }

    var charCount: Int { text.count }
}

/// 一个会话级「资料夹」:若干文档常驻,发送时按问题本地检索 top-K 片段注入上下文。
struct KnowledgeFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var docs: [KnowledgeDoc]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, docs: [KnowledgeDoc] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.docs = docs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var totalChars: Int { docs.reduce(0) { $0 + $1.charCount } }
}

/// 知识库持久化:全部资料夹存进 `syncedDataDir/knowledge/folders.json`(随 iCloud 同步)。
@MainActor
enum KnowledgeStore {
    private static var dir: URL {
        Platform.syncedDataDir.appendingPathComponent("knowledge", isDirectory: true)
    }
    private static var fileURL: URL {
        dir.appendingPathComponent("folders.json")
    }

    static func loadAll() -> [KnowledgeFolder] {
        guard let data = try? Data(contentsOf: fileURL),
              let folders = try? JSONDecoder().decode([KnowledgeFolder].self, from: data)
        else { return [] }
        return folders
    }

    static func saveAll(_ folders: [KnowledgeFolder]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
