import SwiftUI

/// Standalone MVP screen for monitoring and controlling agent runs.
struct AgentRunCenterView: View {
    let store: AgentRunStore
    var onPause: (@MainActor (AgentRun) -> Void)?
    var onCancel: (@MainActor (AgentRun) -> Void)?
    var onRerun: (@MainActor (AgentRun) -> Void)?
    var onApprove: (@MainActor (AgentRun) -> Void)?
    var onReject: (@MainActor (AgentRun) -> Void)?

    @State private var selectedRunID: UUID?
    @State private var statusFilter: AgentRun.Status?

    init(
        store: AgentRunStore = .shared,
        onPause: (@MainActor (AgentRun) -> Void)? = nil,
        onCancel: (@MainActor (AgentRun) -> Void)? = nil,
        onRerun: (@MainActor (AgentRun) -> Void)? = nil,
        onApprove: (@MainActor (AgentRun) -> Void)? = nil,
        onReject: (@MainActor (AgentRun) -> Void)? = nil
    ) {
        self.store = store
        self.onPause = onPause
        self.onCancel = onCancel
        self.onRerun = onRerun
        self.onApprove = onApprove
        self.onReject = onReject
    }

    private let tint = Color(red: 0.10, green: 0.45, blue: 0.72)

    private var filteredRuns: [AgentRun] {
        guard let statusFilter else { return store.runs }
        return store.runs.filter { $0.status == statusFilter }
    }

    private var selectedRun: AgentRun? {
        if let selectedRunID, let run = store.run(id: selectedRunID) { return run }
        return filteredRuns.first
    }

    var body: some View {
        NavigationSplitView {
            runList
                .navigationTitle("Agent 运行中心")
        } detail: {
            if let selectedRun {
                AgentRunDetailView(
                    run: selectedRun,
                    tint: tint,
                    onPause: { handlePause(selectedRun) },
                    onCancel: { handleCancel(selectedRun) },
                    onRerun: { handleRerun(selectedRun) },
                    onApprove: { handleApprove(selectedRun) },
                    onReject: { handleReject(selectedRun) }
                )
            } else {
                emptyState
            }
        }
        #if os(macOS)
        .frame(minWidth: 880, minHeight: 560)
        #endif
        .onAppear {
            if selectedRunID == nil {
                selectedRunID = filteredRuns.first?.id
            }
        }
        .onChange(of: filteredRuns.map(\.id)) { _, ids in
            guard let selectedRunID, ids.contains(selectedRunID) else {
                self.selectedRunID = ids.first
                return
            }
        }
    }

    private var runList: some View {
        VStack(spacing: 0) {
            filterBar
            attentionStrip
            Divider()
            List(selection: $selectedRunID) {
                if filteredRuns.isEmpty {
                    Text("暂无运行记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 18)
                } else {
                    ForEach(filteredRuns) { run in
                        AgentRunRow(run: run, tint: color(for: run.status))
                            .tag(run.id)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var attentionStrip: some View {
        let cards = store.attentionNotifications()
        if !cards.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(cards) { card in
                        AgentRunAttentionCard(
                            card: card,
                            onSelect: { selectedRunID = card.runID },
                            onApprove: {
                                if let run = store.run(id: card.runID) { handleApprove(run) }
                            },
                            onReject: {
                                if let run = store.run(id: card.runID) { handleReject(run) }
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "全部", status: nil, count: store.runs.count)
                ForEach(AgentRun.Status.allCases, id: \.self) { status in
                    let count = store.runs.filter { $0.status == status }.count
                    if count > 0 {
                        filterChip(title: status.displayName, status: status, count: count)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func filterChip(title: String, status: AgentRun.Status?, count: Int) -> some View {
        Button {
            statusFilter = status
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.20), in: Capsule())
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(filterColor(for: status).opacity(statusFilter == status ? 0.18 : 0.08), in: Capsule())
            .foregroundStyle(statusFilter == status ? filterColor(for: status) : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(tint.opacity(0.75))
            Text("还没有 Agent 运行")
                .font(.title3.weight(.bold))
            Text("长任务、深度研究、定时任务、工具调用和会议任务都可以写入同一套 AgentRun 记录。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(30)
    }

    private func handlePause(_ run: AgentRun) {
        if let onPause {
            onPause(run)
        } else if run.canResume {
            store.resume(run.id)
        } else {
            store.pause(run.id)
        }
    }

    private func handleCancel(_ run: AgentRun) {
        if let onCancel {
            onCancel(run)
        } else {
            store.cancel(run.id)
        }
    }

    private func handleRerun(_ run: AgentRun) {
        if let onRerun {
            onRerun(run)
        } else if let rerun = store.rerun(run.id) {
            selectedRunID = rerun.id
        }
    }

    private func handleApprove(_ run: AgentRun) {
        if let onApprove {
            onApprove(run)
        } else {
            store.approve(run.id)
        }
    }

    private func handleReject(_ run: AgentRun) {
        if let onReject {
            onReject(run)
        } else {
            store.reject(run.id)
        }
    }

    private func filterColor(for status: AgentRun.Status?) -> Color {
        status.map(color(for:)) ?? tint
    }
}

private struct AgentRunRow: View {
    let run: AgentRun
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.12))
                Image(systemName: run.kind.symbolName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(run.title.isEmpty ? run.kind.displayName : run.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    StatusPill(status: run.status)
                }
                Text(rowSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Label(run.kind.displayName, systemImage: run.kind.symbolName)
                    if let duration = run.durationSeconds {
                        Label(formatDuration(duration), systemImage: "timer")
                    }
                    if !run.cost.isEmpty {
                        Label(costLabel(run.cost), systemImage: "dollarsign.circle")
                    }
                    if run.approvalStatus != .notRequired {
                        Label(run.approvalStatus.displayName, systemImage: "hand.raised")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }

    private var rowSubtitle: String {
        if let summary = run.summary, !summary.isEmpty { return summary }
        if let error = run.errorMessage, !error.isEmpty { return error }
        if !run.prompt.isEmpty { return run.prompt }
        if let latest = run.steps.last { return latest.title }
        return "更新于 \(formatRelative(run.updatedAt))"
    }
}

private struct AgentRunAttentionCard: View {
    let card: AgentRunNotification
    let onSelect: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(card.title)
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            Text(card.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if card.level == .approval {
                HStack(spacing: 6) {
                    Button("批准", action: onApprove)
                        .buttonStyle(.borderless)
                    Button("拒绝", role: .destructive, action: onReject)
                        .buttonStyle(.borderless)
                }
                .font(.caption2.weight(.semibold))
            } else if let actionTitle = card.actionTitle {
                Text(actionTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 210, alignment: .leading)
        .padding(11)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onSelect)
    }

    private var color: Color {
        switch card.level {
        case .approval: return .orange
        case .running: return .blue
        case .success: return .green
        case .failure: return .red
        }
    }

    private var icon: String {
        switch card.level {
        case .approval: return "hand.raised.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }
}

private struct AgentRunDetailView: View {
    let run: AgentRun
    let tint: Color
    let onPause: () -> Void
    let onCancel: () -> Void
    let onRerun: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                metricsGrid
                resultActions
                if !run.prompt.isEmpty { textSection("任务输入", text: run.prompt) }
                if let summary = run.summary, !summary.isEmpty { textSection("结果摘要", text: summary) }
                if let error = run.errorMessage, !error.isEmpty { textSection("错误信息", text: error, color: .red) }
                stepsSection
                toolCallsSection
                metadataSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(run.title.isEmpty ? run.kind.displayName : run.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if run.needsApproval {
                    Button("批准") { onApprove() }
                    Button("拒绝", role: .destructive) { onReject() }
                }
                Button(run.canResume ? "继续" : "暂停") { onPause() }
                    .disabled(!run.canPause && !run.canResume)
                Button("取消", role: .destructive) { onCancel() }
                    .disabled(!run.canCancel)
                Button("重跑") { onRerun() }
                    .disabled(!run.canRerun)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: run.kind.symbolName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(run.title.isEmpty ? run.kind.displayName : run.title)
                            .font(.title2.weight(.bold))
                        StatusPill(status: run.status)
                    }
                    Text("\(run.kind.displayName) · 创建于 \(formatDate(run.createdAt))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                if run.needsApproval {
                    actionButton(title: "批准", systemImage: "hand.thumbsup.fill", roleColor: .green, action: onApprove)
                    actionButton(title: "拒绝", systemImage: "hand.thumbsdown.fill", roleColor: .red, action: onReject)
                }
                actionButton(title: run.canResume ? "继续" : "暂停", systemImage: run.canResume ? "play.fill" : "pause.fill", action: onPause)
                    .disabled(!run.canPause && !run.canResume)
                actionButton(title: "取消", systemImage: "xmark", roleColor: .red, action: onCancel)
                    .disabled(!run.canCancel)
                actionButton(title: "重跑", systemImage: "arrow.clockwise", action: onRerun)
                    .disabled(!run.canRerun)
            }
        }
        .padding(16)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var resultActions: some View {
        let text = deliverableText
        if !text.isEmpty {
            HStack(spacing: 10) {
                Button {
                    Platform.copyText(text)
                    withAnimation { copied = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "已复制结果" : "复制结果", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.borderless)
                DeliverableStudioSheetButton(
                    title: "\(run.title.isEmpty ? run.kind.displayName : run.title) 交付物",
                    sourceKind: deliverableSourceKind,
                    sourceText: text,
                    targetKind: run.kind == .deepResearch ? .webpage : .markdown,
                    goal: "整理 Agent 运行输入、过程和结果,便于复盘或分享",
                    label: "转交付/发布",
                    systemImage: "shippingbox.and.arrow.backward",
                    tint: tint
                )
                Spacer()
            }
            .sectionCard()
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            metric("审批", value: run.approvalStatus.displayName, icon: "hand.raised")
            metric("步骤", value: "\(run.completedStepCount)/\(run.steps.count)", icon: "checklist")
            metric("工具", value: "\(run.toolCalls.count)", icon: "wrench.and.screwdriver")
            metric("耗时", value: run.durationSeconds.map(formatDuration) ?? "未开始", icon: "timer")
            metric("Token", value: "\(run.cost.totalTokens)", icon: "number")
            metric("费用", value: costLabel(run.cost), icon: "dollarsign.circle")
        }
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(Color.platformControlBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func textSection(_ title: String, text: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sectionCard()
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("运行步骤").font(.headline)
            if run.steps.isEmpty {
                placeholder("暂无步骤")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(run.steps) { step in
                        stepRow(step)
                    }
                }
            }
        }
        .sectionCard()
    }

    private func stepRow(_ step: AgentRun.Step) -> some View {
        HStack(alignment: .top, spacing: 10) {
            stepIcon(step.status)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(step.title).font(.callout.weight(.semibold))
                    StepStatusPill(status: step.status)
                    if step.approvalStatus != .notRequired {
                        Text(step.approvalStatus.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                if !step.detail.isEmpty {
                    Text(step.detail).font(.caption).foregroundStyle(.secondary)
                }
                if let result = step.resultSummary, !result.isEmpty {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
                if let error = step.errorMessage, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
            if let duration = step.durationSeconds {
                Text(formatDuration(duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var toolCallsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("工具调用").font(.headline)
            if run.toolCalls.isEmpty {
                placeholder("暂无工具调用")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(run.toolCalls) { call in
                        toolCallRow(call)
                    }
                }
            }
        }
        .sectionCard()
    }

    private func toolCallRow(_ call: AgentRun.ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(call.displayName).font(.callout.weight(.semibold))
                StepStatusPill(status: call.status)
                Spacer(minLength: 0)
                if !call.cost.isEmpty {
                    Text(costLabel(call.cost))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !call.argumentsSummary.isEmpty {
                Text(call.argumentsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let result = call.resultSummary, !result.isEmpty {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
            if let error = call.errorMessage, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var metadataSection: some View {
        let rows = metadataRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("关联信息").font(.headline)
                ForEach(rows, id: \.0) { key, value in
                    HStack(alignment: .top) {
                        Text(key).font(.caption).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                        Text(value).font(.caption).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
            .sectionCard()
        }
    }

    private var metadataRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let sourceID = run.sourceID { rows.append(("sourceID", sourceID)) }
        if let retryOf = run.retryOf { rows.append(("retryOf", retryOf.uuidString)) }
        rows.append(contentsOf: run.metadata.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        return rows
    }

    private var deliverableSourceKind: DeliverableSourceKind {
        switch run.kind {
        case .deepResearch: return .research
        case .meetingTask: return .meeting
        default: return .custom
        }
    }

    private var deliverableText: String {
        var lines: [String] = [
            "# \(run.title.isEmpty ? run.kind.displayName : run.title)",
            "",
            "## 状态",
            "- 类型：\(run.kind.displayName)",
            "- 状态：\(run.status.displayName)",
            "- 审批：\(run.approvalStatus.displayName)",
            "- 创建：\(formatDate(run.createdAt))"
        ]
        if !run.prompt.isEmpty {
            lines.append(contentsOf: ["", "## 任务输入", run.prompt])
        }
        if let summary = run.summary, !summary.isEmpty {
            lines.append(contentsOf: ["", "## 结果摘要", summary])
        }
        if let error = run.errorMessage, !error.isEmpty {
            lines.append(contentsOf: ["", "## 错误信息", error])
        }
        if !run.steps.isEmpty {
            lines.append(contentsOf: ["", "## 运行步骤"])
            lines.append(contentsOf: run.steps.map { step in
                var text = "- [\(step.status.displayName)] \(step.title)"
                if !step.detail.isEmpty { text += " — \(step.detail)" }
                if let result = step.resultSummary, !result.isEmpty { text += " · \(result)" }
                if let error = step.errorMessage, !error.isEmpty { text += " · \(error)" }
                return text
            })
        }
        if !run.toolCalls.isEmpty {
            lines.append(contentsOf: ["", "## 工具调用"])
            lines.append(contentsOf: run.toolCalls.map { call in
                var text = "- [\(call.status.displayName)] \(call.displayName)"
                if !call.argumentsSummary.isEmpty { text += " — \(call.argumentsSummary)" }
                if let result = call.resultSummary, !result.isEmpty { text += " · \(result)" }
                if let error = call.errorMessage, !error.isEmpty { text += " · \(error)" }
                return text
            })
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body == "# \(run.title.isEmpty ? run.kind.displayName : run.title)\n\n## 状态" ? "" : body
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func actionButton(title: String, systemImage: String, roleColor: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(roleColor ?? tint)
        .background((roleColor ?? tint).opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func stepIcon(_ status: AgentRun.StepStatus) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .waitingForApproval:
            Image(systemName: "hand.raised.circle.fill").foregroundStyle(.orange)
        case .queued:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .skipped:
            Image(systemName: "forward.circle.fill").foregroundStyle(.secondary)
        }
    }
}

private struct StatusPill: View {
    let status: AgentRun.Status

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color(for: status))
            .background(color(for: status).opacity(0.13), in: Capsule())
    }
}

private struct StepStatusPill: View {
    let status: AgentRun.StepStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color(for: status))
            .background(color(for: status).opacity(0.12), in: Capsule())
    }
}

private extension View {
    func sectionCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.platformControlBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private func color(for status: AgentRun.Status) -> Color {
    switch status {
    case .queued: return .secondary
    case .running: return .blue
    case .waitingForApproval: return .orange
    case .paused: return .yellow
    case .succeeded: return .green
    case .failed: return .red
    case .cancelled: return .secondary
    }
}

private func color(for status: AgentRun.StepStatus) -> Color {
    switch status {
    case .queued: return .secondary
    case .running: return .blue
    case .waitingForApproval: return .orange
    case .done: return .green
    case .error: return .red
    case .cancelled, .skipped: return .secondary
    }
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(secs)s" }
    return "\(secs)s"
}

private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func formatRelative(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func costLabel(_ cost: AgentRun.Cost) -> String {
    guard cost.estimatedUSD > 0 else { return "\(cost.totalTokens) tok" }
    return String(format: "$%.4f", cost.estimatedUSD)
}
