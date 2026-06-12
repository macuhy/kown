import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - 引用动作

/// 划词引用的三种动作:引用追问(留给用户接着输入)/ 解释这段 / 翻译这段(完整 prompt,等用户确认后发)。
enum QuoteAction {
    case ask, explain, translate
}

/// 引用追问的跨视图桥:答卡(深嵌在各模式视图里,拿不到 AppViewModel)把格式化好的
/// 预填文本发到这里,`InputBarView` 用 `.onReceive` 消费并写入输入框 + 聚焦。
/// 模式同 `FavoritesStore.shared` —— 全局唯一,主线程使用。
@MainActor
final class QuoteReplyCenter: ObservableObject {
    static let shared = QuoteReplyCenter()
    private init() {}

    /// 待写入输入框的预填文本。InputBarView 消费后置回 nil。
    @Published var pendingPrompt: String?

    /// 把选中片段格式化成 Markdown 引用块并请求预填输入框。
    /// - `.ask`:引用块 + 空行结尾,光标(焦点)落在末尾让用户接着输入问题,不自动发送。
    /// - `.explain` / `.translate`:预填完整 prompt,同样不自动发送,由用户确认后发。
    func quote(_ snippet: String, action: QuoteAction) {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 多行片段逐行加 "> ",保持引用块在 Markdown 里完整连续。
        let block = trimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        switch action {
        case .ask:
            pendingPrompt = block + "\n\n"
        case .explain:
            pendingPrompt = "请解释以下内容:\n\(block)"
        case .translate:
            pendingPrompt = "请翻译以下内容:\n\(block)"
        }
    }

    /// 直接预填一段完整文本(不做引用块格式化),同样不自动发送。
    /// 供代码块「让 AI 修复」等已自带格式(代码围栏 + 报错)的入口使用。
    func prefill(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingPrompt = trimmed + "\n"
    }
}

// MARK: - 答卡入口(footer 小药丸菜单)

/// 答卡 footer 的「引用」入口:菜单两项 ——
/// 「引用片段…」打开选择 sheet 划词后引用;「引用整条回答」整段直接进输入框。
/// 各答卡(HistoricalResponseCard / AnswerFooterBar / ChairSummaryCard)复用。
struct QuoteReplyMenu: View {
    let text: String
    /// iOS 紧凑宽度只显示图标(同 SaveToDeviceMenu)。
    var compact: Bool = false

    @State private var showSheet = false

    var body: some View {
        Menu {
            Button { showSheet = true } label: { Label("引用片段…", systemImage: "text.quote") }
            Button { QuoteReplyCenter.shared.quote(text, action: .ask) } label: {
                Label("引用整条回答", systemImage: "quote.opening")
            }
        } label: {
            let base = Label("引用", systemImage: "text.quote")
                .font(.caption2.weight(.semibold)).lineLimit(1).foregroundStyle(.secondary)
            Group {
                if compact { base.labelStyle(.iconOnly) }
                else { base.labelStyle(.titleAndIcon) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.10), in: Capsule()).fixedSize()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .sheet(isPresented: $showSheet) {
            QuoteReplySheet(fullText: text)
        }
    }
}

// MARK: - 划词选择 sheet

/// 划词引用 sheet:回答以**纯文本、可选区**形式展示(NSTextView / UITextView 只读包装,
/// 系统选区能直接读出选中字符串 —— 纯 SwiftUI 的 .textSelection 拿不到选区,故走这条路,双端一致)。
/// 用户选中片段后,底部「引用追问 / 解释这段 / 翻译这段」把片段以 Markdown 引用块预填进输入框。
struct QuoteReplySheet: View {
    let fullText: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedText = ""

    /// 当前选中片段(去首尾空白)。为空时三个动作不可用。
    private var snippet: String {
        selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            divider
            SelectableTextView(text: fullText, selectedText: $selectedText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            divider
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 540)
        #endif
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("引用回答", systemImage: "text.quote")
                .font(.headline)
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 选区状态提示:没选时引导,选中后预览片段开头。
            if snippet.isEmpty {
                Label("在上方选中要引用的文字,再选择一个动作", systemImage: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("已选中 \(snippet.count) 字:“\(String(snippet.prefix(40)))\(snippet.count > 40 ? "…" : "")”",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actionButtons }
                WrappingHStack(horizontalSpacing: 8, verticalSpacing: 8) { actionButtons }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButtons: some View {
        actionButton("引用追问", systemImage: "arrowshape.turn.up.left", action: .ask)
        actionButton("解释这段", systemImage: "questionmark.bubble", action: .explain)
        actionButton("翻译这段", systemImage: "character.book.closed", action: .translate)
    }

    private func actionButton(_ title: String, systemImage: String, action: QuoteAction) -> some View {
        Button {
            QuoteReplyCenter.shared.quote(snippet, action: action)
            dismiss()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(snippet.isEmpty ? 0.06 : 0.13), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.accentColor.opacity(snippet.isEmpty ? 0.10 : 0.30), lineWidth: 1)
                }
                .foregroundStyle(snippet.isEmpty ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(snippet.isEmpty)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }
}

// MARK: - 只读可选文本(双端原生包装)

#if os(macOS)
/// 只读可选 NSTextView 包装:系统选区变化时把选中字符串同步到 `selectedText`。
private struct SelectableTextView: NSViewRepresentable {
    let text: String
    @Binding var selectedText: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.delegate = context.coordinator
        tv.string = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableTextView
        init(_ parent: SelectableTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let range = tv.selectedRange()
            let selected = range.length > 0 ? (tv.string as NSString).substring(with: range) : ""
            if parent.selectedText != selected { parent.selectedText = selected }
        }
    }
}
#else
/// 只读可选 UITextView 包装:长按/拖动选中后把选中字符串同步到 `selectedText`。
private struct SelectableTextView: UIViewRepresentable {
    let text: String
    @Binding var selectedText: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.font = .preferredFont(forTextStyle: .body)
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        tv.delegate = context.coordinator
        tv.text = text
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text { uiView.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableTextView
        init(_ parent: SelectableTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let selected: String
            if let r = textView.selectedTextRange, !r.isEmpty {
                selected = textView.text(in: r) ?? ""
            } else {
                selected = ""
            }
            if parent.selectedText != selected { parent.selectedText = selected }
        }
    }
}
#endif
