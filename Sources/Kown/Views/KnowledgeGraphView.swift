import SwiftUI

/// [知识图谱自动连线] 把「知识条目 ↔ 对话 ↔ 长期记忆」之间由向量相似度发现的暗线渲染成关系图。
/// 节点按类型分簇环形排布,边按相似度权重画线;点节点跳到对应会话 / 打开知识库。
///
/// 计算(向量相似度)全在 `KnowledgeGraphService`(actor,后台);本视图只做布局(纯几何,
/// 一次性 + 轻量松弛迭代,O(边数 × 常数),不在每帧跑)与渲染。结果与布局都自管 @State。
struct KnowledgeGraphView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var graph: KnowledgeGraph = KnowledgeGraph(nodes: [], edges: [])
    @State private var positions: [String: CGPoint] = [:]
    @State private var loading = true
    @State private var selectedNodeID: String?
    @State private var threshold: Double = Double(KnowledgeGraphService.defaultThreshold)

    /// 是否打开知识库(点知识节点时)。
    @State private var openKnowledge = false

    private static let canvasSize = CGSize(width: 900, height: 700)

    var body: some View {
        platformBody
            .task { await rebuild(force: false) }
            .sheet(isPresented: $openKnowledge) {
                KnowledgeView(viewModel: viewModel)
            }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(iOS)
        NavigationStack {
            graphBody
                .navigationTitle("知识图谱")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .cancellationAction) { rebuildButton }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        #else
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(KownTheme.hairline).frame(height: 1)
            graphBody
        }
        .frame(minWidth: 680, idealWidth: 900, maxWidth: 1140, minHeight: 540, idealHeight: 720)
        .background(backdrop)
        #endif
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("知识图谱")
                    .font(.headline.weight(.black))
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            thresholdControl
            rebuildButton
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

    private var subtitleText: String {
        if loading { return "正在计算关系…" }
        return "\(graph.nodes.count) 个节点 · \(graph.edges.count) 条关联 · \(graph.connectedNodeCount) 个相连"
    }

    private var rebuildButton: some View {
        Button {
            Task { await rebuild(force: true) }
        } label: {
            Label("重新发现", systemImage: "arrow.clockwise")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(tint.opacity(0.12), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .help("重新计算节点之间的关联")
    }

    #if os(macOS)
    private var thresholdControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Slider(value: $threshold, in: 0.4...0.8, step: 0.05) { editing in
                if !editing { Task { await rebuild(force: true) } }
            }
            .frame(width: 120)
            Text("阈值 \(threshold, format: .number.precision(.fractionLength(2)))")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
        }
    }
    #else
    private var thresholdControl: some View { EmptyView() }
    #endif

    @ViewBuilder
    private var graphBody: some View {
        if loading {
            loadingState
        } else if graph.nodes.count < 2 {
            emptyState
        } else {
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                graphCanvas
                    .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
                    .padding(30)
            }
            .background(backdrop)
            .overlay(alignment: .bottom) { legend }
        }
    }

    private var graphCanvas: some View {
        ZStack(alignment: .topLeading) {
            // 边:相似度越高线越亮越粗。点击穿透到节点。
            Canvas { ctx, _ in
                for edge in graph.edges {
                    guard let p1 = positions[edge.a], let p2 = positions[edge.b] else { continue }
                    let highlighted = selectedNodeID == edge.a || selectedNodeID == edge.b
                    let strength = Double(max(0, min(1, (edge.weight - 0.4) / 0.4)))
                    var path = Path()
                    path.move(to: p1)
                    path.addLine(to: p2)
                    let baseOpacity = 0.18 + strength * 0.5
                    let opacity = highlighted ? min(1, baseOpacity + 0.3) : baseOpacity
                    ctx.stroke(path,
                               with: .color(tint.opacity(opacity)),
                               style: StrokeStyle(lineWidth: highlighted ? 2.4 : (1 + strength * 1.6),
                                                  lineCap: .round))
                }
            }
            .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
            .allowsHitTesting(false)

            ForEach(graph.nodes) { node in
                if let pos = positions[node.id] {
                    nodeView(node)
                        .position(pos)
                }
            }
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height, alignment: .topLeading)
    }

    private func nodeView(_ node: GraphNode) -> some View {
        let selected = selectedNodeID == node.id
        let color = kindColor(node.kind)
        let degree = degreeOf(node.id)
        // 度数越高节点越大(更显眼),夹在 [40, 72]。
        let size = min(72, 40 + CGFloat(degree) * 5)
        return Button {
            if selected {
                activate(node)
            } else {
                selectedNodeID = node.id
            }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.6)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: kindIcon(node.kind))
                        .font(.system(size: size * 0.34, weight: .black))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .overlay {
                    Circle().strokeBorder(selected ? Color.white : color.opacity(0.4),
                                          lineWidth: selected ? 3 : 1)
                }
                .shadow(color: color.opacity(selected ? 0.4 : 0.18), radius: selected ? 12 : 5, x: 0, y: 4)
                Text(node.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(selected ? 3 : 1)
                    .multilineTextAlignment(.center)
                    .frame(width: 110)
                    .fixedSize(horizontal: false, vertical: true)
                if selected {
                    Text(node.subtitle + " · 点击打开")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .help("\(node.title) — \(node.subtitle)")
        .accessibilityLabel("\(node.title),\(node.subtitle),\(degree) 条关联")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.knowledge, "知识")
            legendItem(.conversation, "对话")
            legendItem(.memory, "记忆")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay { Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
        .padding(.bottom, 14)
    }

    private func legendItem(_ kind: GraphNodeKind, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(kindColor(kind)).frame(width: 10, height: 10)
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("正在用本地向量发现关联…")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("首次计算需要为各条目算句向量,稍候。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backdrop)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34, weight: .black))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("内容还不够画图")
                .font(.headline.weight(.black))
            Text("知识库文档、会话、长期记忆加起来至少要有两条,Kown 才能发现它们之间的暗线。多用一阵子再来看。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backdrop)
    }

    // MARK: - 交互

    /// 点击已选中节点 → 跳转到来源。
    private func activate(_ node: GraphNode) {
        switch node.kind {
        case .conversation:
            if let id = node.refID {
                viewModel.selectConversation(id)
                dismiss()
            }
        case .knowledge:
            openKnowledge = true
        case .memory:
            break   // 记忆无独立详情页,仅高亮其关联
        }
    }

    private func degreeOf(_ id: String) -> Int {
        graph.edges.reduce(0) { $0 + (($1.a == id || $1.b == id) ? 1 : 0) }
    }

    // MARK: - 重算 + 布局

    private func rebuild(force: Bool) async {
        loading = true
        let g = await viewModel.buildKnowledgeGraph(force: force)
        let layout = Self.computeLayout(graph: g, canvas: Self.canvasSize)
        graph = g
        positions = layout
        selectedNodeID = nil
        loading = false
    }

    private var tint: Color { Color(red: 0.10, green: 0.66, blue: 0.56) }

    private func kindColor(_ kind: GraphNodeKind) -> Color {
        switch kind {
        case .knowledge:    return Color(red: 0.10, green: 0.66, blue: 0.56)
        case .conversation: return Color(red: 0.16, green: 0.48, blue: 0.94)
        case .memory:       return Color(red: 0.56, green: 0.40, blue: 0.86)
        }
    }

    private func kindIcon(_ kind: GraphNodeKind) -> String {
        switch kind {
        case .knowledge:    return "doc.text.fill"
        case .conversation: return "bubble.left.and.bubble.right.fill"
        case .memory:       return "brain"
        }
    }

    private var backdrop: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(colors: [tint.opacity(0.10), Color.clear],
                           center: .center, startRadius: 40, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 布局算法(纯几何,与 SwiftUI 解耦)

extension KnowledgeGraphView {
    /// 确定性布局:三类节点各占一条同心环带(知识内环 / 对话中环 / 记忆外环),
    /// 然后做少量弹簧松弛(相连节点相互靠拢、所有节点相互排斥)让相关簇聚拢。
    /// 一次性算完(非每帧),迭代数固定,O(节点² + 边×迭代),节点已在 actor 端截断,开销可控。
    static func computeLayout(graph: KnowledgeGraph, canvas: CGSize) -> [String: CGPoint] {
        let nodes = graph.nodes
        guard !nodes.isEmpty else { return [:] }
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let maxR = min(canvas.width, canvas.height) / 2 - 80

        // 1) 初始位置:按类型分环,环内均匀铺角度(稳定、可复现)。
        let byKind: [GraphNodeKind: [GraphNode]] = Dictionary(grouping: nodes, by: \.kind)
        let ringRadius: [GraphNodeKind: CGFloat] = [
            .knowledge: maxR * 0.42,
            .conversation: maxR * 0.72,
            .memory: maxR * 1.0
        ]
        var pos: [String: CGPoint] = [:]
        for (kind, group) in byKind {
            let r = ringRadius[kind] ?? maxR * 0.7
            let n = max(1, group.count)
            for (i, node) in group.enumerated() {
                let angle = (Double(i) / Double(n)) * 2 * .pi
                pos[node.id] = CGPoint(x: center.x + r * CGFloat(cos(angle)),
                                       y: center.y + r * CGFloat(sin(angle)))
            }
        }

        // 2) 弹簧松弛:相连节点吸引,所有节点轻微排斥,迭代少量步。
        let ids = nodes.map(\.id)
        let idSet = Set(ids)
        let edges = graph.edges.filter { idSet.contains($0.a) && idSet.contains($0.b) }
        let iterations = 60
        let kRepel: CGFloat = 9000      // 排斥强度
        let kAttract: CGFloat = 0.012   // 吸引强度
        for _ in 0..<iterations {
            var disp: [String: CGVector] = [:]
            // 排斥(O(n²),n 已截断)。
            for i in 0..<ids.count {
                var dx: CGFloat = 0, dy: CGFloat = 0
                guard let pi = pos[ids[i]] else { continue }
                for j in 0..<ids.count where j != i {
                    guard let pj = pos[ids[j]] else { continue }
                    var ddx = pi.x - pj.x, ddy = pi.y - pj.y
                    var dist2 = ddx * ddx + ddy * ddy
                    if dist2 < 1 { dist2 = 1; ddx = CGFloat.random(in: -1...1); ddy = CGFloat.random(in: -1...1) }
                    let force = kRepel / dist2
                    let dist = max(1, dist2.squareRoot())
                    dx += ddx / dist * force
                    dy += ddy / dist * force
                }
                disp[ids[i]] = CGVector(dx: dx, dy: dy)
            }
            // 吸引(沿边)。
            for e in edges {
                guard let pa = pos[e.a], let pb = pos[e.b] else { continue }
                let ddx = pb.x - pa.x, ddy = pb.y - pa.y
                let pull = kAttract * (1 + CGFloat(e.weight))
                disp[e.a]?.dx += ddx * pull
                disp[e.a]?.dy += ddy * pull
                disp[e.b]?.dx -= ddx * pull
                disp[e.b]?.dy -= ddy * pull
            }
            // 应用位移(限幅,避免抖飞),并夹回画布内。
            for id in ids {
                guard var p = pos[id], let d = disp[id] else { continue }
                let cap: CGFloat = 18
                p.x += max(-cap, min(cap, d.dx))
                p.y += max(-cap, min(cap, d.dy))
                p.x = max(60, min(canvas.width - 60, p.x))
                p.y = max(60, min(canvas.height - 60, p.y))
                pos[id] = p
            }
        }
        return pos
    }
}
