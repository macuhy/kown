import SwiftUI
import UIKit

/// 键盘面板 UI:顶部操作按钮 → 中间结果区 → 底部地球键 + 插入/复制。
struct KeyboardRootView: View {
    let model: KeyboardModel
    /// 地球键需要直接给 UIInputViewController 发 handleInputModeList(必须由按钮事件触发)。
    weak var controller: UIInputViewController?

    var body: some View {
        VStack(spacing: 8) {
            if !model.hasFullAccess {
                fullAccessGuide
            } else if model.config == nil {
                configGuide
            } else {
                actionsRow
                resultArea
            }
            bottomBar
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 引导态

    /// 未授予「完全访问」:键盘进程没网络、也读不到 App Group 配置,先引导去系统设置。
    private var fullAccessGuide: some View {
        guideCard(
            icon: "lock.shield",
            title: "需要开启「完全访问」",
            detail: "AI 处理需要联网。请到 设置 → 通用 → 键盘 → 键盘 → Kown,打开「允许完全访问」,然后回来重新切到本键盘。"
        )
    }

    /// 主 app 还没共享模型配置。
    private var configGuide: some View {
        guideCard(
            icon: "app.badge",
            title: "还没有可用的模型配置",
            detail: "打开 Kown 主 app → 设置 → 模型,开启「AI 键盘」开关,把当前模型共享给键盘后即可使用。"
        )
    }

    private func guideCard(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: 操作按钮排

    private var actionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(KeyboardAction.allCases) { action in
                    actionChip(action)
                }
            }
        }
    }

    private func actionChip(_ action: KeyboardAction) -> some View {
        let isRunning = model.runningAction == action
        return Button {
            model.run(action)
        } label: {
            HStack(spacing: 4) {
                if isRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: action.icon)
                        .font(.caption)
                }
                Text(isRunning ? "停止" : action.label)
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(isRunning ? Color.accentColor.opacity(0.18)
                                  : Color(uiColor: .secondarySystemBackground),
                        in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.isStreaming && !isRunning)
    }

    // MARK: 结果区

    private var resultArea: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
            if let err = model.errorText {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
            } else if model.isPreparingShot {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("读取最近截图…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            } else if model.result.isEmpty && !model.isStreaming {
                Text("选中或输入文字后点上面的操作;输入框没有文字时会改用剪贴板内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else if model.isStreaming {
                ScrollViewReader { scroll in
                    ScrollView {
                        Text(model.result + " ▍")
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .id("kown.keyboard.result")
                    }
                    .onChange(of: model.result) { _, _ in
                        scroll.scrollTo("kown.keyboard.result", anchor: .bottom)
                    }
                }
            } else {
                EditableResultTextView(
                    text: Binding(get: { model.result }, set: { model.result = $0 })
                )
                .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底部栏

    private var bottomBar: some View {
        HStack(spacing: 8) {
            // 地球键:切换输入法 —— Apple 审核硬性要求(needsInputModeSwitchKey 时必须提供)。
            if model.needsGlobe {
                GlobeKey(controller: controller)
                    .frame(width: 40, height: 32)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if !model.sourceNote.isEmpty {
                Text(model.sourceNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if model.hasFullAccess && model.config != nil {
                Button {
                    model.insertResult()
                } label: {
                    Label(model.inserted ? "已插入" : "插入",
                          systemImage: model.inserted ? "checkmark" : "text.insert")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.result.isEmpty || model.isStreaming)

                Button {
                    model.copyResult()
                } label: {
                    Label(model.copied ? "已替换" : "替换剪贴板",
                          systemImage: model.copied ? "checkmark" : "doc.on.clipboard")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.result.isEmpty || model.isStreaming)

                Button {
                    model.sendResult()
                } label: {
                    Label(model.returnKeyLabel,
                          systemImage: "paperplane.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
                .disabled(model.result.isEmpty || model.isStreaming)
            }
        }
    }
}

/// 键盘内可编辑文本区:inputView 设为空 View,防止焦点时弹出第二层键盘。
/// 用户可通过长按/双击使用系统原生选择/复制/粘贴/删除。
private struct EditableResultTextView: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.inputView = UIView()           // 空 inputView → 获得焦点不弹第二层键盘
        tv.font = .preferredFont(forTextStyle: .footnote)
        tv.backgroundColor = .clear
        tv.isEditable = true
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}

/// 系统地球键:必须是真 UIButton 并把触摸事件直接交给 handleInputModeList(长按弹输入法列表)。
private struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        if let controller {
            button.addTarget(controller,
                             action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                             for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
