import SwiftUI

struct EmptyStateCard: View {
    let mode: ConversationMode
    let providers: [ProviderConfig]
    let onOpenSettings: () -> Void

    private var enabledProviders: [ProviderConfig] { providers.filter(\.enabled) }
    private var modeTint: Color { mode.workspaceTint }

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        mobileBody
        #else
        VStack(spacing: 22) {
            Spacer(minLength: 12)

            heroCard
                .frame(maxWidth: 760)

            cardGrid
                .frame(maxWidth: 920)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    #if os(iOS)
    private var mobileBody: some View {
        VStack(spacing: 14) {
            mobileHeroCard
            mobileQuickStartCard
            mobileProviderSummaryCard
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var mobileHeroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [modeTint.opacity(0.20), Color.orange.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image("AppIcon")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: modeTint.opacity(0.16), radius: 14, x: 0, y: 8)
                }
                .frame(width: 82, height: 82)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    modeBadge
                    Text(mode.emptyStateTitle)
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(mode.emptyStateSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Label("底部输入即可开始", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(modeTint)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(modeTint.opacity(0.12), in: Capsule())

                Spacer(minLength: 0)

                Button(action: onOpenSettings) {
                    Label(enabledProviders.isEmpty ? "启用模型" : "配置模型", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            LinearGradient(
                                colors: [modeTint.opacity(0.98), modeTint.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: modeTint, cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(modeTint.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: modeTint.opacity(0.10), radius: 22, x: 0, y: 14)
    }

    private var mobileQuickStartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Quick start",
                subtitle: "三个小动作让回答更稳定",
                icon: "sparkles",
                tint: modeTint
            )

            VStack(spacing: 8) {
                mobileTipRow("1", text: mode == .debate ? "把争议点写清楚，让模型先独立立论" : "直接描述目标、背景和你希望比较的标准")
                mobileTipRow("2", text: "需要上下文时先附图，再在问题里说明重点")
                mobileTipRow("3", text: "发送前可用 Prompt Enhancer 做一次整理")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: modeTint.opacity(0.88), cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var mobileProviderSummaryCard: some View {
        let enabled = enabledProviders
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                sectionHeader(
                    title: enabled.isEmpty ? "Provider 未就绪" : "Provider 已就绪",
                    subtitle: enabled.isEmpty ? "先启用一个模型再开始" : "\(enabled.count) 个模型可参与本轮",
                    icon: enabled.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                    tint: enabled.isEmpty ? .orange : modeTint
                )

                Spacer(minLength: 0)

                Button("设置", action: onOpenSettings)
                    .font(.caption.weight(.black))
                    .foregroundStyle(modeTint)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(modeTint.opacity(0.11), in: Capsule())
                    .buttonStyle(.plain)
            }

            if enabled.isEmpty {
                Text("打开设置后启用 OpenAI Compatible、Anthropic、Gemini 或 CLI Provider。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(enabled.prefix(3))) { cfg in
                        mobileProviderPill(cfg)
                    }

                    if enabled.count > 3 {
                        Text("+\(enabled.count - 3)")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Color.platformControlBackground.opacity(0.52), in: Circle())
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: .orange, cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func mobileTipRow(_ number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(modeTint, in: Circle())
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.platformControlBackground.opacity(0.38), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func mobileProviderPill(_ cfg: ProviderConfig) -> some View {
        let tint = providerTint(cfg)
        return HStack(spacing: 7) {
            Image(systemName: providerSymbol(cfg))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(cfg.displayName)
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(Color.platformControlBackground.opacity(0.50), in: Capsule())
    }
    #endif

    private var heroCard: some View {
        VStack(spacing: 18) {
            heroArtwork

            VStack(spacing: 10) {
                modeBadge
                Text(mode.emptyStateTitle)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(mode.emptyStateSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                modeTint.opacity(0.18),
                                Color.orange.opacity(mode == .debate ? 0.14 : 0.06),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(modeTint.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: modeTint.opacity(0.10), radius: 28, x: 0, y: 16)
    }

    private var modeBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: mode.symbol)
                .font(.caption.weight(.bold))
            Text(mode.displayName.uppercased())
                .font(.caption.weight(.black))
                .tracking(0.7)
            Text("\(enabledProviders.count) active")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(modeTint)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(modeTint.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(modeTint.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var heroArtwork: some View {
        ZStack {
            Circle()
                .fill(modeTint.opacity(0.14))
                .frame(width: 180, height: 180)
                .blur(radius: 18)
                .offset(x: -26, y: 18)
            Circle()
                .fill(Color.orange.opacity(0.12))
                .frame(width: 130, height: 130)
                .blur(radius: 16)
                .offset(x: 42, y: -18)

            #if os(iOS)
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 330)
                .frame(height: 230)
                .shadow(color: Color(red: 0.10, green: 0.35, blue: 0.95).opacity(0.16),
                        radius: 24, x: 0, y: 14)
            #else
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [modeTint.opacity(0.95), Color.orange.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 112, height: 112)
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
            }
            .shadow(color: modeTint.opacity(0.24), radius: 24, x: 0, y: 14)
            #endif
        }
        #if os(iOS)
        .frame(height: 250)
        #else
        .frame(height: 144)
        #endif
    }

    @ViewBuilder
    private var cardGrid: some View {
        #if os(iOS)
        VStack(spacing: 14) {
            tipsCard
            councilCard
        }
        #else
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                tipsCard
                councilCard
            }
            VStack(spacing: 14) {
                tipsCard
                councilCard
            }
        }
        #endif
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "Better first prompts",
                subtitle: "Small moves that improve the whole run",
                icon: "sparkles",
                tint: modeTint
            )

            VStack(spacing: 10) {
                tipRow(
                    "lightbulb.fill",
                    text: mode == .debate
                        ? "Use Debate for questions with trade-offs, uncertainty, or competing strategies"
                        : "Ask complex questions that benefit from multiple perspectives",
                    color: .yellow
                )
                tipRow("paperclip", text: "Attach files by dragging them into the input area", color: .secondary)
                tipRow("wand.and.stars", text: "Use the Prompt Enhancer to refine your question before sending", color: Color(red: 0.57, green: 0.42, blue: 0.82))
                tipRow(
                    mode == .debate ? "quote.bubble.fill" : "slider.horizontal.3",
                    text: mode == .debate
                        ? "Models will first argue independently, then read each other and rebut"
                        : "Adjust response depth and style using the toolbar options",
                    color: .pink
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground(tint: modeTint.opacity(0.9), cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func sectionHeader(title: String, subtitle: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(tint.opacity(0.20), lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func tipRow(_ symbol: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.platformControlBackground.opacity(0.34), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var councilCard: some View {
        let enabled = enabledProviders
        let chair = enabled.first { $0.isChair }

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                sectionHeader(
                    title: mode == .debate ? "Your debaters" : "Your council",
                    subtitle: enabled.isEmpty ? "Enable providers before sending" : "Ready for the next message",
                    icon: mode == .debate ? "quote.bubble.fill" : "person.3.fill",
                    tint: .orange
                )
                Spacer(minLength: 8)
                Button(action: onOpenSettings) {
                    Text("Change")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(18)

            if enabled.isEmpty {
                emptyCouncilHint
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(enabled) { cfg in
                        councilRow(cfg: cfg, showChairBadge: false)
                        if cfg.id != enabled.last?.id {
                            Divider().opacity(0.5).padding(.leading, 58).padding(.trailing, 18)
                        }
                    }
                    if let chair {
                        Divider().opacity(0.5).padding(.horizontal, 18).padding(.top, 8)
                        councilRow(cfg: chair, showChairBadge: true)
                            .padding(.top, 4)
                    }
                }
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground(tint: .orange, cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var emptyCouncilHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 42, height: 42)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("还没启用任何模型")
                .font(.callout.weight(.semibold))
            Text("点 \"Change\" 在配置里启用至少一个 provider。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 1)
        }
    }

    private func councilRow(cfg: ProviderConfig, showChairBadge: Bool) -> some View {
        let tint = showChairBadge ? Color.orange : providerTint(cfg)
        return HStack(spacing: 12) {
            Image(systemName: showChairBadge ? "crown.fill" : providerSymbol(cfg))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cfg.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if showChairBadge {
                        Text(mode == .debate ? "Moderator" : "Chair")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.orange)
                    }
                }
                Text(cfg.model)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(cfg.kind.compactName)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.10), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func cardBackground(tint: Color, cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.08), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private func providerTint(_ cfg: ProviderConfig) -> Color {
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
}

private extension ConversationMode {
    var workspaceTint: Color {
        switch self {
        case .council: return Color(red: 0.10, green: 0.66, blue: 0.56)
        case .direct:  return Color(red: 0.16, green: 0.48, blue: 0.94)
        case .compare: return Color(red: 0.91, green: 0.55, blue: 0.20)
        case .debate:  return Color(red: 0.88, green: 0.35, blue: 0.22)
        }
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
