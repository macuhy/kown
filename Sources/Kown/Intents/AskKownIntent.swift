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
    }
}
#endif
