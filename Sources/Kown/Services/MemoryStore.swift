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
    /// 归属的 Persona(nil = 全局记忆)。Persona 会话里抽取的记忆归属该 Persona,
    /// 回灌时只注入「全局 + 当前 Persona」两类,不同 Persona 的记忆互不串。
    var personaID: UUID?
    /// 置顶:回灌时优先注入(与查询相关性无关),且溢出淘汰永不删除。
    var pinned: Bool

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        sourceConversationID: UUID? = nil,
        tags: [String] = [],
        personaID: UUID? = nil,
        pinned: Bool = false
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.sourceConversationID = sourceConversationID
        self.tags = tags
        self.personaID = personaID
        self.pinned = pinned
    }

    // 兼容旧 JSON(缺新字段时容错,避免整份解码失败)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try c.decode(String.self, forKey: .text)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.sourceConversationID = try c.decodeIfPresent(UUID.self, forKey: .sourceConversationID)
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.personaID = try c.decodeIfPresent(UUID.self, forKey: .personaID)
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

/// 跨会话长期记忆库。单例,设置页与发送编排共享(同 `UsageStore.shared` 模式)。
///
/// 持久化:`syncedDataDir/memories.json`(随 iCloud 同步),atomic 写入。
/// 件数上限 `maxItems`,超出时**从最旧的未置顶条目开始溢出**(置顶记忆永不被淘汰)。
@Observable
@MainActor
final class MemoryStore {
    static let shared = MemoryStore()

    /// 最新在前(`items[0]` 是最近添加 / 抽取的)。
    private(set) var items: [MemoryItem]

    /// 件数上限 — 超出时丢弃最旧的未置顶条目(置顶不淘汰)。
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

    /// 写入前判重:在「全局 + 目标 Persona」作用域内做归一化包含 / 高相似检查。
    /// 抽取器产出的同义改写(标点 / 空白 / 大小写不同、或一句话被另一句完整包含)都会被拦下。
    func hasNearDuplicate(_ text: String, personaID: UUID?) -> Bool {
        let scope = items.lazy
            .filter { $0.personaID == nil || $0.personaID == personaID }
            .map(\.text)
        return Self.containsNearDuplicate(text, in: Array(scope))
    }

    /// 追加一条记忆。空文本 / 近重复(归一化包含或高相似)直接忽略,返回是否真正写入。
    @discardableResult
    func add(
        text: String,
        sourceConversationID: UUID? = nil,
        tags: [String] = [],
        personaID: UUID? = nil,
        pinned: Bool = false
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hasNearDuplicate(trimmed, personaID: personaID) else { return false }
        items.insert(
            MemoryItem(text: trimmed, sourceConversationID: sourceConversationID,
                       tags: tags, personaID: personaID, pinned: pinned),
            at: 0
        )
        trimToCap()
        persist()
        return true
    }

    /// 批量追加(抽取器一次产出多条),返回真正写入的条数。
    /// `personaID`:抽取来源会话绑定的 Persona(开了长期记忆才归属;nil = 全局)。
    @discardableResult
    func addMany(_ texts: [String], sourceConversationID: UUID? = nil, personaID: UUID? = nil) -> Int {
        var added = 0
        for t in texts {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !hasNearDuplicate(trimmed, personaID: personaID) else { continue }
            items.insert(
                MemoryItem(text: trimmed, sourceConversationID: sourceConversationID, personaID: personaID),
                at: 0
            )
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

    /// 置顶 / 取消置顶。
    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned = pinned
        persist()
    }

    /// 编辑正文(管理 UI 用)。空文本忽略。
    func updateText(_ id: UUID, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].text = t
        persist()
    }

    /// 超出上限时从最旧的未置顶条目开始溢出(置顶永不淘汰)。
    private func trimToCap() {
        items = Self.trimmedToCap(items, cap: Self.maxItems)
    }

    // MARK: - 归属查询(分组管理 / 发送回灌)

    /// 某一归属组的记忆(personaID == nil → 全局组)。管理 UI 分组用。
    func items(ownedBy personaID: UUID?) -> [MemoryItem] {
        items.filter { $0.personaID == personaID }
    }

    /// 发送回灌候选:全局记忆 + 指定 Persona 的专属记忆(personaID == nil → 仅全局)。
    func injectableItems(personaID: UUID?) -> [MemoryItem] {
        Self.filterInjectable(items: items, personaID: personaID)
    }

    /// `nonisolated` 纯函数:从快照里筛出「全局 + 指定 Persona」的可注入条目,保持原有顺序(最新在前)。
    nonisolated static func filterInjectable(items: [MemoryItem], personaID: UUID?) -> [MemoryItem] {
        items.filter { item in
            guard let owner = item.personaID else { return true }   // 全局记忆人人可用
            return personaID != nil && owner == personaID           // Persona 记忆只给自己的会话
        }
    }

    // MARK: - 相关性检索(注入用)

    /// 给定本轮 prompt,选出最相关的 top-K 条记忆。
    func relevantMemories(for query: String, topK: Int = 5) -> [MemoryItem] {
        Self.selectForInjection(items: items, query: query, topK: topK)
    }

    /// 把相关记忆拼成注入用的上下文块(中文标注),无相关记忆时返回 nil。
    /// 风格与 `AppViewModel+Send` 里知识库片段注入一致。
    func injectionBlock(for query: String, topK: Int = 5) -> String? {
        Self.relevanceBlock(items: items, query: query, topK: topK)
    }

    /// `nonisolated` 纯函数:在给定 items 快照上选出本轮要注入的记忆。
    /// 规则:**置顶永远优先注入**(这正是「置顶」的意义,与查询相关性无关);
    /// 余下名额给未置顶条目,按 BM25 相关性排名,0 分不注入(宁缺毋滥)。
    /// 选入时按归一化正文去重,避免「同一句话全局 / Persona 各存一份」被重复注入。
    nonisolated static func selectForInjection(items: [MemoryItem], query: String, topK: Int = 5) -> [MemoryItem] {
        guard !items.isEmpty, topK > 0 else { return [] }
        var selected: [MemoryItem] = []
        var seenNorm = Set<String>()
        func push(_ item: MemoryItem) -> Bool {
            let n = normalizeForDedup(item.text)
            guard !n.isEmpty, seenNorm.insert(n).inserted else { return false }
            selected.append(item)
            return true
        }
        // 1) 置顶优先(items 最新在前,置顶多于 topK 时取最近置顶的)。
        for item in items where item.pinned {
            if selected.count >= topK { break }
            _ = push(item)
        }
        // 2) 余下名额按 BM25 相关性给未置顶条目。
        let slots = topK - selected.count
        if slots > 0 {
            let unpinned = items.filter { !$0.pinned }
            let queryTerms = LocalRAG.tokenize(query)
            if !unpinned.isEmpty, !queryTerms.isEmpty {
                let docs = unpinned.map { LocalRAG.tokenize($0.text) }
                let scores = LocalRAG.bm25Scores(query: queryTerms, docs: docs)
                let ranked = scores.enumerated()
                    .filter { $0.element > 0 }
                    .sorted { $0.element > $1.element }
                var taken = 0
                for (offset, _) in ranked {
                    guard taken < slots else { break }
                    if push(unpinned[offset]) { taken += 1 }
                }
            }
        }
        return selected
    }

    /// `nonisolated`:纯函数,发送时主线程先取一份 `items` 快照(O(1) COW),
    /// 把可能上百条的 BM25 打分挪到后台线程跑。
    nonisolated static func relevanceBlock(items: [MemoryItem], query: String, topK: Int = 5) -> String? {
        let hits = selectForInjection(items: items, query: query, topK: topK)
        guard !hits.isEmpty else { return nil }
        let lines = hits.map { "- \($0.text)" }
        return "[长期记忆 — 来自以往会话沉淀的事实 / 偏好,回答时可参考,但与本轮明显冲突时以本轮为准]\n"
            + lines.joined(separator: "\n")
    }

    // MARK: - 溢出淘汰(置顶保护)

    /// `nonisolated` 纯函数:超出 cap 时从尾部(最旧)往前淘汰**未置顶**条目;
    /// 置顶永不淘汰 —— 极端情况下(置顶数 ≥ cap)允许超额保留置顶。
    nonisolated static func trimmedToCap(_ items: [MemoryItem], cap: Int) -> [MemoryItem] {
        guard items.count > cap else { return items }
        var result = items
        var overflow = result.count - cap
        var idx = result.count - 1
        while overflow > 0, idx >= 0 {
            if !result[idx].pinned {
                result.remove(at: idx)
                overflow -= 1
            }
            idx -= 1
        }
        return result
    }

    // MARK: - 去重(归一化 + 高相似;纯本地,无模型调用)

    /// 一键去重:对当前记忆库做归一化 / 高相似合并。
    /// 计划在后台线程算(O(n²) 相似度比较不上主线程),应用回主线程按 id 求交 — 期间新增的条目不受影响。
    /// 返回合并掉的条数。
    func deduplicate() async -> Int {
        let snapshot = items
        guard snapshot.count > 1 else { return 0 }
        let plan = await Task.detached(priority: .utility) {
            Self.dedupPlan(items: snapshot)
        }.value
        guard !plan.removeIDs.isEmpty else { return 0 }
        var removed = 0
        items.removeAll { item in
            guard plan.removeIDs.contains(item.id) else { return false }
            removed += 1
            return true
        }
        // 被合并的条目里有置顶的 → 幸存条目继承置顶,保证「置顶不因去重而消失」。
        for idx in items.indices where plan.pinIDs.contains(items[idx].id) {
            items[idx].pinned = true
        }
        if removed > 0 { persist() }
        return removed
    }

    /// `nonisolated` 纯函数:算一份去重计划(要删除的 id + 需要继承置顶的幸存者 id)。
    /// 只在**同一归属组内**合并(全局组 / 各 Persona 组互不跨组,避免改变记忆的可见范围)。
    /// 幸存者偏好:置顶 > 正文更长(信息更全)> 更新。
    nonisolated static func dedupPlan(items: [MemoryItem]) -> (removeIDs: Set<UUID>, pinIDs: Set<UUID>) {
        var removeIDs = Set<UUID>()
        var pinIDs = Set<UUID>()
        let groups = Dictionary(grouping: items, by: { $0.personaID })
        for (_, group) in groups {
            guard group.count > 1 else { continue }
            let ordered = group.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                let na = normalizeForDedup(a.text), nb = normalizeForDedup(b.text)
                if na.count != nb.count { return na.count > nb.count }
                return a.createdAt > b.createdAt
            }
            var survivors: [MemoryItem] = []
            for item in ordered {
                if let surv = survivors.first(where: { isNearDuplicate($0.text, item.text) }) {
                    removeIDs.insert(item.id)
                    if item.pinned && !surv.pinned { pinIDs.insert(surv.id) }
                } else {
                    survivors.append(item)
                }
            }
        }
        return (removeIDs, pinIDs)
    }

    /// 归一化(判重用):小写 + 去掉所有空白 / 标点 / 符号,只留字母数字与 CJK。
    nonisolated static func normalizeForDedup(_ s: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
            .union(.controlCharacters)
        var out = String.UnicodeScalarView()
        for scalar in s.lowercased().unicodeScalars where !drop.contains(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    /// 两段正文是否近重复:归一化后相等、一方完整包含另一方(短方 ≥ 6 字,防碎词误杀)、
    /// 或字符二元组 Jaccard 相似度 ≥ 0.85。
    nonisolated static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let na = normalizeForDedup(a), nb = normalizeForDedup(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        let (short, long) = na.count <= nb.count ? (na, nb) : (nb, na)
        if short.count >= 6, long.contains(short) { return true }
        return bigramJaccard(na, nb) >= 0.85
    }

    /// 给定文本在已有正文集合里是否有近重复。
    nonisolated static func containsNearDuplicate(_ text: String, in existing: [String]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return existing.contains { isNearDuplicate($0, t) }
    }

    /// 字符二元组 Jaccard 相似度(对中文短句友好,零依赖)。
    nonisolated static func bigramJaccard(_ a: String, _ b: String) -> Double {
        func bigrams(_ s: String) -> Set<String> {
            let chars = Array(s)
            guard chars.count >= 2 else { return chars.isEmpty ? [] : [String(chars[0])] }
            var set = Set<String>()
            set.reserveCapacity(chars.count - 1)
            for i in 0..<(chars.count - 1) {
                set.insert(String(chars[i]) + String(chars[i + 1]))
            }
            return set
        }
        let sa = bigrams(a), sb = bigrams(b)
        guard !sa.isEmpty, !sb.isEmpty else { return 0 }
        let inter = sa.intersection(sb).count
        let union = sa.union(sb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}
