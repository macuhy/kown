import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MainContentView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showSystemPromptDrawer = false
    @FocusState private var inputFocused: Bool
    @Binding var showSettings: Bool
    /// 正在编辑/重发的历史轮(nil = 未打开)。
    @State private var editRequest: EditTurnRequest?
    /// 会话内查找状态。
    @State private var findQuery: String = ""
    @State private var findIndex: Int = 0
    @State private var scrollTarget: UUID?
    @FocusState private var findFocused: Bool
    /// 批量执行 / 提示词队列 sheet 开关。
    @State private var showBatch = false
    #if os(iOS)
    /// iOS 导出时待分享的文件(包成 Identifiable 以驱动 .sheet(item:))。
    @State private var shareSheet: ShareSheetPayload?
    #endif

    var body: some View {
        ZStack {
            MainWorkspaceBackdrop(mode: viewModel.currentMode)
            VStack(spacing: 0) {
                #if os(iOS)
                mobileModeBar
                #else
                desktopSessionHeader
                #endif
                workspacePathBar
                if viewModel.showFind { findBar }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(iOS)
                mobileComposerDock
                #else
                PendingFileWritesView()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                ActiveProviderBar(viewModel: viewModel)
                InputBarView(
                    viewModel: viewModel,
                    showSystemPromptDrawer: $showSystemPromptDrawer,
                    inputFocused: $inputFocused
                )
                #endif
            }
        }
        .navigationTitle(viewModel.selectedConversation?.title ?? "New Conversation")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                sessionActionsMenu
            }
            #endif
        }
        .sheet(isPresented: $showBatch) {
            BatchView(viewModel: viewModel)
        }
        #if os(iOS)
        .sheet(item: $shareSheet) { payload in
            ShareSheet(activityItems: [payload.url])
        }
        #endif
        .sheet(item: $editRequest) { req in
            EditTurnSheet(viewModel: viewModel, turnID: req.id, initialText: req.text)
        }
        .alert("成本预算提醒", isPresented: Binding(
            get: { viewModel.budgetGate != nil },
            set: { if !$0 { viewModel.budgetGate = nil } }
        ), presenting: viewModel.budgetGate) { _ in
            Button("仍要发送", role: .destructive) { viewModel.confirmBudgetAndSend() }
            Button("取消", role: .cancel) { viewModel.budgetGate = nil }
        } message: { gate in
            Text(gate.message)
        }
        .onAppear {
            #if !os(iOS)
            // iOS 上不 auto-focus(避免 NavigationStack push 动画与 @FocusState 抢占),
            // 让用户点输入框自然唤起键盘
            inputFocused = true
            #endif
        }
        .onChange(of: viewModel.showFind) { _, showing in
            if showing {
                DispatchQueue.main.async { findFocused = true }
            } else {
                findQuery = ""
                findFocused = false
            }
        }
    }

    #if !os(iOS)
    private var desktopSessionHeader: some View {
        let mode = viewModel.currentMode
        let tint = mode.kownTint
        let turnCount = viewModel.selectedConversation?.turns.count ?? 0
        let providerCount = viewModel.providersForCurrentSend().panel.count
        return HStack(spacing: 14) {
            KownModeMark(mode: mode, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(viewModel.selectedConversation?.title ?? "New Conversation")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .lineLimit(1)
                    Text(mode.displayName)
                        .font(.caption.weight(.black))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.11), in: Capsule())
                }
                Text(mode.kownModeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            headerMetric("\(turnCount)", label: "Turns", tint: tint)
            headerMetric("\(providerCount)", label: "Models", tint: providerCount == 0 ? .orange : tint)
            if viewModel.isRunning {
                headerMetric("Live", label: "Running", tint: .green)
            }
            HStack(spacing: 8) {
                desktopHeaderButton(viewModel.showFind ? "xmark" : "magnifyingglass", tint: tint, help: "会话内查找") {
                    withAnimation(.easeInOut(duration: 0.18)) { viewModel.showFind.toggle() }
                }
                desktopHeaderButton("command", tint: tint, help: "命令面板") {
                    viewModel.showCommandPalette = true
                }
                desktopHeaderButton("square.and.pencil", tint: tint, filled: true, help: "新建会话") {
                    viewModel.newConversation(mode: viewModel.currentMode)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background {
            ZStack {
                Rectangle().fill(.thinMaterial)
                LinearGradient(
                    colors: [tint.opacity(0.11), mode.kownSecondaryTint.opacity(0.05), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(tint.opacity(0.12)).frame(height: 1)
        }
    }

    private func headerMetric(_ value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.caption.weight(.black))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
    }

    private func desktopHeaderButton(
        _ symbol: String,
        tint: Color,
        filled: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(filled ? Color.white : tint)
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(filled ? tint : Color.platformControlBackground.opacity(0.58))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(filled ? Color.white.opacity(0.24) : tint.opacity(0.16), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }
    #endif

    // MARK: - 会话内查找

    /// 当前会话里命中 query 的 turn id 列表(在 prompt / 各回答 / chair / summary 里找)。
    private var findMatches: [UUID] {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 1, let turns = viewModel.selectedConversation?.turns else { return [] }
        return turns.filter { turn in
            if turn.prompt.lowercased().contains(q) { return true }
            if turn.responses.values.contains(where: { $0.lowercased().contains(q) }) { return true }
            if (turn.chairSummary ?? "").lowercased().contains(q) { return true }
            if (turn.summaryText ?? "").lowercased().contains(q) { return true }
            return false
        }.map(\.id)
    }

    private var findBar: some View {
        let matches = findMatches
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                findInput
                findControls(matches: matches)
            }
            VStack(spacing: 7) {
                findInput
                HStack {
                    Spacer(minLength: 0)
                    findControls(matches: matches)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var findInput: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("在本会话内查找", text: $findQuery)
                .textFieldStyle(.plain)
                .focused($findFocused)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .onChange(of: findQuery) { _, _ in
                    findIndex = 0
                    if let first = findMatches.first { scrollTarget = first }
                }
                .onSubmit { jumpFind(+1, findMatches) }
            if !findQuery.isEmpty {
                Button {
                    findQuery = ""
                    findFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("清空查找关键词")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.platformControlBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(minWidth: 160)
    }

    private func findControls(matches: [UUID]) -> some View {
        HStack(spacing: 6) {
            Text(findStatus(matches: matches))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 54, alignment: .trailing)
            Button { jumpFind(-1, matches) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(matches.isEmpty)
                .accessibilityLabel("上一处匹配")
            Button { jumpFind(+1, matches) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(matches.isEmpty)
                .accessibilityLabel("下一处匹配")
            Button { closeFind() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭会话内查找")
        }
    }

    private func findStatus(matches: [UUID]) -> String {
        if findQuery.isEmpty { return "" }
        if matches.isEmpty { return "无匹配" }
        return "\(min(findIndex + 1, matches.count))/\(matches.count)"
    }

    private func jumpFind(_ delta: Int, _ matches: [UUID]) {
        guard !matches.isEmpty else { return }
        findIndex = (findIndex + delta + matches.count) % matches.count
        scrollTarget = matches[findIndex]
    }

    private func closeFind() {
        viewModel.showFind = false
        findQuery = ""
        findFocused = false
    }

    /// 打开「编辑并重发」sheet,初值用该轮原始 prompt。
    private func requestEdit(_ turnID: UUID) {
        guard let t = viewModel.selectedConversation?.turns.first(where: { $0.id == turnID }) else { return }
        editRequest = EditTurnRequest(id: turnID, text: t.prompt)
    }

    /// 追问:聚焦输入框继续在该轮结论之上提问。若该轮不是最新轮,先分支再聚焦。
    private func requestFollowUp(_ turnID: UUID) {
        if let conv = viewModel.selectedConversation, conv.turns.last?.id != turnID {
            viewModel.forkConversation(fromTurnID: turnID)
        }
        inputFocused = true
    }

    /// 导出单轮报告:复用整会话导出的存盘 / 分享管线。
    private func exportTurnReport(_ turnID: UUID) {
        guard let report = viewModel.turnReport(turnID: turnID) else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = report.fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? report.text.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(report.fileName)
        try? report.text.data(using: .utf8)?.write(to: url, options: .atomic)
        shareSheet = ShareSheetPayload(url: url)
        #endif
    }

    /// 复制单轮为图片(并排各模型回答)到剪贴板。
    private func shareTurnImage(_ turnID: UUID) {
        guard let conv = viewModel.selectedConversation,
              let turn = conv.turns.first(where: { $0.id == turnID }) else { return }
        AnswerImageExporter.copyTurnToClipboard(turn: turn, mode: conv.mode)
    }

    /// 复制整会话为一张长图到剪贴板。
    private func shareSessionImage() {
        guard let conv = viewModel.selectedConversation else { return }
        AnswerImageExporter.copySessionToClipboard(conversation: conv)
    }

    // MARK: - 整会话导出

    #if os(iOS)
    private var sessionActionsMenu: some View {
        Menu {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    viewModel.showFind.toggle()
                    if !viewModel.showFind { findQuery = "" }
                }
            } label: {
                Label(viewModel.showFind ? "关闭会话内查找" : "会话内查找",
                      systemImage: viewModel.showFind ? "xmark.circle" : "magnifyingglass")
            }
            Button {
                showBatch = true
            } label: {
                Label("批量执行 / 提示词队列", systemImage: "square.grid.3x3.fill.square")
            }
            Divider()
            exportMenuItems(conversation: viewModel.selectedConversation)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(viewModel.currentMode.kownTint.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("会话操作")
    }
    #endif

    @ViewBuilder
    private func exportMenuItems(conversation conv: Conversation?) -> some View {
        ForEach(ConversationExporter.Format.allCases, id: \.self) { format in
            Button {
                if let conv { export(conv, as: format) }
            } label: {
                Label(format.menuTitle, systemImage: format.symbol)
            }
            .disabled(conv == nil)
        }
        Divider()
        Button {
            shareSessionImage()
        } label: {
            Label("复制整会话为图片", systemImage: "photo.on.rectangle.angled")
        }
        .disabled(conv?.turns.isEmpty != false)
        Button {
            if let conv { exportSessionPDF(conv) }
        } label: {
            Label("导出会话为 PDF", systemImage: "doc.richtext")
        }
        .disabled(conv?.turns.isEmpty != false)
        Button {
            if let conv { Platform.copyText(ConversationExporter.markdown(for: conv)) }
        } label: {
            Label("复制为 Markdown", systemImage: "doc.on.doc")
        }
        .disabled(conv == nil)
        Button {
            let all = ConversationExporter.markdownForAll(viewModel.activeConversations)
            saveText(all, fileName: "Kown-全部会话.md")
        } label: {
            Label("导出全部会话(Markdown)", systemImage: "tray.full")
        }
        .disabled(viewModel.conversations.isEmpty)
    }

    /// 把会话导出成指定格式:复用 saveText 的存盘 / 分享管线。
    private func export(_ conversation: Conversation, as format: ConversationExporter.Format) {
        saveText(ConversationExporter.text(for: conversation, format: format),
                 fileName: ConversationExporter.suggestedFileName(for: conversation, format: format))
    }

    /// 导出当前会话为多页 PDF(矢量、全文),复用 saveData 的存盘 / 分享管线。
    /// sessionPDF 现在是 async(块之间让出主线程),包进 Task 里跑,导出期间 UI 不卡死。
    private func exportSessionPDF(_ conversation: Conversation) {
        Task { @MainActor in
            guard let pdf = await AnswerImageExporter.sessionPDF(conversation: conversation) else { return }
            let safeTitle = conversation.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let name = safeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Kown 会话" : safeTitle
            saveData(pdf, fileName: "\(name).pdf")
        }
    }

    /// 存二进制到文件:macOS 弹 NSSavePanel,iOS 落临时文件后系统分享(PDF / 图片等)。
    private func saveData(_ data: Data, fileName: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? data.write(to: url, options: .atomic)
        shareSheet = ShareSheetPayload(url: url)
        #endif
    }

    /// 存文本到文件:macOS 弹 NSSavePanel,iOS 落临时文件后系统分享。整会话 / 全部 / 单轮报告共用。
    private func saveText(_ text: String, fileName: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        shareSheet = ShareSheetPayload(url: url)
        #endif
    }

    /// 「继续生成」按钮 — 让模型接着上一轮回答继续(回答被截断时尤其有用)。
    private var continueButton: some View {
        HStack {
            Spacer()
            Button { viewModel.continueGenerating() } label: {
                Label("继续生成", systemImage: "arrow.down.circle")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
            Spacer()
        }
        .padding(.vertical, 6)
    }

    /// 追问建议:无建议时显示「追问建议」按钮(按需生成);有建议时列出可点的追问 chips。
    @ViewBuilder
    private var followUpBar: some View {
        if viewModel.followUpSuggestions.isEmpty {
            VStack(spacing: 6) {
                HStack {
                    Spacer()
                    Button { viewModel.suggestFollowUps() } label: {
                        Label(viewModel.suggestingFollowUps ? "生成中…" : "追问建议", systemImage: "sparkles")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .disabled(viewModel.suggestingFollowUps)
                    Spacer()
                }
                if let err = viewModel.followUpError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }
            }
            .padding(.bottom, 6)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.followUpSuggestions, id: \.self) { q in
                    Button { viewModel.askFollowUp(q) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(modeTint)
                            Text(q)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 6)
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(modeTint.opacity(0.7))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(modeTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(modeTint.opacity(0.18), lineWidth: 1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    /// 答案质量增强:自我反思修订 + 事实核查。作用于当前会话最后一轮。
    /// 没结果时显示按钮(按需触发);有结果时展示对应卡片。
    @ViewBuilder
    private var qualityBar: some View {
        if let turn = viewModel.selectedConversation?.turns.last {
            VStack(alignment: .leading, spacing: 10) {
                let revising = viewModel.isRevising(turnID: turn.id)
                let checking = viewModel.isFactChecking(turnID: turn.id)

                if turn.selfRevision == nil || turn.factCheck == nil {
                    HStack(spacing: 10) {
                        if turn.selfRevision == nil {
                            Button { viewModel.reviseTurn(turnID: turn.id) } label: {
                                Label(revising ? "反思中…" : "自我反思", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                            }
                            .buttonStyle(.bordered).clipShape(Capsule())
                            .disabled(revising)
                        }
                        if turn.factCheck == nil {
                            Button { viewModel.factCheckTurn(turnID: turn.id) } label: {
                                Label(checking ? "核查中…" : "事实核查", systemImage: "checkmark.shield")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                            }
                            .buttonStyle(.bordered).clipShape(Capsule())
                            .disabled(checking)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if let err = viewModel.revisionErrors[turn.id] {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
                if let err = viewModel.factCheckErrors[turn.id] {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
                if let revision = turn.selfRevision {
                    SelfRevisionCard(revision: revision,
                                     providerName: turn.providerSnapshot[revision.providerID]?.displayName)
                }
                if let factCheck = turn.factCheck {
                    FactCheckCard(result: factCheck,
                                  providerName: turn.providerSnapshot[factCheck.providerID]?.displayName)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        let conv = viewModel.selectedConversation
        let hasTurns = conv?.turns.isEmpty == false
        let hasLive = viewModel.liveTurnPrompt != nil
        if !hasTurns && !hasLive && viewModel.currentMode == .structured {
            // Structured 模式即使还没有任何 turn,也要让用户先编辑 / 校验 JSON Schema。
            ScrollView {
                StructuredTurnsView(
                    viewModel: viewModel,
                    conversation: conv ?? Conversation(),
                    liveStates: [:],
                    livePrompt: nil,
                    livePanel: viewModel.providersForCurrentSend().panel,
                    onEditTurn: { requestEdit($0) },
                    onFollowUpTurn: { requestFollowUp($0) },
                    onExportTurn: { exportTurnReport($0) },
                    onShareTurn: { shareTurnImage($0) }
                )
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.bottom, 10, for: .scrollContent)
            #endif
        } else if !hasTurns && !hasLive {
            ScrollView {
                EmptyStateCard(
                    mode: viewModel.currentMode,
                    providers: viewModel.providers,
                    onOpenSettings: { showSettings = true },
                    onUseScenario: { s in
                        viewModel.startScenario(mode: s.mode, systemPrompt: s.systemPrompt)
                        inputFocused = true
                    }
                )
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.bottom, 10, for: .scrollContent)
            #endif
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // 当前会话 == 正在跑的会话 时才把直播 state 透给 TurnsView。
                    // 否则用户切到别的会话只看历史,后台任务继续跑(切回原会话自然又看到直播)。
                    let showLive = viewModel.runningConvID == conv?.id
                    let lStates = showLive ? viewModel.liveStates : [:]
                    let lChair = showLive ? viewModel.liveChairState : nil
                    let lSummary = showLive ? viewModel.liveSummaryState : nil
                    let lPrompt = showLive ? viewModel.liveTurnPrompt : nil
                    let lImages = showLive ? viewModel.liveTurnImages : []
                    let lDebateRounds = showLive ? viewModel.liveDebateRounds : []
                    let lTournamentRounds = showLive ? viewModel.liveTournamentRounds : []
                    let lIsRunning = showLive && viewModel.isRunning
                    Group {
                        switch viewModel.currentMode {
                        case .council:
                            CouncilTurnsView(
                                viewModel: viewModel,
                                conversation: conv ?? Conversation(),
                                liveStates: lStates,
                                liveChairState: lChair,
                                liveSummaryState: lSummary,
                                livePrompt: lPrompt,
                                liveImages: lImages,
                                isRunning: lIsRunning,
                                livePanel: viewModel.providersForCurrentSend().panel,
                                liveChair: viewModel.chairProvider,
                                liveSummary: viewModel.summaryProvider,
                                onEditTurn: { requestEdit($0) },
                                onFollowUpTurn: { requestFollowUp($0) },
                                onExportTurn: { exportTurnReport($0) },
                                onShareTurn: { shareTurnImage($0) }
                            )
                        case .direct:
                            DirectTurnsView(
                                conversation: conv ?? Conversation(),
                                liveStates: lStates,
                                livePrompt: lPrompt,
                                liveImages: lImages,
                                livePanel: viewModel.providersForCurrentSend().panel,
                                onForkTurn: { viewModel.forkConversation(fromTurnID: $0) },
                                onEditTurn: { requestEdit($0) },
                                onFollowUpTurn: { requestFollowUp($0) },
                                onExportTurn: { exportTurnReport($0) },
                                onShareTurn: { shareTurnImage($0) },
                                regenerateProviders: viewModel.regenerateCandidates,
                                onRegenerate: { viewModel.regenerateDirectWithModel(turnID: $0, newProviderID: $1) },
                                onUndoWrite: { viewModel.undoWrite(turnID: $0, write: $1) },
                                onEscalateStronger: { viewModel.escalateToStrongerModel(turnID: $0) },
                                onEscalateCouncil: { viewModel.escalateToCouncil(turnID: $0) }
                            )
                        case .compare:
                            CompareTurnsView(
                                viewModel: viewModel,
                                conversation: conv ?? Conversation(),
                                liveStates: lStates,
                                liveChairState: lChair,
                                livePrompt: lPrompt,
                                liveImages: lImages,
                                livePanel: viewModel.providersForCurrentSend().panel,
                                liveChair: viewModel.providersForCurrentSend().chair,
                                onEditTurn: { requestEdit($0) },
                                onFollowUpTurn: { requestFollowUp($0) },
                                onExportTurn: { exportTurnReport($0) },
                                onShareTurn: { shareTurnImage($0) }
                            )
                        case .debate:
                            DebateTurnsView(
                                viewModel: viewModel,
                                conversation: conv ?? Conversation(),
                                liveStates: lStates,
                                liveChairState: lChair,
                                liveDebateRounds: lDebateRounds,
                                livePrompt: lPrompt,
                                liveImages: lImages,
                                isRunning: lIsRunning,
                                livePanel: viewModel.providersForCurrentSend().panel,
                                liveChair: viewModel.chairProvider,
                                onEditTurn: { requestEdit($0) },
                                onFollowUpTurn: { requestFollowUp($0) },
                                onExportTurn: { exportTurnReport($0) },
                                onShareTurn: { shareTurnImage($0) }
                            )
                        case .structured:
                            StructuredTurnsView(
                                viewModel: viewModel,
                                conversation: conv ?? Conversation(),
                                liveStates: lStates,
                                livePrompt: lPrompt,
                                liveImages: lImages,
                                livePanel: viewModel.providersForCurrentSend().panel,
                                onEditTurn: { requestEdit($0) },
                                onFollowUpTurn: { requestFollowUp($0) },
                                onExportTurn: { exportTurnReport($0) },
                                onShareTurn: { shareTurnImage($0) }
                            )
                        case .tournament:
                            TournamentTurnsView(
                                viewModel: viewModel,
                                conversation: conv ?? Conversation(),
                                liveStates: lStates,
                                liveTournamentRounds: lTournamentRounds,
                                livePrompt: lPrompt,
                                liveImages: lImages,
                                isRunning: lIsRunning,
                                livePanel: viewModel.providersForCurrentSend().panel,
                                onEditTurn: { requestEdit($0) },
                                onFollowUpTurn: { requestFollowUp($0) },
                                onExportTurn: { exportTurnReport($0) },
                                onShareTurn: { shareTurnImage($0) }
                            )
                        }
                        if hasTurns, !(viewModel.runningConvID == conv?.id && viewModel.isRunning) {
                            continueButton
                            qualityBar
                            followUpBar
                        }
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .onChange(of: viewModel.liveTurnPrompt) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                }
                // 全局搜索跳转:命令面板先切会话并置 pendingScrollTurnID,这里监听后滚到对应轮。
                // 切会话后新内容需要一帧布局,稍延后再滚,避免目标 turn 还没渲染。
                .onChange(of: viewModel.pendingScrollTurnID) { _, target in
                    guard let target else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                        viewModel.pendingScrollTurnID = nil
                    }
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                .contentMargins(.bottom, 14, for: .scrollContent)
                #endif
                .overlay(alignment: .bottomTrailing) {
                    if shouldOfferJumpToBottom(conversation: conv, hasLive: hasLive) {
                        jumpToBottomButton {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                    }
                }
            }
        }
    }

    private func shouldOfferJumpToBottom(conversation: Conversation?, hasLive: Bool) -> Bool {
        (conversation?.turns.count ?? 0) >= 3 || hasLive
    }

    private func jumpToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("到底部", systemImage: "arrow.down.to.line.compact")
                .font(.caption.weight(.bold))
                .foregroundStyle(modeTint)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(modeTint.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: modeTint.opacity(0.14), radius: 14, x: 0, y: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("跳到会话底部")
    }

    /// Workspace 路径条 — 设置了 working folder 时在会话顶端显示完整路径。
    /// 点击在 Finder 里展开;✕ 解除 workspace。
    @ViewBuilder
    private var workspacePathBar: some View {
        if let path = viewModel.currentWorkspaceDisplayPath {
            let tint = viewModel.currentMode.kownTint
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text("Workspace")
                        .font(.caption2.weight(.black))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                #if os(macOS)
                Button {
                    let url = URL(fileURLWithPath: path)
                    Platform.revealInExplorer(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .help("在 Finder 里打开")
                #endif
                Button {
                    viewModel.clearWorkspace()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.04), in: Circle())
                }
                .buttonStyle(.plain)
                .help("移除 workspace")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.10), Color.clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tint.opacity(0.18), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            #if os(iOS)
            .padding(.vertical, 6)
            #else
            .padding(.vertical, 8)
            #endif
            .background {
                Rectangle().fill(.thinMaterial)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            }
        }
    }

    private var modeTint: Color {
        viewModel.currentMode.kownTint
    }

    #if os(iOS)
    private var mobileModeBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ModeTabsView(viewModel: viewModel)
            HStack(spacing: 5) {
                Text("当前")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(modeTint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(modeTint.opacity(0.12), in: Capsule())
                Text("\(viewModel.currentMode.displayName) · \(viewModel.currentMode.kownModeDescription)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前模式 \(viewModel.currentMode.displayName)，\(viewModel.currentMode.kownModeDescription)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        modeTint.opacity(0.08),
                        viewModel.currentMode.kownSecondaryTint.opacity(viewModel.currentMode == .debate ? 0.05 : 0.02),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }

    private var mobileComposerDock: some View {
        VStack(spacing: 0) {
            ActiveProviderBar(viewModel: viewModel)
            InputBarView(
                viewModel: viewModel,
                showSystemPromptDrawer: $showSystemPromptDrawer,
                inputFocused: $inputFocused
            )
        }
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [modeTint.opacity(0.10), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }
    #endif
}

/// 编辑/重发请求 — 携带目标轮 id 与初始文本,Identifiable 以驱动 .sheet(item:)。
struct EditTurnRequest: Identifiable {
    let id: UUID
    let text: String
}

#if os(iOS)
/// iOS 导出分享用的载荷 — 包一个临时文件 URL,Identifiable 以驱动 .sheet(item:)。
private struct ShareSheetPayload: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController 的 SwiftUI 封装(iOS 系统分享面板)。
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

private struct MainWorkspaceBackdrop: View {
    let mode: ConversationMode

    var body: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [mode.kownTint.opacity(0.17), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 560
            )
            RadialGradient(
                colors: [mode.kownSecondaryTint.opacity(mode == .debate ? 0.16 : 0.10), Color.clear],
                center: .bottomTrailing,
                startRadius: 80,
                endRadius: 620
            )
            LinearGradient(
                colors: [Color.white.opacity(0.035), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

}
