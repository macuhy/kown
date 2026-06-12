#if os(macOS)
import AppKit
import ScreenCaptureKit
import Vision

/// 聊天窗口识别(划词助手「回复聊天」用):
/// 截取指定 app 的前台窗口 → 系统 Vision OCR → 按文本块的左右位置区分发言人
/// (聊天 app 通行布局:对方气泡靠左,自己的气泡靠右)→ 拼成带角色的对话转录。
///
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

    /// 一条按左右位置归类出来的消息。
    struct Message {
        enum Side { case me, other }
        let side: Side
        var text: String
    }

    /// 主入口:截取 `app` 的前台窗口并 OCR 出对话转录(顶部 → 底部)。
    /// 返回空数组前已抛错,调用方拿到的结果保证非空。
    static func readChat(of app: NSRunningApplication) async throws -> [Message] {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ReadError.noPermission
        }
        let image = try await captureFrontWindow(of: app)
        let messages = try recognizeMessages(in: image)
        guard !messages.isEmpty else { throw ReadError.nothingRecognized }
        return messages
    }

    /// 把消息拼成给模型看的转录文本。
    static func transcript(_ messages: [Message]) -> String {
        messages.map { m in
            (m.side == .me ? "我: " : "对方: ") + m.text
        }.joined(separator: "\n")
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

    // MARK: - OCR + 左右归边

    /// Vision OCR 后按文本块位置归类:
    /// - 离左边近 → 对方;离右边近 → 我;
    /// - 基本居中(时间戳/系统提示)→ 跳过;
    /// - 同侧、纵向相邻的行合并成一条消息(气泡内换行)。
    private static func recognizeMessages(in image: CGImage) throws -> [Message] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []

        // 一行识别结果 + 归一化 bbox(Vision 原点在左下)。
        struct Line {
            let text: String
            let box: CGRect
            let side: Message.Side
        }

        var lines: [Line] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first, candidate.confidence > 0.3 else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = obs.boundingBox
            let leftGap = box.minX
            let rightGap = 1 - box.maxX
            // 两边距离差太小视为居中(时间戳「昨天 14:32」、入群提示等),不算发言。
            guard abs(leftGap - rightGap) > 0.08 else { continue }
            lines.append(Line(text: text,
                              box: box,
                              side: leftGap < rightGap ? .other : .me))
        }
        guard !lines.isEmpty else { return [] }

        // 顶部 → 底部排序(maxY 大的在上)。
        lines.sort { $0.box.maxY > $1.box.maxY }

        // 同侧、纵向间距小于约 1.2 行高的行合并为同一条消息(气泡内自动换行的长消息)。
        var messages: [Message] = []
        var lastBottom: CGFloat = .greatestFiniteMagnitude
        for line in lines {
            let gap = lastBottom - line.box.maxY
            let lineHeight = max(line.box.height, 0.012)
            if var last = messages.last, last.side == line.side, gap < lineHeight * 1.2 {
                last.text += line.text
                messages[messages.count - 1] = last
            } else {
                messages.append(Message(side: line.side, text: line.text))
            }
            lastBottom = line.box.minY
        }
        return messages
    }
}
#endif
