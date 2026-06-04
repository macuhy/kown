import SwiftUI

/// 会话级系统提示编辑 sheet。
/// 仅对单个会话生效:非空时覆盖全局 `AppViewModel.systemPrompt`,留空则回退全局。
/// 可从提示词库(`PromptLibraryStore`)一键载入常用模板正文。
struct ConversationPromptSheet: View {
    @Bindable var viewModel: AppViewModel
    let conversationID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    /// 与 SettingsView 一致:本地实例化,init 时从磁盘载入模板。
    @State private var library = PromptLibraryStore()

    // 会话级生成参数覆盖
    @State private var overrideTemp: Bool = false
    @State private var temp: Double = 0.7
    @State private var overrideTopP: Bool = false
    @State private var topP: Double = 1.0
    @State private var maxTokensText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                } header: {
                    Text("会话系统提示")
                } footer: {
                    Text("仅对当前会话生效;留空则发送时使用全局系统提示。")
                }

                Section {
                    if !library.templates.isEmpty {
                        Menu("从提示词库载入…") {
                            ForEach(library.templates) { t in
                                Button(t.title) { draft = t.body }
                            }
                        }
                    }
                    if !draft.isEmpty {
                        Button("清空", role: .destructive) { draft = "" }
                    }
                }

                Section {
                    Toggle("自定义温度", isOn: $overrideTemp)
                    if overrideTemp {
                        VStack(alignment: .leading) {
                            Text("温度 \(temp, specifier: "%.2f")")
                                .font(.callout).monospacedDigit()
                            Slider(value: $temp, in: 0...2, step: 0.05)
                        }
                    }
                    Toggle("自定义 top-p", isOn: $overrideTopP)
                    if overrideTopP {
                        VStack(alignment: .leading) {
                            Text("top-p \(topP, specifier: "%.2f")")
                                .font(.callout).monospacedDigit()
                            Slider(value: $topP, in: 0...1, step: 0.05)
                        }
                    }
                    TextField("最大 tokens(留空 = 模型默认)", text: $maxTokensText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                } header: {
                    Text("生成参数(仅本会话)")
                } footer: {
                    Text("覆盖所选模型的默认温度 / 最大 tokens;关闭温度或留空 tokens 则用模型默认。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("会话设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.setConversationSystemPrompt(conversationID, prompt: draft)
                        let t: Double? = overrideTemp ? temp : nil
                        let p: Double? = overrideTopP ? topP : nil
                        let m = Int(maxTokensText.trimmingCharacters(in: .whitespaces))
                        viewModel.setConversationGenerationParams(conversationID, temperature: t, topP: p, maxTokens: m)
                        dismiss()
                    }
                }
            }
            .onAppear {
                draft = viewModel.conversationSystemPrompt(conversationID)
                let conv = viewModel.conversations.first { $0.id == conversationID }
                if let t = conv?.conversationTemperature { overrideTemp = true; temp = t }
                if let p = conv?.conversationTopP { overrideTopP = true; topP = p }
                if let m = conv?.conversationMaxTokens { maxTokensText = String(m) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }
}
