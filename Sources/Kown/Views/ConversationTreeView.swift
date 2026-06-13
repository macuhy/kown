import SwiftUI

/// [对话树画布] 把会话的**分支血缘**(`parentConversationID` / `forkedFromTurnID`)铺成
/// 一棵可缩放、可平移的空间树:一条思路怎么分叉、每个岔路通向哪,一眼看清;点节点跳到该会话。
///
/// 纯前端、只读:从 `viewModel.conversations` 读血缘字段,自己算分层 tidy-tree 布局,
/// 不改 Conversation 模型、不落盘。布局在 `onAppear` / 会话数变化时算一次,渲染用
/// ZStack 摆节点 + Canvas 画连线(连线是纯绘制,不参与命中,节点各自接收点击)。
struct ConversationTreeView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    /// 缩放(手势 + 双击复位)。
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    /// 已算好的布局(节点位置 + 边)。
    @State private var layout: TreeLayout = .empty
    /// 是否只看「有分支的树」(过滤掉没有任何父/子的孤立会话,默认开 —— 孤立会话太多会糊)。
    @State private var onlyBranched = true

    private var tint: Color { Color(red: 0.10, green: 0.66, blue: 0.56) }
    private var warmTint: Color { Color(red: 0.20, green: 0.56, blue: 0.78) }

    var body: some View {
        platformBody
            .onAppear { recomputeLayout() }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(iOS)
        NavigationStack {
            canvasBody
                .navigationTitle("对话树")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .cancellationAction) { branchFilterToggle }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        #else
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(KownTheme.hairline).frame(height: 1)
            canvasBody
        }
        .frame(minWidth: 640, idealWidth: 860, maxWidth: 1100, minHeight: 520, idealHeight: 700)
        .background(backdrop)
        #endif
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("对话树画布")
                    .font(.headline.weight(.black))
                Text("\(layout.nodes.count) 个会话 · \(layout.treeCount) 棵分支树 — 点节点跳到会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            branchFilterToggle
            zoomControls
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.platformControlBackground.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var branchFilterToggle: some View {
        Button {
            onlyBranched.toggle()
            recomputeLayout()
        } label: {
            Label(onlyBranched ? "只看分支" : "全部会话",
                  systemImage: onlyBranched ? "arrow.triangle.branch" : "square.grid.2x2")
                .font(.caption.weight(.bold))
                .foregroundStyle(onlyBranched ? Color.white : tint)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(onlyBranched ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)),
                            in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(onlyBranched ? "当前只显示有分叉血缘的会话树,点击显示全部会话" : "显示全部会话(含未分支的孤立会话)")
    }

    #if os(macOS)
    private var zoomControls: some View {
        HStack(spacing: 6) {
            zoomButton("minus.magnifyingglass") { setZoom(zoom / 1.25) }
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.weight(.black))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44)
            zoomButton("plus.magnifyingglass") { setZoom(zoom * 1.25) }
            zoomButton("arrow.counterclockwise") { setZoom(1) }
        }
    }

    private func zoomButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.black))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
    }
    #else
    private var zoomControls: some View { EmptyView() }
    #endif

    @ViewBuilder
    private var canvasBody: some View {
        if layout.nodes.isEmpty {
            emptyState
        } else {
            GeometryReader { _ in
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    treeContent
                        .padding(40)
                        .scaleEffect(effectiveZoom, anchor: .topLeading)
                        .frame(
                            width: layout.canvasSize.width * effectiveZoom + 80,
                            height: layout.canvasSize.height * effectiveZoom + 80,
                            alignment: .topLeading
                        )
                }
                #if os(iOS)
                .gesture(magnifyGesture)
                #endif
            }
            .background(backdrop)
        }
    }

    /// 节点 + 连线叠在一张固定尺寸画布上(缩放由外层 scaleEffect 统一施加)。
    private var treeContent: some View {
        ZStack(alignment: .topLeading) {
            // 连线:纯绘制层,allowsHitTesting(false) 让点击穿透到下面的节点。
            Canvas { ctx, _ in
                let pos = Dictionary(layout.nodes.map { ($0.id, $0.center) },
                                     uniquingKeysWith: { a, _ in a })
                for edge in layout.edges {
                    guard let from = pos[edge.parent], let to = pos[edge.child] else { continue }
                    var path = Path()
                    let start = CGPoint(x: from.x, y: from.y + Self.nodeHeight / 2)
                    let end = CGPoint(x: to.x, y: to.y - Self.nodeHeight / 2)
                    let midY = (start.y + end.y) / 2
                    path.move(to: start)
                    path.addCurve(to: end,
                                  control1: CGPoint(x: start.x, y: midY),
                                  control2: CGPoint(x: end.x, y: midY))
                    ctx.stroke(path, with: .color(tint.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
            .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
            .allowsHitTesting(false)

            ForEach(layout.nodes) { node in
                nodeCard(node)
                    .position(x: node.center.x, y: node.center.y)
            }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height, alignment: .topLeading)
    }

    private func nodeCard(_ node: TreeNode) -> some View {
        let selected = viewModel.selectedConversationID == node.id
        let mode = node.mode
        return Button {
            viewModel.selectConversation(node.id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    KownModeMark(mode: mode, size: 22, selected: true)
                    Text(modeLabel(mode))
                        .font(.caption2.weight(.black))
                        .foregroundStyle(mode.kownTint)
                    Spacer(minLength: 0)
                    if node.isRoot && node.hasChildren {
                        Image(systemName: "asterisk.circle.fill")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(node.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Label("\(node.turnCount)", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if node.forkedFromTurnID != nil {
                        Label("分支", systemImage: "arrow.triangle.branch")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(warmTint)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(width: Self.nodeWidth, height: Self.nodeHeight, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: [mode.kownTint.opacity(selected ? 0.24 : 0.10), Color.clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? mode.kownTint : mode.kownTint.opacity(0.22),
                                  lineWidth: selected ? 2 : 1)
            }
            .shadow(color: mode.kownTint.opacity(selected ? 0.20 : 0.06), radius: selected ? 12 : 6, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .help(node.title)
        .accessibilityLabel("会话 \(node.title),\(node.turnCount) 轮" + (node.forkedFromTurnID != nil ? ",分支" : ""))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 34, weight: .black))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text(onlyBranched ? "还没有分支会话" : "还没有会话")
                .font(.headline.weight(.black))
            Text(onlyBranched
                 ? "在任意回答上点「从这里分支」开新思路,这里就会长出一棵对话树。也可以点上方「全部会话」看所有会话。"
                 : "先开几个会话再来看血缘图。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backdrop)
    }

    // MARK: - 缩放

    private var effectiveZoom: CGFloat {
        max(0.3, min(2.5, zoom * pinch))
    }

    #if os(iOS)
    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in setZoom(zoom * value) }
    }
    #endif

    private func setZoom(_ new: CGFloat) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            zoom = max(0.3, min(2.5, new))
        }
    }

    // MARK: - 布局计算

    private func recomputeLayout() {
        layout = TreeLayouter.layout(
            conversations: viewModel.conversations.filter { $0.deletedAt == nil },
            onlyBranched: onlyBranched,
            nodeWidth: Self.nodeWidth, nodeHeight: Self.nodeHeight,
            hGap: Self.hGap, vGap: Self.vGap
        )
    }

    private var backdrop: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(colors: [tint.opacity(0.10), Color.clear],
                           center: .topLeading, startRadius: 10, endRadius: 460)
            RadialGradient(colors: [warmTint.opacity(0.10), Color.clear],
                           center: .bottomTrailing, startRadius: 20, endRadius: 540)
        }
        .ignoresSafeArea()
    }

    // 节点尺寸与间距(布局与渲染共用)。
    private static let nodeWidth: CGFloat = 168
    private static let nodeHeight: CGFloat = 86
    private static let hGap: CGFloat = 26
    private static let vGap: CGFloat = 64

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
}

// MARK: - 布局模型

/// 树上一个节点(一个会话的展示快照 + 它在画布上的中心点)。
struct TreeNode: Identifiable {
    let id: UUID
    let title: String
    let mode: ConversationMode
    let turnCount: Int
    let forkedFromTurnID: UUID?
    let isRoot: Bool
    let hasChildren: Bool
    var center: CGPoint
}

/// 一条父→子血缘边(画连线用)。
struct TreeEdge: Hashable {
    let parent: UUID
    let child: UUID
}

/// 一次布局结果:节点(含坐标)+ 边 + 画布尺寸 + 树数量。
struct TreeLayout {
    var nodes: [TreeNode]
    var edges: [TreeEdge]
    var canvasSize: CGSize
    var treeCount: Int

    static let empty = TreeLayout(nodes: [], edges: [], canvasSize: .zero, treeCount: 0)
}

/// 分层 tidy-tree 布局算法:森林(多棵树)按经典「子树宽度递归 + 父节点居中于子节点跨度」摆放。
/// 纯函数 / 无副作用,与 SwiftUI 解耦,易测。深度 = 纵向层级,叶子从左到右铺开,父节点居中。
/// 防御:父指针可能成环或指向已过滤节点 —— 用 visited 集合断环,缺失父按根处理。
enum TreeLayouter {
    static func layout(
        conversations: [Conversation],
        onlyBranched: Bool,
        nodeWidth: CGFloat, nodeHeight: CGFloat,
        hGap: CGFloat, vGap: CGFloat
    ) -> TreeLayout {
        guard !conversations.isEmpty else { return .empty }

        let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        // 子节点表:parentID → [childID](父必须也在集合内,否则该子按根处理)。
        var childrenOf: [UUID: [UUID]] = [:]
        for conv in conversations {
            if let pid = conv.parentConversationID, byID[pid] != nil {
                childrenOf[pid, default: []].append(conv.id)
            }
        }

        // 只看分支模式:保留「有父(在集合内)或有子」的会话,过滤掉完全孤立的。
        let visibleIDs: Set<UUID>
        if onlyBranched {
            var keep = Set<UUID>()
            for conv in conversations {
                let hasParent = conv.parentConversationID.flatMap { byID[$0] } != nil
                let hasChild = !(childrenOf[conv.id]?.isEmpty ?? true)
                if hasParent || hasChild { keep.insert(conv.id) }
            }
            visibleIDs = keep
        } else {
            visibleIDs = Set(conversations.map(\.id))
        }
        guard !visibleIDs.isEmpty else { return .empty }

        // 根 = 在可见集合里、且没有可见父的节点。稳定排序(updatedAt 新→旧)让布局可复现。
        func visibleChildren(_ id: UUID) -> [UUID] {
            (childrenOf[id] ?? []).filter { visibleIDs.contains($0) }
        }
        let roots = conversations
            .filter { visibleIDs.contains($0.id) }
            .filter { conv in
                guard let pid = conv.parentConversationID, byID[pid] != nil, visibleIDs.contains(pid)
                else { return true }
                return false
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.id)

        // 递归摆放:列游标(leafX)从左到右推进;父节点 x = 子节点 x 的均值。
        var centers: [UUID: CGPoint] = [:]
        var visited = Set<UUID>()
        var leafCursor: CGFloat = 0
        let stepX = nodeWidth + hGap
        let stepY = nodeHeight + vGap

        func place(_ id: UUID, depth: Int) {
            guard visited.insert(id).inserted else { return }   // 断环
            let kids = visibleChildren(id).filter { !visited.contains($0) }
            let y = CGFloat(depth) * stepY + nodeHeight / 2
            if kids.isEmpty {
                let x = leafCursor * stepX + nodeWidth / 2
                centers[id] = CGPoint(x: x, y: y)
                leafCursor += 1
            } else {
                for kid in kids { place(kid, depth: depth + 1) }
                let kidXs = kids.compactMap { centers[$0]?.x }
                let x = kidXs.isEmpty
                    ? leafCursor * stepX + nodeWidth / 2
                    : (kidXs.min()! + kidXs.max()!) / 2
                centers[id] = CGPoint(x: x, y: y)
            }
        }

        // 棵与棵之间留一列空隙(leafCursor 自然推进即可,这里每棵树开始前不额外加,靠节点本身间隔)。
        for root in roots {
            place(root, depth: 0)
            leafCursor += 1   // 相邻树之间空一列,避免两棵树贴在一起
        }

        guard !centers.isEmpty else { return .empty }

        // 组装节点 + 边。
        var nodes: [TreeNode] = []
        for (id, center) in centers {
            guard let conv = byID[id] else { continue }
            let kids = visibleChildren(id)
            let title = conv.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "未命名会话" : conv.title
            let parentVisible = conv.parentConversationID.map { visibleIDs.contains($0) && byID[$0] != nil } ?? false
            nodes.append(TreeNode(
                id: id, title: title, mode: conv.mode, turnCount: conv.turns.count,
                forkedFromTurnID: conv.forkedFromTurnID,
                isRoot: !parentVisible, hasChildren: !kids.isEmpty,
                center: center))
        }
        var edges: [TreeEdge] = []
        for id in visibleIDs {
            for kid in visibleChildren(id) where centers[kid] != nil && centers[id] != nil {
                edges.append(TreeEdge(parent: id, child: kid))
            }
        }

        let maxX = centers.values.map(\.x).max() ?? nodeWidth
        let maxY = centers.values.map(\.y).max() ?? nodeHeight
        let size = CGSize(width: maxX + nodeWidth / 2, height: maxY + nodeHeight / 2)
        // 稳定输出顺序(便于 ForEach diff)。
        nodes.sort { ($0.center.y, $0.center.x) < ($1.center.y, $1.center.x) }
        return TreeLayout(nodes: nodes, edges: edges, canvasSize: size, treeCount: roots.count)
    }
}
