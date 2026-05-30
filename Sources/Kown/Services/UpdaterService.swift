#if os(macOS)
import Foundation
import Combine
import SwiftUI
import AppKit
import Sparkle

/// Sparkle 自动更新的封装 —— 整个 macOS 端的「检查 / 下载 / 安装更新」都走这里。
///
/// 设计：
/// - **单例 + 启动即起**：`SPUStandardUpdaterController(startingUpdater: true)` 在
///   App 启动时就拉起 Sparkle 的定时检查器。配合 Info.plist 的
///   `SUEnableAutomaticChecks=true`，满足「每次打开 App 也检测并启用自动更新」。
/// - **设置项实时可调**：`automaticallyChecksForUpdates` / `automaticallyDownloadsUpdates`
///   / `updateCheckInterval`（检查频率）都直接读写 `SPUUpdater` 的属性。Sparkle 会把它们
///   持久化进 UserDefaults，所以设置页改完即生效、跨启动保留。
/// - **手动拉取**：`checkForUpdates()` 触发 Sparkle 标准 UI（含 release notes、
///   下载进度、一键安装并重启）。
///
/// 更新源 / 公钥来自 Info.plist 的 `SUFeedURL` / `SUPublicEDKey`（见 release.sh / Info.plist）。
@MainActor
final class UpdaterService: NSObject, ObservableObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = UpdaterService()

    /// 检查频率选项。Sparkle 要求最小间隔 1 小时。
    enum CheckFrequency: TimeInterval, CaseIterable, Identifiable {
        case hourly  = 3600       // 每小时
        case daily   = 86_400     // 每天
        case weekly  = 604_800    // 每周

        var id: TimeInterval { rawValue }
        var label: String {
            switch self {
            case .hourly: return "每小时"
            case .daily:  return "每天"
            case .weekly: return "每周"
            }
        }

        /// 把任意秒数归一到最接近的预设档（Info.plist 默认 86400 → 每天）。
        static func nearest(to interval: TimeInterval) -> CheckFrequency {
            allCases.min(by: { abs($0.rawValue - interval) < abs($1.rawValue - interval) }) ?? .daily
        }
    }

    private var controller: SPUStandardUpdaterController!

    /// 手动「检查更新」按钮是否可点（Sparkle 检查中会自动置灰）。
    @Published private(set) var canCheckForUpdates = false
    /// 上次检查时间（用于设置页展示）。
    @Published private(set) var lastUpdateCheckDate: Date?

    /// 启动时自动检查更新。
    @Published var automaticallyChecksForUpdates: Bool = true {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    /// 自动下载并安装更新（关闭则只提示、等用户确认）。
    @Published var automaticallyDownloadsUpdates: Bool = false {
        didSet { updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }
    /// 检查频率。
    @Published var checkFrequency: CheckFrequency = .daily {
        didSet { updater.updateCheckInterval = checkFrequency.rawValue }
    }

    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        let updater = controller.updater
        // 用 updater 当前（持久化）状态初始化 @Published，保证设置页显示真实值。
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        checkFrequency = CheckFrequency.nearest(to: updater.updateCheckInterval)
        lastUpdateCheckDate = updater.lastUpdateCheckDate

        // KVO → @Published 桥接：检查按钮可用性。
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .assign(to: &$lastUpdateCheckDate)
    }

    private var updater: SPUUpdater { controller.updater }

    /// 手动触发一次更新检查（弹 Sparkle 标准 UI）。
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// 启动时静默后台检查 —— 不受 `SUScheduledCheckInterval`(每天一次)限制,
    /// 满足「每次打开 App 都检测」。发现新版时:开了自动下载就静默下载、下次启动安装;
    /// 否则才弹标准更新窗。仅在用户开了自动检查时才查,尊重设置。
    func checkInBackground() {
        guard updater.automaticallyChecksForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// 声明本 app 支持「温和提醒」。
    ///
    /// **这是修「安装并重启按钮无效」的关键**:不声明时 Sparkle 把 Kown 判成
    /// background app,点安装并重启后**不会替我们终止进程**(后台 app 由自己管生命周期),
    /// 于是 `Autoupdate` / `Updater.app` 起来后死等 Kown 退出 → 用户看着就是"按钮没反应",
    /// 必须手动 Cmd+Q 才装上。声明支持后,Sparkle 走正常前台流程,会正确终止并重启。
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 声明支持 gentle reminders 后必须配套实现:这里返回 true = 仍让 Sparkle 标准 UI
    /// 负责展示更新弹窗(保持原行为,不自己接管),只是借此让 Sparkle 按"前台交互式 app"
    /// 对待 Kown,从而在安装时正确终止并重启,而不是把它当后台进程死等。
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle 准备重启 app 时回调 —— 兜底强制终止当前进程,确保安装器能替换并重启。
    /// (即使前面 Sparkle 没替我们终止,这里也补一刀,彻底治"安装并重启按钮不退出"。)
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Task { @MainActor in
            NSApplication.shared.terminate(nil)
        }
    }
}

/// 放进 macOS 菜单栏「Kown ▸ 检查更新…」的菜单项。
struct CheckForUpdatesMenuItem: View {
    @ObservedObject private var updater = UpdaterService.shared
    var body: some View {
        Button("检查更新…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
#endif
