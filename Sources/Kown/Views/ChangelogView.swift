import SwiftUI
import MarkdownUI

/// 更新日志 sheet。两种打开方式:
/// 1. 自动:`KownApp` 检测到 app 版本 > 上次看到版本时弹
/// 2. 手动:设置 → 更新日志 tab(随时翻历史)
struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var service = ChangelogService.shared

    /// 是否是"自动弹出 What's New"模式(顶部多一个"v0.5.3 更新摘要"标题)
    var autoOpenedForVersion: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if let text = service.fullText {
                    Markdown(text)
                        .markdownTheme(Theme.gitHub)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    Text("更新日志暂不可用 — bundle 里找不到 CHANGELOG.md 资源。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(30)
                }
            }
            #if os(macOS)
            Divider()
            HStack {
                Spacer()
                Button("知道了") {
                    service.markCurrentSeen()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 640)
        #else
        .navigationTitle("更新日志")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("知道了") {
                    service.markCurrentSeen()
                    dismiss()
                }
            }
        }
        #endif
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let v = autoOpenedForVersion {
                    Text("Kown 已更新到 v\(v)")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                } else {
                    Text("Kown 更新日志")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                }
                Text("当前版本 v\(service.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.platformControlBackground.opacity(0.4))
    }
}
