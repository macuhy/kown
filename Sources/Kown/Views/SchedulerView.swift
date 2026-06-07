import SwiftUI

/// 设置 ▸ 定时任务:管理「每天固定时刻自动发送某段提问」的简易调度任务。
/// 仅在 app 运行(前台 / 被系统短暂保活)期间触发 —— 后台常驻执行受 OS 限制。
struct SchedulerView: View {
    @Bindable var viewModel: AppViewModel
    @Bindable private var scheduler = SchedulerService.shared

    @State private var editing: ScheduledTask?
    @State private var isNew = false
    @State private var confirmDeleteID: UUID?

    private var schedulerTint: Color { Color(red: 0.20, green: 0.56, blue: 0.78) }
    private var schedulerWarmTint: Color { Color(red: 0.92, green: 0.55, blue: 0.22) }

    private var enabledTasks: [ScheduledTask] {
        scheduler.tasks.filter(\.enabled)
    }

    private var nextTask: ScheduledTask? {
        let now = Date()
        let cal = Calendar.current
        return enabledTasks.min { lhs, rhs in
            (nextFireDate(for: lhs, after: now, calendar: cal) ?? .distantFuture) <
            (nextFireDate(for: rhs, after: now, calendar: cal) ?? .distantFuture)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                heroHeader
                metricsStrip
                taskSectionHeader

                if scheduler.tasks.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 286), spacing: 14, alignment: .top)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(scheduler.tasks) { task in
                            taskCard(task)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $editing) { task in
            SchedulerTaskEditor(
                task: task,
                isNew: isNew,
                onSave: { updated in
                    if isNew {
                        scheduler.add(updated)
                    } else {
                        scheduler.update(updated)
                    }
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
        .confirmationDialog(
            "删除这个定时任务?",
            isPresented: Binding(get: { confirmDeleteID != nil }, set: { if !$0 { confirmDeleteID = nil } })
        ) {
            Button("删除", role: .destructive) {
                if let id = confirmDeleteID { scheduler.remove(id) }
                confirmDeleteID = nil
            }
            Button("取消", role: .cancel) { confirmDeleteID = nil }
        }
    }

    private var heroHeader: some View {
        KownGlassCard(tint: schedulerTint, cornerRadius: 28, intensity: 0.11) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    heroIcon
                    heroCopy
                    Spacer(minLength: 12)
                    heroActions
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 13) {
                        heroIcon
                        heroCopy
                    }
                    heroActions
                }
            }
            .padding(18)
        }
    }

    private var heroIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [schedulerTint, schedulerWarmTint.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                .frame(width: 54, height: 54)
                .offset(x: 16, y: -15)
            Circle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 26, height: 26)
                .offset(x: -20, y: 18)
            Image(systemName: "clock.fill")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 72, height: 72)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: schedulerTint.opacity(0.22), radius: 20, x: 0, y: 12)
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("自动时间线")
                .font(.system(size: 31, weight: .black, design: .rounded))
                .tracking(-0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text("把固定 Prompt 安排成日程:晨报、复盘、提醒和周报,打开 Kown 就会自动补跑错过的任务。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                heroBadge("每分钟巡检", systemImage: "dot.radiowaves.left.and.right", tint: schedulerTint)
                heroBadge("打开后补跑", systemImage: "arrow.triangle.2.circlepath", tint: schedulerWarmTint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                newTaskButton
                limitationPill
            }

            VStack(alignment: .leading, spacing: 9) {
                newTaskButton
                limitationPill
            }
        }
    }

    private func heroBadge(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.black))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.11), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 1)
            }
    }

    private var limitationPill: some View {
        Label("App 运行时触发", systemImage: "exclamationmark.shield.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.platformControlBackground.opacity(0.62), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }

    private var metricsStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                metricCard(title: "任务总数", value: "\(scheduler.tasks.count)", icon: "tray.full.fill", tint: schedulerTint)
                metricCard(title: "正在运行", value: "\(enabledTasks.count)", icon: "bolt.fill", tint: enabledTasks.isEmpty ? .orange : .green)
                metricCard(title: "下次触发", value: nextTriggerText, icon: "calendar.badge.clock", tint: schedulerWarmTint)
            }

            VStack(spacing: 10) {
                metricCard(title: "任务总数", value: "\(scheduler.tasks.count)", icon: "tray.full.fill", tint: schedulerTint)
                metricCard(title: "正在运行", value: "\(enabledTasks.count)", icon: "bolt.fill", tint: enabledTasks.isEmpty ? .orange : .green)
                metricCard(title: "下次触发", value: nextTriggerText, icon: "calendar.badge.clock", tint: schedulerWarmTint)
            }
        }
    }

    private var nextTriggerText: String {
        let now = Date()
        guard let task = nextTask,
              let date = nextFireDate(for: task, after: now, calendar: .current) else {
            return "未安排"
        }
        if date <= now {
            return "待补跑 · \(taskDisplayTitle(task))"
        }
        return "\(compactDateTime(date)) · \(taskDisplayTitle(task))"
    }

    private func metricCard(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.callout.weight(.black))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.56), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var taskSectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("任务编排")
                    .font(.headline.weight(.black))
                Text(scheduler.tasks.isEmpty ? "先创建第一条自动提问。" : "卡片可直接启停,也可以进入编辑微调节奏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(scheduler.tasks.isEmpty ? "空" : "\(scheduler.tasks.count) 条")
                .font(.caption.weight(.black))
                .monospacedDigit()
                .foregroundStyle(schedulerTint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(schedulerTint.opacity(0.11), in: Capsule(style: .continuous))
        }
    }

    private var newTaskButton: some View {
        Button {
            editing = ScheduledTask(mode: viewModel.activeMode)
            isNew = true
        } label: {
            Label("新建任务", systemImage: "plus")
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(
                        colors: [schedulerTint, schedulerWarmTint.opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                }
                .shadow(color: schedulerTint.opacity(0.22), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新建定时任务")
    }

    private var emptyState: some View {
        KownGlassCard(tint: schedulerWarmTint, cornerRadius: 26, intensity: 0.09) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 18) {
                    emptyStateMark
                    emptyStateCopy
                    Spacer(minLength: 12)
                    newTaskButton
                }

                VStack(alignment: .leading, spacing: 14) {
                    emptyStateMark
                    emptyStateCopy
                    newTaskButton
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyStateMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [schedulerWarmTint.opacity(0.22), schedulerTint.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 29, weight: .black))
                .foregroundStyle(schedulerWarmTint)
        }
        .frame(width: 66, height: 66)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(schedulerWarmTint.opacity(0.22), lineWidth: 1)
        }
    }

    private var emptyStateCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有自动提问")
                .font(.title3.weight(.black))
            Text("适合每天早上的信息汇总、每周复盘、定时提醒自己问模型一遍固定问题。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func taskCard(_ task: ScheduledTask) -> some View {
        let tint = task.enabled ? task.mode.kownTint : Color.secondary
        return VStack(alignment: .leading, spacing: 12) {
            taskCardHeader(task, tint: tint)
            taskTitle(task)
            promptPreview(task, tint: tint)
            taskCardFooter(task, tint: tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(task.enabled ? 0.13 : 0.04), Color.platformControlBackground.opacity(0.26), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Capsule(style: .continuous)
                    .fill(tint.opacity(task.enabled ? 0.85 : 0.30))
                    .frame(width: 4)
                    .padding(.vertical, 18)
                    .padding(.leading, 1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(tint.opacity(task.enabled ? 0.18 : 0.08), lineWidth: 1)
        }
        .shadow(color: tint.opacity(task.enabled ? 0.10 : 0.03), radius: 16, x: 0, y: 10)
        .opacity(task.enabled ? 1 : 0.72)
    }

    private func taskCardHeader(_ task: ScheduledTask, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 11) {
            KownModeMark(mode: task.mode, size: 42, selected: task.enabled)

            VStack(alignment: .leading, spacing: 5) {
                Text(task.timeText)
                    .font(.system(size: 29, weight: .black, design: .rounded))
                    .tracking(-0.5)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                scheduleChip(task, tint: tint)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: taskEnabledBinding(task))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(task.enabled ? "停用定时任务" : "启用定时任务")
        }
    }

    private func scheduleChip(_ task: ScheduledTask, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: task.weekday == nil ? "repeat" : "repeat.1")
                .font(.caption2.weight(.black))
            Text(task.weekday.flatMap { ScheduledTask.weekdayName($0) }.map { "每\($0)" } ?? "每天")
                .font(.caption2.weight(.black))
            Text(modeLabel(task.mode))
                .font(.caption2.weight(.black))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.13), in: Capsule(style: .continuous))
        }
        .foregroundStyle(tint)
        .lineLimit(1)
    }

    private func taskTitle(_ task: ScheduledTask) -> some View {
        Text(taskDisplayTitle(task))
            .font(.callout.weight(.black))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func promptPreview(_ task: ScheduledTask, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.caption.weight(.black))
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(promptPreviewText(task))
                .font(.caption)
                .foregroundStyle(promptPreviewIsPlaceholder(task) ? .tertiary : .secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.50), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.10), lineWidth: 1)
        }
    }

    private func taskCardFooter(_ task: ScheduledTask, tint: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                statusPill(task, tint: tint)
                lastRunPill(task)
                Spacer(minLength: 8)
                editIconButton(task, tint: tint)
                deleteIconButton(task)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    statusPill(task, tint: tint)
                    lastRunPill(task)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    editIconButton(task, tint: tint)
                    deleteIconButton(task)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func statusPill(_ task: ScheduledTask, tint: Color) -> some View {
        Label(task.enabled ? "运行中" : "已暂停", systemImage: task.enabled ? "bolt.fill" : "pause.fill")
            .font(.caption2.weight(.black))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(tint.opacity(task.enabled ? 0.12 : 0.08), in: Capsule(style: .continuous))
    }

    private func lastRunPill(_ task: ScheduledTask) -> some View {
        Label {
            Text(task.lastRun.map { "上次 \(compactDateTime($0))" } ?? "尚未触发")
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: task.lastRun == nil ? "sparkle.magnifyingglass" : "checkmark.circle.fill")
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.platformControlBackground.opacity(0.54), in: Capsule(style: .continuous))
    }

    private func editIconButton(_ task: ScheduledTask, tint: Color) -> some View {
        Button {
            beginEditing(task)
        } label: {
            Image(systemName: "pencil")
                .font(.caption.weight(.black))
                .foregroundStyle(tint)
                .frame(width: 29, height: 29)
                .background(tint.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("编辑定时任务")
    }

    private func deleteIconButton(_ task: ScheduledTask) -> some View {
        Button(role: .destructive) {
            confirmDeleteID = task.id
        } label: {
            Image(systemName: "trash")
                .font(.caption.weight(.black))
                .foregroundStyle(.red)
                .frame(width: 29, height: 29)
                .background(Color.red.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("删除定时任务")
    }

    private func taskEnabledBinding(_ task: ScheduledTask) -> Binding<Bool> {
        Binding(
            get: { task.enabled },
            set: { scheduler.setEnabled(task.id, enabled: $0) }
        )
    }

    private func beginEditing(_ task: ScheduledTask) {
        editing = task
        isNew = false
    }

    private func taskDisplayTitle(_ task: ScheduledTask) -> String {
        let trimmed = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return task.isBriefing ? "晨间简报" : "未命名定时提问"
    }

    /// 卡片正文预览:简报任务展示订阅话题(没有则给固定说明),普通任务展示 prompt。
    private func promptPreviewText(_ task: ScheduledTask) -> String {
        if task.isBriefing {
            if !task.briefingTopics.isEmpty {
                return "晨报 · 话题:" + task.briefingTopics.joined(separator: "、")
            }
            return "自动汇总今日日程与长期关注点"
        }
        return task.prompt.isEmpty ? "尚未填写提问内容" : task.prompt
    }

    private func promptPreviewIsPlaceholder(_ task: ScheduledTask) -> Bool {
        !task.isBriefing && task.prompt.isEmpty
    }

    private func compactDateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private func nextFireDate(for task: ScheduledTask, after now: Date, calendar cal: Calendar) -> Date? {
        for offset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            if let weekday = task.weekday, cal.component(.weekday, from: day) != weekday { continue }

            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = task.hour
            comps.minute = task.minute
            comps.second = 0
            guard let fireDate = cal.date(from: comps) else { continue }
            if fireDate <= now {
                if let lastRun = task.lastRun, lastRun >= fireDate { continue }
                return now
            }
            return fireDate
        }
        return nil
    }
}

/// 模式的中文标签(`ConversationMode.displayName` 是英文,这里给 UI 用中文)。
func modeLabel(_ mode: ConversationMode) -> String {
    switch mode {
    case .council: return "议会"
    case .direct:  return "直接"
    case .compare: return "对比"
    case .debate:  return "辩论"
    case .structured: return "结构化"
    case .tournament: return "擂台"
    }
}

/// 新建 / 编辑一条定时任务的表单。
private struct SchedulerTaskEditor: View {
    @State var task: ScheduledTask
    let isNew: Bool
    let onSave: (ScheduledTask) -> Void
    let onCancel: () -> Void

    /// 用 DatePicker 选时刻,保存时拆回 hour/minute。
    @State private var time: Date
    /// 周期:false = 每天;true = 每周。每周时用 `weekday`(1=周日…7=周六)。
    @State private var weekly: Bool
    @State private var weekday: Int
    /// 任务类型(普通提问 / 晨间简报)。
    @State private var kind: ScheduledTask.Kind
    /// 简报订阅话题,编辑时用「每行一个」的文本承载,保存时拆成数组。
    @State private var topicsText: String

    private var schedulerTint: Color { Color(red: 0.20, green: 0.56, blue: 0.78) }
    private var schedulerWarmTint: Color { Color(red: 0.92, green: 0.55, blue: 0.22) }

    init(task: ScheduledTask, isNew: Bool,
         onSave: @escaping (ScheduledTask) -> Void,
         onCancel: @escaping () -> Void) {
        _task = State(initialValue: task)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        var comps = DateComponents()
        comps.hour = task.hour
        comps.minute = task.minute
        _time = State(initialValue: Calendar.current.date(from: comps) ?? Date())
        _weekly = State(initialValue: task.weekday != nil)
        _weekday = State(initialValue: task.weekday ?? 2)   // 默认周一
        _kind = State(initialValue: task.kind)
        _topicsText = State(initialValue: task.briefingTopics.joined(separator: "\n"))
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            editorContent
                .navigationTitle(isNew ? "新建定时任务" : "编辑定时任务")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { onCancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save() }.disabled(!canSave)
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        #else
        VStack(spacing: 0) {
            editorTitleBar
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            editorContent
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            editorFooter
        }
        .frame(minWidth: 520, idealWidth: 590, maxWidth: 660, minHeight: 620, idealHeight: 680)
        .background(editorBackdrop)
        #endif
    }

    private var editorTitleBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isNew ? "calendar.badge.plus" : "calendar.badge.clock")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(schedulerTint)
                .frame(width: 38, height: 38)
                .background(schedulerTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "新建定时任务" : "编辑定时任务")
                    .font(.headline.weight(.black))
                Text("设计触发节奏、模式和要自动发送的提问。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.platformControlBackground.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭定时任务编辑器")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var editorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                editorHero
                editorSection(
                    "任务类型",
                    subtitle: "普通提问按固定 Prompt 发出;晨间简报会即时组装日程、关注点和订阅话题。",
                    icon: "sparkles",
                    tint: schedulerTint
                ) {
                    kindPicker
                }

                editorSection(
                    "任务身份",
                    subtitle: "名字可选,模式决定自动发送后进入哪种对话编排。",
                    icon: "tag.fill",
                    tint: task.mode.kownTint
                ) {
                    titleField
                    modeGrid
                }

                if kind == .morningBriefing {
                    editorSection(
                        "订阅话题",
                        subtitle: "每行一个话题,简报会逐条给最新进展(可联网核实)。可留空,只汇总日程与关注点。",
                        icon: "newspaper.fill",
                        tint: schedulerWarmTint
                    ) {
                        topicsField
                    }
                }

                editorSection(
                    "触发节奏",
                    subtitle: "每天固定时间或每周指定星期触发。",
                    icon: "metronome.fill",
                    tint: schedulerWarmTint
                ) {
                    scheduleControls
                }

                editorSection(
                    kind == .morningBriefing ? "额外指示(可选)" : "提问内容",
                    subtitle: kind == .morningBriefing
                        ? "想让简报额外包含什么、用什么语气,可写在这里;留空也行。"
                        : "保存前会自动去掉首尾空白;为空时不能保存。",
                    icon: "text.quote",
                    tint: schedulerTint
                ) {
                    promptField
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .background(editorBackdrop)
    }

    private var editorHero: some View {
        KownGlassCard(tint: task.mode.kownTint, cornerRadius: 26, intensity: 0.10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    KownModeMark(mode: task.mode, size: 58, selected: task.enabled)
                    editorHeroCopy
                    Spacer(minLength: 12)
                    editorEnabledToggle
                }

                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .center, spacing: 12) {
                        KownModeMark(mode: task.mode, size: 52, selected: task.enabled)
                        editorHeroCopy
                    }
                    editorEnabledToggle
                }
            }
            .padding(16)
        }
    }

    private var editorHeroCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isNew ? "安排一个自动提问" : "打磨自动提问")
                .font(.title3.weight(.black))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(schedulePreview)
                .font(.system(.headline, design: .rounded).weight(.black))
                .monospacedDigit()
                .foregroundStyle(task.mode.kownTint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(task.mode.kownModeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editorEnabledToggle: some View {
        Toggle("启用", isOn: $task.enabled)
            .font(.caption.weight(.black))
            .toggleStyle(.switch)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.platformControlBackground.opacity(0.55), in: Capsule(style: .continuous))
    }

    private var kindPicker: some View {
        Picker("类型", selection: $kind) {
            Text("普通提问").tag(ScheduledTask.Kind.plainPrompt)
            Text("晨间简报").tag(ScheduledTask.Kind.morningBriefing)
        }
        .pickerStyle(.segmented)
    }

    private var topicsField: some View {
        TextField("每行一个话题,例如:\nAI 行业要闻\n我关注的球队", text: $topicsText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.callout)
            .lineLimit(3...8)
            .padding(13)
            .background(inputBackground(tint: schedulerWarmTint))
    }

    private var titleField: some View {
        TextField("例如: 每天晨报 / 周五复盘", text: $task.title)
            .textFieldStyle(.plain)
            .font(.callout.weight(.semibold))
            .padding(13)
            .background(inputBackground(tint: task.mode.kownTint))
    }

    private var modeGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 9)], spacing: 9) {
            ForEach(ConversationMode.allCases, id: \.self) { mode in
                modeChoice(mode)
            }
        }
    }

    private func modeChoice(_ mode: ConversationMode) -> some View {
        let selected = task.mode == mode
        return Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                task.mode = mode
            }
        } label: {
            HStack(spacing: 8) {
                KownModeMark(mode: mode, size: 32, selected: selected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(modeLabel(mode))
                        .font(.caption.weight(.black))
                        .foregroundStyle(selected ? .white : .primary)
                    Text(mode.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(selected ? Color.white.opacity(0.82) : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? mode.kownTint : Color.platformControlBackground.opacity(0.58))
                if selected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [mode.kownTint, mode.kownSecondaryTint.opacity(0.82)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder((selected ? Color.white : mode.kownTint).opacity(selected ? 0.24 : 0.14), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择\(modeLabel(mode))模式")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var scheduleControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            controlCard(title: "触发时刻", subtitle: "到点后会新建会话并发送", icon: "clock.fill", tint: schedulerWarmTint) {
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }

            VStack(alignment: .leading, spacing: 9) {
                Picker("周期", selection: $weekly) {
                    Text("每天").tag(false)
                    Text("每周").tag(true)
                }
                .pickerStyle(.segmented)

                if weekly {
                    weekdayPicker
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(12)
            .background(inputBackground(tint: schedulerWarmTint))

            controlCard(title: "任务状态", subtitle: task.enabled ? "保存后立即纳入巡检" : "暂停后不会自动触发", icon: task.enabled ? "bolt.fill" : "pause.fill", tint: task.enabled ? .green : .orange) {
                Toggle("", isOn: $task.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var weekdayPicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 45), spacing: 7)], spacing: 7) {
            ForEach(1...7, id: \.self) { wd in
                weekdayButton(wd)
            }
        }
    }

    private func weekdayButton(_ wd: Int) -> some View {
        let selected = weekday == wd
        let label = ScheduledTask.weekdayName(wd) ?? "周?"
        return Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                weekday = wd
            }
        } label: {
            Text(label)
                .font(.caption.weight(.black))
                .foregroundStyle(selected ? .white : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    selected
                    ? LinearGradient(colors: [schedulerWarmTint, schedulerTint.opacity(0.88)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Color.platformControlBackground.opacity(0.70), Color.platformControlBackground.opacity(0.46)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder((selected ? Color.white : schedulerWarmTint).opacity(selected ? 0.25 : 0.13), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("要自动发送的提问…", text: $task.prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(6...12)
                .padding(13)
                .background(inputBackground(tint: schedulerTint))

            HStack(spacing: 6) {
                Image(systemName: canSave ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(canSave ? .green : .orange)
                Text(canSave ? "内容已准备好" : "请输入要自动发送的提问")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var editorFooter: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("取消") { onCancel() }
                .buttonStyle(.bordered)
            Button {
                save()
            } label: {
                Label("保存任务", systemImage: "checkmark")
                    .font(.callout.weight(.black))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private func editorSection<Content: View>(
        _ title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.black))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(tint.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.06), radius: 14, x: 0, y: 8)
    }

    private func controlCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.black))
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(12)
        .background(inputBackground(tint: tint))
    }

    private func inputBackground(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.platformControlBackground.opacity(0.58))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(0.12), lineWidth: 1)
            }
    }

    private var editorBackdrop: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [task.mode.kownTint.opacity(0.16), Color.clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 440
            )
            RadialGradient(
                colors: [schedulerWarmTint.opacity(0.13), Color.clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    private var schedulePreview: String {
        let timeText = time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if weekly {
            return "每\(ScheduledTask.weekdayName(weekday) ?? "周一") \(timeText)"
        }
        return "每天 \(timeText)"
    }

    private var canSave: Bool {
        // 简报任务不要求填 prompt(内容由日程/关注点/话题即时组装)。
        if kind == .morningBriefing { return true }
        return !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        var updated = task
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        updated.hour = comps.hour ?? 9
        updated.minute = comps.minute ?? 0
        updated.weekday = weekly ? weekday : nil
        updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.prompt = updated.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.kind = kind
        updated.briefingTopics = topicsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        onSave(updated)
    }
}
