#if os(macOS)
import AppKit
import UserNotifications

/// 系统级「划词 AI」服务提供者(macOS 专用,NSServices)。
///
/// 任意 app 选中文字 → 右键「服务」菜单(或 App 菜单 ▸ 服务)→
/// 「用 Kown 翻译 / 用 Kown 总结 / 问 Kown / 存入 Kown 知识库」。
/// 服务条目声明在 `mac/project.yml` 的 Info.plist `NSServices` 里,
/// `NSMessage` 与本类的 `@objc` handler 一一对应;系统在主线程回调。
///
/// 注意:服务请求可能在 app **冷启动**时就到达(用户在别的 app 里点服务把 Kown 拉起来),
/// 此时 `AppViewModel` 还没注入 —— 先把动作暂存,`attach(viewModel:)` 后补发。
@MainActor
final class MacServicesProvider: NSObject {
    static let shared = MacServicesProvider()

    /// 「存入 Kown 知识库」落进的资料夹名(不存在则自动创建)。
    static let collectionFolderName = "划词收集"

    /// 主 ViewModel,app 启动后由 `KownApp` 注入(weak,不影响生命周期)。
    private weak var viewModel: AppViewModel?
    /// viewModel 注入前到达的服务请求(冷启动场景),注入后补发。
    private var pending: (action: Action, text: String)?

    private enum Action {
        case translate        // 用 Kown 翻译(Translate 模式,直接发送)
        case summarize        // 用 Kown 总结(Direct 模式,直接发送)
        case ask              // 问 Kown(预填输入框,停在那等用户补充)
        case saveToKnowledge  // 存入知识库(写进「划词收集」资料夹 + 系统通知)
    }

    /// 注册成全局服务提供者。在 `applicationDidFinishLaunching` 调用,
    /// 保证冷启动被服务唤起时也能收到回调。
    func register() {
        NSApp.servicesProvider = self
        // 把四个服务写进系统的服务启用表(= 系统设置→键盘→服务 里的勾选),
        // 用户无需手动勾选;必须在 NSUpdateDynamicServices 之前写好。
        ensureServicesEnabled()
        // 让 pbs 重扫一遍服务声明 —— 新装/更新 app 后服务菜单能尽快出现,无需注销。
        NSUpdateDynamicServices()
    }

    /// Info.plist NSServices 的 (菜单标题, NSMessage) 清单 —— 改服务声明时这里要同步。
    private static let serviceEntries: [(title: String, message: String)] = [
        ("用 Kown 翻译", "kownServiceTranslate"),
        ("用 Kown 总结", "kownServiceSummarize"),
        ("问 Kown", "kownServiceAsk"),
        ("存入 Kown 知识库", "kownServiceSaveToKnowledge"),
    ]

    /// 服务的启用状态存在 `pbs` 偏好域的 NSServicesStatus 里,key 形如
    /// "bundleID - 菜单标题 - NSMessage"。没有条目时系统按默认规则决定是否出现在
    /// 右键菜单,部分 app 里会缺席;这里主动写入「双菜单启用」,让服务装完即用。
    /// 只补缺失的条目 —— 用户在系统设置里手动关过的(条目已存在)绝不覆盖。
    private func ensureServicesEnabled() {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let pbs = UserDefaults(suiteName: "pbs") else { return }
        var status = pbs.dictionary(forKey: "NSServicesStatus") ?? [:]
        var changed = false
        for entry in Self.serviceEntries {
            let key = "\(bundleID) - \(entry.title) - \(entry.message)"
            guard status[key] == nil else { continue }
            status[key] = [
                "enabled_context_menu": true,
                "enabled_services_menu": true,
                "presentation_modes": ["ContextMenu": true, "ServicesMenu": true],
            ]
            changed = true
        }
        if changed { pbs.set(status, forKey: "NSServicesStatus") }
    }

    /// 注入主 ViewModel,并补发注册前积压的服务请求。
    func attach(viewModel: AppViewModel) {
        self.viewModel = viewModel
        if let p = pending {
            pending = nil
            perform(p.action, text: p.text)
        }
    }

    // MARK: - NSServices handlers(selector 名 = Info.plist NSMessage + ":userData:error:")

    @objc(kownServiceTranslate:userData:error:)
    func kownServiceTranslate(_ pboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(.translate, pboard: pboard, error: error)
    }

    @objc(kownServiceSummarize:userData:error:)
    func kownServiceSummarize(_ pboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(.summarize, pboard: pboard, error: error)
    }

    @objc(kownServiceAsk:userData:error:)
    func kownServiceAsk(_ pboard: NSPasteboard, userData: String?,
                        error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(.ask, pboard: pboard, error: error)
    }

    @objc(kownServiceSaveToKnowledge:userData:error:)
    func kownServiceSaveToKnowledge(_ pboard: NSPasteboard, userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handle(.saveToKnowledge, pboard: pboard, error: error)
    }

    // MARK: - 分发

    private func handle(_ action: Action, pboard: NSPasteboard,
                        error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let text = (pboard.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            error.pointee = "选中的内容里没有文字" as NSString
            return
        }
        perform(action, text: text)
    }

    private func perform(_ action: Action, text: String) {
        guard let vm = viewModel else {
            // 冷启动:viewModel 还没就位,暂存等 attach 后补发。
            pending = (action, text)
            return
        }
        switch action {
        case .translate:
            // Translate 模式直接把原文当输入发送(目标语言走该模式的全局默认)。
            vm.newConversation(mode: .translate)
            vm.prompt = text
            vm.send()
            MacQuickAsk.activateMainWindow()
        case .summarize:
            // 复用菜单栏剪贴板动作的总结指令,在主窗口开新会话发送。
            vm.newConversation(mode: .direct)
            vm.prompt = ClipboardAction.summarize.prompt(for: text)
            vm.send()
            MacQuickAsk.activateMainWindow()
        case .ask:
            // 预填输入框不发送,停在那等用户补一句要问什么。
            vm.newConversation(mode: .direct)
            vm.prompt = text
            vm.focusInputRequest &+= 1
            MacQuickAsk.activateMainWindow()
        case .saveToKnowledge:
            saveToKnowledge(text, viewModel: vm)
        }
    }

    // MARK: - 存入知识库

    private func saveToKnowledge(_ text: String, viewModel vm: AppViewModel) {
        // 统一落进「划词收集」资料夹,没有就建一个。
        let folderID = vm.knowledgeFolders.first(where: { $0.name == Self.collectionFolderName })?.id
            ?? vm.createKnowledgeFolder(name: Self.collectionFolderName)
        // 文档名:取正文压成一行后的前 24 个字,空了就用日期兜底。
        let line = SchedulerService.oneLineSummary(text)
        let docName = line.isEmpty
            ? "划词 \(Date().formatted(date: .abbreviated, time: .shortened))"
            : String(line.prefix(24))
        vm.addKnowledgeDoc(folderID: folderID, name: docName, text: text)
        notifySaved(docName: docName)
    }

    /// 入库成功后发系统通知(无 UI 反馈的服务动作,得让用户知道成了)。
    private func notifySaved(docName: String) {
        SchedulerService.shared.ensureNotificationPermission()
        let content = UNMutableNotificationContent()
        content.title = "已存入知识库"
        content.body = "「\(docName)」已加入资料夹「\(Self.collectionFolderName)」"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }
}
#endif
