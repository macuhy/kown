import AppIntents
import SwiftUI
import WidgetKit

/// 控制中心控件(iOS 18+):一键直达 Kown 语音对话 ——「随身 AI 对讲机」。
/// 用户在控制中心「添加控件」里搜 Kown 即可加入,也可设到锁屏底部按钮。
@available(iOS 18.0, *)
struct VoiceControlWidget: ControlWidget {
    static let kind = "com.xiaobo.kown.widgets.voicecontrol"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenVoiceChatControlIntent()) {
                Label("Kown 语音", systemImage: "waveform.circle.fill")
            }
        }
        .displayName("Kown 语音")
        .description("一键打开 Kown 语音对话。")
    }
}

/// 控件点按动作:经深链 `kown://voice` 打开主 app 并直达语音对话界面。
/// 控件的 intent 在扩展进程里跑,拿不到主 app 状态 → 用 OpenURLIntent 把路由交给主 app 的深链处理。
@available(iOS 18.0, *)
struct OpenVoiceChatControlIntent: AppIntent {
    static var title: LocalizedStringResource { "打开 Kown 语音对话" }
    static var description: IntentDescription {
        IntentDescription("打开 Kown 并直接进入语音对话界面。")
    }
    /// 点按控件即把主 app 带到前台。
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "kown://voice")!))
    }
}
