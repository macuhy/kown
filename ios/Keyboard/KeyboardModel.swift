import UIKit
import Observation

// MARK: - 配置(主 app 经 App Group 写入)

/// 主 app `KeyboardConfigBridge` 写入 App Group UserDefaults 的精简 provider 配置。
/// 字段必须与主 app 侧 `KeyboardConfigBridge.Payload` 保持一致(JSON 编码)。
struct KeyboardProviderConfig: Codable, Sendable {
    var name: String
    /// "openAICompatible" / "anthropic"
    var kind: String
    var baseURL: String
    var apiKey: String
    var model: String

    var isAnthropic: Bool { kind == "anthropic" }
}

/// 键盘扩展侧读取配置。注意:未授予「完全访问」时,键盘进程访问不到 App Group 容器,
/// 这里会直接读不到 —— UI 层先判 hasFullAccess 再判配置。
enum KeyboardConfigStore {
    static let appGroupID = "group.com.xiaobo.kown"
    static let configKey = "kown.keyboard.provider.v1"

    static func load() -> KeyboardProviderConfig? {
        guard let ud = UserDefaults(suiteName: appGroupID),
              let data = ud.data(forKey: configKey),
              let cfg = try? JSONDecoder().decode(KeyboardProviderConfig.self, from: data),
              !cfg.apiKey.isEmpty, !cfg.baseURL.isEmpty, !cfg.model.isEmpty
        else { return nil }
        return cfg
    }
}

// MARK: - 操作

/// 键盘顶部一排 AI 操作:对「正在输入的文字」做的事,不是打字按键。
enum KeyboardAction: String, CaseIterable, Identifiable, Sendable {
    case polish
    case translate
    case reply
    case formal
    case casual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .polish:    return "润色"
        case .translate: return "翻译"
        case .reply:     return "回复建议"
        case .formal:    return "转正式"
        case .casual:    return "转口语"
        }
    }

    var icon: String {
        switch self {
        case .polish:    return "wand.and.stars"
        case .translate: return "globe.asia.australia"
        case .reply:     return "arrowshape.turn.up.left"
        case .formal:    return "briefcase"
        case .casual:    return "bubble.left.and.bubble.right"
        }
    }

    var systemPrompt: String {
        switch self {
        case .polish:
            return "你是文字润色助手。把用户给的文字改得更通顺、自然、有表达力,保持原意、原语言和大致篇幅。只输出润色后的文字,不要任何解释或前后缀。"
        case .translate:
            return "你是翻译助手。在中文与英文之间智能互译:输入主要是中文就译成地道英文,主要是英文就译成地道简体中文。只输出译文本身,不加任何解释。"
        case .reply:
            return "你是回复建议助手。用户给的是别人发来的消息或一段对话上下文,请站在用户的立场拟一条得体、自然、可直接发送的回复(与对方语言一致)。只输出回复内容本身,不要解释。"
        case .formal:
            return "把用户给的文字改写成正式、书面、礼貌的语气,保持原意和原语言。只输出改写后的文字,不要任何解释。"
        case .casual:
            return "把用户给的文字改写成轻松、自然、口语化的语气,保持原意和原语言。只输出改写后的文字,不要任何解释。"
        }
    }
}

// MARK: - 状态机

/// 键盘 AI 面板状态机:取材(输入框上下文 / 剪贴板)→ 流式请求 → 插入/复制结果。
@MainActor
@Observable
final class KeyboardModel {
    var config: KeyboardProviderConfig?
    var hasFullAccess = false
    var needsGlobe = true

    var result = ""
    var errorText: String?
    var isStreaming = false
    /// 正在读最近截图 + OCR(还没开始流式请求)的过渡态,UI 显示「读取最近截图…」。
    var isPreparingShot = false
    var runningAction: KeyboardAction?
    /// 「取材:输入框文字」/「取材:剪贴板」,告诉用户这次 AI 处理的是哪段内容。
    var sourceNote = ""
    var inserted = false
    var copied = false

    /// 由 KeyboardViewController 注入:插入文字到宿主输入框(textDocumentProxy.insertText)。
    var insertText: (String) -> Void = { _ in }
    /// 由 KeyboardViewController 注入:拼出光标附近的段落文字(before + selected + after)。
    var fetchContext: () -> String = { "" }
    /// 由 KeyboardViewController 注入:向宿主输入框发送 Return(发送/换行)。
    var sendAction: () -> Void = {}
    /// 由 KeyboardViewController 注入:删除宿主输入框光标前一个字符(textDocumentProxy.deleteBackward)。
    var deleteBackward: () -> Void = {}
    /// 宿主输入框当前 Return 键的文案(发送 / 换行 / 完成 / …)。
    var returnKeyLabel: String = "换行"

    private var task: Task<Void, Never>?

    func reload(hasFullAccess: Bool, needsGlobe: Bool) {
        self.hasFullAccess = hasFullAccess
        self.needsGlobe = needsGlobe
        // 没有完全访问时读 App Group 也会失败,直接置空走引导文案。
        config = hasFullAccess ? KeyboardConfigStore.load() : nil
    }

    /// 跑一个 AI 操作。正在跑同一个操作时再点 = 取消。
    func run(_ action: KeyboardAction) {
        if isStreaming {
            cancel()
            return
        }
        guard config != nil else { return }

        var source = fetchContext().trimmingCharacters(in: .whitespacesAndNewlines)
        var note = "取材:输入框文字"
        if source.isEmpty {
            source = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            note = source.isEmpty ? "" : "取材:剪贴板"
        }
        guard !source.isEmpty else {
            errorText = "输入框和剪贴板里都没有文字。先在输入框打几个字,或复制一段内容再试。"
            return
        }
        startStream(action: action, source: source, note: note)
    }

    /// 全自动:键盘打开 → 读最近一张截图 → Vision OCR → 直接生成回复建议。
    /// 命中守卫(已授权 + 新鲜 + 未处理过)才真正跑;否则静默,不打扰、不花 token。
    func autoReplyFromLatestScreenshot() {
        guard !isStreaming, !isPreparingShot, config != nil else { return }
        isPreparingShot = true
        errorText = nil
        sourceNote = "读取最近截图…"

        Task { [weak self] in
            guard let shot = await KeyboardScreenshot.latestFresh() else {
                self?.cancelShotPrep()
                return
            }
            do {
                let text = try await OCRService.recognizeText(in: shot.image)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // 标记这张已处理:同一张重复开键盘不再自动跑。
                KeyboardScreenshot.lastHandledID = shot.localIdentifier
                guard let self, !text.isEmpty else { self?.cancelShotPrep(); return }
                self.isPreparingShot = false
                self.startStream(action: .reply, source: text, note: "取材:最近截图")
            } catch {
                // OCR 没识别到文字等:标记已处理避免反复试,静默回退。
                KeyboardScreenshot.lastHandledID = shot.localIdentifier
                self?.cancelShotPrep()
            }
        }
    }

    private func cancelShotPrep() {
        isPreparingShot = false
        if sourceNote == "读取最近截图…" { sourceNote = "" }
    }

    /// 真正发起一次流式请求:把已确定的取材文字喂给模型。
    private func startStream(action: KeyboardAction, source: String, note: String) {
        guard let cfg = config else { return }
        result = ""
        errorText = nil
        inserted = false
        copied = false
        sourceNote = note
        isStreaming = true
        runningAction = action

        let client = KeyboardChatClient(config: cfg)
        task = Task { [weak self] in
            do {
                try await client.stream(system: action.systemPrompt, user: source) { [weak self] delta in
                    await self?.append(delta)
                }
                self?.finish(error: nil)
            } catch is CancellationError {
                self?.finish(error: nil)
            } catch {
                self?.finish(error: error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isStreaming = false
        runningAction = nil
    }

    func insertResult() {
        guard !result.isEmpty else { return }
        insertText(result)
        inserted = true
    }

    func sendResult() {
        guard !result.isEmpty else { return }
        insertText(result)
        sendAction()
    }

    func copyResult() {
        guard !result.isEmpty else { return }
        UIPasteboard.general.string = result
        copied = true
    }

    private func append(_ delta: String) {
        result += delta
    }

    private func finish(error: Error?) {
        isStreaming = false
        runningAction = nil
        if let error, !Task.isCancelled {
            errorText = error.localizedDescription
        }
    }
}
