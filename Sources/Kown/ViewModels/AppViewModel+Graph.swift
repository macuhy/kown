import Foundation

/// [知识图谱自动连线] 在主线程把三类内容(知识 chunk / 会话 / 长期记忆)抽成节点快照,
/// 交给 `KnowledgeGraphService`(actor,后台算向量相似度)产出关系图。
/// 这里只做轻量快照组装,重活全在 actor —— 不在主线程算任何向量(防 CPU 卡死)。
extension AppViewModel {
    /// 构建知识图谱:组装输入 → 后台 actor 计算 → 返回 Sendable 图。
    /// `force` 透传给 actor 忽略缓存。视图自管结果 @State,本方法不落任何状态。
    func buildKnowledgeGraph(force: Bool = false) async -> KnowledgeGraph {
        let input = makeGraphInput()
        guard input.totalCount >= 2 else { return KnowledgeGraph(nodes: input.knowledgeNodes + input.conversationNodes + input.memoryNodes, edges: []) }
        return await KnowledgeGraphService.shared.buildGraph(input: input, force: force)
    }

    /// 让图缓存失效(知识库 / 记忆 / 会话有改动后,下次重算)。
    func invalidateKnowledgeGraph() {
        Task { await KnowledgeGraphService.shared.invalidate() }
    }

    /// 当前是否有足够内容值得画图(总节点 ≥ 2)。供入口按钮判断启用态。
    var hasGraphableContent: Bool {
        makeGraphInput().totalCount >= 2
    }

    // MARK: - 输入快照组装(主线程,纯取值)

    /// 把会话 / 知识库文档 / 长期记忆各抽成代表文本节点。各类型分别截断到 actor 上限的两倍
    /// (actor 内再精确截断),取最新 / 最有内容的优先。
    private func makeGraphInput() -> GraphInput {
        GraphInput(
            knowledgeNodes: knowledgeGraphNodes(),
            conversationNodes: conversationGraphNodes(),
            memoryNodes: memoryGraphNodes()
        )
    }

    /// 知识库节点:每份文档一个节点(代表文本取文档正文前若干字)。空文档跳过。
    private func knowledgeGraphNodes() -> [GraphNode] {
        var out: [GraphNode] = []
        for folder in knowledgeFolders {
            for doc in folder.docs {
                let body = doc.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                out.append(GraphNode(
                    id: "doc-\(doc.id.uuidString)",
                    kind: .knowledge,
                    title: doc.name.isEmpty ? "未命名文档" : doc.name,
                    subtitle: "知识库 · \(folder.name)",
                    embedText: String(body.prefix(1000)),
                    refID: doc.id))
                if out.count >= KnowledgeGraphService.maxNodesPerKind * 2 { return out }
            }
        }
        return out
    }

    /// 会话节点:代表文本 = 标题 + 最近若干轮的问答拼接(截断)。空会话(无轮)跳过。
    private func conversationGraphNodes() -> [GraphNode] {
        let active = activeConversations.prefix(KnowledgeGraphService.maxNodesPerKind * 2)
        var out: [GraphNode] = []
        for conv in active {
            guard !conv.turns.isEmpty else { continue }
            let title = conv.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "未命名会话" : conv.title
            // 代表文本:标题 + 最近 3 轮 prompt + 首个非空回答片段。
            var parts: [String] = [title]
            for turn in conv.turns.suffix(3) {
                let q = turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty { parts.append(q) }
                if let a = turn.responses.values.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    parts.append(String(a.prefix(300)))
                }
            }
            let embed = String(parts.joined(separator: "\n").prefix(1200))
            out.append(GraphNode(
                id: "conv-\(conv.id.uuidString)",
                kind: .conversation,
                title: title,
                subtitle: "会话 · \(conv.turns.count) 轮",
                embedText: embed,
                refID: conv.id))
        }
        return out
    }

    /// 记忆节点:每条长期记忆一个节点(代表文本 = 记忆正文)。
    private func memoryGraphNodes() -> [GraphNode] {
        MemoryStore.shared.items.prefix(KnowledgeGraphService.maxNodesPerKind * 2).compactMap { item in
            let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            return GraphNode(
                id: "mem-\(item.id.uuidString)",
                kind: .memory,
                title: String(t.prefix(40)),
                subtitle: "长期记忆",
                embedText: t,
                refID: item.id)
        }
    }
}
