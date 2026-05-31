import SwiftUI

/// 编辑历史某轮的用户消息并重新生成。
/// 重新生成会丢弃该轮之后的所有回合(不可撤销),因此确认按钮走二次确认。
struct EditTurnSheet: View {
    @Bindable var viewModel: AppViewModel
    let turnID: UUID
    let initialText: String
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var confirmRegen = false

    private var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .font(.body)
                        .frame(minHeight: 160)
                } header: {
                    Text("编辑这条消息")
                } footer: {
                    Text("重新生成会丢弃这条消息之后的所有回合,不可撤销。")
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑并重发")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("重新生成") { confirmRegen = true }
                        .disabled(isEmpty)
                }
            }
            .confirmationDialog(
                "重新生成会丢弃这条消息之后的所有回合,确定吗?",
                isPresented: $confirmRegen,
                titleVisibility: .visible
            ) {
                Button("丢弃后续并重发", role: .destructive) {
                    viewModel.editAndRegenerate(turnID: turnID, newPrompt: draft)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
            .onAppear { draft = initialText }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }
}
