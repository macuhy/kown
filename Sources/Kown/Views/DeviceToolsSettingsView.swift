import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 设备工具设置(设置 ▸ 设备工具)。让模型能在系统「提醒事项 / 备忘录」里创建条目。
/// 提供总开关、提醒事项权限申请与状态、平台说明。macOS / iOS 通用。
struct DeviceToolsSettingsView: View {
    @Bindable var viewModel: AppViewModel

    private static let tint = Color(red: 0.20, green: 0.60, blue: 0.62)

    @State private var reminderAuthorized: Bool = false
    @State private var calendarAuthorized: Bool = false
    @State private var requesting = false
    @State private var requestingCalendar = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                LazyVGrid(columns: toolColumns, alignment: .leading, spacing: 12) {
                    remindersCard
                    calendarCard
                    notesCard
                    #if os(macOS)
                    localFilesCard
                    #endif
                    codeExecCard
                }
                usageCard
            }
            #if os(iOS)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            #else
            .padding(20)
            #endif
            .frame(maxWidth: 760, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .onAppear { refreshAuth() }
    }

    private var toolColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)]
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    heroTitle
                    Spacer(minLength: 16)
                    deviceToolsSwitch
                }
                VStack(alignment: .leading, spacing: 12) {
                    heroTitle
                    deviceToolsSwitch
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    statusChip(
                        title: viewModel.deviceToolsEnabledForNextSend ? "发送时可用" : "发送时关闭",
                        icon: viewModel.deviceToolsEnabledForNextSend ? "checkmark.seal.fill" : "power",
                        color: viewModel.deviceToolsEnabledForNextSend ? Self.tint : .secondary
                    )
                    statusChip(
                        title: reminderAuthorized ? "提醒已授权" : "提醒待授权",
                        icon: reminderAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                        color: reminderAuthorized ? .green : .orange
                    )
                    statusChip(
                        title: calendarAuthorized ? "日历已授权" : "日历待授权",
                        icon: calendarAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                        color: calendarAuthorized ? .green : .orange
                    )
                    #if os(macOS)
                    statusChip(title: "备忘录自动化", icon: "note.text", color: .teal)
                    #else
                    statusChip(title: "备忘录需粘贴", icon: "doc.on.clipboard", color: .teal)
                    #endif
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Self.tint.opacity(0.14), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Self.tint.opacity(0.18), lineWidth: 1)
        }
    }

    private var heroTitle: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Self.tint.opacity(0.15))
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Self.tint)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text("本次发送可用的设备能力")
                    .font(.headline.weight(.bold))
                Text("和输入栏的设备工具按钮同步;开启后模型可在需要时创建提醒、日程或备忘录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var deviceToolsSwitch: some View {
        Toggle(isOn: $viewModel.deviceToolsEnabledForNextSend) {
            Text(viewModel.deviceToolsEnabledForNextSend ? "已启用" : "未启用")
                .font(.caption.weight(.bold))
                .foregroundStyle(viewModel.deviceToolsEnabledForNextSend ? Self.tint : .secondary)
        }
        .toggleStyle(.switch)
        .tint(Self.tint)
        .fixedSize()
        .accessibilityLabel(viewModel.deviceToolsEnabledForNextSend ? "关闭设备工具" : "启用设备工具")
    }

    private var remindersCard: some View {
        card(icon: "checklist", title: "提醒事项") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    reminderAuthPill
                    Spacer(minLength: 12)
                    reminderAuthButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    reminderAuthPill
                    reminderAuthButton
                }
            }
            Text("模型创建提醒时会按当前时间换算「明天 / 下周一」等相对时间,并挂一个到点闹钟。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var calendarCard: some View {
        card(icon: "calendar", title: "日历") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    calendarAuthPill
                    Spacer(minLength: 12)
                    calendarAuthButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    calendarAuthPill
                    calendarAuthButton
                }
            }
            Text("模型添加日程时会按当前时间换算「明天下午 3 点」等相对时间;没给结束时间则默认 1 小时。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notesCard: some View {
        card(icon: "note.text", title: "备忘录") {
            #if os(macOS)
            statusChip(title: "首次写入时弹系统授权", icon: "lock.shield", color: .teal)
            #else
            statusChip(title: "复制到剪贴板后打开备忘录", icon: "doc.on.clipboard", color: .teal)
            #endif
            #if os(macOS)
            Text("macOS 通过自动化直接写入「备忘录」。首次写入时系统会弹出授权框,请在「系统设置 ▸ 隐私 ▸ 自动化」里允许 Kown 控制备忘录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("iOS 没有公开的备忘录写入接口:创建备忘时会把内容复制到剪贴板并打开「备忘录」App,你粘贴保存即可。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }

    #if os(macOS)
    @Bindable private var fileToolState = LocalFileToolState.shared

    private var localFilesCard: some View {
        card(icon: "folder", title: "本地文件(macOS)") {
            if let path = fileToolState.displayPath {
                statusChip(title: "已授权目录", icon: "checkmark.circle.fill", color: .green)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                statusChip(title: "未授权目录", icon: "exclamationmark.circle.fill", color: .orange)
            }
            Text("授权一个文件夹后,模型可读取 / 列出其中的文本文件;写文件会先暂存,你在输入栏上方看 diff 点「应用」才落盘。仅限该目录内,自动挡掉越权路径。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    pickLocalFolder()
                } label: {
                    Label(fileToolState.isAuthorized ? "重选目录" : "选择目录", systemImage: "folder.badge.plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                if fileToolState.isAuthorized {
                    Button(role: .destructive) {
                        fileToolState.clearAuthorization()
                    } label: {
                        Label("移除", systemImage: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func pickLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "授权"
        panel.message = "选择一个文件夹,允许 Kown 的模型在其中读写文本文件"
        if panel.runModal() == .OK, let url = panel.url {
            fileToolState.setAuthorized(url: url)
        }
    }
    #endif

    // MARK: - 代码执行

    @Bindable private var codeExecState = CodeExecToolState.shared

    private var codeExecCard: some View {
        card(icon: "terminal", title: "代码执行") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    codeExecStatusPill
                    Spacer(minLength: 12)
                    codeExecToggle
                }
                VStack(alignment: .leading, spacing: 8) {
                    codeExecStatusPill
                    codeExecToggle
                }
            }
            #if os(macOS)
            Text("开启后模型可调用 run_code 真正运行 Python(python3)/ JavaScript(node)做数据分析、算账等;需本机已安装对应运行时。每次在独立临时目录执行,30 秒超时强制终止,输出各截断 20KB。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("开启后模型可调用 run_code 用系统内置 JavaScriptCore 运行 JavaScript 做计算、数据处理(仅 JS,无网络与文件访问)。30 秒超时自动中断,输出截断 20KB。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
            Label("这不是隔离沙盒:代码以你的用户权限在本机运行,仅在信任的对话里开启。", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var codeExecStatusPill: some View {
        statusChip(
            title: codeExecState.isEnabled ? "已开启" : "默认关闭",
            icon: codeExecState.isEnabled ? "exclamationmark.shield.fill" : "checkmark.shield",
            color: codeExecState.isEnabled ? .orange : .secondary
        )
    }

    private var codeExecToggle: some View {
        Toggle(isOn: $codeExecState.isEnabled) {
            Text(codeExecState.isEnabled ? "已启用" : "未启用")
                .font(.caption.weight(.bold))
                .foregroundStyle(codeExecState.isEnabled ? .orange : .secondary)
        }
        .toggleStyle(.switch)
        .tint(.orange)
        .fixedSize()
        .accessibilityLabel(codeExecState.isEnabled ? "关闭代码执行" : "启用代码执行")
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("发送时怎么用", systemImage: "sparkles")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Self.tint)
            Text("在输入栏点亮设备工具,或让已绑定技能开放这些工具。模型只有在生成明确的工具调用时才会写入提醒 / 备忘录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("建议先授权提醒事项;备忘录在 macOS 首次写入时再按系统弹窗确认。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.50), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Self.tint.opacity(0.12), lineWidth: 1)
        }
    }

    private var reminderAuthPill: some View {
        statusChip(
            title: reminderAuthorized ? "已授权" : "未授权",
            icon: reminderAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            color: reminderAuthorized ? .green : .orange
        )
    }

    private var reminderAuthButton: some View {
        Button {
            requestReminders()
        } label: {
            Label(requesting ? "请求中…" : "授权访问", systemImage: "lock.open")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(Self.tint)
        .disabled(requesting || reminderAuthorized)
        .fixedSize()
    }

    private var calendarAuthPill: some View {
        statusChip(
            title: calendarAuthorized ? "已授权" : "未授权",
            icon: calendarAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            color: calendarAuthorized ? .green : .orange
        )
    }

    private var calendarAuthButton: some View {
        Button {
            requestCalendar()
        } label: {
            Label(requestingCalendar ? "请求中…" : "授权访问", systemImage: "lock.open")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(Self.tint)
        .disabled(requestingCalendar || calendarAuthorized)
        .fixedSize()
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

    private func card<Content: View>(icon: String, title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Self.tint.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Self.tint)
                }
                .frame(width: 32, height: 32)
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Self.tint.opacity(0.16), lineWidth: 1)
        }
    }

    private func refreshAuth() {
        #if canImport(EventKit)
        reminderAuthorized = EventKitService.shared.isAuthorized
        calendarAuthorized = EventKitService.shared.isEventAuthorized
        #endif
    }

    private func requestReminders() {
        #if canImport(EventKit)
        requesting = true
        Task {
            let granted = await EventKitService.shared.requestAccess()
            await MainActor.run {
                reminderAuthorized = granted
                requesting = false
            }
        }
        #endif
    }

    private func requestCalendar() {
        #if canImport(EventKit)
        requestingCalendar = true
        Task {
            let granted = await EventKitService.shared.requestEventAccess()
            await MainActor.run {
                calendarAuthorized = granted
                requestingCalendar = false
            }
        }
        #endif
    }
}
