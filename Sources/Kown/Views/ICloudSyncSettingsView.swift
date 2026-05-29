import SwiftUI

/// 设置 → "iCloud 同步" tab。展示当前同步状态、开关、说明。
struct ICloudSyncSettingsView: View {
    @Bindable var viewModel: AppViewModel

    /// 冲突备份的文件数(`.kown 2`、`.kown 3` ... 累计)。本地状态,UI 显隐用。
    @State private var conflictBackupCount: Int = 0
    @State private var confirmDelete = false

    var body: some View {
        #if os(iOS)
        Form {
            statusSection
            toggleSection
            scopeSection
            if conflictBackupCount > 0 {
                conflictBackupSection
            }
            tipsSection
        }
        .task {
            conflictBackupCount = viewModel.iCloudSync.conflictBackupFileCount()
        }
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusCard
                toggleCard
                scopeCard
                if conflictBackupCount > 0 {
                    conflictBackupCard
                }
                tipsCard
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .topLeading)
        }
        .task {
            conflictBackupCount = viewModel.iCloudSync.conflictBackupFileCount()
        }
        #endif
    }

    // MARK: - Conflict backup cleanup

    private var conflictBackupBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("iCloud 冲突备份")
                    .font(.subheadline.weight(.semibold))
            }
            Text("发现 \(conflictBackupCount) 个文件残留在 `.kown 2` / `.kown 3` 等冲突备份目录里。Kown 已经把数据 merge 回主目录,这些备份是冗余的,可以删除以释放 iCloud 配额。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("删除冲突备份", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
        .confirmationDialog(
            "确定删除 iCloud 冲突备份目录?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                let removed = viewModel.iCloudSync.deleteConflictBackups()
                NSLog("Kown: deleted %d conflict backup dir(s)", removed)
                conflictBackupCount = viewModel.iCloudSync.conflictBackupFileCount()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("数据已 merge 回 .kown,这些备份是冗余的。该操作不可撤销。")
        }
    }

    private var conflictBackupSection: some View {
        Section { conflictBackupBody }
    }

    private var conflictBackupCard: some View {
        conflictBackupBody
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                Color.orange.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
            }
    }

    // MARK: - Common content

    private var statusBody: some View {
        let status = viewModel.iCloudSync.status
        return HStack(spacing: 12) {
            Image(systemName: statusSymbol(status))
                .font(.title2.weight(.semibold))
                .foregroundStyle(statusColor(status))
                .frame(width: 36, height: 36)
                .background(statusColor(status).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(status.displayText)
                    .font(.headline)
                Text(detailLine(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if viewModel.iCloudMigrationInFlight {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var toggleBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { viewModel.iCloudSync.isEnabled },
                set: { viewModel.setICloudSyncEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("启用 iCloud 同步")
                        .font(.body.weight(.semibold))
                    Text(viewModel.iCloudSync.isEnabled
                         ? "会话和配置正在通过 iCloud 在你的设备间同步。"
                         : "打开后,会话和配置将保存到 iCloud,在所有登录同一 Apple ID 的设备上保持一致。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(viewModel.iCloudMigrationInFlight || !viewModel.iCloudSync.isAvailable)

            if viewModel.iCloudSync.isEnabled && viewModel.iCloudSync.isAvailable {
                Button {
                    viewModel.refreshFromICloud()
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.iCloudMigrationInFlight {
                            ProgressView().controlSize(.small)
                            Text("刷新中...")
                        } else {
                            Image(systemName: "arrow.clockwise.icloud")
                            Text("立即从 iCloud 拉取")
                        }
                    }
                    .font(.callout.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.iCloudMigrationInFlight)
                .help("触发 iCloud 占位文件下载 + 重新加载会话和配置。另一端刚新增的会话过 1-2 分钟还没看到,点这个立即拉。")
            }
        }
    }

    private var scopeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            scopeRow(icon: "bubble.left.and.bubble.right.fill",
                     title: "会话",
                     detail: "全部对话记录、模型回答、Debate 轮次",
                     synced: true)
            scopeRow(icon: "square.stack.3d.up.fill",
                     title: "Provider 配置",
                     detail: "Base URL / 模型 / 温度 / Max tokens 等",
                     synced: true)
            scopeRow(icon: "globe",
                     title: "Web Search 配置",
                     detail: "Firecrawl base URL / 结果数 等",
                     synced: true)
            scopeRow(icon: "key.fill",
                     title: "API Key",
                     detail: "iCloud 容器内同步;对 Files app 隐藏,不会出现在 iCloud Drive 列表里",
                     synced: true)
            Divider().padding(.vertical, 2)
            scopeRow(icon: "slider.horizontal.3",
                     title: "本机偏好",
                     detail: "Debate 轮数、Web Search 开关等,每台独立",
                     synced: false)
        }
    }

    private var tipsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            tipRow("首次启用时,本地已有数据会上传到 iCloud(不覆盖云端已存在的)。")
            tipRow("关闭同步会把云端最新内容拉回本地一次,之后修改不再同步。")
            tipRow("如果同步状态显示\"不可用\",请检查 设置 → Apple ID → iCloud → iCloud Drive 是否开启。")
            tipRow("API Key 跟随同步开关一起进 iCloud 容器,但不会出现在 Files / iCloud Drive 列表里;只有登录同一 Apple ID 的本应用能读到。")
        }
    }

    // MARK: - iOS Form sections

    #if os(iOS)
    private var statusSection: some View {
        Section { statusBody }
    }
    private var toggleSection: some View {
        Section { toggleBody } footer: {
            if !viewModel.iCloudSync.isAvailable {
                Text("当前 iCloud 容器不可用 — 检查 iCloud Drive 是否登录并开启。")
                    .foregroundStyle(.orange)
            }
        }
    }
    private var scopeSection: some View {
        Section("同步范围") { scopeBody }
    }
    private var tipsSection: some View {
        Section("说明") { tipsBody }
    }
    #endif

    // MARK: - macOS cards

    private var statusCard: some View {
        cardShell { statusBody }
    }
    private var toggleCard: some View {
        cardShell {
            VStack(alignment: .leading, spacing: 10) {
                toggleBody
                if !viewModel.iCloudSync.isAvailable {
                    Label("iCloud 容器不可用 — 请确认已登录 Apple ID 并开启 iCloud Drive。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
    private var scopeCard: some View {
        cardShell {
            VStack(alignment: .leading, spacing: 10) {
                Text("同步范围")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                scopeBody
            }
        }
    }
    private var tipsCard: some View {
        cardShell {
            VStack(alignment: .leading, spacing: 8) {
                Text("说明")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                tipsBody
            }
        }
    }

    @ViewBuilder
    private func cardShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                Color.platformControlBackground.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
    }

    // MARK: - Row helpers

    private func scopeRow(icon: String, title: String, detail: String, synced: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 22, height: 22)
                .foregroundStyle(synced ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold))
                    if synced {
                        Text("同步").font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.13), in: Capsule())
                    } else {
                        Text("仅本地").font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.13), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusSymbol(_ s: ICloudSync.Status) -> String {
        switch s {
        case .syncing:                return "icloud.fill"
        case .available:              return "icloud"
        case .unavailable:            return "icloud.slash"
        case .signedOutOrUnavailable: return "exclamationmark.icloud.fill"
        }
    }

    private func statusColor(_ s: ICloudSync.Status) -> Color {
        switch s {
        case .syncing:                return Color.accentColor
        case .available:              return .secondary
        case .unavailable:            return .secondary
        case .signedOutOrUnavailable: return .orange
        }
    }

    private func detailLine(_ s: ICloudSync.Status) -> String {
        switch s {
        case .syncing:
            return "数据通过 iCloud Drive 后台同步。状态变化时此页会自动更新。"
        case .available:
            return "iCloud 容器已就绪,打开下方开关即可启用同步。"
        case .unavailable:
            return "未检测到 iCloud 容器。请确认已登录 Apple ID,且在 iCloud Drive 设置里允许了本应用。"
        case .signedOutOrUnavailable:
            return "同步已开启但容器暂时不可达 — 检查网络或重新登录 iCloud。新数据先保存在本地,可用时自动追上。"
        }
    }
}
