import Foundation

/// 对话图片的**字节**存储(元数据在 `TurnImage`,放进会话 JSON;字节存这里)。
///
/// 文件放在同步根下的 `conversation-images/`,随 iCloud 同步。文件名用 UUID,
/// **永不与别处撞名 → iCloud 不会 fork 出冲突副本**(`.kown N` 那类问题不会发生)。
/// 对端首次拿到的是 iCloud 占位文件,读之前触发下载。
@MainActor
enum ConversationImageStore {
    static var dir: URL {
        let url = Platform.syncedDataDir.appendingPathComponent("conversation-images", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700 as NSNumber]
        )
        return url
    }

    static func url(for fileName: String) -> URL {
        dir.appendingPathComponent(fileName)
    }

    /// 写字节。文件名唯一,直接原子写即可。
    @discardableResult
    static func save(_ data: Data, fileName: String) -> Bool {
        do {
            try data.write(to: url(for: fileName), options: .atomic)
            return true
        } catch {
            NSLog("Kown: ConversationImageStore save failed: \(error.localizedDescription)")
            return false
        }
    }

    static func ext(forMime mime: String) -> String {
        switch mime {
        case "image/png":  return "png"
        case "image/jpeg": return "jpg"
        case "image/gif":  return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default:           return "img"
        }
    }

    /// 后台读字节(URL 由调用方在 MainActor 上用 `url(for:)` 算好传进来)。
    /// 文件还是 iCloud 占位时返回 nil,并触发下载,UI 稍后重试。
    nonisolated static func loadData(at url: URL) -> Data? {
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return nil
    }
}
