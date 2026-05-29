import SwiftUI

struct EmptyStateCard: View {
    let mode: ConversationMode
    let providers: [ProviderConfig]
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)

            heroArtwork

            VStack(spacing: 6) {
                Text(mode.emptyStateTitle)
                    .font(.system(size: 24, weight: .semibold))
                Text(mode.emptyStateSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            tipsCard
                .frame(maxWidth: 540)

            councilCard
                .frame(maxWidth: 540)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var heroArtwork: some View {
        #if os(iOS)
        Image("LaunchLogo")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 360)
            .frame(height: 280)
            .shadow(color: Color(red: 0.10, green: 0.35, blue: 0.95).opacity(0.14),
                    radius: 22, x: 0, y: 12)
            .padding(.bottom, -8)
        #else
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 86, height: 86)
            Image(systemName: "brain.head.profile")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        #endif
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            tipRow("lightbulb",       text: mode == .debate
                   ? "Use Debate for questions with trade-offs, uncertainty, or competing strategies"
                   : "Ask complex questions that benefit from multiple perspectives", color: .yellow)
            tipRow("paperclip",       text: "Attach files by dragging them into the input area",            color: .secondary)
            tipRow("wand.and.stars",  text: "Use the Prompt Enhancer to refine your question before sending", color: .purple)
            tipRow(mode == .debate ? "quote.bubble" : "slider.horizontal.3",
                   text: mode == .debate
                   ? "Models will first argue independently, then read each other and rebut"
                   : "Adjust response depth and style using the toolbar options",
                   color: .pink)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func tipRow(_ symbol: String, text: String, color: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private var councilCard: some View {
        let enabled = providers.filter(\.enabled)
        let chair = enabled.first { $0.isChair }

        return VStack(spacing: 0) {
            HStack {
                Text(mode == .debate ? "YOUR DEBATERS" : "YOUR COUNCIL")
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Change", action: onOpenSettings)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if enabled.isEmpty {
                emptyCouncilHint
            } else {
                VStack(spacing: 0) {
                    // 所有 enabled 都列出（包括 Chair）
                    ForEach(enabled) { cfg in
                        councilRow(cfg: cfg, showChairBadge: false)
                        if cfg.id != enabled.last?.id {
                            Divider().padding(.horizontal, 16)
                        }
                    }
                    if let chair {
                        Color.clear.frame(height: 8)
                        Divider().padding(.horizontal, 16)
                        councilRow(cfg: chair, showChairBadge: true)
                    }
                }
                .padding(.bottom, 14)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var emptyCouncilHint: some View {
        VStack(spacing: 6) {
            Text("还没启用任何模型")
                .font(.callout.weight(.semibold))
            Text("点 \"Change\" 在配置里启用至少一个 provider。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private func councilRow(cfg: ProviderConfig, showChairBadge: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: showChairBadge ? "crown.fill" : "person.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(showChairBadge ? Color.orange : .secondary)

            Text(cfg.displayName)
                .font(.callout)
                .foregroundStyle(.primary)

            if showChairBadge {
                Text(mode == .debate ? "Moderator" : "Chair")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.orange)
            }

            Spacer()

            Text(cfg.kind.compactName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

private extension ProviderKind {
    var compactName: String {
        switch self {
        case .openAICompatible: return "openai"
        case .anthropic:        return "anthropic"
        case .gemini:           return "google"
        case .cliCommand:       return "cli"
        }
    }
}
