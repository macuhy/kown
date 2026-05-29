import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: AppViewModel
    let onOpenSettings: () -> Void
    var onSelectConversation: () -> Void = {}
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .frame(minWidth: 240)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full.fill")
                .foregroundStyle(Color.accentColor)
            Text("All Conversations")
                .font(.headline.weight(.semibold))
            Spacer()
            #if os(iOS)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("厂商配置")
            #endif
            Button {
                viewModel.newConversation(mode: viewModel.activeMode)
                onSelectConversation()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("新建会话")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var list: some View {
        if viewModel.conversations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("还没有会话")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("点右上 ⊕ 或直接在底部输入一条问题。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.conversations) { conv in
                        ConversationRowView(
                            conversation: conv,
                            isSelected: viewModel.selectedConversationID == conv.id,
                            isRenaming: renamingID == conv.id,
                            renameDraft: $renameDraft,
                            onSelect: {
                                viewModel.selectConversation(conv.id)
                                onSelectConversation()
                            },
                            onStartRename: {
                                renameDraft = conv.title
                                renamingID = conv.id
                            },
                            onCommitRename: {
                                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    viewModel.renameConversation(conv.id, title: trimmed)
                                }
                                renamingID = nil
                            },
                            onCancelRename: { renamingID = nil },
                            onDelete: { viewModel.deleteConversation(conv.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }
}
