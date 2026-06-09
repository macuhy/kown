#if os(macOS)
import Foundation
import AppKit

/// 截图提问(macOS):用系统自带的 `screencapture -i` 让用户**原生框选**屏幕区域,
/// 存临时 PNG → 交 `OCRService` 识别文字 → 返回。
///
/// 用系统二进制而非 ScreenCaptureKit + 自绘选区:省一套 overlay/权限代码,框选体验与系统截图一致;
/// 首次使用由系统弹「屏幕录制」授权(app 已 `app-sandbox: false`,可起子进程)。
enum ScreenCaptureService {

    enum CaptureError: LocalizedError {
        case cancelled       // 用户按 Esc 取消框选(未生成文件)
        case toolFailed      // screencapture 进程异常
        case unreadable      // 截图文件读不出来

        var errorDescription: String? {
            switch self {
            case .cancelled:  return "已取消截图"
            case .toolFailed: return "截图失败"
            case .unreadable: return "无法读取截图"
            }
        }
    }

    /// 框选一块屏幕区域 → OCR → 返回识别到的文字。取消框选抛 `.cancelled`。
    static func captureRegionAndRecognize() async throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kown-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try await runScreencapture(to: url)
        // 取消框选时 screencapture 退出码仍为 0 但不写文件 → 没文件即视为取消。
        guard FileManager.default.fileExists(atPath: url.path) else { throw CaptureError.cancelled }
        guard let image = NSImage(contentsOf: url) else { throw CaptureError.unreadable }
        return try await OCRService.recognizeText(in: image)
    }

    /// 跑 `/usr/sbin/screencapture -i <file>`(交互式框选,PNG)。
    private static func runScreencapture(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-i", "-x", url.path]   // -i 交互框选,-x 静音
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: CaptureError.toolFailed)
                }
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: CaptureError.toolFailed)
            }
        }
    }
}
#endif
