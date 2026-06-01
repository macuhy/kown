#if os(macOS)
import SwiftUI

/// Settings → 软件更新 tab（仅 macOS）。
///
/// 走 Sparkle：手动拉取最新版、设置检查频率、开关自动检查 / 自动下载安装。
/// 实际下载 / 校验 / 安装 / 重启都由 Sparkle 标准 UI 接管。
struct UpdateSettingsView: View {
    @ObservedObject private var updater = UpdaterService.shared
    /// 触发更新前先关掉设置 sheet —— 否则 modal sheet 会挡住 Sparkle 的安装/重启(terminate 退不出去)。
    /// 默认直接检查(用于无 sheet 上下文);SettingsView 传入会先 dismiss 再 checkForUpdates。
    var onRequestUpdate: () -> Void = { UpdaterService.shared.checkForUpdates() }

    private let tint = Color(red: 0.57, green: 0.42, blue: 0.82)
    private let secondaryTint = Color(red: 0.95, green: 0.57, blue: 0.16)

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }
    private var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                autoUpdateCard
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .topLeading)
        }
    }

    // MARK: - 当前版本 + 手动检查

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                iconTile("arrow.down.circle.fill", tint: tint, secondary: secondaryTint)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("软件更新")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        statusBadge(updater.canCheckForUpdates ? "可检查" : "检查中",
                                    icon: updater.canCheckForUpdates ? "checkmark.seal.fill" : "hourglass",
                                    color: updater.canCheckForUpdates ? .green : .secondary)
                    }
                    Text("通过 Sparkle 检查、下载并安装最新版本。手动检查会弹出 Sparkle 标准更新窗口。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    onRequestUpdate()
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!updater.canCheckForUpdates)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                metricTile(title: "当前版本",
                           value: "v\(currentVersion)",
                           detail: "Build \(buildNumber)",
                           icon: "app.badge.checkmark.fill",
                           color: tint)
                metricTile(title: "上次检查",
                           value: lastCheckShortText,
                           detail: lastCheckDetailText,
                           icon: "clock.arrow.circlepath",
                           color: secondaryTint)
                metricTile(title: "自动检查",
                           value: updater.automaticallyChecksForUpdates ? "开启" : "关闭",
                           detail: updater.automaticallyChecksForUpdates ? updater.checkFrequency.label : "仅手动检查",
                           icon: updater.automaticallyChecksForUpdates ? "bell.badge.fill" : "bell.slash.fill",
                           color: updater.automaticallyChecksForUpdates ? .green : .secondary)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(heroBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.09), radius: 22, x: 0, y: 12)
    }

    private var lastCheckText: String {
        guard let date = updater.lastUpdateCheckDate else {
            return "尚未检查过更新。"
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return "上次检查：\(fmt.string(from: date))"
    }

    private var lastCheckShortText: String {
        guard let date = updater.lastUpdateCheckDate else { return "从未" }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }

    private var lastCheckDetailText: String {
        guard let date = updater.lastUpdateCheckDate else { return "尚未检查过更新" }
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    // MARK: - 自动更新设置

    private var autoUpdateCard: some View {
        card(tint: tint) {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("自动更新", subtitle: "启动时自动检查、检查频率和后台下载都直接同步到 Sparkle。", icon: "sparkles", color: tint)

                settingToggle(isOn: $updater.automaticallyChecksForUpdates,
                              title: "启动时自动检查更新",
                              detail: "打开 App 后按下面的频率在后台静默检查。",
                              icon: "bell.badge.fill",
                              color: updater.automaticallyChecksForUpdates ? .green : .secondary)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(secondaryTint)
                            .frame(width: 28, height: 28)
                            .background(secondaryTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text("检查频率")
                            .font(.body.weight(.semibold))
                        Spacer()
                        statusBadge(updater.checkFrequency.label, icon: "clock", color: secondaryTint)
                    }
                    Picker("检查频率", selection: $updater.checkFrequency) {
                        ForEach(UpdaterService.CheckFrequency.allCases) { freq in
                            Text(freq.label).tag(freq)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!updater.automaticallyChecksForUpdates)
                    Text("每隔这段时间检查一次新版本（最小 1 小时）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                settingToggle(isOn: $updater.automaticallyDownloadsUpdates,
                              title: "自动下载并安装更新",
                              detail: "发现新版本后自动下载,下次启动时静默装好;关闭则每次先弹窗征求同意。",
                              icon: "square.and.arrow.down.fill",
                              color: updater.automaticallyDownloadsUpdates ? .green : .secondary)
                    .disabled(!updater.automaticallyChecksForUpdates)

                messageBanner(lastCheckText, icon: "clock.arrow.circlepath", color: secondaryTint)
            }
        }
    }

    // MARK: - Styling helpers

    private var heroBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.16), secondaryTint.opacity(0.10), Color.clear],
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
                        colors: [tint.opacity(0.95), secondary.opacity(0.78)],
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

    private func settingToggle(isOn: Binding<Bool>, title: String, detail: String, icon: String, color: Color) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func card<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
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
}
#endif
