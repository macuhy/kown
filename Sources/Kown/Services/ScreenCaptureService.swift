#if os(macOS)
import Foundation
import AppKit
import ScreenCaptureKit

/// 截图提问(macOS):用系统自带的 `screencapture -i` 让用户**原生框选**屏幕区域,
/// 存临时 PNG → 交 `OCRService` 识别文字 → 返回。
///
/// 用系统二进制而非 ScreenCaptureKit + 自绘选区:省一套 overlay/权限代码,框选体验与系统截图一致;
/// 首次使用由系统弹「屏幕录制」授权(app 已 `app-sandbox: false`,可起子进程)。
///
/// 另提供**非交互全屏定时截图**(`captureMainDisplay`,ScreenCaptureKit `SCScreenshotManager`),
/// 给「实时屏幕副驾」(`ScreenCopilotService`)的节流捕获循环用——不弹框选、不写盘,直接拿 CGImage 喂 OCR。
enum ScreenCaptureService {

    enum CaptureError: LocalizedError {
        case cancelled       // 用户按 Esc 取消框选(未生成文件)
        case toolFailed      // screencapture 进程异常
        case unreadable      // 截图文件读不出来
        case noPermission    // 没有屏幕录制权限(非交互捕获用)
        case noDisplay       // 找不到可截的显示器

        var errorDescription: String? {
            switch self {
            case .cancelled:  return "已取消截图"
            case .toolFailed: return "截图失败"
            case .unreadable: return "无法读取截图"
            case .noPermission:
                return "Kown 没有「屏幕录制」权限。请在系统设置 › 隐私与安全性 › 屏幕录制里勾选 Kown,然后重开。"
            case .noDisplay:  return "找不到可捕获的显示器。"
            }
        }
    }

    // MARK: - 非交互全屏截图(实时屏幕副驾用)

    /// 当前是否已有屏幕录制权限(不弹窗;`notDetermined` 返回 false)。
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 打开系统设置「屏幕录制」面板的 deep link(引导用户授权)。
    static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    /// 非交互地截取主显示器整屏,返回 `CGImage`(不弹框选、不写盘)。
    /// 给 `ScreenCopilotService` 的节流循环用:抓屏 → OCR → 滚动 buffer。
    /// 无权限时先触发一次系统授权请求再抛 `.noPermission`(首次会弹窗)。
    ///
    /// `maxDimension`:把捕获分辨率限制在该上限内(等比缩放),OCR 不需要 Retina 全分辨率,
    /// 降一档省内存与 Vision 算力(节流循环要长时间反复跑)。
    static func captureMainDisplay(maxDimension: Int = 1920) async throws -> CGImage {
        guard hasScreenRecordingPermission() else {
            _ = CGRequestScreenCaptureAccess()   // 同步调用,notDetermined 时弹窗;已拒返回 false
            throw CaptureError.noPermission
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.noPermission
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        // 排除 Kown 自己的窗口(副驾面板),免得把自己的 UI 也 OCR 进 buffer 形成回声。
        let myWindows = content.windows.filter {
            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: myWindows)

        let config = SCStreamConfiguration()
        // 等比缩放到 maxDimension 内(像素维度;display.width/height 是点,Retina 时实际更大)。
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pxW = Double(display.width) * scale
        let pxH = Double(display.height) * scale
        let longest = max(pxW, pxH, 1)
        let ratio = min(1.0, Double(maxDimension) / longest)
        config.width = max(1, Int(pxW * ratio))
        config.height = max(1, Int(pxH * ratio))
        config.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.unreadable
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
