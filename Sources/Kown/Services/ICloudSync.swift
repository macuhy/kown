import Foundation
import Observation

/// iCloud Drive 同步管理器。
///
/// 方案:把会话 / Provider 配置 / Web Search 配置 这三类 JSON 文件,从本地
/// `~/.kown` / `<Documents>/.kown` 切换到 iCloud Ubiquity Container 的 Documents
/// 子目录里。系统自动跨设备同步,Foundation 处理后台上传 / 拉取 / 冲突。
///
/// API Key 通过 `KeychainStore` secret-store facade 管理;当前默认 JSON 后端
/// (`apikeys.json`) 不参与同步,继续留在本地敏感目录。
///
/// 容器可用性 + 用户偏好共同决定 `activeDataDirectory`;Store 们只问这一个 URL。
@Observable
@MainActor
final class ICloudSync {
    static let shared = ICloudSync()

    /// 容器 identifier — 必须与 entitlements 里的 `com.apple.developer.icloud-container-identifiers`
    /// 第一项一致。Apple Developer 开 Container 时需要用同一个 ID。
    nonisolated static let containerIdentifier = "iCloud.com.xiaobo.kown"

    nonisolated private static let prefKey = "kown.iCloudSync.enabled.v1"
    /// Default JSON secret-store file is local-sensitive data; never copy it during
    /// iCloud migration, mirror, or conflict reconciliation.
    nonisolated static let sensitiveFilenamesExcludedFromCloudCopy: Set<String> = ["apikeys.json"]

    /// 用户的开关偏好(持久化到 UserDefaults)。
    /// 即使容器临时不可用(账号登出),偏好本身不丢 — 重新登录后自动恢复同步。
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.prefKey)
        }
    }

    /// 容器 Documents 子目录的本地缓存路径(系统会在后台与云端同步)。
    /// nil = entitlement 没配 / 用户没登录 iCloud / 容器不可达。
    private(set) var containerDocumentsURL: URL?

    /// 是否允许往 iCloud `.kown` 写入。
    ///
    /// **关键不变式 — 不要随意改这个 gate 的语义**:
    /// 即使 `containerDocumentsURL` 已经拿到(几十 ms),也**不能**立刻往
    /// `.kown` 写,因为 iCloud 可能还在后台把现有 `.kown` 拉成 placeholder。
    /// 这时本地 `.kown` 不存在;只要任何 `createDirectory(...intermediates:true)`
    /// 触发本地 `.kown` 凭空生成 → 跟云上的旧 `.kown` 撞车 → macOS 把云上的
    /// 重命名成 `.kown 2/3/4...`,用户会话"突然消失"。
    ///
    /// 这个 gate 在 init / refresh 时:等本地 `.kown` 出现(iCloud 同步好了)
    /// 或 10s timeout 后才置 true。这之前 `activeDataDirectory` 强制走本地。
    private(set) var readyForCloudWrite: Bool = false

    /// 容器是否可达(UI 显示用,不代表能安全写)。
    var isAvailable: Bool { containerDocumentsURL != nil }

    /// 当前实际的同步状态(用于 UI 展示)。
    var status: Status {
        if isEnabled {
            return isAvailable ? .syncing : .signedOutOrUnavailable
        } else {
            return isAvailable ? .available : .unavailable
        }
    }

    enum Status {
        /// 容器可用但用户关着同步。
        case available
        /// 容器可用 + 同步打开。
        case syncing
        /// 用户没登录 iCloud,或容器还没 provision。
        case unavailable
        /// 同步打开但容器不可用 — UI 需要警示。
        case signedOutOrUnavailable

        var displayText: String {
            switch self {
            case .available:              return "iCloud 可用 · 同步未开启"
            case .syncing:                return "iCloud 同步已开启"
            case .unavailable:            return "iCloud 不可用 · 请检查账号"
            case .signedOutOrUnavailable: return "iCloud 已登出或暂时不可达"
            }
        }

        var isHealthy: Bool {
            self == .available || self == .syncing
        }
    }

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.prefKey)
        Task.detached(priority: .utility) { [weak self] in
            await self?.bootstrapICloud()
        }
        // 监听 iCloud 账号切换 — 用户登出/切换 Apple ID 时容器 token 变化,需要重探测。
        NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task.detached { await self?.bootstrapICloud() }
        }
    }

    /// 重新探测 iCloud 容器(账号切换 / 启动后手动刷新调用)。
    func refreshContainerURL() {
        Task.detached(priority: .utility) { [weak self] in
            await self?.bootstrapICloud()
        }
    }

    /// 完整的 iCloud 启动流程:
    /// 1. 拿 container Documents URL
    /// 2. 立刻 expose 给 main thread(UI 拿到正确 status)
    /// 3. **等本地 `.kown` 出现**(iCloud 把 placeholder 同步下来)再开闸允许写
    ///    最多等 10s;超时就认定云上没有 `.kown`(全新账号),开闸允许首次创建
    /// 4. 跑 reconcile(merge `.kown N` 兄弟回 `.kown`)
    nonisolated private func bootstrapICloud() async {
        let url = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerIdentifier)
        let documents = url?.appendingPathComponent("Documents", isDirectory: true)
        if let documents {
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        }
        // 立刻 expose URL,UI 状态先到位(reconcile / 闸门关着也能正确显)
        await MainActor.run {
            self.containerDocumentsURL = documents
            self.readyForCloudWrite = false   // 重置闸门
        }

        guard let documents else { return }

        // 关键:等 iCloud 把 `.kown` 同步到本地(哪怕只是 placeholder 都算)
        // 这之前 activeDataDirectory 走本地,避免空 `.kown` 撞云端实数据。
        let cloudKown = documents.appendingPathComponent(".kown", isDirectory: true)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: cloudKown.path) { break }
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms 轮一次
        }

        await MainActor.run {
            self.readyForCloudWrite = true
        }

        // 闸门已开后再 reconcile;此时 `.kown` 已就位,merge 安全
        Self.reconcileConflictSiblings(in: documents)
    }

    /// 找 iCloud Documents 里所有 ".kown 2" / ".kown 3" 之类的冲突备份目录(已被 reconcile 过的)
    /// — 用户在 Settings 里看到统计、可手动删除以释放 iCloud 配额。
    @MainActor
    func conflictBackupDirectories() -> [URL] {
        guard let cloud = containerDocumentsURL else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cloud,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        return entries.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(".kown ") else { return false }
            let suffix = name.dropFirst(".kown ".count)
            return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
        }
    }

    /// 统计冲突备份的文件总数(给 UI 显示用)
    @MainActor
    func conflictBackupFileCount() -> Int {
        let fm = FileManager.default
        var total = 0
        for dir in conflictBackupDirectories() {
            if let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: []) {
                for case let url as URL in en {
                    let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                    if isFile { total += 1 }
                }
            }
        }
        return total
    }

    /// 用户确认后调用 — 真正删除所有 `.kown N` 备份目录。
    /// 因为 `.kown` 已经通过 reconcile 拿到了所有数据,这些备份是冗余的。
    @discardableResult
    @MainActor
    func deleteConflictBackups() -> Int {
        let dirs = conflictBackupDirectories()
        var removed = 0
        for dir in dirs {
            if (try? FileManager.default.removeItem(at: dir)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// 自愈:扫 iCloud Documents 里所有 ".kown 2" / ".kown 3" 类的冲突重命名目录,
    /// 把里面的文件递归 merge 回 ".kown"(skip 已存在的,不覆盖)。
    ///
    /// 冲突产生原因:新设备启动时本地还没 download 已有的 `.kown`,
    /// `activeDataDirectory` getter 又 eager 建了空 `.kown`,跟云上有数据的 `.kown` 撞车 →
    /// macOS 把旧的重命名成 `.kown 2`,新空的"赢"。
    /// 修这个根因比较复杂(要 NSMetadataQuery 探测云上状态再决定建不建),
    /// 但**自动 reconcile 是 100% 安全的兜底**:不管以前怎么坏过,启动一次就把数据救回来。
    ///
    /// 处理后**不**删除 `.kown N`,留作用户人工核对的备份。下个版本可加 UI 提示用户清理。
    private nonisolated static func reconcileConflictSiblings(in documentsURL: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        let mainKown = documentsURL.appendingPathComponent(".kown", isDirectory: true)
        // 匹配 ".kown 2" / ".kown 3" / ".kown 10" 这种(macOS 冲突重命名格式)
        let siblings = entries.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(".kown ") else { return false }
            let suffix = name.dropFirst(".kown ".count)
            return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
        }
        guard !siblings.isEmpty else { return }

        // 确保 .kown 存在(可能这是首次启动,还没建)
        try? fm.createDirectory(at: mainKown, withIntermediateDirectories: true)

        for sibling in siblings {
            let merged = copyTree(
                from: sibling,
                to: mainKown,
                overwrite: false,
                excluding: sensitiveFilenamesExcludedFromCloudCopy
            )
            NSLog("Kown: iCloud reconcile — merged %d files from \(sibling.lastPathComponent) into .kown", merged)
        }
    }

    /// Store 们从这里取根目录:同步开启 + 容器可用 + **闸门已开** → iCloud;否则 → 本地。
    ///
    /// **闸门(readyForCloudWrite)的存在**:即使 iCloud 容器拿到了,本地 `.kown` 可能
    /// 还在被 iCloud 后台同步成 placeholder 的过程中。任何 `createDirectory(...intermediates:true)`
    /// 触发本地凭空生成 `.kown` 都会跟云上的真 `.kown` 撞车,macOS 把云上的重命名成
    /// `.kown 2/3/4...`,用户看到"会话突然没了"。所以闸门必须等到本地 `.kown` 出现(<10s)
    /// 或 timeout 才开。期间所有写入落到 `~/.kown` 本地,等下次启动 iCloud 同步好了再合上去。
    var activeDataDirectory: URL {
        if isEnabled, readyForCloudWrite, let cloud = containerDocumentsURL {
            return cloud.appendingPathComponent(".kown", isDirectory: true)
        }
        return Platform.localDataDir
    }

    // MARK: - 迁移

    /// 一次性把本地数据(会话 + provider + web search 等非敏感 JSON)复制到 iCloud 容器。
    /// 默认 JSON secret-store 文件不复制,继续留在本地敏感目录。
    /// 不删除本地副本 — 关闭同步时仍能 fallback 回来。
    /// 已存在的 iCloud 文件不覆盖,以"远端为准"(用户在另一设备上的最新版本)。
    /// 返回拷贝的文件数。
    @discardableResult
    func migrateLocalToCloud() async -> Int {
        guard let cloud = containerDocumentsURL else { return 0 }
        let local = Platform.localDataDir
        let cloudKown = cloud.appendingPathComponent(".kown", isDirectory: true)
        try? FileManager.default.createDirectory(at: cloudKown, withIntermediateDirectories: true)
        // 关键:把文件拷贝派到 detached 后台 task,不阻 main thread
        // (会话多时 copyTree 同步遍历 + 复制可能耗时,占 main 会让 UI 看起来卡死)
        return await Task.detached(priority: .utility) {
            Self.copyTree(
                from: local,
                to: cloudKown,
                overwrite: false,
                excluding: Self.sensitiveFilenamesExcludedFromCloudCopy
            )
        }.value
    }

    /// 把 iCloud 上的内容拉回本地(用户关闭同步时)。
    /// 远端为准:本地老文件直接覆盖,避免下次开启时反向覆盖云端。
    /// 已有旧版本同步到云端的默认 JSON secret-store 文件会被跳过,避免覆盖本机密钥。
    @discardableResult
    func mirrorCloudToLocal() async -> Int {
        guard let cloud = containerDocumentsURL else { return 0 }
        let cloudKown = cloud.appendingPathComponent(".kown", isDirectory: true)
        let local = Platform.localDataDir
        return await Task.detached(priority: .utility) {
            Self.copyTree(
                from: cloudKown,
                to: local,
                overwrite: true,
                excluding: Self.sensitiveFilenamesExcludedFromCloudCopy
            )
        }.value
    }

    /// 遍历 iCloud 容器内的目录,把还是"占位"状态(NSURLUbiquitousItemDownloadingStatusKey != .current)
    /// 的文件触发下载。这是 iCloud Documents API 的"按需下载"模型 — 不调这个,iPhone 端
    /// 即便文件元数据已经同步过来,实际字节还在云上,`Data(contentsOf:)` 会读到空 / 报错。
    /// 调用后立即返回(下载是异步的),需要 UI 给一点等待时间再 reload。
    /// 返回触发下载的文件数。
    /// `nonisolated` + `Sendable` — 文件枚举可能慢,不能阻 main thread。
    @discardableResult
    nonisolated static func triggerDownloads(in directory: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var triggered = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .isUbiquitousItemKey
            ])
            guard values?.isUbiquitousItem == true else { continue }
            if values?.ubiquitousItemDownloadingStatus != .current {
                try? fm.startDownloadingUbiquitousItem(at: url)
                triggered += 1
            }
        }
        return triggered
    }

    /// 触发下载 + 等待(给 iCloud 一点时间真把字节拉到本地)。
    /// 默认最多等 5 秒,超时后剩余文件等下次 reload 时再补。
    /// 关键:文件枚举在 detached task 里跑,不阻塞 main thread。
    @discardableResult
    func triggerDownloadsAndWait(in directory: URL, timeoutSeconds: Double = 5.0) async -> Int {
        let triggered = await Task.detached(priority: .utility) {
            Self.triggerDownloads(in: directory)
        }.value
        guard triggered > 0 else { return 0 }
        try? await Task.sleep(for: .seconds(timeoutSeconds))
        return triggered
    }

    /// 递归拷贝目录树。`overwrite=false` 时已存在的目标文件跳过。
    /// `excluding` 指定不参与拷贝的文件名(API Key 走单独路径)。
    nonisolated static func copyTree(
        from source: URL,
        to dest: URL,
        overwrite: Bool,
        excluding: Set<String>
    ) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let sourceRootPath = source.resolvingSymlinksInPath().path
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            if excluding.contains(url.lastPathComponent) { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let path = url.resolvingSymlinksInPath().path
            let rel: String
            if path == sourceRootPath {
                rel = ""
            } else if path.hasPrefix(sourceRootPath + "/") {
                rel = String(path.dropFirst(sourceRootPath.count + 1))
            } else {
                rel = url.lastPathComponent
            }
            guard !rel.isEmpty else { continue }
            let target = dest.appendingPathComponent(rel)
            if isDir {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            // 不覆盖模式:目标已存在直接跳过(coordinatedCopy 内部也会按需删旧)
            if !overwrite, fm.fileExists(atPath: target.path) { continue }
            // 走 NSFileCoordinator 协调拷贝 —— 单个失败静默跳过,不阻塞整体迁移
            if coordinatedCopy(from: url, to: target) {
                count += 1
            }
        }
        return count
    }

    /// 用 `NSFileCoordinator` 协调地把单个文件从 `src` 拷到 `dst`。
    ///
    /// **为什么不能用裸 `FileManager.copyItem`**:`src`/`dst` 落在 iCloud ubiquity
    /// 容器里时,容器由 FileProvider(`bird`/`fileproviderd`)托管。裸 copy:
    /// 1. 读云端 placeholder 会**同步阻塞**等系统 materialize,FileProvider 忙时可能卡死
    ///    (主迁移就是卡在某个 `copyItem` 上 100% 不动);
    /// 2. 未协调的写入会让 iCloud 把同名文件 fork 成 `.kown 2/3/...` 冲突副本。
    /// 协调访问:读端会先把云文件拉下来再给我们,写端拿到独占 slot 再落盘,
    /// 既不会无限卡,也不会产生冲突副本。
    private nonisolated static func coordinatedCopy(from src: URL, to dst: URL) -> Bool {
        let fm = FileManager.default
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var copied = false
        coordinator.coordinate(
            readingItemAt: src, options: [],
            writingItemAt: dst, options: .forReplacing,
            error: &coordError
        ) { readURL, writeURL in
            do {
                try fm.createDirectory(
                    at: writeURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: writeURL.path) {
                    try fm.removeItem(at: writeURL)
                }
                try fm.copyItem(at: readURL, to: writeURL)
                copied = true
            } catch {
                copied = false
            }
        }
        return copied && coordError == nil
    }
}
