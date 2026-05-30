import SwiftUI

struct ConversationRowView: View {
    let conversation: Conversation
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onSelect: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: iconCorner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                modeColor.opacity(isSelected ? 0.95 : 0.18),
                                modeColor.opacity(isSelected ? 0.62 : 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: conversation.mode.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isSelected ? .white : modeColor)
            }
            .frame(width: iconSize, height: iconSize)
            .overlay {
                RoundedRectangle(cornerRadius: iconCorner, style: .continuous)
                    .strokeBorder((isSelected ? Color.white : modeColor).opacity(isSelected ? 0.25 : 0.16), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 5) {
                if isRenaming {
                    let baseField = TextField("会话标题", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline.weight(.semibold))
                        .focused($renameFocused)
                        .onSubmit { onCommitRename() }
                        .onAppear { renameFocused = true }
                    #if os(macOS)
                    baseField.onExitCommand { onCancelRename() }
                    #else
                    baseField
                    #endif
                } else {
                    Text(conversation.title.isEmpty ? "New Conversation" : conversation.title)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                if !conversation.lastPromptPreview.isEmpty {
                    Text(conversation.lastPromptPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !isRenaming {
                    Text("New conversation")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if !isRenaming {
                    HStack(spacing: 6) {
                        Text(modeLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(modeColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(modeColor.opacity(0.11), in: Capsule())
                        Text(formattedDate)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer(minLength: 0)

            #if os(iOS)
            if !isRenaming {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? modeColor.opacity(0.95) : Color.secondary.opacity(0.45))
                    .padding(.top, 10)
            }
            #endif
        }
        .padding(.horizontal, 11)
        .padding(.vertical, rowVerticalPadding)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: rowCorner, style: .continuous)
                    .fill(isSelected ? modeColor.opacity(0.13) : Color.platformControlBackground.opacity(0.30))
                RoundedRectangle(cornerRadius: rowCorner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [modeColor.opacity(isSelected ? 0.10 : 0.035), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: rowCorner, style: .continuous)
                .strokeBorder(isSelected ? modeColor.opacity(0.36) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: modeColor.opacity(isSelected ? 0.12 : 0.035), radius: isSelected ? 16 : 9, x: 0, y: 7)
        // 整行可点 = 选中（重命名状态下不响应，避免点 TextField 退出 rename）
        .contentShape(RoundedRectangle(cornerRadius: rowCorner, style: .continuous))
        .onTapGesture {
            if !isRenaming { onSelect() }
        }
        .contextMenu {
            Button("重命名") { onStartRename() }
            Button("删除", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("删除「\(conversation.title)」?", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { onDelete() }
            Button("取消", role: .cancel) { }
        }
    }

    private var iconSize: CGFloat {
        #if os(iOS)
        return 34
        #else
        return 34
        #endif
    }

    private var iconCorner: CGFloat {
        #if os(iOS)
        return 12
        #else
        return 12
        #endif
    }

    private var rowCorner: CGFloat {
        #if os(iOS)
        return 16
        #else
        return 16
        #endif
    }

    private var rowVerticalPadding: CGFloat {
        #if os(iOS)
        return 10
        #else
        return 11
        #endif
    }

    private var modeColor: Color {
        switch conversation.mode {
        case .council: return Color(red: 0.06, green: 0.55, blue: 0.95)
        case .direct:  return Color(red: 0.55, green: 0.45, blue: 0.78)
        case .compare: return Color(red: 0.83, green: 0.38, blue: 0.18)
        case .debate:  return Color.indigo
        }
    }

    private var modeLabel: String {
        switch conversation.mode {
        case .council: return "Council"
        case .direct:  return "Direct"
        case .compare: return "Compare"
        case .debate:  return "Debate"
        }
    }

    private var formattedDate: String {
        let fmt = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(conversation.updatedAt) {
            fmt.dateFormat = "HH:mm"
        } else if cal.isDate(conversation.updatedAt, equalTo: Date(), toGranularity: .year) {
            fmt.dateFormat = "MMM d, HH:mm"
        } else {
            fmt.dateFormat = "yyyy-MM-dd"
        }
        return fmt.string(from: conversation.updatedAt)
    }
}
