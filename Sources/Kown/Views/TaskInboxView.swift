import SwiftUI

/// 设置 ▸ AI 待办:把散在 Agent、定时任务和长期记忆里的可处理事项聚合到一个入口。
struct TaskInboxView: View {
    private var agentRuns = AgentRunStore.shared
    @Bindable private var scheduler = SchedulerService.shared
    private var memoryStore = MemoryStore.shared

    @State private var dedupRunning = false
    @State private var dedupMessage: String?

    private let tint = Color(red: 0.18, green: 0.52, blue: 0.84)
    private let warmTint = Color(red: 0.92, green: 0.54, blue: 0.20)

    private var approvalRuns: [AgentRun] {
        agentRuns.runs.filter(\.needsApproval)
    }

    private var activeRuns: [AgentRun] {
        agentRuns.runs.filter { $0.status.isActive && !$0.needsApproval }
    }

    private var failedRuns: [AgentRun] {
        agentRuns.runs.filter { $0.status == .failed }
    }

    private var failedTasks: [ScheduledTask] {
        scheduler.tasks.filter { $0.lastRunStatus == .failure }
    }

    private var runningTasks: [ScheduledTask] {
        scheduler.tasks.filter { $0.lastRunStatus == .running }
    }

    private var memorySourceGapCount: Int {
        memoryStore.items.filter { $0.sourceConversationID == nil }.count
    }

    private var memoryOverflowRisk: Bool {
        memoryStore.items.count >= Int(Double(MemoryStore.maxItems) * 0.85)
    }

    private var duplicateMemoryCount: Int {
        MemoryStore.dedupPlan(items: memoryStore.items).removeIDs.count
    }

    private var inboxCount: Int {
        approvalRuns.count + activeRuns.count + failedRuns.count + failedTasks.count + runningTasks.count
        + (memorySourceGapCount > 0 ? 1 : 0)
        + (duplicateMemoryCount > 0 ? 1 : 0)
        + (memoryOverflowRisk ? 1 : 0)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                metrics
                approvalSection
                activeSection
                failureSection
                schedulerSection
                memorySection
                if inboxCount == 0 {
                    emptyState
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI 待办收件箱")
                        .font(.title2.weight(.black))
                    Text("集中处理审批、失败、运行中任务和记忆健康提醒。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    agentRuns.reload()
                    scheduler.reload()
                    memoryStore.reload()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                metric("待处理", value: inboxCount, icon: "tray.full.fill", color: tint)
                metric("待审批", value: approvalRuns.count, icon: "hand.raised.fill", color: .orange)
                metric("失败", value: failedRuns.count + failedTasks.count, icon: "exclamationmark.triangle.fill", color: .red)
                metric("运行中", value: activeRuns.count + runningTasks.count, icon: "arrow.triangle.2.circlepath", color: .blue)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                metric("待处理", value: inboxCount, icon: "tray.full.fill", color: tint)
                metric("待审批", value: approvalRuns.count, icon: "hand.raised.fill", color: .orange)
                metric("失败", value: failedRuns.count + failedTasks.count, icon: "exclamationmark.triangle.fill", color: .red)
                metric("运行中", value: activeRuns.count + runningTasks.count, icon: "arrow.triangle.2.circlepath", color: .blue)
            }
        }
    }

    private func metric(_ title: String, value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.headline.weight(.black))
                    .monospacedDigit()
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.56), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var approvalSection: some View {
        if !approvalRuns.isEmpty {
            section(title: "待审批", icon: "hand.raised.fill", tint: .orange) {
                ForEach(approvalRuns) { run in
                    runCard(run, tone: .orange) {
                        Button("批准") { agentRuns.approve(run.id) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("拒绝", role: .destructive) { agentRuns.reject(run.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var activeSection: some View {
        if !activeRuns.isEmpty {
            section(title: "运行中 / 已暂停", icon: "arrow.triangle.2.circlepath", tint: .blue) {
                ForEach(activeRuns) { run in
                    runCard(run, tone: .blue) {
                        if run.canPause {
                            Button("暂停") { agentRuns.pause(run.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        if run.canResume {
                            Button("继续") { agentRuns.resume(run.id) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        if run.canCancel {
                            Button("取消", role: .destructive) { agentRuns.cancel(run.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var failureSection: some View {
        if !failedRuns.isEmpty {
            section(title: "失败的 Agent 运行", icon: "exclamationmark.triangle.fill", tint: .red) {
                ForEach(failedRuns) { run in
                    runCard(run, tone: .red) {
                        Button("删除记录", role: .destructive) { agentRuns.remove(run.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var schedulerSection: some View {
        if !failedTasks.isEmpty || !runningTasks.isEmpty {
            section(title: "定时任务状态", icon: "calendar.badge.clock", tint: warmTint) {
                ForEach(failedTasks) { task in
                    taskCard(task, tone: .red) {
                        Button("停用") { scheduler.setEnabled(task.id, enabled: false) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("立即检查") { scheduler.checkAndFire() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                ForEach(runningTasks) { task in
                    taskCard(task, tone: .blue) {
                        Button("立即检查") { scheduler.checkAndFire() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var memorySection: some View {
        let shouldShow = memorySourceGapCount > 0 || duplicateMemoryCount > 0 || memoryOverflowRisk
        if shouldShow {
            section(title: "记忆健康提醒", icon: "brain.head.profile", tint: .purple) {
                if duplicateMemoryCount > 0 {
                    inboxCard(
                        title: "发现 \(duplicateMemoryCount) 条近重复记忆",
                        subtitle: "可以合并重复偏好和事实,减少上下文注入噪音。",
                        icon: "square.on.square",
                        tone: .purple
                    ) {
                        Button(dedupRunning ? "去重中…" : "一键去重") {
                            runMemoryDedup()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(dedupRunning)
                    }
                }
                if memorySourceGapCount > 0 {
                    inboxCard(
                        title: "\(memorySourceGapCount) 条记忆缺少来源",
                        subtitle: "手动添加或旧版本迁移的记忆无法回溯到会话,建议定期审计。",
                        icon: "link.badge.plus",
                        tone: .orange
                    )
                }
                if memoryOverflowRisk {
                    inboxCard(
                        title: "长期记忆接近容量上限",
                        subtitle: "\(memoryStore.items.count) / \(MemoryStore.maxItems) 条。置顶会保留,未置顶旧记忆会先淘汰。",
                        icon: "externaldrive.badge.exclamationmark",
                        tone: .red
                    )
                }
                if let dedupMessage {
                    Label(dedupMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.green)
            Text("暂时没有需要处理的事项")
                .font(.headline)
            Text("审批、失败任务和记忆健康提醒会出现在这里。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func section<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
            content()
        }
    }

    private func runCard<Trailing: View>(
        _ run: AgentRun,
        tone: Color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        inboxCard(
            title: run.title.isEmpty ? run.kind.displayName : run.title,
            subtitle: runSubtitle(run),
            icon: run.kind.symbolName,
            tone: tone,
            trailing: trailing
        )
    }

    private func taskCard<Trailing: View>(
        _ task: ScheduledTask,
        tone: Color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        inboxCard(
            title: task.title.isEmpty ? taskKindTitle(task.kind) : task.title,
            subtitle: "\(task.scheduleText) · \(task.lastRunSummary ?? "暂无摘要")",
            icon: "calendar.badge.clock",
            tone: tone,
            trailing: trailing
        )
    }

    private func inboxCard<Trailing: View>(
        title: String,
        subtitle: String,
        icon: String,
        tone: Color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(tone)
                .frame(width: 34, height: 34)
                .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                trailing()
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func inboxCard(
        title: String,
        subtitle: String,
        icon: String,
        tone: Color
    ) -> some View {
        inboxCard(title: title, subtitle: subtitle, icon: icon, tone: tone) {
            EmptyView()
        }
    }

    private func runSubtitle(_ run: AgentRun) -> String {
        let detail = run.errorMessage ?? run.summary ?? run.prompt
        let base = "\(run.kind.displayName) · \(run.status.displayName) · \(relativeDate(run.updatedAt))"
        guard !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        return base + "\n" + detail
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func taskKindTitle(_ kind: ScheduledTask.Kind) -> String {
        switch kind {
        case .plainPrompt: return "定时提问"
        case .morningBriefing: return "晨间简报"
        case .agentTask: return "Agent 任务"
        }
    }

    private func runMemoryDedup() {
        dedupRunning = true
        dedupMessage = nil
        Task {
            let removed = await memoryStore.deduplicate()
            dedupMessage = removed == 0 ? "没有可合并的重复记忆" : "已合并 \(removed) 条重复记忆"
            dedupRunning = false
        }
    }
}
