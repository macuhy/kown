import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: AppViewModel
    let onOpenSettings: () -> Void
    var onSelectConversation: () -> Void = {}
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""
    /// 正在编辑会话系统提示的会话(nil = 未打开)。包一层以满足 `.sheet(item:)` 的 Identifiable。
    @State private var promptEditTarget: IdentifiedID?
    /// 跨会话全文搜索:内存倒排索引,随侧栏生命周期存在,不落盘(重启重建)。
    @State private var searchIndex = ConversationSearchIndex()
    /// 搜索框输入
    @State private var searchText: String = ""

    /// 当前是否处于搜索态
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 搜索命中(会话 id → 片段)。无 query 时为空。
    private var hitsByID: [UUID: ConversationSearchHit] {
        guard isSearching else { return [:] }
        var map: [UUID: ConversationSearchHit] = [:]
        for hit in searchIndex.search(searchText) {
            map[hit.id] = hit
        }
        return map
    }

    /// 过滤后展示的会话:有 query 时按命中过滤并维持原顺序,无 query 维持现状。
    private var displayedConversations: [Conversation] {
        guard isSearching else { return viewModel.conversations }
        let hits = hitsByID
        return viewModel.conversations.filter { hits[$0.id] != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            searchField
            list
        }
        .frame(minWidth: 240)
        .background(sidebarBackdrop)
        // 索引构建:侧栏出现及会话数组变化时全量重建(只在内存)
        .onAppear { searchIndex.rebuild(viewModel.conversations) }
        .onChange(of: viewModel.conversations) { _, newValue in
            searchIndex.rebuild(newValue)
        }
        .sheet(item: $promptEditTarget) { target in
            ConversationPromptSheet(viewModel: viewModel, conversationID: target.id)
        }
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
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

    #if os(iOS)
    private var mobileHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [currentModeTint.opacity(0.95), Color.orange.opacity(0.70)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .shadow(color: currentModeTint.opacity(0.16), radius: 10, x: 0, y: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text("会话库")
                    .font(.headline.weight(.black))
                Text("\(viewModel.conversations.count) 个会话 · \(viewModel.currentMode.displayName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            headerIconButton("gearshape.fill", help: "厂商配置", action: onOpenSettings)
            headerIconButton("square.and.pencil", help: "新建会话") {
                viewModel.newConversation(mode: viewModel.activeMode)
                onSelectConversation()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            ZStack {
                Rectangle().fill(.thinMaterial)
                LinearGradient(
                    colors: [currentModeTint.opacity(0.14), Color.orange.opacity(0.08), Color.clear],
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
    }

    #endif

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
        } else if isSearching && displayedConversations.isEmpty {
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
            let hits = hitsByID
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(displayedConversations) { conv in
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
                                onEditSystemPrompt: { promptEditTarget = IdentifiedID(id: conv.id) }
                            )
                            // 搜索态下,在行下方展示命中片段(带关键词高亮)
                            if let hit = hits[conv.id], let snippet = highlightedSnippet(hit) {
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
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                #if os(iOS)
                .padding(.bottom, 10)
                #endif
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

    private var currentModeTint: Color {
        switch viewModel.currentMode {
        case .council: return Color(red: 0.10, green: 0.66, blue: 0.56)
        case .direct:  return Color(red: 0.16, green: 0.48, blue: 0.94)
        case .compare: return Color(red: 0.91, green: 0.55, blue: 0.20)
        case .debate:  return Color(red: 0.88, green: 0.35, blue: 0.22)
        }
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
