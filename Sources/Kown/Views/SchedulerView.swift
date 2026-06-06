import SwiftUI

/// 设置 ▸ 定时任务:管理「每天固定时刻自动发送某段提问」的简易调度任务。
/// 仅在 app 运行(前台 / 被系统短暂保活)期间触发 —— 后台常驻执行受 OS 限制。
struct SchedulerView: View {
    @Bindable var viewModel: AppViewModel
    @Bindable private var scheduler = SchedulerService.shared

    @State private var editing: ScheduledTask?
    @State private var isNew = false
    @State private var confirmDeleteID: UUID?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                infoBanner

                taskListHeader

                if scheduler.tasks.isEmpty {
                    emptyState
                } else {
                    ForEach(scheduler.tasks) { task in
                        row(task)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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

    private var taskListHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                taskCountText
                Spacer(minLength: 12)
                newTaskButton
            }

            VStack(alignment: .leading, spacing: 10) {
                taskCountText
                newTaskButton
            }
        }
    }

    private var taskCountText: some View {
        Text(scheduler.tasks.isEmpty ? "还没有定时任务" : "\(scheduler.tasks.count) 个任务")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var newTaskButton: some View {
        Button {
            editing = ScheduledTask(mode: viewModel.activeMode)
            isNew = true
        } label: {
            Label("新建任务", systemImage: "plus")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .accessibilityLabel("新建定时任务")
    }

    private var infoBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text("定时任务只在 Kown 运行时检查并触发(每分钟检查一次)。app 没打开时错过的任务,会在下次打开当天补跑一次。系统后台常驻执行不受支持。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 62, height: 62)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("没有定时任务")
                .font(.headline.weight(.bold))
            Text("点「新建任务」让某段提问每天固定时刻自动发送。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func row(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            taskHeader(task)

            if !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(task.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(task.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            taskFooter(task)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(task.enabled ? 0.10 : 0.05), lineWidth: 1)
        }
        .opacity(task.enabled ? 1 : 0.6)
    }

    private func taskHeader(_ task: ScheduledTask) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                taskMetadata(task)
                Spacer(minLength: 8)
                taskEnabledToggle(task, labeled: false)
            }

            VStack(alignment: .leading, spacing: 8) {
                taskMetadata(task)
                taskEnabledToggle(task, labeled: true)
                    .fixedSize()
            }
        }
    }

    private func taskMetadata(_ task: ScheduledTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .font(.caption)
                .foregroundStyle(task.enabled ? .blue : .secondary)
            Text(task.timeText)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(modeLabel(task.mode))
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.12), in: Capsule())
                .foregroundStyle(.blue)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func taskEnabledToggle(_ task: ScheduledTask, labeled: Bool) -> some View {
        if labeled {
            Toggle("启用", isOn: taskEnabledBinding(task))
                .font(.caption.weight(.semibold))
                .accessibilityLabel(task.enabled ? "停用定时任务" : "启用定时任务")
        } else {
            Toggle("", isOn: taskEnabledBinding(task))
                .labelsHidden()
                .accessibilityLabel(task.enabled ? "停用定时任务" : "启用定时任务")
        }
    }

    private func taskEnabledBinding(_ task: ScheduledTask) -> Binding<Bool> {
        Binding(
            get: { task.enabled },
            set: { scheduler.setEnabled(task.id, enabled: $0) }
        )
    }

    private func taskFooter(_ task: ScheduledTask) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                lastRunText(task)
                Spacer(minLength: 10)
                editTaskButton(task)
                deleteTaskButton(task)
            }

            HStack(spacing: 8) {
                lastRunText(task)
                Spacer(minLength: 8)
                taskActionsMenu(task)
            }
        }
    }

    private func lastRunText(_ task: ScheduledTask) -> some View {
        Group {
            if let last = task.lastRun {
                Text("上次:\(Self.dateFmt.string(from: last))")
            } else {
                Text("尚未触发")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    private func editTaskButton(_ task: ScheduledTask) -> some View {
        Button {
            beginEditing(task)
        } label: {
            Label("编辑", systemImage: "pencil").font(.caption2.weight(.semibold))
        }
        .buttonStyle(.borderless)
    }

    private func deleteTaskButton(_ task: ScheduledTask) -> some View {
        Button(role: .destructive) {
            confirmDeleteID = task.id
        } label: {
            Label("删除", systemImage: "trash")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
    }

    private func taskActionsMenu(_ task: ScheduledTask) -> some View {
        Menu {
            Button {
                beginEditing(task)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                confirmDeleteID = task.id
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Label("操作", systemImage: "ellipsis.circle")
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.button)
        .controlSize(.small)
        .accessibilityLabel("定时任务操作")
    }

    private func beginEditing(_ task: ScheduledTask) {
        editing = task
        isNew = false
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
    }

    var body: some View {
        #if os(iOS)
        NavigationStack { form }
        #else
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "新建定时任务" : "编辑定时任务")
                    .font(.headline)
                Spacer()
            }
            .padding(16)
            Divider()
            form
            Divider()
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 560, minHeight: 500, idealHeight: 560)
        #endif
    }

    private var form: some View {
        Form {
            Section("基本") {
                TextField("任务名(可选)", text: $task.title)
                Picker("模式", selection: $task.mode) {
                    ForEach(ConversationMode.allCases, id: \.self) { m in
                        Text(modeLabel(m)).tag(m)
                    }
                }
                DatePicker("触发时刻", selection: $time, displayedComponents: .hourAndMinute)
                Toggle("每天重复", isOn: $task.repeatsDaily)
                Toggle("启用", isOn: $task.enabled)
            }
            Section("提问内容") {
                TextField("要自动发送的提问…", text: $task.prompt, axis: .vertical)
                    .lineLimit(4...10)
            }
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
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
        #endif
    }

    private var canSave: Bool {
        !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        var updated = task
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        updated.hour = comps.hour ?? 9
        updated.minute = comps.minute ?? 0
        updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.prompt = updated.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(updated)
    }
}
