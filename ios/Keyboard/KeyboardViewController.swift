import UIKit
import SwiftUI

/// Kown AI 键盘:不是打字键盘,是对正在输入文字的「AI 操作面板」。
/// 独立编译,不依赖主 app 模块;模型配置由主 app 经 App Group UserDefaults 共享。
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()

        model.insertText = { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        }
        // 取材:拼出光标附近段落(before + selected + after);拿不到时模型层退回剪贴板。
        model.fetchContext = { [weak self] in
            guard let proxy = self?.textDocumentProxy else { return "" }
            let before = proxy.documentContextBeforeInput ?? ""
            let selected = proxy.selectedText ?? ""
            let after = proxy.documentContextAfterInput ?? ""
            return before + selected + after
        }
        model.sendAction = { [weak self] in
            self?.textDocumentProxy.insertText("\n")
        }

        let host = UIHostingController(rootView: KeyboardRootView(model: model, controller: self))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshState()
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()
        // 面板高度 ~260pt:挂到 window 后再加约束,优先级 999 避免和系统约束打架。
        guard heightConstraint == nil, view.window != nil else { return }
        let c = view.heightAnchor.constraint(equalToConstant: 260)
        c.priority = UILayoutPriority(999)
        c.isActive = true
        heightConstraint = c
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // 切换宿主输入框后,needsInputModeSwitchKey / 完全访问状态可能变化。
        refreshState()
    }

    private func refreshState() {
        model.returnKeyLabel = returnKeyLabel(for: textDocumentProxy.returnKeyType ?? .default)
        model.reload(hasFullAccess: hasFullAccess, needsGlobe: needsInputModeSwitchKey)
    }

    private func returnKeyLabel(for type: UIReturnKeyType) -> String {
        switch type {
        case .send:          return "发送"
        case .done:          return "完成"
        case .go:            return "前往"
        case .search:        return "搜索"
        case .join:          return "加入"
        case .next:          return "下一个"
        case .route:         return "路线"
        case .google:        return "Google"
        case .yahoo:         return "Yahoo"
        case .continue:      return "继续"
        default:             return "换行"
        }
    }
}
