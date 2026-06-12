#if os(macOS)
import AppKit
import ScreenCaptureKit

/// 聊天窗口识别(划词助手「回复聊天」用):
/// 截取指定 app 的前台窗口,交给 OCRService 的聊天识别(右=我、左=对方)出对话转录。
/// 需要「屏幕录制」权限(系统设置 ▸ 隐私与安全性 ▸ 屏幕录制);未授权时抛错引导。
enum ChatWindowReader {

    enum ReadError: LocalizedError {
        case noPermission
        case windowNotFound
        case captureFailed
        case nothingRecognized

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "需要「屏幕录制」权限才能识别聊天窗口。已弹出系统授权请求;授权后需重启 Kown 生效。"
            case .windowNotFound:
                return "没找到可识别的聊天窗口 —— 先把聊天窗口切到前台再按 ⌃⌥L。"
            case .captureFailed:
                return "截取聊天窗口失败,稍后再试。"
            case .nothingRecognized:
                return "窗口里没识别出聊天文字。把聊天记录滚到可见区域再试一次。"
            }
        }
    }

    /// 主入口:截取 `app` 的前台窗口并 OCR 出对话转录(顶部 → 底部),保证非空。
    static func readChat(of app: NSRunningApplication) async throws -> [OCRService.ChatMessage] {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ReadError.noPermission
        }
        let image = try await captureFrontWindow(of: app)
        guard let messages = try? await OCRService.recognizeChatMessages(in: image),
              !messages.isEmpty else { throw ReadError.nothingRecognized }
        return messages
    }

    // MARK: - 截窗口

    /// 截取 app 的前台(最上层)窗口。用 CGWindowList 的前后顺序找到该 app
    /// 最靠前的常规窗口,再在 ScreenCaptureKit 的可共享内容里按 windowID 对上。
    private static func captureFrontWindow(of app: NSRunningApplication) async throws -> CGImage {
        let pid = app.processIdentifier

        // CGWindowList 按 z-order 前→后返回;取该 pid 第一个 layer 0、有合理尺寸的窗口。
        let infoList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]]) ?? []
        let frontWindowID: CGWindowID? = infoList.first { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 200, (bounds["Height"] ?? 0) > 150
            else { return false }
            return true
        }.flatMap { ($0[kCGWindowNumber as String] as? CGWindowID) }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let target: SCWindow? = {
            if let id = frontWindowID, let w = content.windows.first(where: { $0.windowID == id }) {
                return w
            }
            // 兜底:该 app 面积最大的 layer 0 在屏窗口。
            return content.windows
                .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }()
        guard let target else { throw ReadError.windowNotFound }

        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(target.frame.width * scale)
        config.height = Int(target.frame.height * scale)
        config.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: target)
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ReadError.captureFailed
        }
    }
}
#endif
