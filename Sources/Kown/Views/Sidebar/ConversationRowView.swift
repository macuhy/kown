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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: conversation.mode.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? .white : modeColor)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill((isSelected ? Color.accentColor : modeColor).opacity(isSelected ? 1 : 0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                if !conversation.lastPromptPreview.isEmpty {
                    Text("Asked about: \(conversation.lastPromptPreview)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !isRenaming {
                    Text("New conversation")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if !isRenaming {
                    Text(formattedDate)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        // 整行可点 = 选中（重命名状态下不响应，避免点 TextField 退出 rename）
        .contentShape(Rectangle())
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

    private var modeColor: Color {
        switch conversation.mode {
        case .council: return Color(red: 0.06, green: 0.55, blue: 0.95)
        case .direct:  return Color(red: 0.55, green: 0.45, blue: 0.78)
        case .compare: return Color(red: 0.83, green: 0.38, blue: 0.18)
        case .debate:  return Color.indigo
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
