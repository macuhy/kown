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
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            list
        }
        .frame(minWidth: 240)
        .background(sidebarBackdrop)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.92), Color.orange.opacity(0.68)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .shadow(color: Color.accentColor.opacity(0.18), radius: 12, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text("All Conversations")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Text("\(viewModel.conversations.count) 个会话")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            #if os(iOS)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("厂商配置")
            #endif
            Button {
                viewModel.newConversation(mode: viewModel.activeMode)
                onSelectConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("新建会话")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var list: some View {
        if viewModel.conversations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 66, height: 66)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text("还没有会话")
                    .font(.headline.weight(.bold))
                Text("点右上 ⊕ 或直接在底部输入一条问题。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .padding(16)
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 7) {
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
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
    }

    private var sidebarBackdrop: some View {
        ZStack {
            Color.platformWindowBackground
            LinearGradient(
                colors: [Color.accentColor.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            RadialGradient(
                colors: [Color.orange.opacity(0.08), Color.clear],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 360
            )
        }
    }
}
