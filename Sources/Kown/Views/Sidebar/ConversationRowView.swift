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
    var onEditSystemPrompt: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onEditTags: () -> Void = {}
    /// 回收站态:菜单改为「恢复 / 永久删除」。
    var inTrash: Bool = false
    var onRestore: () -> Void = {}
    var onPurge: () -> Void = {}
    /// 「移动到文件夹」子菜单数据(空 = 不显示该项)。
    var folders: [ConversationFolder] = []
    var onMoveToFolder: (UUID?) -> Void = { _ in }
    /// 分支血缘:与本会话相关的会话(父 + 兄弟分支),用于「切换分支」子菜单。空 = 不显示。
    var branchRelatives: [(id: UUID, title: String, isParent: Bool)] = []
    var onSwitchTo: (UUID) -> Void = { _ in }

    @State private var confirmPurge = false
    @FocusState private var renameFocused: Bool

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt
    }()

    private static let monthDayTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, HH:mm"
        return fmt
    }()

    private static let fullDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            KownModeMark(mode: conversation.mode, size: iconSize, selected: isSelected)

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
                    HStack(spacing: 5) {
                        if conversation.pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(modeColor)
                                .rotationEffect(.degrees(45))
                        }
                        if conversation.parentConversationID != nil {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(modeColor)
                                .help("分支会话")
                        }
                        Text(displayTitle)
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }

                if !conversation.lastPromptPreview.isEmpty {
                    Text(conversation.lastPromptPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !isRenaming {
                    Text("新会话")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if !isRenaming {
                    metadataLine
                }
            }

            Spacer(minLength: 0)

            #if os(iOS)
            if !isRenaming {
                HStack(spacing: 6) {
                    rowActionsMenu
                    if !inTrash {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isSelected ? modeColor.opacity(0.95) : Color.secondary.opacity(0.45))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.top, 5)
            }
            #endif
        }
        .padding(.horizontal, 11)
        .padding(.vertical, rowVerticalPadding)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: rowCorner, style: .continuous)
                    .fill(isSelected ? modeColor.opacity(0.12) : Color.platformControlBackground.opacity(0.24))
                RoundedRectangle(cornerRadius: rowCorner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [modeColor.opacity(isSelected ? 0.12 : 0.026), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: rowCorner, style: .continuous)
                .strokeBorder(isSelected ? modeColor.opacity(0.34) : KownTheme.quietStroke, lineWidth: 1)
        )
        .shadow(color: modeColor.opacity(isSelected ? 0.14 : 0.025), radius: isSelected ? 16 : 7, x: 0, y: isSelected ? 8 : 4)
        // 整行可点 = 选中（重命名状态下不响应，避免点 TextField 退出 rename）
        .contentShape(RoundedRectangle(cornerRadius: rowCorner, style: .continuous))
        .onTapGesture {
            if !isRenaming && !inTrash { onSelect() }
        }
        .contextMenu { rowActionItems }
        .accessibilityHint(inTrash ? "打开更多操作可恢复或永久删除" : "点按打开会话，更多操作里可置顶、重命名或移动")
        .confirmationDialog("永久删除「\(displayTitle)」?此操作不可恢复。", isPresented: $confirmPurge) {
            Button("永久删除", role: .destructive) { onPurge() }
            Button("取消", role: .cancel) { }
        }
    }

    private var rowActionsMenu: some View {
        Menu {
            rowActionItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.05), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("\(displayTitle) 的更多操作")
    }

    @ViewBuilder
    private var rowActionItems: some View {
        if inTrash {
            Button { onRestore() } label: {
                Label("恢复", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { confirmPurge = true } label: {
                Label("永久删除", systemImage: "trash.slash")
            }
        } else {
            Button { onTogglePin() } label: {
                Label(conversation.pinned ? "取消置顶" : "置顶",
                      systemImage: conversation.pinned ? "pin.slash" : "pin")
            }
            Button { onEditTags() } label: {
                Label("编辑标签…", systemImage: "tag")
            }
            Button { onStartRename() } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button { onEditSystemPrompt() } label: {
                Label("会话设置(提示 / 参数)…", systemImage: "slider.horizontal.3")
            }
            if !branchRelatives.isEmpty {
                Menu("切换分支") {
                    ForEach(branchRelatives, id: \.id) { rel in
                        Button {
                            onSwitchTo(rel.id)
                        } label: {
                            Label(rel.isParent ? "↑ \(rel.title)" : rel.title,
                                  systemImage: rel.isParent ? "arrow.up.left" : "arrow.triangle.branch")
                        }
                    }
                }
            }
            if !folders.isEmpty {
                Menu("移动到文件夹") {
                    ForEach(folders) { f in
                        Button {
                            onMoveToFolder(f.id)
                        } label: {
                            if conversation.folderID == f.id {
                                Label(f.name, systemImage: "checkmark")
                            } else {
                                Text(f.name)
                            }
                        }
                    }
                    Divider()
                    Button("移出(未分组)") { onMoveToFolder(nil) }
                }
            }
            Button(role: .destructive) { onDelete() } label: {
                Label("移到回收站", systemImage: "trash")
            }
        }
    }

    private var iconSize: CGFloat {
        #if os(iOS)
        return 34
        #else
        return 34
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
        conversation.mode.kownTint
    }

    private var displayTitle: String {
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title == "New Conversation" ? "新会话" : title
    }

    private var metadataLine: some View {
        ViewThatFits(in: .horizontal) {
            metadataRow(showTags: true)
            metadataRow(showTags: false)
            modePill
        }
    }

    private func metadataRow(showTags: Bool) -> some View {
        HStack(spacing: 6) {
            modePill
            datePill
            if showTags {
                tagPills
            }
        }
    }

    private var modePill: some View {
        Text(modeLabel)
            .font(.caption2.weight(.bold))
            .foregroundStyle(modeColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(modeColor.opacity(0.11), in: Capsule())
    }

    private var datePill: some View {
        Text(formattedDate)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var tagPills: some View {
        ForEach(conversation.tags.prefix(2), id: \.self) { tag in
            Text(tag)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    private var modeLabel: String {
        switch conversation.mode {
        case .council: return "议会"
        case .direct:  return "直接"
        case .compare: return "对比"
        case .debate:  return "辩论"
        case .structured: return "结构化"
        case .tournament: return "擂台"
        case .translate: return "翻译"
        }
    }

    private var formattedDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(conversation.updatedAt) {
            return Self.timeFormatter.string(from: conversation.updatedAt)
        } else if cal.isDate(conversation.updatedAt, equalTo: Date(), toGranularity: .year) {
            return Self.monthDayTimeFormatter.string(from: conversation.updatedAt)
        } else {
            return Self.fullDateFormatter.string(from: conversation.updatedAt)
        }
    }
}
