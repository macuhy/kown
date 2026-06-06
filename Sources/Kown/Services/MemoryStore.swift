import Foundation
import Observation

/// 一条「跨会话长期记忆」= 从某个会话里抽取出的、值得长期保留的事实 / 偏好 / 决定。
///
/// 与「会话内滚动摘要」(`Conversation.contextSummary` + `ConversationSummarizer`)是两套东西:
/// - contextSummary 只活在单个会话里,压缩**本会话**的历史轮次。
/// - MemoryItem 跨会话沉淀,新会话发送时按相关性回灌少量条目到上下文。
struct MemoryItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// 一句话事实 / 偏好(中文),给模型看的原文。
    var text: String
    var createdAt: Date
    /// 抽取自哪个会话(可空 — 手动添加 / 旧数据没有来源)。
    var sourceConversationID: UUID?
    /// 轻量标签(预留,目前抽取器不强制产出)。
    var tags: [String]

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        sourceConversationID: UUID? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.sourceConversationID = sourceConversationID
        self.tags = tags
    }

    // 兼容旧 JSON(缺新字段时容错,避免整份解码失败)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try c.decode(String.self, forKey: .text)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.sourceConversationID = try c.decodeIfPresent(UUID.self, forKey: .sourceConversationID)
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

/// 跨会话长期记忆库。单例,设置页与发送编排共享(同 `UsageStore.shared` 模式)。
///
/// 持久化:`syncedDataDir/memories.json`(随 iCloud 同步),atomic 写入。
/// 件数上限 `maxItems`,超出时**从最旧的开始溢出**(保留最近沉淀的记忆)。
@Observable
@MainActor
final class MemoryStore {
    static let shared = MemoryStore()

    /// 最新在前(`items[0]` 是最近添加 / 抽取的)。
    private(set) var items: [MemoryItem]

    /// 件数上限 — 超出时丢弃最旧的(数组尾部)。
    static let maxItems = 200

    private var url: URL { Platform.syncedDataDir.appendingPathComponent("memories.json") }

    private init() {
        self.items = Self.load()
    }

    private static func load() -> [MemoryItem] {
        let url = Platform.syncedDataDir.appendingPathComponent("memories.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([MemoryItem].self, from: data) else {
            return []
        }
        return list
    }

    func reload() {
        items = Self.load()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 是否已存在语义等价的记忆(按正文 normalize 后判重 — 轻量去重,不做向量相似)。
    func contains(_ text: String) -> Bool {
        let t = norm(text)
        guard !t.isEmpty else { return false }
        return items.contains { norm($0.text) == t }
    }

    /// 追加一条记忆。空文本 / 重复(正文判重)直接忽略,返回是否真正写入。
    @discardableResult
    func add(text: String, sourceConversationID: UUID? = nil, tags: [String] = []) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !contains(trimmed) else { return false }
        items.insert(
            MemoryItem(text: trimmed, sourceConversationID: sourceConversationID, tags: tags),
            at: 0
        )
        trimToCap()
        persist()
        return true
    }

    /// 批量追加(抽取器一次产出多条),返回真正写入的条数。
    @discardableResult
    func addMany(_ texts: [String], sourceConversationID: UUID? = nil) -> Int {
        var added = 0
        for t in texts {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !contains(trimmed) else { continue }
            items.insert(MemoryItem(text: trimmed, sourceConversationID: sourceConversationID), at: 0)
            added += 1
        }
        if added > 0 {
            trimToCap()
            persist()
        }
        return added
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    /// 超出上限时从最旧的(数组尾部)开始溢出。
    private func trimToCap() {
        if items.count > Self.maxItems {
            items.removeLast(items.count - Self.maxItems)
        }
    }

    // MARK: - 相关性检索(注入用)

    /// 给定本轮 prompt,选出最相关的 top-K 条记忆原文。
    ///
    /// 复用 `LocalRAG.tokenize` + `LocalRAG.bm25Scores`:把每条记忆当成一个「文档」做 BM25 关键词排名。
    /// 这一步纯本地、零成本,不引入向量缓存(记忆条目短、量小,BM25 已足够)。
    /// 查询无有效词或全 0 分时,**不注入**(返回空)— 宁缺毋滥,避免塞一堆不相关记忆。
    func relevantMemories(for query: String, topK: Int = 5) -> [MemoryItem] {
        guard !items.isEmpty else { return [] }
        let queryTerms = LocalRAG.tokenize(query)
        guard !queryTerms.isEmpty else { return [] }

        let docs = items.map { LocalRAG.tokenize($0.text) }
        let scores = LocalRAG.bm25Scores(query: queryTerms, docs: docs)
        let ranked = scores.enumerated()
            .filter { $0.element > 0 }
            .sorted { $0.element > $1.element }
            .prefix(topK)
            .map { items[$0.offset] }
        return Array(ranked)
    }

    /// 把相关记忆拼成注入用的上下文块(中文标注),无相关记忆时返回 nil。
    /// 风格与 `AppViewModel+Send` 里知识库片段注入一致。
    func injectionBlock(for query: String, topK: Int = 5) -> String? {
        Self.relevanceBlock(items: items, query: query, topK: topK)
    }

    /// `nonisolated`:纯函数,在给定 items 快照([MemoryItem] 是 Sendable)上做 BM25 排序并拼注入块。
    /// 发送时主线程先取一份 `items` 快照(O(1) COW),把可能上百条的 BM25 打分挪到后台线程跑。
    nonisolated static func relevanceBlock(items: [MemoryItem], query: String, topK: Int = 5) -> String? {
        guard !items.isEmpty else { return nil }
        let queryTerms = LocalRAG.tokenize(query)
        guard !queryTerms.isEmpty else { return nil }
        let docs = items.map { LocalRAG.tokenize($0.text) }
        let scores = LocalRAG.bm25Scores(query: queryTerms, docs: docs)
        let hits = scores.enumerated()
            .filter { $0.element > 0 }
            .sorted { $0.element > $1.element }
            .prefix(topK)
            .map { items[$0.offset].text }
        guard !hits.isEmpty else { return nil }
        let lines = hits.map { "- \($0)" }
        return "[长期记忆 — 来自以往会话沉淀的事实 / 偏好,回答时可参考,但与本轮明显冲突时以本轮为准]\n"
            + lines.joined(separator: "\n")
    }
}
