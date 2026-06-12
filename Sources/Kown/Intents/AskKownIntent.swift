#if os(iOS)
import AppIntents

/// 「问 Kown」快捷指令 / Siri:输入一个问题,打开 Kown 并预填到输入框。
struct AskKownIntent: AppIntent {
    static var title: LocalizedStringResource { "向 Kown 提问" }
    static var description: IntentDescription { IntentDescription("把问题预填到 Kown 输入框并打开 app。") }
    /// 运行后打开主 app(主 app 前台时从 SharedInbox 取出预填)。
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "问题")
    var question: String

    func perform() async throws -> some IntentResult {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            SharedInbox.deposit(trimmed)
        }
        return .result()
    }
}

/// 模式枚举(供「用某模式问」快捷指令选择)。
enum KownAskMode: String, AppEnum {
    case direct, compare, council, debate

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "对话模式" }
    static var caseDisplayRepresentations: [KownAskMode: DisplayRepresentation] {
        [.direct: "直接问答", .compare: "模型对比", .council: "模型议会", .debate: "模型辩论"]
    }
}

/// 「用指定模式问 Kown」:新建该模式会话并预填问题。
struct AskKownInModeIntent: AppIntent {
    static var title: LocalizedStringResource { "用指定模式问 Kown" }
    static var description: IntentDescription { IntentDescription("新建指定模式的会话,并把问题预填到输入框。") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "模式")
    var mode: KownAskMode
    @Parameter(title: "问题")
    var question: String

    func perform() async throws -> some IntentResult {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            SharedInbox.depositMode(mode.rawValue)
            SharedInbox.deposit(trimmed)
        }
        return .result()
    }
}

/// Siri / 快捷指令短语。
struct KownShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskKownIntent(),
            phrases: [
                "用 \(.applicationName) 提问",
                "问 \(.applicationName)"
            ],
            shortTitle: "向 Kown 提问",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
        AppShortcut(
            intent: StartVoiceChatIntent(),
            phrases: [
                "用 \(.applicationName) 语音对话",
                "和 \(.applicationName) 语音聊天"
            ],
            shortTitle: "开始语音对话",
            systemImageName: "waveform.circle.fill"
        )
        AppShortcut(
            intent: AskKownInModeIntent(),
            phrases: [
                "用 \(.applicationName) 指定模式提问",
                "让 \(.applicationName) 对比模型"
            ],
            shortTitle: "用指定模式问 Kown",
            systemImageName: "rectangle.split.2x1.fill"
        )
        AppShortcut(
            intent: TranslateTextIntent(),
            phrases: [
                "用 \(.applicationName) 翻译",
                "让 \(.applicationName) 翻译"
            ],
            shortTitle: "翻译文本",
            systemImageName: "globe"
        )
        AppShortcut(
            intent: SummarizeLinkIntent(),
            phrases: [
                "让 \(.applicationName) 总结链接",
                "用 \(.applicationName) 总结网页"
            ],
            shortTitle: "总结链接",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: SaveToKnowledgeIntent(),
            phrases: [
                "存到 \(.applicationName) 知识库",
                "用 \(.applicationName) 收藏笔记"
            ],
            shortTitle: "存入知识库",
            systemImageName: "books.vertical.fill"
        )
    }
}
#endif
