import Foundation

/// [知识图谱自动连线] 在后台发现「知识条目 ↔ 对话 ↔ 长期记忆」之间的暗线:
/// 把三类内容各抽成一段代表文本,用 `LocalRAG` 的本地句向量(Apple `NLContextualEmbedding`,
/// 资产未就绪时回退 `NLEmbedding`)两两算余弦相似度,超阈值的连成一条边 ——
/// 「Kown 发现这条和你三周前讨论的某事相关」。
///
/// `actor`:全部向量计算 + 缓存隔离在 actor 内(复用 `RAGVectorCache`,本身就是 actor),
/// 在后台线程跑,绝不回主线程(防 CPU 卡死)。结果是 Sendable 的纯数据图,回主线程渲染。
/// 复用 LocalRAG 的向量能力,不自己造嵌入。
actor KnowledgeGraphService {
    static let shared = KnowledgeGraphService()

    /// 上次算好的图(同输入直接复用,避免重复全量计算)。
    private var cached: KnowledgeGraph?
    /// 上次输入的指纹(节点集合变化才重算)。
    private var cachedSignature: String?

    private init() {}

    /// 相似度阈值:余弦 ≥ 此值才连边。句向量已单位化,点积即余弦。
    /// 0.55 在中文 contextual 向量上能滤掉泛泛相关、留下「确有关联」的对,经验值。
    static let defaultThreshold: Float = 0.55
    /// 每个节点最多保留的边数(只连最相关的 K 条,避免稠密图糊成一团 + 控制 O(n²) 后的边量)。
    static let maxEdgesPerNode = 4
    /// 参与计算的节点上限(各类型分别截断,防超大知识库 / 海量会话把 O(n²) 拖爆)。
    static let maxNodesPerKind = 80

    /// 构建知识图谱。`force` 为 true 时忽略缓存重算。
    /// 输入是主线程取好的快照(Sendable),actor 内只做纯计算。
    func buildGraph(
        input: GraphInput,
        threshold: Float = KnowledgeGraphService.defaultThreshold,
        force: Bool = false
    ) async -> KnowledgeGraph {
        let signature = input.signature + "|t=\(threshold)"
        if !force, let cached, cachedSignature == signature { return cached }

        // 1) 汇集节点(各类型截断到上限)。
        var nodes: [GraphNode] = []
        nodes.append(contentsOf: input.knowledgeNodes.prefix(Self.maxNodesPerKind))
        nodes.append(contentsOf: input.conversationNodes.prefix(Self.maxNodesPerKind))
        nodes.append(contentsOf: input.memoryNodes.prefix(Self.maxNodesPerKind))
        guard nodes.count >= 2 else {
            let empty = KnowledgeGraph(nodes: nodes, edges: [])
            cached = empty; cachedSignature = signature
            return empty
        }

        // 2) 算每个节点的句向量(走 RAGVectorCache,与检索同一套缓存,命中即复用)。
        let cache = RAGVectorCache.shared
        var vectors: [Int: [Float]] = [:]
        for (i, node) in nodes.enumerated() {
            if Task.isCancelled { break }
            let text = node.embedText
            guard !text.isEmpty else { continue }
            let lang = LocalRAG.isCJKHeavy(text) ? "zh" : "en"
            guard let tag = await cache.activeTag(forLang: lang) else { continue }
            if let v = await cache.vector(forText: text, lang: tag), v.contains(where: { $0 != 0 }) {
                vectors[i] = v
            }
        }
        await cache.persistIfDirty()

        // 3) 两两算相似度,收集候选边(只在向量同维度时比,跨后端/跨语言维度不同自然跳过)。
        var candidatesByNode: [Int: [(other: Int, sim: Float)]] = [:]
        let idxs = Array(vectors.keys).sorted()
        for a in 0..<idxs.count {
            for b in (a + 1)..<idxs.count {
                let i = idxs[a], j = idxs[b]
                guard let vi = vectors[i], let vj = vectors[j], vi.count == vj.count else { continue }
                let sim = LocalRAG.dot(vi, vj)
                guard sim >= threshold else { continue }
                candidatesByNode[i, default: []].append((j, sim))
                candidatesByNode[j, default: []].append((i, sim))
            }
        }

        // 4) 每个节点只留最相关的 maxEdgesPerNode 条,无向去重。
        var edgeSet = Set<GraphEdge>()
        for (node, cands) in candidatesByNode {
            let top = cands.sorted { $0.sim > $1.sim }.prefix(Self.maxEdgesPerNode)
            for c in top {
                edgeSet.insert(GraphEdge(a: nodes[node].id, b: nodes[c.other].id,
                                         weight: c.sim))
            }
        }
        let edges = edgeSet.sorted { $0.weight > $1.weight }

        let graph = KnowledgeGraph(nodes: nodes, edges: edges)
        cached = graph
        cachedSignature = signature
        return graph
    }

    /// 失效缓存(知识库 / 会话 / 记忆变动后,下次重算)。
    func invalidate() {
        cached = nil
        cachedSignature = nil
    }
}

// MARK: - 图数据模型(全 Sendable,跨 actor 边界安全)

/// 节点类型 —— 决定渲染色与图标,也用于「跨类型连线」的语义。
enum GraphNodeKind: String, Sendable, Hashable {
    case knowledge   // 知识库 chunk
    case conversation
    case memory      // 长期记忆
}

/// 图上一个节点。`embedText` 是拿去算向量的代表文本(actor 内用,不展示);
/// `title` / `subtitle` 是展示文案。`refID` 回溯到原对象(点击跳转用)。
struct GraphNode: Identifiable, Sendable, Hashable {
    let id: String
    let kind: GraphNodeKind
    let title: String
    let subtitle: String
    /// 算向量用的代表文本(截断后的正文)。
    let embedText: String
    /// 回溯目标:会话 = 会话 UUID;知识 = 文档 UUID;记忆 = 记忆 UUID。
    let refID: UUID?

    init(id: String, kind: GraphNodeKind, title: String, subtitle: String, embedText: String, refID: UUID?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.embedText = embedText
        self.refID = refID
    }
}

/// 一条无向边(两节点 id + 相似度权重)。a < b 规范化,保证无向去重。
struct GraphEdge: Sendable, Hashable {
    let a: String
    let b: String
    let weight: Float

    init(a: String, b: String, weight: Float) {
        if a <= b { self.a = a; self.b = b } else { self.a = b; self.b = a }
        self.weight = weight
    }

    // 去重只看端点(同一对节点不重复连),权重不参与 Hash/Equal。
    static func == (lhs: GraphEdge, rhs: GraphEdge) -> Bool { lhs.a == rhs.a && lhs.b == rhs.b }
    func hash(into hasher: inout Hasher) { hasher.combine(a); hasher.combine(b) }
}

/// 一次计算的输出:节点 + 边。
struct KnowledgeGraph: Sendable {
    var nodes: [GraphNode]
    var edges: [GraphEdge]

    var isEmpty: Bool { nodes.isEmpty }

    /// 至少连了一条边的节点数(孤立节点不算)。
    var connectedNodeCount: Int {
        var s = Set<String>()
        for e in edges { s.insert(e.a); s.insert(e.b) }
        return s.count
    }
}

/// 主线程取好的输入快照(三类节点的代表文本),交给 actor 算向量。全 Sendable。
struct GraphInput: Sendable {
    var knowledgeNodes: [GraphNode]
    var conversationNodes: [GraphNode]
    var memoryNodes: [GraphNode]

    /// 输入指纹(节点 id 集合 + 数量)——节点集合没变就直接吃缓存。
    var signature: String {
        let k = knowledgeNodes.map(\.id).joined(separator: ",")
        let c = conversationNodes.map(\.id).joined(separator: ",")
        let m = memoryNodes.map(\.id).joined(separator: ",")
        return "K[\(k)]C[\(c)]M[\(m)]"
    }

    var totalCount: Int { knowledgeNodes.count + conversationNodes.count + memoryNodes.count }
}
