import Foundation
import Observation

/// 更新日志服务。
///
/// CHANGELOG.md 是项目资源文件,跟着 app 一起打包。每次发布更新版本号,这里自动识别
/// "已经看过的版本"(UserDefaults 存)和"当前 app 版本"(`CFBundleShortVersionString`),
/// 不一致时 UI 弹"What's New" sheet,用户看过后 `markCurrentSeen()` 记录。
@Observable
@MainActor
final class ChangelogService {
    static let shared = ChangelogService()

    private static let lastSeenKey = "kown.changelog.lastSeenVersion.v1"

    /// 完整 CHANGELOG 文本(已加载,nil 表示 bundle 里找不到资源 — build 配置问题)
    private(set) var fullText: String?

    /// 当前 app 版本(读 CFBundleShortVersionString)
    let currentVersion: String

    /// 用户上次看过的版本(从 UserDefaults 读)
    private(set) var lastSeenVersion: String?

    /// 是否有未看过的更新 — `currentVersion != lastSeenVersion`(且非首次启动)
    var hasUnseenChanges: Bool {
        guard fullText != nil else { return false }
        // 首次启动(lastSeenVersion 为空)不弹 — 用户对功能可能完全陌生,
        // 弹出"What's New"反而困扰。等他主动用一阵后,下次更新再弹。
        guard let last = lastSeenVersion, !last.isEmpty else { return false }
        return currentVersion != last
    }

    /// 首次启动时(lastSeenVersion 为空),静默标记当前版本为"看过",之后才有比较基准
    var isFreshInstall: Bool {
        (lastSeenVersion ?? "").isEmpty
    }

    private init() {
        self.currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        self.lastSeenVersion = UserDefaults.standard.string(forKey: Self.lastSeenKey)
        self.fullText = Self.loadChangelog()
        // 首次启动静默 mark seen,不弹窗
        if isFreshInstall {
            markCurrentSeen()
        }
    }

    /// 用户看过 What's New 后调用 — 把当前版本写进 UserDefaults
    func markCurrentSeen() {
        UserDefaults.standard.set(currentVersion, forKey: Self.lastSeenKey)
        lastSeenVersion = currentVersion
    }

    /// 强制重置(测试用 — 把 lastSeen 抹掉,下次启动会被当成"有新更新")
    func resetSeen() {
        UserDefaults.standard.removeObject(forKey: Self.lastSeenKey)
        lastSeenVersion = nil
    }

    // MARK: - Bundle 资源加载

    /// 加载 CHANGELOG.md
    ///
    /// **不要用 `Bundle.module`** — SPM 自动生成的 `Bundle.module` 静态初始化在新版 macOS 上
    /// 偶发地找不到嵌套 resource bundle,触发 `fatalError` 把整个 app 干掉,而且没法 catch。
    /// 改成把 CHANGELOG.md 直接放进 `.app/Contents/Resources/`(release.sh 负责拷贝),
    /// 走 `Bundle.main` 读,找不到就静默返回 nil,绝不崩。
    private static func loadChangelog() -> String? {
        // 主路径:CHANGELOG.md 直接放在 .app/Contents/Resources/ 下
        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        // 兜底:resourcePath 拼路径(覆盖某些非标准 bundle 布局)
        if let resPath = Bundle.main.resourcePath {
            let candidate = (resPath as NSString).appendingPathComponent("CHANGELOG.md")
            if let text = try? String(contentsOfFile: candidate, encoding: .utf8) {
                return text
            }
            // 兜底再兜底:SPM 资源 bundle 里
            let candidate2 = (resPath as NSString).appendingPathComponent("Kown_Kown.bundle/CHANGELOG.md")
            if let text = try? String(contentsOfFile: candidate2, encoding: .utf8) {
                return text
            }
        }
        return nil
    }
}
