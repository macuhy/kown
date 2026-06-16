import SwiftUI

/// Standalone Connector Hub surface. It can render a supplied snapshot in previews/tests,
/// or build a live snapshot from `ConnectorHubService` without depending on AppViewModel.
struct ConnectorHubView: View {
    @State private var snapshot: ConnectorHubSnapshot
    private let snapshotProvider: (@MainActor () -> ConnectorHubSnapshot)?

    @MainActor
    init() {
        let initial = ConnectorHubService.snapshot()
        self._snapshot = State(initialValue: initial)
        self.snapshotProvider = { ConnectorHubService.snapshot() }
    }

    init(snapshot: ConnectorHubSnapshot) {
        self._snapshot = State(initialValue: snapshot)
        self.snapshotProvider = nil
    }

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                connectorGrid
                actionsSection
            }
            #if os(iOS)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            #else
            .padding(20)
            #endif
            .frame(maxWidth: 960, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    heroTitle
                    Spacer(minLength: 16)
                    refreshButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    heroTitle
                    refreshButton
                }
            }

            HStack(spacing: 8) {
                statusChip(title: snapshot.healthSummary, icon: "checkmark.seal.fill", color: .green)
                statusChip(title: "\(snapshot.suggestedActions.count) actions", icon: "lightbulb.fill", color: .orange)
                Label {
                    Text(snapshot.generatedAt, style: .relative)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.platformControlBackground.opacity(0.56), in: Capsule(style: .continuous))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.teal.opacity(0.16), Color.blue.opacity(0.08), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.18), lineWidth: 1)
        }
    }

    private var heroTitle: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.teal.opacity(0.16))
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.teal)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text("Connector Hub")
                    .font(.title3.weight(.bold))
                Text("汇总 GitHub、Web、MCP、知识库、iCloud、日历/提醒和系统工具,供项目与 Agent 决定可用能力。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var refreshButton: some View {
        Button {
            refresh()
        } label: {
            Label("刷新", systemImage: "arrow.clockwise")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.teal)
        .disabled(snapshotProvider == nil)
        .help(snapshotProvider == nil ? "当前展示的是传入的静态快照" : "重新读取连接器状态")
    }

    private var connectorGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(snapshot.connectors) { connector in
                ConnectorCard(connector: connector)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        let actions = snapshot.suggestedActions
        VStack(alignment: .leading, spacing: 10) {
            Label("建议操作", systemImage: "wand.and.stars")
                .font(.headline.weight(.bold))
                .foregroundStyle(.teal)

            if actions.isEmpty {
                Label("所有核心连接器都已处于可用或无需处理状态。", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.platformControlBackground.opacity(0.50), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                ForEach(actions) { action in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: action.priority.symbolName)
                            .foregroundStyle(action.priority.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(action.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(action.connector.displayName)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.teal)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.teal.opacity(0.12), in: Capsule(style: .continuous))
                            }
                            Text(action.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.platformControlBackground.opacity(0.50), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(action.priority.tint.opacity(0.14), lineWidth: 1)
                    }
                }
            }
        }
    }

    @MainActor
    private func refresh() {
        guard let snapshotProvider else { return }
        snapshot = snapshotProvider()
    }

    private func statusChip(title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(color.opacity(0.18), lineWidth: 1)
            }
            .fixedSize()
    }
}

private struct ConnectorCard: View {
    let connector: ConnectorHubItem

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            Text(connector.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionRow
            syncRow
            details
            descriptionBlock(title: "Project", text: connector.projectDescription)
            descriptionBlock(title: "Agent", text: connector.agentDescription)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(connector.health.tint.opacity(0.18), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(connector.health.tint.opacity(0.14))
                Image(systemName: connector.kind.systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(connector.health.tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(connector.title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                HStack(spacing: 6) {
                    chip(connector.state.displayName, color: connector.health.tint)
                    chip(connector.health.displayName, color: connector.health.tint)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var permissionRow: some View {
        FlowRow(spacing: 6) {
            ForEach(connector.permissions) { permission in
                chip(permission.displayName, color: permission.tint)
                    .help(permission.agentVerb)
            }
        }
    }

    @ViewBuilder
    private var syncRow: some View {
        if let date = connector.lastSyncAt {
            Label {
                Text(date, style: .relative)
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        } else {
            Label("无可靠同步时间", systemImage: "minus.circle")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(connector.details) { detail in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(detail.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Text(detail.value)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(Color.platformControlBackground.opacity(0.46), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func descriptionBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(connector.health.tint)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.11), in: Capsule(style: .continuous))
    }
}

/// Tiny wrapping layout for permission chips. Kept local so ConnectorHubView is self-contained.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needsNewLine = lineWidth > 0 && lineWidth + spacing + size.width > maxWidth
            if needsNewLine {
                totalWidth = max(totalWidth, lineWidth)
                totalHeight += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }

        totalWidth = max(totalWidth, lineWidth)
        totalHeight += lineHeight
        return CGSize(width: proposal.width ?? totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + spacing + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private extension ConnectorHubHealth {
    var tint: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .orange
        case .needsSetup: return .yellow
        case .unavailable: return .red
        }
    }
}

private extension ConnectorHubPermission {
    var tint: Color {
        switch self {
        case .read: return .blue
        case .write: return .teal
        case .action: return .orange
        }
    }
}

private extension ConnectorHubAction.Priority {
    var tint: Color {
        switch self {
        case .high: return .red
        case .normal: return .orange
        case .low: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .high: return "exclamationmark.triangle.fill"
        case .normal: return "lightbulb.fill"
        case .low: return "info.circle.fill"
        }
    }
}
