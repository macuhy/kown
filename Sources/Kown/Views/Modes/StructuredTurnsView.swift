import SwiftUI

/// Structured 模式:顶部一个 JSON Schema 编辑器,下面每个 turn = 用户问题 +
/// 各启用模型按 schema 返回的「结构化 JSON」并排对照。每张卡片自带校验(剥围栏 → 解析 →
/// 必须键检查),解析失败回退展示原文 + 错误角标。
struct StructuredTurnsView: View {
    @Bindable var viewModel: AppViewModel
    let conversation: Conversation
    let liveStates: [UUID: ResponseState]
    let livePrompt: String?
    var liveImages: [TurnImage] = []
    let livePanel: [ProviderConfig]
    /// 历史 turn 的编辑 / 追问 / 导出 / 分享动作(由父视图注入)。
    var onEditTurn: ((UUID) -> Void)? = nil
    var onFollowUpTurn: ((UUID) -> Void)? = nil
    var onExportTurn: ((UUID) -> Void)? = nil
    var onShareTurn: ((UUID) -> Void)? = nil

    @State private var collapsedTurns: Set<UUID> = []
    @State private var schemaDraft: String = ""
    @State private var schemaLoadedForConv: UUID?
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var stacksVertically: Bool {
        #if os(iOS)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }

    private var turnSpacing: CGFloat { stacksVertically ? 16 : 22 }
    private var horizontalPadding: CGFloat { stacksVertically ? 10 : 18 }
    private var verticalPadding: CGFloat { stacksVertically ? 12 : 18 }

    private var structuredTint: Color {
        Color(red: 0.36, green: 0.42, blue: 0.92)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: turnSpacing) {
            schemaEditorCard
            ForEach(conversation.turns) { turn in
                // 显式稳定身份:切换会话时 conversation 整体替换,靠 turn.id 让 SwiftUI 做增量 diff,避免全量重建。
                historicalTurn(turn)
                    .id(turn.id)
                // 「全新上下文」截断点:分隔线提示以上轮次不再随请求发送,可点击撤销。
                if conversation.contextCutoffTurnID == turn.id {
                    ContextCutoffDivider { viewModel.clearContextCutoff() }
                }
            }
            if let livePrompt {
                liveTurn(prompt: livePrompt)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .onAppear { loadSchemaIfNeeded() }
        .onChange(of: conversation.id) { _, _ in loadSchemaIfNeeded(force: true) }
    }

    /// 切会话 / 首次出现时,把会话里的 schema 灌进编辑草稿。
    private func loadSchemaIfNeeded(force: Bool = false) {
        if force || schemaLoadedForConv != conversation.id {
            schemaDraft = conversation.structuredSchema ?? StructuredOutput.defaultSchema
            schemaLoadedForConv = conversation.id
        }
    }

    // MARK: - Schema 编辑器

    private var schemaEditorCard: some View {
        ModeTurnCard(
            title: "JSON Schema",
            subtitle: "定义结构,各模型将严格按此返回 JSON",
            icon: "curlybraces",
            tint: structuredTint
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // 预设模板
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(StructuredOutput.presets) { preset in
                            Button {
                                schemaDraft = preset.schema
                                viewModel.setStructuredSchema(preset.schema)
                            } label: {
                                Text(preset.title)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(structuredTint.opacity(0.12), in: Capsule())
                                    .overlay { Capsule().strokeBorder(structuredTint.opacity(0.22), lineWidth: 1) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }

                // schema 文本编辑器
                TextEditor(text: $schemaDraft)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 260)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.platformControlBackground.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(structuredTint.opacity(0.20), lineWidth: 1)
                    }
                    .onChange(of: schemaDraft) { _, newValue in
                        viewModel.setStructuredSchema(newValue)
                    }

                // 实时合法性提示
                schemaStatusBar
            }
        }
    }

    @ViewBuilder
    private var schemaStatusBar: some View {
        if let err = viewModel.structuredSchemaError ?? StructuredOutput.schemaError(schemaDraft) {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let keys = StructuredOutput.requiredTopLevelKeys(from: schemaDraft)
            Label("Schema 合法" + (keys.isEmpty ? "" : " · 顶层字段:\(keys.joined(separator: "、"))"),
                  systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 历史轮

    private func historicalTurn(_ turn: Turn) -> some View {
        let isCollapsed = collapsedTurns.contains(turn.id)
        let schema = conversation.structuredSchema ?? StructuredOutput.defaultSchema
        return ModeTurnCard(
            title: "Structured",
            subtitle: isCollapsed ? TurnFold.preview(turn) : "各模型按 schema 返回 JSON,已自动校验",
            icon: "curlybraces",
            tint: structuredTint,
            collapsed: isCollapsed,
            onToggleCollapse: { TurnFold.toggle(turn.id, in: &collapsedTurns) }
        ) {
            PromptBubble(prompt: turn.prompt, timestamp: turn.timestamp, images: turn.images ?? [],
                         onFork: { viewModel.forkConversation(fromTurnID: turn.id) },
                         onEdit: onEditTurn.map { f in { f(turn.id) } },
                         onFollowUp: onFollowUpTurn.map { f in { f(turn.id) } },
                         onExportReport: onExportTurn.map { f in { f(turn.id) } },
                         onShareImage: onShareTurn.map { f in { f(turn.id) } })
            panelGrid(count: turn.orderedPanelConfigs.count) {
                ForEach(turn.orderedPanelConfigs) { cfg in
                    let key = cfg.id.uuidString
                    StructuredResultCard(
                        config: cfg,
                        rawText: turn.responses[key] ?? "",
                        error: turn.errors[key],
                        streaming: false,
                        schema: schema,
                        tint: accentColor(cfg),
                        symbol: providerSymbol(cfg),
                        onRetry: turn.errors[key] != nil ? {
                            viewModel.retryProvider(turnID: turn.id, configID: cfg.id)
                        } : nil,
                        isRetrying: viewModel.isRetrying(turnID: turn.id, configID: cfg.id)
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func liveTurn(prompt: String) -> some View {
        let schema = conversation.structuredSchema ?? StructuredOutput.defaultSchema
        return ModeTurnCard(
            title: "Structured",
            subtitle: "\(livePanel.count) 个模型正在生成结构化结果",
            icon: "curlybraces",
            tint: structuredTint,
            isLive: true
        ) {
            PromptBubble(prompt: prompt, timestamp: Date(), images: liveImages)
            panelGrid(count: livePanel.count) {
                ForEach(livePanel) { cfg in
                    if let state = liveStates[cfg.id] {
                        StructuredResultCard(
                            config: cfg,
                            rawText: state.text,
                            error: errorMessage(state.phase),
                            streaming: isStreaming(state.phase),
                            schema: schema,
                            tint: accentColor(cfg),
                            symbol: providerSymbol(cfg)
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func panelGrid<Content: View>(count: Int, @ViewBuilder content: () -> Content) -> some View {
        if stacksVertically {
            VStack(alignment: .leading, spacing: 14) { content() }
        } else {
            AdaptivePanelGrid(minColumnWidth: 460, count: count) { content() }
        }
    }

    // MARK: - 小工具

    private func isStreaming(_ phase: ResponsePhase) -> Bool {
        if case .streaming = phase { return true }
        return false
    }

    private func errorMessage(_ phase: ResponsePhase) -> String? {
        if case .failed(let m) = phase { return m }
        return nil
    }

    private func accentColor(_ cfg: ProviderConfig) -> Color {
        switch cfg.kind {
        case .openAICompatible: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .anthropic:        return Color(red: 0.83, green: 0.38, blue: 0.18)
        case .gemini:           return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .cliCommand:       return Color(red: 0.55, green: 0.45, blue: 0.78)
        case .appleFM:          return Color(red: 0.78, green: 0.40, blue: 0.86)
        }
    }

    private func providerSymbol(_ cfg: ProviderConfig) -> String {
        switch cfg.kind {
        case .openAICompatible: return "sparkles"
        case .anthropic:        return "text.book.closed"
        case .gemini:           return "diamond.fill"
        case .cliCommand:       return "terminal"
        case .appleFM:          return "apple.logo"
        }
    }
}

/// 单个模型的结构化结果卡片:头部模型名 + 校验角标;主体为美化后的 JSON(成功)或原文(失败兜底)。
private struct StructuredResultCard: View {
    let config: ProviderConfig
    let rawText: String
    let error: String?
    let streaming: Bool
    let schema: String
    let tint: Color
    let symbol: String
    var onRetry: (() -> Void)? = nil
    var isRetrying: Bool = false
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var isCompact: Bool {
        #if os(iOS)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }

    private var validation: StructuredOutput.ValidationResult? {
        // 流式过程中不校验(JSON 还没拼完),只在完成且有内容时算。
        guard !streaming, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return StructuredOutput.validate(responseText: rawText, schema: schema)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let onRetry {
                    Button { onRetry() } label: {
                        Label(isRetrying ? "重试中…" : "重试", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRetrying)
                }
            } else if streaming {
                Text(rawText.isEmpty ? "正在生成 JSON…" : rawText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(rawText.isEmpty ? .tertiary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else if let v = validation {
                resultBody(v)
            } else {
                Text("(空响应)")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.platformControlBackground.opacity(0.55))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 1)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                providerGlyph
                VStack(alignment: .leading, spacing: 1) {
                    Text(config.displayName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Text(config.model)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                statusBadge
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    providerGlyph
                    Text(config.displayName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    statusBadge
                }
                Text(config.model)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var providerGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.5)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: isCompact ? 24 : 26, height: isCompact ? 24 : 26)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if streaming {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("生成中")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .fixedSize()
        } else if error != nil {
            badge("失败", color: .red, symbol: "xmark.octagon.fill")
        } else if let v = validation {
            if v.isValid {
                badge("JSON 有效", color: .green, symbol: "checkmark.seal.fill")
            } else {
                badge("校验未通过", color: .orange, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func badge(_ text: String, color: Color, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }

    @ViewBuilder
    private func resultBody(_ v: StructuredOutput.ValidationResult) -> some View {
        // 校验未通过(JSON 解析失败或缺键)时,先给一条警告,再尽量展示已解析/原始内容。
        if !v.isValid, let err = v.error {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        let shown = v.prettyJSON ?? rawText
        ScrollView(.horizontal, showsIndicators: false) {
            Text(shown)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button {
                Platform.copyText(shown)
            } label: {
                Label("复制 JSON", systemImage: "doc.on.doc")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }
}
