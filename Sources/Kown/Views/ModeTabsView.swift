import SwiftUI

struct ModeTabsView: View {
    @Bindable var viewModel: AppViewModel
    @State private var pendingMode: ConversationMode?
    @State private var confirmSwitch = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ConversationMode.allCases, id: \.self) { mode in
                tab(for: mode)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .confirmationDialog(
            "切换模式将开始一个新会话",
            isPresented: $confirmSwitch
        ) {
            Button("继续") {
                if let m = pendingMode { viewModel.newConversation(mode: m) }
                pendingMode = nil
            }
            Button("取消", role: .cancel) { pendingMode = nil }
        } message: {
            Text("当前会话已有问答记录，切到 \(pendingMode?.displayName ?? "") 模式会新建一个会话。")
        }
    }

    private func tab(for mode: ConversationMode) -> some View {
        let isActive = viewModel.currentMode == mode
        return Button {
            handleTap(mode)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.symbol)
                Text(mode.displayName)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isActive ? Color.primary : .secondary)
            .background(
                Capsule().fill(isActive ? Color.platformWindowBackground : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(isActive ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func handleTap(_ mode: ConversationMode) {
        guard viewModel.currentMode != mode else { return }
        if let id = viewModel.selectedConversationID,
           let conv = viewModel.conversations.first(where: { $0.id == id }),
           !conv.turns.isEmpty {
            pendingMode = mode
            confirmSwitch = true
        } else {
            _ = viewModel.switchMode(to: mode)
        }
    }
}
