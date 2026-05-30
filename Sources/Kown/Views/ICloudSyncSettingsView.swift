import SwiftUI

/// 设置 → "iCloud 同步" tab。展示当前同步状态、开关、说明。
struct ICloudSyncSettingsView: View {
    @Bindable var viewModel: AppViewModel

    /// 冲突备份的文件数(`.kown 2`、`.kown 3` ... 累计)。本地状态,UI 显隐用。
    @State private var conflictBackupCount: Int = 0
    @State private var confirmDelete = false

    private let tint = Color(red: 0.18, green: 0.58, blue: 0.92)
    private let secondaryTint = Color(red: 0.10, green: 0.66, blue: 0.56)

    var body: some View {
        #if os(iOS)
        Form {
            heroSection
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
                heroCard
                toggleCard
                scopeCard
                if conflictBackupCount > 0 {
                    conflictBackupCard
                }
                tipsCard
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .topLeading)
        }
        .task {
            conflictBackupCount = viewModel.iCloudSync.conflictBackupFileCount()
        }
        #endif
    }

    // MARK: - Hero

    private var heroCard: some View {
        let status = viewModel.iCloudSync.status
        let enabled = viewModel.iCloudSync.isEnabled
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                iconTile(statusSymbol(status), tint: statusColor(status), secondary: secondaryTint)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("iCloud 同步")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        statusBadge(status.displayText,
                                    icon: statusSymbol(status),
                                    color: statusColor(status))
                    }
                    Text(detailLine(status))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if viewModel.iCloudMigrationInFlight {
                    ProgressView().controlSize(.small)
                } else {
                    statusBadge(enabled ? "同步已打开" : "同步未打开",
                                icon: enabled ? "checkmark.icloud.fill" : "icloud.slash",
                                color: enabled ? .green : .secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                metricTile(title: "同步范围",
                           value: "4 项",
                           detail: "会话 / Provider / Web Search / API Key",
                           icon: "square.stack.3d.up.fill",
                           color: tint)
                metricTile(title: "本机偏好",
                           value: "独立",
                           detail: "Debate 轮数、默认开关不跨设备覆盖",
                           icon: "slider.horizontal.3",
                           color: .secondary)
                metricTile(title: "冲突备份",
                           value: conflictBackupCount > 0 ? "\(conflictBackupCount)" : "0",
                           detail: conflictBackupCount > 0 ? "可清理冗余目录" : "没有待清理项",
                           icon: conflictBackupCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                           color: conflictBackupCount > 0 ? .orange : .green)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(heroBackground(color: statusColor(status)))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(statusColor(status).opacity(0.22), lineWidth: 1)
        }
        .shadow(color: statusColor(status).opacity(0.09), radius: 22, x: 0, y: 12)
    }

    // MARK: - Conflict backup cleanup

    private var conflictBackupBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 30, height: 30)
                    .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud 冲突备份")
                        .font(.headline)
                    Text("发现 \(conflictBackupCount) 个残留文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
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
        cardShell(tint: .orange) { conflictBackupBody }
    }

    // MARK: - Common content

    private var toggleBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(
                get: { viewModel.iCloudSync.isEnabled },
                set: { viewModel.setICloudSyncEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
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
                    HStack(spacing: 7) {
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
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.iCloudMigrationInFlight)
                .help("触发 iCloud 占位文件下载 + 重新加载会话和配置。另一端刚新增的会话过 1-2 分钟还没看到,点这个立即拉。")
            }
        }
    }

    private var scopeBody: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 9) {
            tipRow("首次启用时,本地已有数据会上传到 iCloud(不覆盖云端已存在的)。")
            tipRow("关闭同步会把云端最新内容拉回本地一次,之后修改不再同步。")
            tipRow("如果同步状态显示\"不可用\",请检查 设置 → Apple ID → iCloud → iCloud Drive 是否开启。")
            tipRow("API Key 跟随同步开关一起进 iCloud 容器,但不会出现在 Files / iCloud Drive 列表里;只有登录同一 Apple ID 的本应用能读到。")
        }
    }

    // MARK: - iOS Form sections

    #if os(iOS)
    private var heroSection: some View {
        Section {
            heroCard
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
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

    private var toggleCard: some View {
        cardShell(tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("同步开关", subtitle: "开启后把核心数据放入 iCloud 容器,关闭时会先拉回云端最新内容。", icon: "icloud.and.arrow.up", color: tint)
                toggleBody
                if !viewModel.iCloudSync.isAvailable {
                    messageBanner("iCloud 容器不可用 — 请确认已登录 Apple ID 并开启 iCloud Drive。",
                                  icon: "exclamationmark.triangle.fill",
                                  color: .orange)
                }
            }
        }
    }
    private var scopeCard: some View {
        cardShell(tint: secondaryTint) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("同步范围", subtitle: "云端同步和本机偏好分开处理,避免多设备互相覆盖习惯设置。", icon: "checklist", color: secondaryTint)
                scopeBody
            }
        }
    }
    private var tipsCard: some View {
        cardShell(tint: .secondary) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("说明", subtitle: "这些规则帮助你理解首次迁移、关闭同步和 API Key 存放位置。", icon: "info.circle.fill", color: .secondary)
                tipsBody
            }
        }
    }

    // MARK: - Styling helpers

    private func heroBackground(color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.16), secondaryTint.opacity(0.10), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private func iconTile(_ symbol: String, tint: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.94), secondary.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 58, height: 58)
        .shadow(color: tint.opacity(0.20), radius: 14, x: 0, y: 8)
    }

    private func sectionHeader(_ title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metricTile(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        }
    }

    private func statusBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .overlay { Capsule().strokeBorder(color.opacity(0.18), lineWidth: 1) }
            .fixedSize()
    }

    private func messageBanner(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(color.opacity(0.18), lineWidth: 1)
            }
    }

    @ViewBuilder
    private func cardShell<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.08), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 1)
            }
    }

    // MARK: - Row helpers

    private func scopeRow(icon: String, title: String, detail: String, synced: Bool) -> some View {
        let color = synced ? tint : Color.secondary
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(color)
                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(title).font(.body.weight(.semibold))
                    statusBadge(synced ? "同步" : "仅本地",
                                icon: synced ? "arrow.triangle.2.circlepath" : "lock.fill",
                                color: color)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(secondaryTint)
                .padding(.top, 1)
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
        case .syncing:                return tint
        case .available:              return secondaryTint
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
