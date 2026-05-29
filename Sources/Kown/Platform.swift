import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 跨平台路径 / 剪贴板 / "在系统里打开" / 颜色等 shim。
/// 让上层 Service / View 不直接依赖 AppKit / UIKit。
enum Platform {
    /// **本地**敏感数据根目录(API Key 等不参与 iCloud 同步的文件)。
    /// macOS: `~/.kown`(沿用历史路径,老用户配置无缝)。
    /// iOS:   `<App Documents>/.kown`(应用沙箱)。
    static var localDataDir: URL {
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
        #else
        let base = URL.documentsDirectory
        #endif
        let dir = base.appendingPathComponent(".kown", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700 as NSNumber]
        )
        return dir
    }

    /// 可被 iCloud 同步的数据根(会话 / providers / web_search)。
    /// 由 `ICloudSync` 决定:同步开启 + 容器可用时返回 iCloud Documents 子目录,
    /// 否则回退到 `localDataDir`。
    @MainActor
    static var syncedDataDir: URL {
        ICloudSync.shared.activeDataDirectory
    }

    /// 旧引用兼容 — 一律走本地路径(KeychainStore / apikeys.json 在用)。
    static var appDataDir: URL { localDataDir }

    /// 用户文档目录;响应日志写这里(用户可见)。macOS = ~/Documents,iOS = App Documents。
    static var userDocumentsDir: URL {
        #if os(macOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        return URL.documentsDirectory
        #endif
    }

    /// 复制纯文本到剪贴板。
    static func copyText(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// 在系统资源管理器里展示 URL(macOS = Finder;iOS 无对应,降级为 open url)。
    static func revealInExplorer(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// 在系统默认应用里打开 URL/路径。
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

/// 跨平台语义色 — 替换原来散落各处的 `Color(NSColor.xxx)`。
extension Color {
    static var platformWindowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var platformTextBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var platformControlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}
