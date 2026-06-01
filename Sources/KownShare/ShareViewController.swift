import UIKit
import UniformTypeIdentifiers

/// Kown 分享扩展:接收别的 app 分享来的文字 / 网址,写入 App Group,
/// 主 app 下次前台时读出来预填到输入框。独立编译 —— 不依赖主 app 模块。
final class ShareViewController: UIViewController {
    /// 与主 app 共享的 App Group(两端硬编码一致)。
    private static let appGroup = "group.com.xiaobo.kown"
    private static let pendingKey = "kown.share.pendingText.v1"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handleShare() }
    }

    private func handleShare() async {
        let text = await extractSharedText()
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let defaults = UserDefaults(suiteName: Self.appGroup)
            // 追加而不是覆盖,避免连续分享丢内容
            var existing = defaults?.string(forKey: Self.pendingKey) ?? ""
            if !existing.isEmpty { existing += "\n\n" }
            existing += text
            defaults?.set(existing, forKey: Self.pendingKey)
        }
        finish()
    }

    /// 从 inputItems 里抽出文字或网址(优先纯文本,其次 URL)。
    private func extractSharedText() async -> String? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let obj = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                       let s = obj as? String {
                        return s
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let obj = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                       let url = obj as? URL {
                        return url.absoluteString
                    }
                }
            }
            // 部分 app 直接把文字塞在 attributedContentText 里
            if let attributed = item.attributedContentText?.string, !attributed.isEmpty {
                return attributed
            }
        }
        return nil
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
