import SwiftUI

/// 表盘主界面:选模式 → 语音输入(听写)→ 流式回答 → 自动朗读。
struct WatchRootView: View {
    @State private var model = WatchChatModel()
    @StateObject private var conn = WatchConnectivityReceiver.shared
    @State private var mode: WatchMode = .direct
    @State private var input = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if conn.config == nil {
                    notConfigured
                } else {
                    modePicker
                    inputField
                    askButton
                    if let err = model.error {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if !model.answer.isEmpty {
                        answerCard
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Kown")
    }

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("还没收到模型配置")
                .font(.headline)
            Text("在 iPhone 上打开 Kown(同一 Apple ID 配对的手表),进「设置 ▸ Provider」点「同步到 Apple Watch」,配置会通过手表连接推送过来。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var modePicker: some View {
        Picker("模式", selection: $mode) {
            ForEach(WatchMode.allCases) { m in
                Text(m.label).tag(m)
            }
        }
        .pickerStyle(.navigationLink)
        .font(.footnote)
    }

    private var inputField: some View {
        // watchOS 的 TextField 点按即弹出听写 / 涂写输入 → 满足「语音输入」。
        TextField("说出你的问题…", text: $input)
            .textFieldStyle(.plain)
            .padding(8)
            .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    private var askButton: some View {
        Button {
            model.ask(mode: mode, prompt: input, config: conn.config)
        } label: {
            HStack {
                Image(systemName: model.isStreaming ? "stop.circle.fill" : "mic.fill")
                Text(model.isStreaming ? "生成中…" : "提问并朗读")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.isStreaming)
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.answer)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button {
                    model.speakAnswer()
                } label: {
                    Label("重读", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if model.isSpeaking {
                    Button {
                        model.stopSpeaking()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}
