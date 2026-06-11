import Photos
import UIKit

/// 键盘扩展侧:取「最近一张截图」并降采样,供 OCR → 自动回复用。
///
/// ⚠️ 平台限制:授权优先在主 app 完成(见主 app 的「允许读取截图」按钮);
/// 如果扩展侧仍是 notDetermined,这里会触发一次系统授权。只有完整照片权限(authorized)可用;
/// 权限异常会交给 UI 提示,没有新截图时由模型层静默回退到输入框/剪贴板取材。
/// ⚠️ 内存:键盘扩展内存上限很低,绝不能塞全分辨率图进 Vision —— 统一降采样到 ~1080 宽再 OCR。
enum KeyboardScreenshot {
    static let appGroupID = "group.com.xiaobo.kown"
    /// 上次已自动处理过的截图 localIdentifier —— 同一张不重复自动跑(省 token)。
    static let lastIDKey = "kown.keyboard.lastScreenshotID.v1"

    enum ScreenshotError: LocalizedError {
        case photoAccessDenied
        case limitedPhotoAccess
        case imageUnavailable

        var errorDescription: String? {
            switch self {
            case .photoAccessDenied:
                return "没有照片权限。请在系统设置里给 Kown 完整照片权限,再回到键盘重试。"
            case .limitedPhotoAccess:
                return "当前是「部分照片」权限,无法自动读取最新截图。请到系统设置把 Kown 的照片权限改为「完整访问」。"
            case .imageUnavailable:
                return "读取最近截图失败,请重新截一张图后再试。"
            }
        }
    }

    struct Shot {
        let image: UIImage
        let localIdentifier: String
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    static var lastHandledID: String? {
        get { defaults?.string(forKey: lastIDKey) }
        set { defaults?.set(newValue, forKey: lastIDKey) }
    }

    /// 满足全部条件才返回降采样图,否则 nil:
    /// - 相册已授权完整照片权限(authorized)
    /// - 存在「截图」类型的照片
    /// - 最近一张在 `maxAge` 秒内(用户刚截图就用,隔太久不乱抓)
    /// - 不是上次已自动处理过的那张(去重)
    static func latestFresh(maxAge: TimeInterval = 180) async throws -> Shot? {
        try await ensureAuthorized()

        let opts = PHFetchOptions()
        opts.fetchLimit = 1
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // 只要「截图」子类型,避开普通照片/相机图。
        opts.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0",
                                     PHAssetMediaSubtype.photoScreenshot.rawValue)

        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        guard let asset = assets.firstObject else { return nil }

        if let created = asset.creationDate, Date().timeIntervalSince(created) > maxAge { return nil }
        if asset.localIdentifier == lastHandledID { return nil }

        guard let image = await requestDownsampled(asset) else {
            throw ScreenshotError.imageUnavailable
        }
        return Shot(image: image, localIdentifier: asset.localIdentifier)
    }

    /// 截图自动回复需要未来新截图也可见,所以必须是完整照片权限;limited 只能看到用户手动挑选的旧图。
    private static func ensureAuthorized() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized:
            return
        case .limited:
            throw ScreenshotError.limitedPhotoAccess
        case .notDetermined:
            let requested = await requestAuthorization()
            switch requested {
            case .authorized:
                return
            case .limited:
                throw ScreenshotError.limitedPhotoAccess
            default:
                throw ScreenshotError.photoAccessDenied
            }
        default:
            throw ScreenshotError.photoAccessDenied
        }
    }

    private static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
    }

    /// 请求降采样图(宽 ~1080,竖长截图按比例)。highQualityFormat 只回调一次,
    /// 但仍用一次性保护避免极端情况下重复 resume continuation。
    private static func requestDownsampled(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = false   // 截图都在本地,不下 iCloud
            opts.isSynchronous = false

            // 截图常是竖长条;给足高度,宽限 1080,contentMode .aspectFit 保比例。
            let target = CGSize(width: 1080, height: 1080 * 4)
            let resumed = ResumeOnce()
            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: target,
                                                  contentMode: .aspectFit,
                                                  options: opts) { image, _ in
                if resumed.fire() { cont.resume(returning: image) }
            }
        }
    }

    /// 保证 continuation 只 resume 一次。
    private final class ResumeOnce {
        private var done = false
        private let lock = NSLock()
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
