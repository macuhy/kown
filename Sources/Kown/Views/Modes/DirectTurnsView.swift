import SwiftUI

/// Direct 模式：ChatGPT 风格的竖向气泡列表
struct DirectTurnsView: View {
    let conversation: Conversation
    let liveStates: [UUID: ResponseState]
    let livePrompt: String?
    var liveImages: [TurnImage] = []
    let livePanel: [ProviderConfig]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(conversation.turns) { turn in
                historicalTurn(turn)
            }
            if let livePrompt {
                liveTurn(prompt: livePrompt)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }

    private func historicalTurn(_ turn: Turn) -> some View {
        directTurnShell(isLive: false) {
            userBubble(prompt: turn.prompt, timestamp: turn.timestamp, images: turn.images ?? [])
            if let cfg = turn.orderedPanelConfigs.first {
                let key = cfg.id.uuidString
                assistantBubble(
                    config: cfg,
                    text: turn.responses[key] ?? "",
                    error: turn.errors[key],
                    streaming: false
                )
            }
            if let writes = turn.appliedWrites, !writes.isEmpty {
                AppliedWritesStrip(writes: writes)
            }
        }
    }

    private func liveTurn(prompt: String) -> some View {
        directTurnShell(isLive: true) {
            userBubble(prompt: prompt, timestamp: Date(), images: liveImages)
            if let cfg = livePanel.first, let state = liveStates[cfg.id] {
                assistantBubble(
                    config: cfg,
                    text: state.text,
                    error: errorMessage(state.phase),
                    streaming: isStreaming(state.phase)
                )
            }
        }
    }

    private func directTurnShell<Content: View>(
        isLive: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
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
                Spacer()
            }
            content()
        }
        .padding(14)
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

    private func userBubble(prompt: String, timestamp: Date, images: [TurnImage] = []) -> some View {
        HStack {
            Spacer(minLength: 60)
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
                                colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.11)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 1)
                        }
                }
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func assistantBubble(config: ProviderConfig, text: String, error: String?, streaming: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
            .frame(width: 34, height: 34)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
            }
            .shadow(color: accentColor(config).opacity(0.16), radius: 10, x: 0, y: 5)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(config.displayName)
                        .font(.caption.weight(.bold))
                    Text(config.model)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if streaming {
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
                    MarkdownText(text: text, streaming: streaming)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 15)
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
            Spacer(minLength: 60)
        }
    }

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
        }
    }

    private func providerSymbol(_ cfg: ProviderConfig) -> String {
        switch cfg.kind {
        case .openAICompatible: return "sparkles"
        case .anthropic:        return "text.book.closed"
        case .gemini:           return "diamond.fill"
        case .cliCommand:       return "terminal"
        }
    }

    private var directTint: Color {
        Color(red: 0.55, green: 0.45, blue: 0.78)
    }
}
