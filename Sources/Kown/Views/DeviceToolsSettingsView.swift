import SwiftUI

/// 设备工具设置(设置 ▸ 设备工具)。让模型能在系统「提醒事项 / 备忘录」里创建条目。
/// 提供总开关、提醒事项权限申请与状态、平台说明。macOS / iOS 通用。
struct DeviceToolsSettingsView: View {
    @Bindable var viewModel: AppViewModel

    private static let tint = Color(red: 0.20, green: 0.60, blue: 0.62)

    @State private var reminderAuthorized: Bool = false
    @State private var requesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                masterToggle
                remindersCard
                notesCard
            }
            #if os(iOS)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            #else
            .padding(20)
            #endif
            .frame(maxWidth: 1040, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .onAppear { refreshAuth() }
    }

    private var masterToggle: some View {
        Toggle(isOn: $viewModel.deviceToolsEnabledForNextSend) {
            VStack(alignment: .leading, spacing: 2) {
                Text("启用设备工具")
                    .font(.subheadline.weight(.semibold))
                Text("开启后,模型可在对话里调用「创建提醒 / 写入备忘录」。技能也能单独点名这些工具。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Self.tint)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Self.tint.opacity(0.16), lineWidth: 1)
        }
    }

    private var remindersCard: some View {
        card(icon: "checklist", title: "提醒事项") {
            HStack(spacing: 8) {
                Circle()
                    .fill(reminderAuthorized ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(reminderAuthorized ? "已授权" : "未授权")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    requestReminders()
                } label: {
                    Label(requesting ? "请求中…" : "授权访问", systemImage: "lock.open")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Self.tint)
                .disabled(requesting || reminderAuthorized)
            }
            Text("模型创建提醒时会按当前时间换算「明天 / 下周一」等相对时间,并挂一个到点闹钟。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var notesCard: some View {
        card(icon: "note.text", title: "备忘录") {
            #if os(macOS)
            Text("macOS 通过自动化直接写入「备忘录」。首次写入时系统会弹出授权框,请在「系统设置 ▸ 隐私 ▸ 自动化」里允许 Kown 控制备忘录。")
                .font(.caption)
                .foregroundStyle(.secondary)
            #else
            Text("iOS 没有公开的备忘录写入接口:创建备忘时会把内容复制到剪贴板并打开「备忘录」App,你粘贴保存即可。")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
        }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Self.tint.opacity(0.16), lineWidth: 1)
        }
    }

    private func refreshAuth() {
        #if canImport(EventKit)
        reminderAuthorized = EventKitService.shared.isAuthorized
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
}
