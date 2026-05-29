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
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Rectangle()
                        .fill(Color.primary.opacity(0.03))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                        }
                )
        }
    }

    @ViewBuilder
    private func content(mode: ConversationMode) -> some View {
        HStack(alignment: .center, spacing: 10) {
            label(mode)
            Spacer()
            chips(mode)
            picker(mode)
        }
    }

    private func label(_ mode: ConversationMode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: mode.symbol)
                .font(.caption.weight(.semibold))
            Text(mode == .direct ? "对话模型" : "对比模型")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func chips(_ mode: ConversationMode) -> some View {
        let (panel, _) = viewModel.providersForCurrentSend()
        if panel.isEmpty {
            Text("无可用 provider")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            HStack(spacing: 6) {
                ForEach(panel) { cfg in
                    providerChip(cfg)
                }
            }
        }
    }

    private func providerChip(_ cfg: ProviderConfig) -> some View {
        HStack(spacing: 6) {
            Image(systemName: providerSymbol(cfg))
                .font(.caption2.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text(cfg.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(cfg.model)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(accentColor(cfg).opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(accentColor(cfg).opacity(0.30), lineWidth: 1))
        .foregroundStyle(accentColor(cfg))
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
            Label(mode == .compare ? "选择 (≤2)" : "切换模型", systemImage: "chevron.up.chevron.down")
                .font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(enabled.isEmpty)
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
