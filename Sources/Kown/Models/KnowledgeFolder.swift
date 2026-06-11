import Foundation

/// 文档预切块(大文档分块入库时携带页码 + 来源元数据)。
/// `page` 是该块所属的 1-based 页码(PDF 才有;纯文本 / 网页为 nil)。
/// 老存档没有 `chunks`,检索时回退到对 `KnowledgeDoc.text` 现场切块(见 LocalRAG)。
struct DocChunk: Codable, Hashable, Sendable {
    var text: String
    /// 1-based 页码,nil 表示无分页概念(txt/md/网页)。
    var page: Int?

    init(text: String, page: Int? = nil) {
        self.text = text
        self.page = page
    }
}

/// 知识库里的一份文档(抽取后的纯文本快照)。
///
/// 大文档(整本 PDF / 文件夹批量导入)入库时会预切块到 `chunks`,每块带页码 + 来源文件名,
/// 这样检索结果能给出「第几页」的引用,且不再受单文档注入字数上限拖累。
/// **Codable 向后兼容**:`chunks` / `sourceFile` 均为 optional,老存档解码出来为 nil,
/// 检索逻辑回退到对 `text` 现场切块(无页码),行为与旧版一致。
struct KnowledgeDoc: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var text: String
    var addedAt: Date
    /// 预切块(带页码)。nil = 老文档,检索时现场切 `text`。
    var chunks: [DocChunk]?
    /// 来源文件名(文件夹批量导入时,`name` 可能带相对路径,这里保留纯文件名)。
    var sourceFile: String?
    /// 文档总页数(PDF 才有,展示用)。
    var pageCount: Int?

    init(id: UUID = UUID(), name: String, text: String, addedAt: Date = Date(),
         chunks: [DocChunk]? = nil, sourceFile: String? = nil, pageCount: Int? = nil) {
        self.id = id
        self.name = name
        self.text = text
        self.addedAt = addedAt
        self.chunks = chunks
        self.sourceFile = sourceFile
        self.pageCount = pageCount
    }

    // 兼容旧 JSON:缺 chunks / sourceFile / pageCount 时以 decodeIfPresent 解出 nil。
    enum CodingKeys: String, CodingKey {
        case id, name, text, addedAt, chunks, sourceFile, pageCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.text = try c.decode(String.self, forKey: .text)
        self.addedAt = try c.decode(Date.self, forKey: .addedAt)
        self.chunks = try c.decodeIfPresent([DocChunk].self, forKey: .chunks)
        self.sourceFile = try c.decodeIfPresent(String.self, forKey: .sourceFile)
        self.pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
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
