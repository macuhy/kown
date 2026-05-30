import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case providers
        case webSearch
        case sync
        case backup
        case usage
        case performance
        case updates
        case changelog

        var id: String { rawValue }
        var label: String {
            switch self {
            case .providers:   return "厂商"
            case .webSearch:   return "Web Search"
            case .sync:        return "iCloud 同步"
            case .backup:      return "导入/导出"
            case .usage:       return "Token 用量"
            case .performance: return "性能"
            case .updates:     return "软件更新"
            case .changelog:   return "更新日志"
            }
        }
        var symbol: String {
            switch self {
            case .providers:   return "square.stack.3d.up"
            case .webSearch:   return "globe"
            case .sync:        return "icloud"
            case .backup:      return "square.and.arrow.up.on.square"
            case .usage:       return "chart.bar.xaxis"
            case .performance: return "speedometer"
            case .updates:     return "arrow.down.circle"
            case .changelog:   return "sparkles"
            }
        }
        var tint: Color {
            switch self {
            case .providers:   return Color(red: 0.10, green: 0.66, blue: 0.56)
            case .webSearch:   return Color(red: 0.16, green: 0.48, blue: 0.94)
            case .sync:        return Color(red: 0.18, green: 0.58, blue: 0.92)
            case .backup:      return Color(red: 0.91, green: 0.55, blue: 0.20)
            case .usage:       return Color(red: 0.24, green: 0.63, blue: 0.36)
            case .performance: return Color(red: 0.88, green: 0.35, blue: 0.22)
            case .updates:     return Color(red: 0.57, green: 0.42, blue: 0.82)
            case .changelog:   return Color(red: 0.95, green: 0.57, blue: 0.16)
            }
        }
    }

    @State private var tab: Tab = .providers
    #if os(iOS)
    @Namespace private var mobileTabNamespace
    #endif
    private static let desktopWidth: CGFloat = 960
    private static let desktopHeight: CGFloat = 660

    /// 实际展示的 tab — 「软件更新」(Sparkle) 仅 macOS 有,iOS 过滤掉。
    private var availableTabs: [Tab] {
        #if os(macOS)
        return Tab.allCases
        #else
        return Tab.allCases.filter { $0 != .updates }
        #endif
    }

    /// 可添加的 provider 类型 — iOS 排除 CLI(沙箱起不了子进程)
    private var addableKinds: [ProviderKind] {
        #if os(macOS)
        return ProviderKind.allCases
        #else
        return ProviderKind.allCases.filter { $0 != .cliCommand }
        #endif
    }

    var body: some View {
        #if os(iOS)
        mobileBody
        #else
        desktopBody
        #endif
    }

    private var desktopBody: some View {
        HStack(spacing: 0) {
            desktopSidebar
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            VStack(spacing: 0) {
                desktopHeader
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                desktopContent
            }
            .background(SettingsBackdrop())
        }
        .frame(width: Self.desktopWidth, height: Self.desktopHeight)
    }

    #if os(iOS)
    private var mobileBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mobileTabBar

                Group {
                    switch tab {
                    case .providers:
                        mobileProvidersList
                    case .webSearch:
                        WebSearchSettingsView(viewModel: viewModel)
                    case .sync:
                        ICloudSyncSettingsView(viewModel: viewModel)
                    case .backup:
                        BackupSettingsView(viewModel: viewModel)
                    case .usage:
                        UsageSettingsView()
                    case .performance:
                        PerformanceSettingsView()
                    case .updates:
                        EmptyView()   // iOS 不展示;.updates 已从 availableTabs 过滤
                    case .changelog:
                        ChangelogView(embeddedInSettings: true)
                    }
                }
            }
            .background(SettingsBackdrop())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                if tab == .providers {
                    ToolbarItem(placement: .primaryAction) {
                        addProviderMenu
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var mobileTabBar: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SettingsAppIcon()
                        .frame(width: 30, height: 30)
                        .shadow(color: tab.tint.opacity(0.16), radius: 10, x: 0, y: 5)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(tab.tint.opacity(0.18), lineWidth: 1)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.label)
                            .font(.subheadline.weight(.bold))
                        Text(headerSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableTabs) { t in
                            mobileTabPill(t)
                                .id(t.id)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 2)
                }
                .padding(.horizontal, -18)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tab.tint.opacity(0.16))
                    .frame(height: 1)
            }
            .onChange(of: tab) { _, newTab in
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(newTab.id, anchor: .center)
                }
            }
        }
    }

    private func mobileTabPill(_ t: Tab) -> some View {
        let selected = tab == t
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                tab = t
            }
        } label: {
            Image(systemName: t.symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 42, height: 42)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.platformControlBackground.opacity(selected ? 0 : 0.72))
                if selected {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [t.tint, t.tint.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .matchedGeometryEffect(id: "mobile-selected-tab", in: mobileTabNamespace)
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(selected ? Color.white.opacity(0.28) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: selected ? t.tint.opacity(0.24) : .clear, radius: 12, x: 0, y: 7)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var mobileProvidersList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                mobileProviderHero
                mobileProviderMetrics

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Provider 配置")
                            .font(.headline)
                        Text("点进卡片即可编辑连接、模型、API Key 和 Council 角色。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text("\(viewModel.providers.count) 家")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.10), in: Capsule(style: .continuous))
                }

                if viewModel.providers.isEmpty {
                    mobileEmptyProvidersCard
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach($viewModel.providers) { $cfg in
                            NavigationLink {
                                MobileProviderEditorView(
                                    config: $cfg,
                                    onDelete: {
                                        viewModel.removeProvider(cfg.id)
                                    },
                                    onSave: {
                                        viewModel.saveProviders()
                                    },
                                    onToggleChair: { newValue in
                                        viewModel.setChair(cfg.id, isChair: newValue)
                                    },
                                    onToggleSummary: { newValue in
                                        viewModel.setSummary(cfg.id, isSummary: newValue)
                                    }
                                )
                            } label: {
                                MobileProviderSummaryRow(config: cfg)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var mobileProviderHero: some View {
        let total = viewModel.providers.count
        let enabled = viewModel.providers.filter(\.enabled).count
        let tint = enabled == 0 ? Color.orange : tab.tint
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.24), tint.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: enabled == 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(tint)
                }
                .frame(width: 46, height: 46)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(tint.opacity(0.22), lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(enabled == 0 ? "先启用一个模型" : "模型已准备好")
                        .font(.headline.weight(.bold))
                    Text(enabled == 0 ? "添加或打开任意 Provider 后即可开始对话。" : "当前有 \(enabled) 家 Provider 可参与回答, 可继续调整默认角色。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                addProviderMenu
                    .labelStyle(.iconOnly)
                    .font(.headline.weight(.bold))
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(tint)
            }

            HStack(spacing: 10) {
                mobileHeroChip(title: "启用", value: "\(enabled)/\(total)", color: enabled == 0 ? .orange : .green)
                mobileHeroChip(title: "总数", value: "\(total)", color: .secondary)
                if let chair = viewModel.providers.first(where: \.isChair) {
                    mobileHeroChip(title: "Chair", value: chair.displayName, color: .orange)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.06), radius: 12, x: 0, y: 8)
    }

    private var mobileProviderMetrics: some View {
        let enabled = viewModel.providers.filter(\.enabled).count
        let chair = viewModel.providers.first(where: \.isChair)?.displayName ?? "未设置"
        let summary = viewModel.providers.first(where: \.isSummary)?.displayName ?? "未设置"
        let apiProviders = viewModel.providers.filter { !$0.kind.isCLI }.count
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                mobileMetricCard(title: "可用模型", value: "\(enabled)", icon: "bolt.fill", color: enabled == 0 ? .orange : .green)
                mobileMetricCard(title: "Chair", value: chair, icon: "crown.fill", color: .orange)
                mobileMetricCard(title: "Summary", value: summary, icon: "list.bullet.rectangle.fill", color: .teal)
                mobileMetricCard(title: "API Provider", value: "\(apiProviders)", icon: "network", color: .blue)
            }
            .padding(.vertical, 1)
        }
    }

    private func mobileHeroChip(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(color.opacity(0.13), lineWidth: 1)
        }
    }

    private func mobileMetricCard(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.72)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 142, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var mobileEmptyProvidersCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.orange)
                .frame(width: 64, height: 64)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("还没有 Provider")
                .font(.headline)
            Text("添加 OpenAI 兼容、Anthropic 或 Gemini Provider 后即可开始使用。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            addProviderMenu
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
    #endif

    private var desktopSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SettingsAppIcon()
                .frame(width: 40, height: 40)
                .shadow(color: Color.primary.opacity(0.10), radius: 12, x: 0, y: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Kown")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                    Text("偏好设置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("导航")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                ForEach(availableTabs) { t in
                    desktopTabButton(t)
                }
            }

            Spacer(minLength: 0)

            sidebarStatusCard
        }
        .padding(16)
        .frame(width: 230)
        .background(.ultraThinMaterial)
    }

    private func desktopTabButton(_ t: Tab) -> some View {
        let selected = tab == t
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                tab = t
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: t.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(selected ? t.tint : .secondary)
                Text(t.label)
                    .font(.callout.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 0)
                if selected {
                    Circle()
                        .fill(t.tint)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? t.tint.opacity(0.13) : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? t.tint.opacity(0.26) : Color.clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(t.label)
    }

    private var sidebarStatusCard: some View {
        let enabled = viewModel.providers.filter(\.enabled).count
        let total = viewModel.providers.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: enabled == 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(enabled == 0 ? .orange : .green)
                Text(enabled == 0 ? "需要启用模型" : "模型可用")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(enabled == 0 ? .orange : .green)
            }
            Text("\(enabled)/\(total) 家 Provider 已启用")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let chair = viewModel.providers.first(where: \.isChair) {
                Text("Chair · \(chair.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.58), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var desktopHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tab.tint.opacity(0.24), tab.tint.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: tab.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tab.tint)
            }
            .frame(width: 52, height: 52)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tab.tint.opacity(0.22), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(tab.label)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if tab == .providers {
                activeBadge
                addProviderMenu
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .fixedSize()
            }

            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var desktopContent: some View {
        Group {
            switch tab {
            case .providers:
                providersList
            case .webSearch:
                WebSearchSettingsView(viewModel: viewModel)
            case .sync:
                ICloudSyncSettingsView(viewModel: viewModel)
            case .backup:
                BackupSettingsView(viewModel: viewModel)
            case .usage:
                UsageSettingsView()
            case .performance:
                PerformanceSettingsView()
            case .updates:
                #if os(macOS)
                UpdateSettingsView()
                #else
                EmptyView()
                #endif
            case .changelog:
                ChangelogView(embeddedInSettings: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            // 标签放得下就显示「图标+文字」,放不下就退化成「只显示图标」(文字进 tooltip),
            // 永远不换行 / 不挤成两行。
            ViewThatFits(in: .horizontal) {
                tabRow(iconOnly: false)
                tabRow(iconOnly: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func tabRow(iconOnly: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(availableTabs) { t in
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.symbol)
                        if !iconOnly {
                            Text(t.label)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tab == t ? Color.accentColor : .secondary)
                    .padding(.horizontal, iconOnly ? 10 : 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill((tab == t ? Color.accentColor : .secondary).opacity(0.10))
                    )
                    .overlay(
                        Capsule().strokeBorder((tab == t ? Color.accentColor : .secondary).opacity(0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(t.label)
            }
        }
    }

    private var providersList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                providerDashboard
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Provider 配置")
                            .font(.headline)
                        Text("启用、角色、连接和模型参数都在这里直接编辑。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(viewModel.providers.count) 家")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                }

                if viewModel.providers.isEmpty {
                    emptyProvidersCard
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach($viewModel.providers) { $cfg in
                            ProviderRowView(
                                config: $cfg,
                                onDelete: { viewModel.removeProvider(cfg.id) },
                                onSave:   { viewModel.saveProviders() },
                                onToggleChair: { newValue in viewModel.setChair(cfg.id, isChair: newValue) },
                                onToggleSummary: { newValue in viewModel.setSummary(cfg.id, isSummary: newValue) }
                            )
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1040, alignment: .topLeading)
        }
    }

    private var providerDashboard: some View {
        let total = viewModel.providers.count
        let enabled = viewModel.providers.filter(\.enabled).count
        let chair = viewModel.providers.first(where: \.isChair)?.displayName ?? "未设置"
        let summary = viewModel.providers.first(where: \.isSummary)?.displayName ?? "未设置"
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            metricTile(
                title: "已启用",
                value: "\(enabled)/\(total)",
                detail: enabled == 0 ? "发送前至少启用一家" : "当前可参与回答",
                icon: enabled == 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                tint: enabled == 0 ? .orange : .green
            )
            metricTile(
                title: "Chair",
                value: chair,
                detail: "Council / Compare 结论角色",
                icon: "crown.fill",
                tint: .orange
            )
            metricTile(
                title: "Summary",
                value: summary,
                detail: "Council 中立总结角色",
                icon: "list.bullet.rectangle.fill",
                tint: .teal
            )
            metricTile(
                title: "CLI Provider",
                value: "\(viewModel.providers.filter { $0.kind.isCLI }.count)",
                detail: "Claude / Gemini / Codex 等命令",
                icon: "terminal.fill",
                tint: Color(red: 0.55, green: 0.45, blue: 0.78)
            )
        }
    }

    private func metricTile(title: String, value: String, detail: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer()
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.78)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
    }

    private var emptyProvidersCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 70, height: 70)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("还没有 Provider")
                .font(.headline)
            Text("添加 OpenAI 兼容、Anthropic、Gemini 或 CLI Provider 后即可开始使用。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            addProviderMenu
                .buttonStyle(.borderedProminent)
        }
        .padding(34)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("设置")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if tab == .providers {
                activeBadge

                addProviderMenu
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var headerSubtitle: String {
        switch tab {
        case .providers:   return "管理连接、密钥和每个模型的默认生成参数。"
        case .webSearch:   return "配置 Firecrawl 让模型在需要时调用 web_search。"
        case .sync:        return "iCloud 同步 会话、Provider 配置、Web Search 配置 与 API Key。容器对 Files app 隐藏。"
        case .backup:      return "把当前配置(不含会话)导出成 JSON 文件,或从备份恢复。可作为多设备同步的离线备选。"
        case .usage:       return "按天 + 模型查看 token 用量。input / output 分别计,辅助估算成本。"
        case .performance: return "流式响应的渲染节奏。机器卡可以拉长刷新间隔降 CPU。"
        case .updates:     return "通过 Sparkle 检查、下载并自动安装最新版本。"
        case .changelog:   return "查看每个版本的新功能、修复和改进。"
        }
    }

    private var activeBadge: some View {
        let active = viewModel.providers.filter(\.enabled).count
        return HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
            Text("\(active)/\(viewModel.providers.count) 已启用")
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(active == 0 ? .orange : .green)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background((active == 0 ? Color.orange : Color.green).opacity(0.10), in: Capsule())
    }

    private var addProviderMenu: some View {
        Menu {
            ForEach(addableKinds, id: \.self) { kind in
                Button("添加 \(kind.displayName)") {
                    viewModel.addProvider(kind: kind)
                }
            }
            Divider()
            Section("国内预设") {
                ForEach(ProviderPreset.allCases) { preset in
                    Button("添加 \(preset.menuLabel)") {
                        viewModel.addPreset(preset)
                    }
                }
            }
        } label: {
            Label("添加", systemImage: "plus")
        }
    }
}

private struct SettingsAppIcon: View {
    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            }
        #else
        // iOS 下 `Image("AppIcon")` 取不到 app 图标(asset catalog 的 AppIcon 不作为普通命名图开放),
        // 之前因此留白。改用 LaunchLogo(普通 imageset,App 其它地方已在用),保证能渲染。
        Image("LaunchLogo")
            .resizable()
            .scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            }
        #endif
    }
}

private struct SettingsBackdrop: View {
    var body: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [
                    Color.teal.opacity(0.18),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [
                    Color.orange.opacity(0.14),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 80,
                endRadius: 560
            )
            LinearGradient(
                colors: [
                    Color.white.opacity(0.04),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

#if os(iOS)
private struct MobileProviderSummaryRow: View {
    let config: ProviderConfig

    var body: some View {
        HStack(spacing: 12) {
            providerMark

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(config.displayName)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                Text("\(config.kind.displayName) · \(config.model)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if config.isChair {
                        roleChip("主席", color: .orange)
                    }
                    if config.isSummary {
                        roleChip("总结", color: .teal)
                    }
                    if !config.kind.isCLI && !isEndpointComplete {
                        roleChip("待补全", color: .orange)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                statusChip
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(kindColor.opacity(config.enabled ? 0.20 : 0.08), lineWidth: 1)
        }
        .shadow(color: kindColor.opacity(config.enabled ? 0.06 : 0.015), radius: 9, x: 0, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var providerMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [kindColor.opacity(0.22), kindColor.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: providerSymbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(kindColor)
        }
        .frame(width: 42, height: 42)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(kindColor.opacity(0.16), lineWidth: 1)
        }
    }

    private var statusChip: some View {
        Text(config.enabled ? "启用" : "关闭")
            .font(.caption.weight(.bold))
            .foregroundStyle(config.enabled ? .green : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background((config.enabled ? Color.green : Color.secondary).opacity(0.12), in: Capsule(style: .continuous))
    }

    private func roleChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var isEndpointComplete: Bool {
        !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var kindColor: Color {
        switch config.kind {
        case .openAICompatible: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .anthropic:        return Color(red: 0.83, green: 0.38, blue: 0.18)
        case .gemini:           return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .cliCommand:       return Color(red: 0.55, green: 0.45, blue: 0.78)
        }
    }

    private var providerSymbol: String {
        switch config.kind {
        case .openAICompatible: return "sparkles"
        case .anthropic:        return "text.book.closed"
        case .gemini:           return "diamond.fill"
        case .cliCommand:       return "terminal"
        }
    }
}

private struct MobileProviderEditorView: View {
    @Binding var config: ProviderConfig
    let onDelete: () -> Void
    let onSave: () -> Void
    let onToggleChair: (Bool) -> Void
    let onToggleSummary: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
    @State private var keyDirty: Bool = false
    @State private var lastError: String?
    @State private var lastSuccess: String?
    @State private var testing: Bool = false
    @State private var confirmingDelete: Bool = false

    var body: some View {
        Form {
            editorHeroSection
            identitySection
            if config.kind.isCLI {
                cliSection
            } else {
                connectionSection
            }
            roleSection
            advancedSection
            statusSection
            dangerSection
        }
        .navigationTitle(config.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(SettingsBackdrop())
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: config.displayName) { _, _ in onSave() }
        .onChange(of: config.enabled) { _, _ in onSave() }
        .onChange(of: config.baseURL) { _, _ in onSave() }
        .onChange(of: config.model) { _, _ in onSave() }
        .confirmationDialog("删除 \(config.displayName)?", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("该供应商配置会被移除, 对应 API Key 也会删除。")
        }
    }

    private var editorHeroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    providerMark
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(config.displayName)
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .lineLimit(1)
                        Text("\(config.kind.displayName) · \(config.model)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    editorStatusChip
                }

                Text(config.enabled ? "这个 Provider 会参与回答。你可以在这里调整连接、模型和 Council 角色。" : "当前不会参与回答，打开后会立即保存到本机配置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(kindColor.opacity(0.18), lineWidth: 1)
            }
        }
        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
    }

    private var identitySection: some View {
        Section("基础信息") {
            TextField("显示名", text: $config.displayName)
            Toggle("启用此供应商", isOn: $config.enabled)
        }
    }

    private var editorStatusChip: some View {
        Text(config.enabled ? "已启用" : "未启用")
            .font(.caption.weight(.bold))
            .foregroundStyle(config.enabled ? .green : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((config.enabled ? Color.green : Color.secondary).opacity(0.12), in: Capsule(style: .continuous))
    }

    private var connectionSection: some View {
        Section("连接") {
            TextField("Base URL", text: $config.baseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if config.kind == .openAICompatible {
                Picker("厂商标签", selection: Binding(
                    get: { config.vendor ?? "" },
                    set: { newValue in
                        config.vendor = newValue.isEmpty ? nil : newValue
                        onSave()
                    }
                )) {
                    Text("自定义 / 未指定").tag("")
                    ForEach(ProviderVendor.allCases) { vendor in
                        Text(vendor.displayName).tag(vendor.rawValue)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Model", text: $config.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                let models = ProviderModelCatalog.knownModels(for: config)
                if !models.isEmpty {
                    Menu {
                        ForEach(models, id: \.self) { m in
                            Button {
                                config.model = m
                                onSave()
                            } label: {
                                if m == config.model {
                                    Label(m, systemImage: "checkmark")
                                } else {
                                    Text(m)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("API Key")
                    Spacer()
                    if hasStoredKey && !keyDirty && apiKey.isEmpty {
                        Label("已保存", systemImage: "key.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                SecureField(keyPlaceholder, text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { _, newValue in
                        keyDirty = !newValue.isEmpty
                    }
                HStack(spacing: 10) {
                    Button {
                        saveKey()
                    } label: {
                        Label("保存 Key", systemImage: "key.fill")
                    }
                    .disabled(apiKey.isEmpty || !keyDirty)

                    Button {
                        runTest()
                    } label: {
                        if testing {
                            Label("测试中", systemImage: "hourglass")
                        } else {
                            Label("测试连接", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .disabled(!canTest)
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }

    private var cliSection: some View {
        Section("命令") {
            TextField("Command", text: Binding(
                get: { config.cliCommand ?? "" },
                set: { config.cliCommand = $0; onSave() }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            TextField("Args", text: Binding(
                get: { config.cliArgs ?? "" },
                set: { config.cliArgs = $0; onSave() }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Text("{prompt} 会被替换成实际输入。不带 {prompt} 则通过 stdin 传入。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var roleSection: some View {
        Section("Council 角色") {
            Toggle("主席：综合判断", isOn: Binding(
                get: { config.isChair },
                set: { onToggleChair($0) }
            ))
            Toggle("总结员：中立汇总", isOn: Binding(
                get: { config.isSummary },
                set: { onToggleSummary($0) }
            ))
        }
    }

    private var advancedSection: some View {
        Section("高级参数") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.1f", config.temperature ?? 0.7))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { config.temperature ?? 0.7 },
                    set: { config.temperature = $0; onSave() }
                ), in: 0...2, step: 0.1)
                Button("恢复默认 Temperature") {
                    config.temperature = nil
                    onSave()
                }
                .font(.caption)
                .disabled(config.temperature == nil)
            }
            TextField("Max Tokens (留空使用默认)", value: Binding(
                get: { config.maxTokens },
                set: { config.maxTokens = $0; onSave() }
            ), format: .number)
            .keyboardType(.numberPad)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let err = lastError {
            Section {
                resultBlock(text: err, icon: "exclamationmark.triangle.fill", color: .red, copyLabel: "复制完整错误")
            }
        } else if let ok = lastSuccess {
            Section {
                resultBlock(text: ok, icon: "checkmark.circle.fill", color: .green, copyLabel: "复制响应")
            }
        } else if config.enabled && !isEndpointComplete {
            Section {
                Label("启用前请补全 Base URL 和 Model", systemImage: "info.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 测试结果块(成功/失败共用):全文展示 + 复制按钮
    private func resultBlock(text: String, icon: String, color: Color, copyLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(text)
                    .foregroundStyle(color)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Platform.copyText(text)
            } label: {
                Label(copyLabel, systemImage: "doc.on.doc")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(color)
        }
    }

    private var dangerSection: some View {
        Section {
            Button("删除供应商", role: .destructive) {
                confirmingDelete = true
            }
        }
    }

    private var providerMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(kindColor.opacity(0.13))
            Image(systemName: providerSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(kindColor)
        }
        .frame(width: 44, height: 44)
    }

    private var keyPlaceholder: String {
        hasStoredKey ? "已保存 (留空表示不变)" : "粘贴 API Key"
    }

    private var hasStoredKey: Bool {
        KeychainStore.hasKey(id: config.id)
    }

    private var isEndpointComplete: Bool {
        !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canTest: Bool {
        !testing && isEndpointComplete && (!apiKey.isEmpty || hasStoredKey)
    }

    private var kindColor: Color {
        switch config.kind {
        case .openAICompatible: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .anthropic:        return Color(red: 0.83, green: 0.38, blue: 0.18)
        case .gemini:           return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .cliCommand:       return Color(red: 0.55, green: 0.45, blue: 0.78)
        }
    }

    private var providerSymbol: String {
        switch config.kind {
        case .openAICompatible: return "sparkles"
        case .anthropic:        return "text.book.closed"
        case .gemini:           return "diamond.fill"
        case .cliCommand:       return "terminal"
        }
    }

    private func saveKey() {
        do {
            try KeychainStore.save(id: config.id, apiKey: apiKey)
            apiKey = ""
            keyDirty = false
            flash(success: "API Key 已保存")
        } catch {
            flash(error: "保存失败: \(error.localizedDescription)")
        }
    }

    private func runTest() {
        lastError = nil
        lastSuccess = nil
        testing = true

        let resolvedKey: String
        if config.kind.isCLI {
            resolvedKey = ""
        } else {
            do {
                if !apiKey.isEmpty {
                    try KeychainStore.save(id: config.id, apiKey: apiKey)
                    resolvedKey = apiKey
                    apiKey = ""
                    keyDirty = false
                } else {
                    resolvedKey = try KeychainStore.load(id: config.id)
                }
            } catch {
                testing = false
                flash(error: "读取 Key 失败: \(error.localizedDescription)")
                return
            }
        }

        let snapshot = config
        Task { @MainActor in
            do {
                let sample = try await AppViewModel.testProvider(config: snapshot, apiKey: resolvedKey)
                let preview = sample.isEmpty ? "(空响应)" : "\"\(sample)\""
                flash(success: "连接成功 · 收到 \(preview)")
            } catch {
                flash(error: error.localizedDescription)
            }
            testing = false
        }
    }

    private func flash(success: String) {
        lastSuccess = success
        lastError = nil
    }

    private func flash(error: String) {
        lastError = error
        lastSuccess = nil
    }
}
#endif
