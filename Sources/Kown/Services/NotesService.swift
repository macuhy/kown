import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 系统「备忘录」(Notes)写入。
///
/// - macOS:`NSAppleScript` 调备忘录 App `create new note`。沙箱已关、但 hardened runtime 下
///   发 Apple Event 需要 `com.apple.security.automation.apple-events` entitlement + 用户的自动化授权。
///   首次会弹「Kown 想要控制备忘录」的系统授权框;拒绝/出错都转成可读错误,不崩。
/// - iOS:**无公开写 Notes 的 API**。降级方案——把标题+正文写进剪贴板并打开备忘录 App,
///   让用户粘贴。回执里说明这一点。
enum NotesService {

    enum NotesError: LocalizedError {
        case automationDenied
        case underlying(String)
        case unsupported

        var errorDescription: String? {
            switch self {
            case .automationDenied: return "没有控制「备忘录」的权限,请在系统设置 ▸ 隐私 ▸ 自动化 里允许 Kown。"
            case .underlying(let m): return m
            case .unsupported:      return "当前平台不支持直接写入备忘录。"
            }
        }
    }

    /// 创建结果。`pasted == true` 表示走的是 iOS 降级路径(已复制+跳转,尚未真正写入)。
    struct CreateResult: Sendable {
        let title: String
        let pastedFallback: Bool
    }

    /// 新建一条备忘。macOS 真正写入;iOS 走剪贴板+跳转降级。
    @MainActor
    static func createNote(title: String, body: String) throws -> CreateResult {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(macOS)
        try createNoteViaAppleScript(title: cleanTitle, body: body)
        return CreateResult(title: cleanTitle, pastedFallback: false)
        #else
        // iOS 降级:内容进剪贴板 + 打开备忘录,提示用户粘贴。
        let combined = cleanTitle.isEmpty ? body : "\(cleanTitle)\n\n\(body)"
        Platform.copyText(combined)
        if let url = URL(string: "mobilenotes://") {
            Platform.open(url)
        }
        return CreateResult(title: cleanTitle, pastedFallback: true)
        #endif
    }

    #if os(macOS)
    /// 用 AppleScript 在备忘录默认账户里建一条 note。body 用换行拼成 HTML,标题作首行加粗。
    private static func createNoteViaAppleScript(title: String, body: String) throws {
        // 先拼 HTML(备忘录 body 吃 HTML),再整体转义进 AppleScript 字符串字面量。
        let htmlBody = htmlEscape(body).replacingOccurrences(of: "\n", with: "<br>")
        let firstLine = title.isEmpty ? "" : "<div><b>\(htmlEscape(title))</b></div>"
        let html = escapeForAppleScript(firstLine + htmlBody)
        let source = """
        tell application "Notes"
            make new note with properties {body:"\(html)"}
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NotesError.underlying("无法构造 AppleScript。")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -1743 = errAEEventNotPermitted(用户拒绝自动化授权)。
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 { throw NotesError.automationDenied }
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "AppleScript 执行失败。"
            throw NotesError.underlying(msg)
        }
    }

    /// 转义进 AppleScript 字符串字面量(反斜杠、双引号)。
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// HTML 转义(备忘录 body 是 HTML)。
    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
    #endif
}
