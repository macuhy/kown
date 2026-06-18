import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: AppViewModel
    let onOpenSettings: () -> Void
    var onSelectConversation: () -> Void = {}
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""
    /// 正在编辑会话系统提示的会话(nil = 未打开)。包一层以满足 `.sheet(item:)` 的 Identifiable。
    @State private var promptEditTarget: IdentifiedID?
    /// 标签过滤(nil = 全部)。
    @State private var selectedTag: String?
    /// 正在编辑标签的会话 + 草稿(逗号分隔)。
    @State private var tagEditTarget: IdentifiedID?
    @State private var tagDraft: String = ""
    /// 跨会话全文搜索:内存倒排索引,随侧栏生命周期存在,不落盘(重启重建)。
    @State private var searchIndex = ConversationSearchIndex()
    /// 搜索框输入
    @State private var searchText: String = ""
    /// 是否在看回收站。
    @State private var isViewingTrash = false
    /// 清空回收站确认。
    @State private var confirmEmptyTrash = false
    /// 折叠的文件夹。
    @State private var collapsedFolders: Set<UUID> = []
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var folderRenameTarget: IdentifiedID?
    @State private var folderRenameDraft = ""
    /// 正在配置「项目设置」的项目(文件夹)。nil = 未打开。
    @State private var projectSettingsTarget: IdentifiedID?
    /// [对话树画布] 是否打开分支血缘可视化画布。
    @State private var showConversationTree = false
    /// [知识图谱] 是否打开知识↔对话↔记忆关系图。
    @State private var showKnowledgeGraph = false

    private typealias BranchRelative = (id: UUID, title: String, isParent: Bool)

    private struct FolderConversationGroups {
        let byFolder: [UUID: [Conversation]]
        let ungrouped: [Conversation]
    }

    /// 当前是否处于搜索态
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 搜索命中(会话 id → 片段)缓存。每次按键只在 onChange 里算一次,避免
    /// 每个可见行(conversationRow)各自再 search 一遍整段索引(O(可见行数 × 全文))。
    @State private var cachedHitsByID: [UUID: ConversationSearchHit] = [:]

    /// 跑一次索引搜索得到命中表。无 query 时为空。仅由 searchText 的 onChange 调用。
    private func computeHitsByID() -> [UUID: ConversationSearchHit] {
        guard isSearching else { return [:] }
        var map: [UUID: ConversationSearchHit] = [:]
        for hit in searchIndex.search(searchText) {
            map[hit.id] = hit
        }
        return map
    }

    /// 过滤后展示的会话:标签过滤 + 搜索命中过滤,然后置顶优先(其余维持数组序)。
    private var displayedConversations: [Conversation] {
        if isViewingTrash {
            return viewModel.trashedConversations
                .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        }
        var list = viewModel.activeConversations
        if let tag = selectedTag {
            list = list.filter { $0.tags.contains(tag) }
        }
        if isSearching {
            let hits = cachedHitsByID
            list = list.filter { hits[$0.id] != nil }
        }
        // 置顶优先,其余保持原数组序(已是改动顶到最前的 updatedAt 序)
        return list.enumerated()
            .sorted { a, b in
                if a.element.pinned != b.element.pinned { return a.element.pinned }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(KownTheme.hairline)
                .frame(height: 1)
            if !isViewingTrash {
                searchField
                tagFilterBar
            }
            list
            trashBar
        }
        .frame(minWidth: sidebarMinWidth)
        .background(sidebarBackdrop)
        // 懒重建:索引只在搜索时用到,所以仅在开始搜索(空→非空)那一刻建一次,
        // 而不是每次会话数组变动都全量重扫 + 对整个大数组做相等性比较(都 O(全部文本))。
        .onChange(of: searchText) { old, new in
            // 仅「空→非空」那一刻才重建索引(后台跑),建好后再算命中;其余按键直接用现成索引算命中。
            if old.isEmpty && !new.isEmpty {
                Task {
                    await searchIndex.rebuild(viewModel.conversations)
                    cachedHitsByID = computeHitsByID()
                }
            } else {
                cachedHitsByID = computeHitsByID()
            }
        }
        .sheet(item: $promptEditTarget) { target in
            ConversationPromptSheet(viewModel: viewModel, conversationID: target.id)
        }
        .sheet(item: $projectSettingsTarget) { target in
            ProjectSettingsSheet(viewModel: viewModel, folderID: target.id)
        }
        .sheet(isPresented: $showConversationTree) {
            ConversationTreeView(viewModel: viewModel)
        }
        .sheet(isPresented: $showKnowledgeGraph) {
            KnowledgeGraphView(viewModel: viewModel)
        }
        .alert("编辑标签", isPresented: Binding(
            get: { tagEditTarget != nil },
            set: { if !$0 { tagEditTarget = nil } }
        )) {
            TextField("用逗号分隔,如 工作, 研究", text: $tagDraft)
            Button("保存") {
                if let id = tagEditTarget?.id {
                    viewModel.setTags(id, tags: tagDraft.split(separator: ",").map(String.init))
                }
                tagEditTarget = nil
            }
            Button("取消", role: .cancel) { tagEditTarget = nil }
        } message: {
            Text("多个标签用逗号分隔")
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") { viewModel.createFolder(name: newFolderName) }
            Button("取消", role: .cancel) { }
        }
        .alert("重命名文件夹", isPresented: Binding(
            get: { folderRenameTarget != nil },
            set: { if !$0 { folderRenameTarget = nil } }
        )) {
            TextField("文件夹名称", text: $folderRenameDraft)
            Button("保存") {
                if let id = folderRenameTarget?.id { viewModel.renameFolder(id, name: folderRenameDraft) }
                folderRenameTarget = nil
            }
            Button("取消", role: .cancel) { folderRenameTarget = nil }
        }
        .confirmationDialog("清空回收站?将永久删除 \(viewModel.trashedConversations.count) 个会话,不可恢复。",
                            isPresented: $confirmEmptyTrash) {
            Button("清空回收站", role: .destructive) { viewModel.emptyTrash() }
            Button("取消", role: .cancel) { }
        }
    }

    /// 底部回收站条:正常态显示「回收站(n)」入口;回收站态显示「返回 + 清空」。
    @ViewBuilder
    private var trashBar: some View {
        let trashCount = viewModel.trashedConversations.count
        if isViewingTrash {
            HStack(spacing: 10) {
                Button {
                    isViewingTrash = false
                } label: {
                    Label("返回会话", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                Button(role: .destructive) {
                    confirmEmptyTrash = true
                } label: {
                    Label("清空", systemImage: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(trashCount == 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
        } else if trashCount > 0 {
            Button {
                isViewingTrash = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("回收站(\(trashCount))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
        }
    }

    /// 标签过滤条 — 有标签时显示「全部 + 各标签」chips,点选过滤。
    @ViewBuilder
    private var tagFilterBar: some View {
        let tags = viewModel.allTags
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    tagChip("全部", active: selectedTag == nil) { selectedTag = nil }
                    ForEach(tags, id: \.self) { tag in
                        tagChip(tag, active: selectedTag == tag) {
                            selectedTag = (selectedTag == tag) ? nil : tag
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 6)
        }
    }

    private func tagChip(_ label: String, active: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? currentModeTint : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 顶部搜索框 — 自绘以贴合现有侧栏视觉(沿用 material + 圆角风格)。
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索会话内容", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if isSearching {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(currentModeTint.opacity(0.14), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var header: some View {
        #if os(iOS)
        mobileHeader
        #else
        desktopHeader
        #endif
    }

    private var desktopHeader: some View {
        HStack(spacing: 10) {
            KownModeMark(mode: viewModel.currentMode, size: 32)
                .shadow(color: currentModeTint.opacity(0.12), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text("会话")
                    .font(.system(.headline, design: .rounded).weight(.black))
                    .lineLimit(1)
                Text("\(viewModel.currentMode.localizedDisplayName) · \(viewModel.activeConversations.count) 个会话 · \(viewModel.conversationFolders.count) 个文件夹")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            desktopHeaderButton("arrow.triangle.branch", help: "对话树画布(分支血缘)") {
                showConversationTree = true
            }
            desktopHeaderButton("point.3.connected.trianglepath.dotted", help: "知识图谱(发现暗线)") {
                showKnowledgeGraph = true
            }
            desktopHeaderButton("folder.badge.plus", help: "新建文件夹") {
                newFolderName = ""
                showNewFolder = true
            }
            desktopHeaderButton("square.and.pencil", filled: true, help: "新建会话") {
                viewModel.newConversation(mode: viewModel.currentMode)
                onSelectConversation()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            ZStack {
                Rectangle().fill(.thinMaterial)
                LinearGradient(
                    colors: [currentModeTint.opacity(0.08), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private func desktopHeaderButton(
        _ symbol: String,
        filled: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(filled ? .white : currentModeTint)
                .frame(width: 31, height: 31)
                .background(
                    filled ? currentModeTint : Color.platformControlBackground.opacity(0.66),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(filled ? Color.white.opacity(0.24) : currentModeTint.opacity(0.14), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    #if os(iOS)
    private var mobileHeader: some View {
        HStack(spacing: 12) {
            KownModeMark(mode: viewModel.currentMode, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("会话库")
                    .font(.headline.weight(.black))
                Text("\(viewModel.activeConversations.count) 个会话 · \(viewModel.currentMode.localizedDisplayName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            headerIconButton("gearshape.fill", help: "设置", action: onOpenSettings)
            headerIconButton("arrow.triangle.branch", help: "对话树画布") {
                showConversationTree = true
            }
            headerIconButton("point.3.connected.trianglepath.dotted", help: "知识图谱") {
                showKnowledgeGraph = true
            }
            headerIconButton("folder.badge.plus", help: "新建文件夹") {
                newFolderName = ""
                showNewFolder = true
            }
            headerIconButton("square.and.pencil", help: "新建会话") {
                viewModel.newConversation(mode: viewModel.currentMode)
                onSelectConversation()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            ZStack {
                Rectangle().fill(.thinMaterial)
                LinearGradient(
                    colors: [currentModeTint.opacity(0.14), viewModel.currentMode.kownSecondaryTint.opacity(0.08), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private func headerIconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(currentModeTint)
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(currentModeTint.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    #endif

    @ViewBuilder
    private var list: some View {
        let activeConversations = viewModel.activeConversations
        let displayed = displayedConversations
        if isViewingTrash && displayed.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, height: 62)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text("回收站为空")
                    .font(.headline.weight(.bold))
            }
            .padding(22)
            .frame(maxHeight: .infinity)
        } else if !isViewingTrash && activeConversations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(currentModeTint)
                    .frame(width: 66, height: 66)
                    .background(currentModeTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text("还没有会话")
                    .font(.headline.weight(.bold))
                Text("点右上新建按钮,或直接在底部输入一条问题。")
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
        } else if isSearching && displayed.isEmpty {
            // 搜索无结果
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, height: 62)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text("没有匹配的会话")
                    .font(.headline.weight(.bold))
                Text("换个关键词试试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxHeight: .infinity)
        } else {
            let branchRelativesByID = isViewingTrash ? [:] : makeBranchRelativesByID(from: activeConversations)
            let folderGroups = groupingActive ? groupedConversationsByFolder(from: activeConversations) : FolderConversationGroups(byFolder: [:], ungrouped: [])
            ScrollView {
                LazyVStack(spacing: 7) {
                    if groupingActive {
                        ForEach(sortedFolders) { folder in
                            folderSection(
                                folder,
                                conversations: folderGroups.byFolder[folder.id] ?? [],
                                branchRelativesByID: branchRelativesByID
                            )
                        }
                        ungroupedSection(
                            conversations: folderGroups.ungrouped,
                            branchRelativesByID: branchRelativesByID
                        )
                    } else {
                        ForEach(displayed) { conv in
                            conversationRow(conv, branchRelatives: branchRelativesByID[conv.id] ?? [])
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                #if os(iOS)
                .padding(.bottom, 10)
                #endif
            }
        }
    }

    /// 分支血缘:与给定会话相关、可一键切换的会话 —— 父会话 + 同源兄弟分支 + 它的子分支。
    /// 一次性建索引,避免每个会话行都全表扫描(O(N²))。
    private func makeBranchRelativesByID(from activeConversations: [Conversation]) -> [UUID: [BranchRelative]] {
        let byID = Dictionary(uniqueKeysWithValues: activeConversations.map { ($0.id, $0) })
        var childrenByParent: [UUID: [Conversation]] = [:]
        for conv in activeConversations {
            if let parentID = conv.parentConversationID {
                childrenByParent[parentID, default: []].append(conv)
            }
        }

        func title(_ c: Conversation) -> String {
            c.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名会话" : c.title
        }

        var result: [UUID: [BranchRelative]] = [:]
        for conv in activeConversations {
            var relatives: [BranchRelative] = []
            if let parentID = conv.parentConversationID {
                if let parent = byID[parentID] {
                    relatives.append((parent.id, title(parent), true))
                }
                for sibling in childrenByParent[parentID] ?? [] where sibling.id != conv.id {
                    relatives.append((sibling.id, title(sibling), false))
                }
            }
            for child in childrenByParent[conv.id] ?? [] {
                relatives.append((child.id, title(child), false))
            }
            if !relatives.isEmpty { result[conv.id] = relatives }
        }
        return result
    }

    /// 单条会话行(含搜索命中片段)。分组与平铺共用。
    @ViewBuilder
    private func conversationRow(_ conv: Conversation, branchRelatives: [BranchRelative]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
                onDelete: { viewModel.deleteConversation(conv.id) },
                onEditSystemPrompt: { promptEditTarget = IdentifiedID(id: conv.id) },
                onTogglePin: { viewModel.togglePinned(conv.id) },
                onEditTags: {
                    tagDraft = conv.tags.joined(separator: ", ")
                    tagEditTarget = IdentifiedID(id: conv.id)
                },
                inTrash: isViewingTrash,
                onRestore: { viewModel.restoreConversation(conv.id) },
                onPurge: { viewModel.permanentlyDeleteConversation(conv.id) },
                folders: viewModel.conversationFolders,
                onMoveToFolder: { viewModel.setFolder(conv.id, folderID: $0) },
                branchRelatives: isViewingTrash ? [] : branchRelatives,
                onSwitchTo: { id in
                    viewModel.selectConversation(id)
                    onSelectConversation()
                }
            )
            if !isViewingTrash, let hit = cachedHitsByID[conv.id], let snippet = highlightedSnippet(hit) {
                snippet
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.top, 3)
                    .padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.selectConversation(conv.id)
                        onSelectConversation()
                    }
            }
        }
    }

    // MARK: - 文件夹分组

    /// 仅在「无搜索 + 无标签过滤 + 非回收站 + 有文件夹」时按文件夹分组展示。
    private var groupingActive: Bool {
        !isSearching && selectedTag == nil && !isViewingTrash && !viewModel.conversationFolders.isEmpty
    }

    private var sortedFolders: [ConversationFolder] {
        viewModel.conversationFolders.sorted { $0.createdAt < $1.createdAt }
    }

    private func groupedConversationsByFolder(from activeConversations: [Conversation]) -> FolderConversationGroups {
        var byFolderEntries: [UUID: [(offset: Int, conversation: Conversation)]] = [:]
        var ungroupedEntries: [(offset: Int, conversation: Conversation)] = []
        for (offset, conversation) in activeConversations.enumerated() {
            if let folderID = conversation.folderID {
                byFolderEntries[folderID, default: []].append((offset, conversation))
            } else {
                ungroupedEntries.append((offset, conversation))
            }
        }

        func sorted(_ entries: [(offset: Int, conversation: Conversation)]) -> [Conversation] {
            entries
                .sorted { lhs, rhs in
                    if lhs.conversation.pinned != rhs.conversation.pinned { return lhs.conversation.pinned }
                    return lhs.offset < rhs.offset
                }
                .map(\.conversation)
        }

        return FolderConversationGroups(
            byFolder: byFolderEntries.mapValues(sorted),
            ungrouped: sorted(ungroupedEntries)
        )
    }

    @ViewBuilder
    private func folderSection(
        _ folder: ConversationFolder,
        conversations convs: [Conversation],
        branchRelativesByID: [UUID: [BranchRelative]]
    ) -> some View {
        let collapsed = collapsedFolders.contains(folder.id)
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                Button {
                    if collapsed { collapsedFolders.remove(folder.id) } else { collapsedFolders.insert(folder.id) }
                } label: {
                    // 项目空间:用项目自己的图标与标识色;未配置时回退 folder.fill + 模式色。
                    groupHeaderLabel(icon: folder.icon ?? "folder.fill",
                                     chevron: collapsed ? "chevron.right" : "chevron.down",
                                     name: folder.name, count: convs.count,
                                     tint: folder.color?.swiftUIColor ?? currentModeTint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(collapsed ? "展开" : "折叠")文件夹 \(folder.name)")
                #if os(iOS)
                folderActionsMenu(folder)
                #endif
            }
            .contextMenu {
                folderActionItems(folder)
            }
            if !collapsed {
                ForEach(convs) { conv in
                    conversationRow(conv, branchRelatives: branchRelativesByID[conv.id] ?? [])
                }
            }
        }
    }

    @ViewBuilder
    private func folderActionItems(_ folder: ConversationFolder) -> some View {
        Button {
            viewModel.newConversation(mode: viewModel.currentMode, inFolder: folder.id)
            onSelectConversation()
        } label: {
            Label("在项目中新建会话", systemImage: "square.and.pencil")
        }
        Button { projectSettingsTarget = IdentifiedID(id: folder.id) } label: {
            Label("项目设置…", systemImage: "gearshape")
        }
        Divider()
        Button { folderRenameDraft = folder.name; folderRenameTarget = IdentifiedID(id: folder.id) } label: {
            Label("重命名文件夹", systemImage: "pencil")
        }
        Button(role: .destructive) { viewModel.deleteFolder(folder.id) } label: {
            Label("删除文件夹", systemImage: "trash")
        }
    }

    #if os(iOS)
    private func folderActionsMenu(_ folder: ConversationFolder) -> some View {
        Menu {
            folderActionItems(folder)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.05), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("文件夹 \(folder.name) 的更多操作")
    }
    #endif

    @ViewBuilder
    private func ungroupedSection(
        conversations convs: [Conversation],
        branchRelativesByID: [UUID: [BranchRelative]]
    ) -> some View {
        if !convs.isEmpty {
            VStack(spacing: 7) {
                groupHeaderLabel(icon: "tray", chevron: nil, name: "未分组", count: convs.count, tint: .secondary)
                ForEach(convs) { conv in
                    conversationRow(conv, branchRelatives: branchRelativesByID[conv.id] ?? [])
                }
            }
        }
    }

    private func groupHeaderLabel(icon: String, chevron: String?, name: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 8) {
            if let chevron {
                Image(systemName: chevron).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            Image(systemName: icon).font(.caption.weight(.semibold)).foregroundStyle(tint)
            Text(name).font(.system(.subheadline, design: .rounded).weight(.bold)).lineLimit(1)
            Text("\(count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var sidebarBackdrop: some View {
        ZStack {
            Color.platformWindowBackground
            LinearGradient(
                colors: [currentModeTint.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            RadialGradient(
                colors: [viewModel.currentMode.kownSecondaryTint.opacity(0.08), Color.clear],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 360
            )
        }
    }

    private var currentModeTint: Color {
        viewModel.currentMode.kownTint
    }

    private var sidebarMinWidth: CGFloat {
        #if os(iOS)
        return 280
        #else
        return 260
        #endif
    }

    /// 把命中片段渲染成带高亮的富文本(命中子串加粗 + 强调色)。
    private func highlightedSnippet(_ hit: ConversationSearchHit) -> Text? {
        guard !hit.snippet.isEmpty else { return nil }
        guard let range = hit.highlight else { return Text(hit.snippet) }
        let pre = String(hit.snippet[hit.snippet.startIndex..<range.lowerBound])
        let match = String(hit.snippet[range])
        let post = String(hit.snippet[range.upperBound..<hit.snippet.endIndex])
        return Text(pre)
            + Text(match).foregroundColor(.accentColor).fontWeight(.semibold)
            + Text(post)
    }
}

/// 把裸 `UUID` 包成 `Identifiable`,供 `.sheet(item:)` 使用(会话系统提示编辑等)。
struct IdentifiedID: Identifiable, Hashable {
    let id: UUID
}
