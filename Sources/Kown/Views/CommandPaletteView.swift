import SwiftUI

/// ⌘K 命令面板:一个输入框统一过滤「跳会话 / 切模式 / 切 provider」。
/// 会话跳转复用 `ConversationSearchIndex`(标题 + 正文全文);模式/Provider 为静态动作项。
/// macOS 优先键盘操作:↑/↓ 选,回车执行,Esc 关闭(sheet 自带)。
struct CommandPaletteView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var searchIndex = ConversationSearchIndex()
    @FocusState private var fieldFocused: Bool

    /// 一条可执行动作。
    private struct Action: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String
        let run: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            results
        }
        .frame(minWidth: 460, minHeight: 360)
        .onAppear {
            searchIndex.rebuild(viewModel.conversations)
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    // MARK: - 输入框

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("跳会话 / 切模式 / 切 Provider…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { runSelected() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: - 结果列表

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    let items = filteredActions
                    if items.isEmpty {
                        Text("没有匹配项")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, action in
                        row(action, isSelected: idx == selectedIndex)
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture { execute(action) }
                    }
                }
                .padding(8)
            }
            .onChange(of: selectedIndex) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func row(_ action: Action, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: action.icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(action.tint)
                .frame(width: 30, height: 30)
                .background(action.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if !action.subtitle.isEmpty {
                    Text(action.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
    }

    // MARK: - 动作组装

    private var filteredActions: [Action] {
        modeActions + providerActions + conversationActions
    }

    private func matches(_ text: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || text.localizedCaseInsensitiveContains(q)
    }

    private var modeActions: [Action] {
        ConversationMode.allCases.compactMap { mode in
            let name = modeLabel(mode)
            guard matches(name) || matches("切换模式") else { return nil }
            return Action(icon: mode.symbol, tint: .teal, title: "切换到 \(name)", subtitle: "对话模式") {
                _ = viewModel.switchMode(to: mode)
            }
        }
    }

    /// 仅 Direct / Compare 模式有「选模型」语义;Council / Debate 用全部 enabled,不在此列。
    private var providerActions: [Action] {
        let mode = viewModel.currentMode
        guard mode == .direct || mode == .compare else { return [] }
        let active = Set(viewModel.activeModelChoicesForCurrent.map(\.providerID))
        return viewModel.providers.filter { $0.enabled }.compactMap { p in
            guard matches(p.displayName) || matches(p.model) || matches("provider") else { return nil }
            let on = active.contains(p.id)
            let verb = mode == .direct ? "选用模型" : (on ? "取消对比" : "加入对比")
            return Action(
                icon: on ? "checkmark.circle.fill" : "cpu",
                tint: .blue,
                title: "\(verb) · \(p.displayName)",
                subtitle: p.model
            ) {
                if mode == .direct { viewModel.setDirectProvider(p.id) }
                else { viewModel.toggleCompareProvider(p.id) }
            }
        }
    }

    private var conversationActions: [Action] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let convs: [Conversation]
        if q.isEmpty {
            convs = Array(viewModel.conversations.prefix(8))
        } else {
            // 全文命中(标题 + 正文)优先;再并上标题直接命中,去重保持顺序。
            let hitIDs = searchIndex.search(q).map(\.id)
            var ordered: [UUID] = hitIDs
            for c in viewModel.conversations where c.title.localizedCaseInsensitiveContains(q) && !ordered.contains(c.id) {
                ordered.append(c.id)
            }
            let byID = Dictionary(uniqueKeysWithValues: viewModel.conversations.map { ($0.id, $0) })
            convs = ordered.compactMap { byID[$0] }
        }
        return convs.map { conv in
            Action(icon: conv.mode.symbol, tint: .orange, title: conv.title.isEmpty ? "未命名会话" : conv.title,
                   subtitle: "\(modeLabel(conv.mode)) · \(conv.turns.count) 轮") {
                viewModel.selectConversation(conv.id)
            }
        }
    }

    private func modeLabel(_ mode: ConversationMode) -> String {
        switch mode {
        case .direct:  return "直接问答"
        case .compare: return "模型对比"
        case .council: return "模型议会"
        case .debate:  return "模型辩论"
        }
    }

    // MARK: - 键盘

    private func move(_ delta: Int) {
        let count = filteredActions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func runSelected() {
        let items = filteredActions
        guard items.indices.contains(selectedIndex) else { return }
        execute(items[selectedIndex])
    }

    private func execute(_ action: Action) {
        action.run()
        dismiss()
    }
}
