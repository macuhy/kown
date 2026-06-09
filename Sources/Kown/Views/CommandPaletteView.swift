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
            // 索引重建挪到后台(见 ConversationSearchIndex.rebuild),不卡命令面板的弹出动画。
            Task { await searchIndex.rebuild(viewModel.conversations) }
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
        let active = viewModel.activeConversations
        if q.isEmpty {
            convs = Array(active.prefix(8))
        } else {
            // 全文命中(标题 + 正文)优先;再并上标题直接命中,去重保持顺序。
            // 封顶 8 条:下面对每条 conv 都要 matchingTurn 扫全部轮(无索引子串搜索),
            // 不封顶时大量会话 × 每条全文扫 → 按键卡顿。8 与空 query 的 prefix(8) 对齐。
            let hitIDs = searchIndex.search(q).prefix(8).map(\.id)
            var ordered: [UUID] = Array(hitIDs)
            for c in active where ordered.count < 8
                && c.title.localizedCaseInsensitiveContains(q) && !ordered.contains(c.id) {
                ordered.append(c.id)
            }
            let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
            convs = ordered.compactMap { byID[$0] }
        }
        return convs.map { conv in
            // 搜索态:定位首条命中的轮,subtitle 显示命中片段,点选跳到该轮;否则跳会话。
            let hit = q.isEmpty ? nil : matchingTurn(in: conv, query: q)
            let subtitle = hit?.snippet ?? "\(modeLabel(conv.mode)) · \(conv.turns.count) 轮"
            return Action(icon: conv.mode.symbol, tint: .orange,
                          title: conv.title.isEmpty ? "未命名会话" : conv.title,
                          subtitle: subtitle) {
                if let turnID = hit?.turnID {
                    viewModel.selectConversationAndTurn(conv.id, turnID)
                } else {
                    viewModel.selectConversation(conv.id)
                }
            }
        }
    }

    /// 在会话里找首条包含 query 的轮,返回 (turnID, 命中片段)。扫 prompt / 各回答 / chair / summary / 辩论各轮。
    private func matchingTurn(in conv: Conversation, query: String) -> (turnID: UUID, snippet: String)? {
        for turn in conv.turns {
            var texts: [String] = [turn.prompt]
            texts.append(contentsOf: turn.responses.values)
            if let c = turn.chairSummary { texts.append(c) }
            if let s = turn.summaryText { texts.append(s) }
            if let rounds = turn.debateRounds {
                for r in rounds { texts.append(contentsOf: r.responses.values) }
            }
            for t in texts {
                if let range = t.range(of: query, options: .caseInsensitive) {
                    return (turn.id, Self.snippet(t, around: range))
                }
            }
        }
        return nil
    }

    /// 截取命中词周围一小段上下文用于展示。
    private static func snippet(_ text: String, around range: Range<String.Index>, pad: Int = 24) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -pad, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: pad, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[lower..<upper]).replacingOccurrences(of: "\n", with: " ")
        if lower > text.startIndex { s = "…" + s }
        if upper < text.endIndex { s = s + "…" }
        return s
    }

    private func modeLabel(_ mode: ConversationMode) -> String {
        switch mode {
        case .direct:  return "直接问答"
        case .compare: return "模型对比"
        case .council: return "模型议会"
        case .debate:  return "模型辩论"
        case .structured: return "结构化输出"
        case .tournament: return "模型擂台"
        case .translate: return "翻译 / 改写"
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
