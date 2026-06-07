import SwiftUI

/// Direct 模式：ChatGPT 风格的竖向气泡列表
struct DirectTurnsView: View {
    let conversation: Conversation
    let liveStates: [UUID: ResponseState]
    let livePrompt: String?
    var liveImages: [TurnImage] = []
    let livePanel: [ProviderConfig]
    /// 历史 turn 的分支/编辑/追问/导出动作(由持有 viewModel 的父视图注入)。
    var onForkTurn: ((UUID) -> Void)? = nil
    var onEditTurn: ((UUID) -> Void)? = nil
    var onFollowUpTurn: ((UUID) -> Void)? = nil
    var onExportTurn: ((UUID) -> Void)? = nil
    var onShareTurn: ((UUID) -> Void)? = nil
    /// 「换模型重答」候选 + 回调(turnID, 新 providerID)。
    var regenerateProviders: [ProviderConfig] = []
    var onRegenerate: ((UUID, UUID) -> Void)? = nil
    /// 撤销某轮的 workspace 写入(turnID, write)。
    var onUndoWrite: ((UUID, AppliedWrite) -> Void)? = nil
    /// 自动升级建议:换更强模型重答 / 转 Council 重答(turnID)。
    var onEscalateStronger: ((UUID) -> Void)? = nil
    var onEscalateCouncil: ((UUID) -> Void)? = nil

    @State private var collapsedTurns: Set<UUID> = []
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(conversation.turns) { turn in
                historicalTurn(turn)
            }
            if let livePrompt {
                liveTurn(prompt: livePrompt)
            }
        }
        .padding(.horizontal, listHorizontalPadding)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }

    private func historicalTurn(_ turn: Turn) -> some View {
        let isCollapsed = collapsedTurns.contains(turn.id)
        return directTurnShell(
            isLive: false,
            collapsed: isCollapsed,
            collapsedPreview: TurnFold.preview(turn),
            onToggleCollapse: { TurnFold.toggle(turn.id, in: &collapsedTurns) }
        ) {
            userBubble(prompt: turn.prompt, timestamp: turn.timestamp, images: turn.images ?? [],
                       onFork: onForkTurn.map { f in { f(turn.id) } },
                       onEdit: onEditTurn.map { f in { f(turn.id) } },
                       onFollowUp: onFollowUpTurn.map { f in { f(turn.id) } },
                       onExportReport: onExportTurn.map { f in { f(turn.id) } },
                       onShareImage: onShareTurn.map { f in { f(turn.id) } })
            if isImageComparisonTurn(turn) {
                GeneratedImageComparison(
                    order: turn.panelOrder,
                    snapshot: turn.providerSnapshot,
                    imagesByProvider: turn.generatedImagesByProvider ?? [:],
                    errors: turn.imageGenErrors ?? [:]
                )
            } else {
                // 历史回看:有留痕的工具步骤树就展示(深入模式 / 带工具的回答)。
                if let steps = turn.toolSteps, !steps.isEmpty {
                    AgentStepsView(steps: steps)
                }
                if let cfg = turn.orderedPanelConfigs.first {
                    let key = cfg.id.uuidString
                    assistantBubble(
                        config: cfg,
                        text: turn.responses[key] ?? "",
                        error: turn.errors[key],
                        streaming: false,
                        reasoning: turn.reasoningByProvider?[key],
                        tokenUsage: turn.tokenUsage?[key],
                        showActions: true,
                        sources: turn.sourcesByProvider?[key] ?? (turn.sources ?? []),
                        knowledgeSources: turn.knowledgeSources ?? [],
                        onRegenerate: onRegenerate.map { f in { pid in f(turn.id, pid) } }
                    )
                }
                if let gen = turn.generatedImages, !gen.isEmpty {
                    ConversationImagesRow(images: gen)
                }
            }
            if let writes = turn.appliedWrites, !writes.isEmpty {
                AppliedWritesStrip(writes: writes, onUndo: onUndoWrite.map { cb in { cb(turn.id, $0) } })
            }
            if let suggestion = turn.escalationSuggestion, onEscalateStronger != nil || onEscalateCouncil != nil {
                EscalationBanner(
                    suggestion: suggestion,
                    onStronger: onEscalateStronger.map { cb in { cb(turn.id) } },
                    onCouncil: onEscalateCouncil.map { cb in { cb(turn.id) } }
                )
            }
            TurnSourcesStrip(turn: turn)
        }
    }

    private func liveTurn(prompt: String) -> some View {
        directTurnShell(isLive: true) {
            userBubble(prompt: prompt, timestamp: Date(), images: liveImages)
            if let cfg = livePanel.first, let state = liveStates[cfg.id] {
                if !state.toolSteps.isEmpty {
                    AgentStepsView(steps: state.toolSteps)
                }
                assistantBubble(
                    config: cfg,
                    text: state.text,
                    error: errorMessage(state.phase),
                    streaming: isStreaming(state.phase),
                    reasoning: state.reasoning,
                    tokenUsage: (state.inputTokens > 0 || state.outputTokens > 0)
                        ? TurnTokenUsage(input: state.inputTokens, output: state.outputTokens) : nil
                )
            }
        }
    }

    private func directTurnShell<Content: View>(
        isLive: Bool,
        collapsed: Bool = false,
        collapsedPreview: String = "",
        onToggleCollapse: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let onToggleCollapse {
                    Button { onToggleCollapse() } label: {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(directTint)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(directTint)
                Text("Direct")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(directTint)
                if isLive {
                    Text("Live")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(directTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(directTint.opacity(0.11), in: Capsule())
                }
                if collapsed, !collapsedPreview.isEmpty {
                    Text(collapsedPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            if !collapsed {
                content()
            }
        }
        .padding(.horizontal, turnShellHorizontalPadding)
        .padding(.vertical, turnShellVerticalPadding)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [directTint.opacity(isLive ? 0.12 : 0.07), Color.platformControlBackground.opacity(0.24), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(directTint.opacity(isLive ? 0.26 : 0.12), lineWidth: 1)
        }
        .shadow(color: directTint.opacity(isLive ? 0.10 : 0.05), radius: 22, x: 0, y: 10)
    }

    private func userBubble(prompt: String, timestamp: Date, images: [TurnImage] = [],
                            onFork: (() -> Void)? = nil, onEdit: (() -> Void)? = nil,
                            onFollowUp: (() -> Void)? = nil, onExportReport: (() -> Void)? = nil,
                            onShareImage: (() -> Void)? = nil) -> some View {
        HStack {
            Spacer(minLength: userLeadingGutter)
            VStack(alignment: .trailing, spacing: 4) {
                if !images.isEmpty {
                    ConversationImagesRow(images: images)
                }
                if !prompt.isEmpty {
                    Text(prompt)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(
                            LinearGradient(
                                colors: [directTint.opacity(0.22), directTint.opacity(0.11)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(directTint.opacity(0.24), lineWidth: 1)
                        }
                }
                HStack(spacing: 6) {
                    if onFork != nil || onEdit != nil || onFollowUp != nil || onExportReport != nil || onShareImage != nil {
                        Menu {
                            if let onEdit {
                                Button { onEdit() } label: { Label("编辑并重发", systemImage: "pencil") }
                            }
                            if let onFollowUp {
                                Button { onFollowUp() } label: { Label("追问", systemImage: "arrowshape.turn.up.left") }
                            }
                            if let onFork {
                                Button { onFork() } label: { Label("从这里分支", systemImage: "arrow.triangle.branch") }
                            }
                            if let onShareImage {
                                Button { onShareImage() } label: { Label("复制本轮为图片", systemImage: "photo.on.rectangle") }
                            }
                            if let onExportReport {
                                Button { onExportReport() } label: { Label("导出本轮报告", systemImage: "square.and.arrow.up") }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                                .contentShape(Circle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("本轮问题操作")
                    }
                    Text(timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func assistantBubble(config: ProviderConfig, text: String, error: String?, streaming: Bool,
                                 reasoning: String? = nil, tokenUsage: TurnTokenUsage? = nil,
                                 showActions: Bool = false, sources: [SourceRef] = [],
                                 knowledgeSources: [KnowledgeSourceRef] = [],
                                 onRegenerate: ((UUID) -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: assistantSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentColor(config).opacity(0.90), accentColor(config).opacity(0.46)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: providerSymbol(config))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: assistantAvatarSize, height: assistantAvatarSize)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
            }
            .shadow(color: accentColor(config).opacity(0.16), radius: 10, x: 0, y: 5)

            VStack(alignment: .leading, spacing: 8) {
                assistantHeader(config: config, streaming: streaming, tokenUsage: tokenUsage)
                if let reasoning, !reasoning.isEmpty {
                    ReasoningDisclosure(reasoning: reasoning, streaming: streaming, tint: accentColor(config))
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if text.isEmpty {
                    Text(streaming ? "正在思考..." : "(空响应)")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarkdownText(text: streaming ? text : citationLinkified(text, sources: sources, knowledgeSources: knowledgeSources),
                                 streaming: streaming)
                        .knowledgeCitationHost(streaming ? [] : knowledgeSources)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showActions, error == nil, !text.isEmpty {
                    AnswerFooterBar(text: text, providerName: config.displayName, model: config.model,
                                    sources: sources, tint: accentColor(config),
                                    regenerateProviders: onRegenerate == nil ? [] : regenerateProviders,
                                    onRegenerate: onRegenerate)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, messageHorizontalPadding)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.platformControlBackground.opacity(0.55))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accentColor(config).opacity(0.08), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(accentColor(config).opacity(0.20), lineWidth: 1)
            }
            Spacer(minLength: assistantTrailingGutter)
        }
    }

    private func assistantHeader(config: ProviderConfig, streaming: Bool, tokenUsage: TurnTokenUsage?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text(config.displayName)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text(config.model)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let tokenUsage, tokenUsage.input > 0 || tokenUsage.output > 0 {
                    TokenCostPill(usage: tokenUsage, model: config.model, providerKind: config.kind)
                }
                if streaming {
                    streamingBadge(config: config)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(config.displayName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if streaming {
                        streamingBadge(config: config)
                    }
                }
                Text(config.model)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let tokenUsage, tokenUsage.input > 0 || tokenUsage.output > 0 {
                    TokenCostPill(usage: tokenUsage, model: config.model, providerKind: config.kind)
                }
            }
        }
    }

    private func streamingBadge(config: ProviderConfig) -> some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.small)
            Text("生成中")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(accentColor(config))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(accentColor(config).opacity(0.10), in: Capsule())
    }

    private var usesCompactChatLayout: Bool {
        #if os(iOS)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }

    private var listHorizontalPadding: CGFloat {
        usesCompactChatLayout ? 10 : 18
    }

    private var turnShellHorizontalPadding: CGFloat {
        usesCompactChatLayout ? 10 : 14
    }

    private var turnShellVerticalPadding: CGFloat {
        usesCompactChatLayout ? 12 : 14
    }

    private var userLeadingGutter: CGFloat {
        usesCompactChatLayout ? 20 : 60
    }

    private var assistantTrailingGutter: CGFloat {
        usesCompactChatLayout ? 8 : 60
    }

    private var assistantSpacing: CGFloat {
        usesCompactChatLayout ? 9 : 12
    }

    private var assistantAvatarSize: CGFloat {
        usesCompactChatLayout ? 30 : 34
    }

    private var messageHorizontalPadding: CGFloat {
        usesCompactChatLayout ? 13 : 15
    }

    private func isStreaming(_ phase: ResponsePhase) -> Bool {
        if case .streaming = phase { return true }
        return false
    }

    private func errorMessage(_ phase: ResponsePhase) -> String? {
        if case .failed(let m) = phase { return m }
        return nil
    }

    /// 多模型图像生成对比的轮:有按 provider 分组的出图或出图错误。
    private func isImageComparisonTurn(_ turn: Turn) -> Bool {
        !(turn.generatedImagesByProvider?.isEmpty ?? true) || !(turn.imageGenErrors?.isEmpty ?? true)
    }

    private func accentColor(_ cfg: ProviderConfig) -> Color {
        cfg.kownTint
    }

    private func providerSymbol(_ cfg: ProviderConfig) -> String {
        cfg.kownSymbol
    }

    private var directTint: Color {
        ConversationMode.direct.kownTint
    }
}

/// 自动升级建议横幅(建议式):答卡下方非侵入提示,点按钮才重答,默认仅建议。
struct EscalationBanner: View {
    let suggestion: EscalationSuggestion
    /// nil 表示不提供该动作(隐藏对应按钮)。
    var onStronger: (() -> Void)? = nil
    var onCouncil: (() -> Void)? = nil

    private var tint: Color { Color(red: 0.92, green: 0.55, blue: 0.22) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.top, 1)
                Text("可能想更稳一点?\(suggestion.reason),要不要换更强的方式再答一次?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if let onStronger {
                    actionButton("换更强模型重答", icon: "arrow.up.circle.fill", action: onStronger)
                }
                if let onCouncil {
                    actionButton("转 Council 重答", icon: "person.3.fill", action: onCouncil)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 1)
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(tint.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 1))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}
