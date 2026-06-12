#if os(iOS)
import AppIntents

/// 「开始语音对话」快捷指令 / Siri / Action Button(侧边按钮):
/// 打开 Kown 并直达语音对话界面 ——「随身 AI 对讲机」。
/// 控制中心控件走深链 `kown://voice`,这里走 SharedInbox 暂存,两条路在 AppViewModel 汇合。
struct StartVoiceChatIntent: AppIntent {
    static var title: LocalizedStringResource { "开始语音对话" }
    static var description: IntentDescription {
        IntentDescription("打开 Kown 并直接进入语音对话:听 → 发 → 朗读 → 再听的免手循环。")
    }
    /// 运行后打开主 app(perform 在主 app 进程跑,前台时从 SharedInbox 取走标记)。
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        SharedInbox.depositVoiceRequest()
        return .result()
    }
}
#endif
