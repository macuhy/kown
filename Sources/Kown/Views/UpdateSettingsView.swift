#if os(macOS)
import SwiftUI

/// Settings → 软件更新 tab（仅 macOS）。
///
/// 走 Sparkle：手动拉取最新版、设置检查频率、开关自动检查 / 自动下载安装。
/// 实际下载 / 校验 / 安装 / 重启都由 Sparkle 标准 UI 接管。
struct UpdateSettingsView: View {
    @ObservedObject private var updater = UpdaterService.shared

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }
    private var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                versionCard
                autoUpdateCard
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .topLeading)
        }
    }

    // MARK: - 当前版本 + 手动检查

    private var versionCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前版本")
                            .font(.headline)
                        Text("Kown \(currentVersion) (\(buildNumber))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updater.canCheckForUpdates)
                }

                Text(lastCheckText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

    // MARK: - 自动更新设置

    private var autoUpdateCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                Text("自动更新")
                    .font(.headline)

                Toggle(isOn: $updater.automaticallyChecksForUpdates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启动时自动检查更新")
                        Text("打开 App 后按下面的频率在后台静默检查。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
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

                Divider()

                Toggle(isOn: $updater.automaticallyDownloadsUpdates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动下载并安装更新")
                        Text("发现新版本后自动下载，下次启动时静默装好；关闭则每次先弹窗征求同意。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!updater.automaticallyChecksForUpdates)
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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
}
#endif
