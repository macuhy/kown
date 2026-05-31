import SwiftUI

/// Direct / Compare 模式下显示当前选中的 provider,点击可改。
/// Council 模式隐藏(用全部 enabled,不需要选)。
struct ActiveProviderBar: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        let mode = viewModel.currentMode
        if mode == .council || mode == .debate {
            EmptyView()
        } else {
            content(mode: mode)
                .padding(.horizontal, outerHorizontalPadding)
                .padding(.vertical, outerVerticalPadding)
                .background {
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(.thinMaterial)
                        LinearGradient(
                            colors: [modeTint(mode).opacity(0.06), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 1)
                    }
                }
        }
    }

    @ViewBuilder
    private func content(mode: ConversationMode) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                label(mode)
                Spacer(minLength: 12)
                chips(mode)
                picker(mode)
            }
            VStack(alignment: .leading, spacing: compactStackSpacing) {
                HStack {
                    label(mode)
                    Spacer(minLength: 8)
                    picker(mode)
                }
                chips(mode)
            }
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.vertical, contentVerticalPadding)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [modeTint(mode).opacity(0.10), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(modeTint(mode).opacity(0.18), lineWidth: 1)
        }
    }

    private func label(_ mode: ConversationMode) -> some View {
        HStack(spacing: 9) {
            Image(systemName: mode.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(modeTint(mode))
                .frame(width: 28, height: 28)
                .background(modeTint(mode).opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(modeTint(mode).opacity(0.20), lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(mode == .direct ? "对话模型" : "对比模型")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                #if !os(iOS)
                Text(mode == .direct ? "Single responder" : "Same prompt, two reads")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func chips(_ mode: ConversationMode) -> some View {
        // 展示「当前可参与回答」的 provider 集合:enabled 的(可点击停用)+ 真正进 panel 的。
        // 全为空(一个 provider 都没配)才报警告。点 chip 可快速启停。
        let chipList = chipProviders()
        if chipList.isEmpty {
            statusChip("无可用 provider", icon: "exclamationmark.triangle.fill", tint: .orange)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chipList) { cfg in
                        providerChip(cfg)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: 520)
        }
    }

    /// chip 列表 = 真正进 panel 的(本轮会回答的)∪ 其余 enabled 的(随手可停用)。
    /// 全部 enabled 都展示,这样关掉某家后仍能在条上把它重新点亮。
    private func chipProviders() -> [ProviderConfig] {
        let (panel, _) = viewModel.providersForCurrentSend()
        let panelIDs = Set(panel.map(\.id))
        let extras = viewModel.providers.filter { $0.enabled && !panelIDs.contains($0.id) }
        return panel + extras
    }

    private func statusChip(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
    }

    private func providerChip(_ cfg: ProviderConfig) -> some View {
        let tint = accentColor(cfg)
        let isOn = cfg.enabled
        // 点 chip 即快速开关该 provider 的启用态(沿用 setChair/setSummary 的
        // 「直接改 providers[i] + saveProviders()」模式,只动 public 接口)。
        return Button {
            toggleEnabled(cfg)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: providerSymbol(cfg))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isOn ? tint : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background((isOn ? tint : Color.secondary).opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(cfg.displayName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isOn ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        if cfg.isChair { roleBadge("主席", icon: "crown.fill", tint: chairTint) }
                        if cfg.isSummary { roleBadge("总结", icon: "list.bullet.rectangle.fill", tint: summaryTint) }
                    }
                    #if !os(iOS)
                    Text(cfg.model)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    #endif
                }
                // 启用态的小指示器:开 = 实心点,关 = 空心(灰)。
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isOn ? tint : Color.secondary.opacity(0.6))
            }
            .padding(.leading, 6)
            .padding(.trailing, chipTrailingPadding)
            .padding(.vertical, chipVerticalPadding)
            .background {
                Capsule()
                    .fill((isOn ? tint : Color.secondary).opacity(isOn ? 0.10 : 0.06))
            }
            .overlay {
                Capsule().strokeBorder((isOn ? tint : Color.secondary).opacity(isOn ? 0.24 : 0.16), lineWidth: 1)
            }
            .opacity(isOn ? 1 : 0.6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .help(isOn ? "点按停用 \(cfg.displayName)" : "点按启用 \(cfg.displayName)")
    }

    /// Chair / Summary 角色小徽标 — 紧凑 capsule,跟 chip 内文对齐。
    private func roleBadge(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(tint.opacity(0.16), in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.5)
        }
    }

    /// 快速开关某个 provider 的启用态。直接改 `viewModel.providers` 并持久化,
    /// 与 AppViewModel 内 setChair / setSummary 一致的写法,只用 public 接口。
    private func toggleEnabled(_ cfg: ProviderConfig) {
        guard let idx = viewModel.providers.firstIndex(where: { $0.id == cfg.id }) else { return }
        viewModel.providers[idx].enabled.toggle()
        viewModel.saveProviders()
    }

    @ViewBuilder
    private func picker(_ mode: ConversationMode) -> some View {
        let enabled = viewModel.providers.filter(\.enabled)
        let selected = currentSelectedChoices(mode: mode)
        Menu {
            if enabled.isEmpty {
                Text("没有启用的 provider — 去设置启用一个")
            } else {
                ForEach(enabled) { cfg in
                    providerMenuItem(cfg: cfg, mode: mode, selected: selected)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(mode == .compare ? "选择 ≤2" : "切换模型")
                    .font(.caption.weight(.bold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(enabled.isEmpty ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background((enabled.isEmpty ? Color.secondary : Color.accentColor).opacity(0.11), in: Capsule())
            .overlay {
                Capsule().strokeBorder((enabled.isEmpty ? Color.secondary : Color.accentColor).opacity(0.22), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(enabled.isEmpty)
    }

    private var outerHorizontalPadding: CGFloat {
        #if os(iOS)
        return 12
        #else
        return 14
        #endif
    }

    private var outerVerticalPadding: CGFloat {
        #if os(iOS)
        return 5
        #else
        return 9
        #endif
    }

    private var contentHorizontalPadding: CGFloat {
        #if os(iOS)
        return 10
        #else
        return 12
        #endif
    }

    private var contentVerticalPadding: CGFloat {
        #if os(iOS)
        return 7
        #else
        return 10
        #endif
    }

    private var compactStackSpacing: CGFloat {
        #if os(iOS)
        return 7
        #else
        return 10
        #endif
    }

    private var chipTrailingPadding: CGFloat {
        #if os(iOS)
        return 8
        #else
        return 10
        #endif
    }

    private var chipVerticalPadding: CGFloat {
        #if os(iOS)
        return 4
        #else
        return 6
        #endif
    }

    /// 为单个 provider 生成菜单项 — 已知厂商展开成"厂商 → 模型列表"子菜单,
    /// 未知厂商 / CLI 只列已配置的那一个 model。
    @ViewBuilder
    private func providerMenuItem(cfg: ProviderConfig, mode: ConversationMode, selected: Set<ProviderModelChoice>) -> some View {
        let known = ProviderModelCatalog.knownModels(for: cfg)
        // 已知模型 ∪ 用户当前在设置里硬填的 model(去重)
        let union = uniqueOrdered([cfg.model] + known)
        if union.count <= 1 {
            choiceButton(cfg: cfg, model: cfg.model, mode: mode, selected: selected)
        } else {
            Menu(cfg.displayName) {
                ForEach(union, id: \.self) { model in
                    choiceButton(cfg: cfg, model: model, mode: mode, selected: selected)
                }
            }
        }
    }

    private func choiceButton(cfg: ProviderConfig, model: String, mode: ConversationMode, selected: Set<ProviderModelChoice>) -> some View {
        let choice = ProviderModelChoice(providerID: cfg.id, model: model)
        let isPicked = selected.contains(choice)
        let label = ProviderModelCatalog.knownModels(for: cfg).count <= 1
            ? "\(cfg.displayName) · \(model)"
            : model
        return Button {
            switch mode {
            case .direct:
                viewModel.setDirectChoice(providerID: cfg.id, model: model)
            case .compare:
                viewModel.toggleCompareChoice(providerID: cfg.id, model: model)
            case .council, .debate:
                break
            }
        } label: {
            if isPicked {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    /// 当前真正会被发送的 (provider, model) 组合(用于打勾)。
    private func currentSelectedChoices(mode: ConversationMode) -> Set<ProviderModelChoice> {
        let active = viewModel.activeModelChoicesForCurrent
        if !active.isEmpty { return Set(active) }
        // 回退到 active provider ids(老数据) → 用 provider 的默认 model
        let activeIDs = viewModel.activeProviderIDsForCurrent
        if !activeIDs.isEmpty {
            return Set(activeIDs.compactMap { id in
                viewModel.providers.first(where: { $0.id == id })
                    .map { ProviderModelChoice(providerID: $0.id, model: $0.model) }
            })
        }
        // 完全没选 → 缺省的 first N enabled,各用其默认 model
        let enabled = viewModel.providers.filter(\.enabled)
        let count = mode == .compare ? 2 : (mode == .direct ? 1 : enabled.count)
        return Set(enabled.prefix(count).map { ProviderModelChoice(providerID: $0.id, model: $0.model) })
    }

    private func uniqueOrdered(_ arr: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in arr where !item.isEmpty {
            if seen.insert(item).inserted { result.append(item) }
        }
        return result
    }

    private func modeTint(_ mode: ConversationMode) -> Color {
        switch mode {
        case .council: return Color(red: 0.10, green: 0.66, blue: 0.56)
        case .direct:  return Color(red: 0.16, green: 0.48, blue: 0.94)
        case .compare: return Color(red: 0.91, green: 0.55, blue: 0.20)
        case .debate:  return Color(red: 0.88, green: 0.35, blue: 0.22)
        }
    }

    /// Chair 角色徽标色（金/橙系，呼应「主席」)。
    private var chairTint: Color { Color(red: 0.84, green: 0.60, blue: 0.13) }

    /// Summary 角色徽标色(青/绿系,呼应 Council 主色)。
    private var summaryTint: Color { Color(red: 0.10, green: 0.62, blue: 0.55) }

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
}
