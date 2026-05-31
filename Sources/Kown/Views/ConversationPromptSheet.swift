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
            }
            .formStyle(.grouped)
            .navigationTitle("会话系统提示")
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
                        dismiss()
                    }
                }
            }
            .onAppear { draft = viewModel.conversationSystemPrompt(conversationID) }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }
}
