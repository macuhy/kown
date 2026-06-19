import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case providers
        case modelDoctor
        case prompts
        case skills
        case connectorHub
        case agentRuns
        case meetingWorkflow
        case deliverables
        case skillPackages
        case personas
        case deviceTools
        case mcp
        case github
        case chains
        case webSearch
        case tts
        case secretStore
        case sync
        case backup
        case usage
        case dashboard
        case memory
        case favorites
        case leaderboard
        case routing
        case eval
        case scheduler
        case performance
        case updates
        case changelog
        case debugLog
        // MARK: - [PII]
        case privacy
        // MARK: - [PII] end

        var id: String { rawValue }
        var label: String {
            switch self {
            case .providers:   return "厂商"
            case .modelDoctor: return "模型体检"
            case .prompts:     return "Prompt 库"
            case .skills:      return "技能"
            case .connectorHub: return "连接器"
            case .agentRuns:    return "Agent 运行"
            case .meetingWorkflow: return "会议闭环"
            case .deliverables: return "交付物"
            case .skillPackages: return "技能包"
            case .personas:    return "Persona"
            case .deviceTools: return "设备工具"
            case .mcp:         return "MCP"
            case .github:      return "GitHub"
            case .chains:      return "工作流"
            case .webSearch:   return "Web Search"
            case .tts:         return "朗读"
            case .secretStore:  return "密钥存储"
            case .sync:        return "iCloud 同步"
            case .backup:      return "导入/导出"
            case .usage:       return "Token 用量"
            case .dashboard:   return "仪表盘"
            case .memory:      return "记忆"
            case .favorites:   return "收藏"
            case .leaderboard: return "排行榜"
            case .routing:     return "模型路由"
            case .eval:        return "评测台"
            case .scheduler:   return "定时任务"
            case .performance: return "性能"
            case .updates:     return "软件更新"
            case .changelog:   return "更新日志"
            case .debugLog:    return "调试日志"
            // MARK: - [PII]
            case .privacy:     return "隐私脱敏"
            // MARK: - [PII] end
            }
        }
        var symbol: String {
            switch self {
            case .providers:   return "square.stack.3d.up"
            case .modelDoctor: return "stethoscope"
            case .prompts:     return "text.badge.plus"
            case .skills:      return "wand.and.stars"
            case .connectorHub: return "point.3.connected.trianglepath.dotted"
            case .agentRuns:    return "list.bullet.rectangle.portrait"
            case .meetingWorkflow: return "person.2.wave.2"
            case .deliverables: return "shippingbox.and.arrow.backward.fill"
            case .skillPackages: return "shippingbox.fill"
            case .personas:    return "theatermasks"
            case .deviceTools: return "wrench.and.screwdriver.fill"
            case .mcp:         return "powerplug"
            case .github:      return "chevron.left.forwardslash.chevron.right"
            case .chains:      return "arrow.triangle.branch"
            case .webSearch:   return "globe"
            case .tts:         return "waveform"
            case .secretStore:  return "key.fill"
            case .sync:        return "icloud"
            case .backup:      return "square.and.arrow.up.on.square"
            case .usage:       return "chart.bar.xaxis"
            case .dashboard:   return "chart.line.uptrend.xyaxis"
            case .memory:      return "brain"
            case .favorites:   return "star"
            case .leaderboard: return "trophy.fill"
            case .routing:     return "arrow.triangle.branch"
            case .eval:        return "checklist"
            case .scheduler:   return "clock.badge"
            case .performance: return "speedometer"
            case .updates:     return "arrow.down.circle"
            case .changelog:   return "sparkles"
            case .debugLog:    return "ladybug"
            // MARK: - [PII]
            case .privacy:     return "hand.raised.fill"
            // MARK: - [PII] end
            }
        }
        var tint: Color {
            switch self {
            case .providers:   return Color(red: 0.10, green: 0.66, blue: 0.56)
            case .modelDoctor: return Color(red: 0.10, green: 0.66, blue: 0.56)
            case .prompts:     return Color(red: 0.56, green: 0.40, blue: 0.86)
            case .skills:      return Color(red: 0.48, green: 0.36, blue: 0.90)
            case .connectorHub: return Color(red: 0.12, green: 0.58, blue: 0.62)
            case .agentRuns:    return Color(red: 0.10, green: 0.45, blue: 0.72)
            case .meetingWorkflow: return Color(red: 0.85, green: 0.42, blue: 0.18)
            case .deliverables: return Color(red: 0.88, green: 0.46, blue: 0.18)
            case .skillPackages: return Color(red: 0.10, green: 0.62, blue: 0.70)
            case .personas:    return Color(red: 0.72, green: 0.34, blue: 0.62)
            case .deviceTools: return Color(red: 0.20, green: 0.60, blue: 0.62)
            case .mcp:         return Color(red: 0.26, green: 0.54, blue: 0.80)
            case .github:      return Color(red: 0.18, green: 0.62, blue: 0.58)
            case .chains:      return Color(red: 0.30, green: 0.52, blue: 0.88)
            case .webSearch:   return Color(red: 0.16, green: 0.48, blue: 0.94)
            case .tts:         return Color(red: 0.36, green: 0.46, blue: 0.92)
            case .secretStore:  return Color(red: 0.18, green: 0.54, blue: 0.48)
            case .sync:        return Color(red: 0.18, green: 0.58, blue: 0.92)
            case .backup:      return Color(red: 0.91, green: 0.55, blue: 0.20)
            case .usage:       return Color(red: 0.24, green: 0.63, blue: 0.36)
            case .dashboard:   return Color(red: 0.18, green: 0.52, blue: 0.92)
            case .memory:      return Color(red: 0.56, green: 0.40, blue: 0.86)
            case .favorites:   return Color(red: 0.92, green: 0.70, blue: 0.18)
            case .leaderboard: return Color(red: 0.85, green: 0.60, blue: 0.14)
            case .routing:     return Color(red: 0.46, green: 0.40, blue: 0.90)
            case .eval:        return Color(red: 0.40, green: 0.52, blue: 0.92)
            case .scheduler:   return Color(red: 0.20, green: 0.56, blue: 0.78)
            case .performance: return Color(red: 0.88, green: 0.35, blue: 0.22)
            case .updates:     return Color(red: 0.57, green: 0.42, blue: 0.82)
            case .changelog:   return Color(red: 0.95, green: 0.57, blue: 0.16)
            case .debugLog:    return Color(red: 0.46, green: 0.49, blue: 0.55)
            // MARK: - [PII]
            case .privacy:     return Color(red: 0.16, green: 0.52, blue: 0.50)
            // MARK: - [PII] end
            }
        }
    }

    @State private var tab: Tab = .providers
    @State private var promptLibrary = PromptLibraryStore()
    @State private var settingsSearchQuery = ""
    #if os(iOS)
    @Namespace private var mobileTabNamespace
    #endif
    private static let desktopWidth: CGFloat = 960
    private static let desktopHeight: CGFloat = 660
    private static let desktopSheetTopPadding: CGFloat = 14

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
        Group {
            #if os(iOS)
            mobileBody
            #else
            desktopBody
            #endif
        }
        .onChange(of: settingsSearchQuery) { _, _ in
            selectFirstVisibleTabIfNeeded()
        }
    }

    private var normalizedSettingsSearchQuery: String {
        settingsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredTabs: [Tab] {
        let query = normalizedSettingsSearchQuery
        guard !query.isEmpty else { return availableTabs }
        return availableTabs.filter { tabMatches($0, query: query) }
    }

    private var filteredDesktopTabSections: [(title: String, tabs: [Tab])] {
        let visibleTabs = Set(filteredTabs)
        return desktopTabSections
            .map { section in
                (title: section.title, tabs: section.tabs.filter { visibleTabs.contains($0) })
            }
            .filter { !$0.tabs.isEmpty }
    }

    private func tabMatches(_ candidate: Tab, query: String) -> Bool {
        let haystack = "\(candidate.label) \(candidate.rawValue) \(candidate.symbol) \(headerSubtitle(for: candidate))"
        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func selectFirstVisibleTabIfNeeded() {
        let tabs = filteredTabs
        guard !tabs.isEmpty, !tabs.contains(tab) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            tab = tabs[0]
        }
    }

    private var desktopBody: some View {
        // 顶部对齐:避免侧栏(高度可能与右栏不一致)被 .center 垂直居中后头部上浮到 sheet 顶被裁。
        HStack(alignment: .top, spacing: 0) {
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
        .frame(width: Self.desktopWidth, height: Self.desktopHeight, alignment: .topLeading)
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
                    case .modelDoctor:
                        ModelDoctorView(viewModel: viewModel)
                    case .prompts:
                        PromptLibraryView(viewModel: promptLibrary)
                    case .skills:
                        SkillsLibraryView(store: viewModel.skillsStore, viewModel: viewModel)
                    case .connectorHub:
                        ConnectorHubView()
                    case .agentRuns:
                        AgentRunCenterView(embeddedInSettings: true)
                    case .meetingWorkflow:
                        MeetingWorkflowView(
                            title: "会议闭环示例",
                            attendees: ["我", "团队"],
                            transcript: "我们决定先上线连接器中心。下周三前补齐 Agent 运行中心。风险是入口太分散,需要统一到设置页。",
                            embeddedInSettings: true
                        )
                    case .deliverables:
                        DeliverableStudioView(request: DeliverableRequest(title: "路线图交付物", sourceKind: .research, sourceText: "# 结论\nKown 下一步应把连接器、Agent 运行、会议闭环、交付物和技能包串成闭环。"))
                    case .skillPackages:
                        SkillPackageMarketView(onInstallPackage: installSkillPackage)
                    case .personas:
                        PersonaSettingsView(viewModel: viewModel)
                    case .deviceTools:
                        DeviceToolsSettingsView(viewModel: viewModel)
                    case .mcp:
                        MCPSettingsView(viewModel: viewModel)
                    case .github:
                        gitHubTab
                    case .chains:
                        ChainView()
                    case .webSearch:
                        WebSearchSettingsView(viewModel: viewModel)
                    case .tts:
                        TTSSettingsView()
                    case .secretStore:
                        SecretStoreSettingsView(viewModel: viewModel)
                    case .sync:
                        ICloudSyncSettingsView(viewModel: viewModel)
                    case .backup:
                        BackupSettingsView(viewModel: viewModel)
                    case .usage:
                        UsageSettingsView()
                    case .dashboard:
                        UsageDashboardView()
                    case .memory:
                        MemorySettingsView(viewModel: viewModel)
                    case .favorites:
                        FavoritesSettingsView()
                    case .leaderboard:
                        LeaderboardView(viewModel: viewModel)
                    case .routing:
                        ModelRoutingSettingsView(viewModel: viewModel)
                    case .eval:
                        EvalView(viewModel: viewModel)
                    case .scheduler:
                        SchedulerView(viewModel: viewModel)
                    case .performance:
                        PerformanceSettingsView()
                    case .updates:
                        EmptyView()   // iOS 不展示;.updates 已从 availableTabs 过滤
                    case .changelog:
                        ChangelogView(embeddedInSettings: true)
                    case .debugLog:
                        DebugLogSettingsView()
                    // MARK: - [PII]
                    case .privacy:
                        PrivacySettingsView()
                    // MARK: - [PII] end
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
                HStack(spacing: 7) {
                    SettingsAppIcon()
                        .frame(width: 26, height: 26)
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
                            .minimumScaleFactor(0.86)
                    }

                    Spacer(minLength: 0)
                }

                settingsSearchField

                if filteredTabs.isEmpty {
                    settingsSearchEmptyState
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(filteredTabs) { t in
                                mobileTabPill(t)
                                    .id(t.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)
                    }
                    .padding(.horizontal, -14)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 5)
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
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 36, height: 36)
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
            VStack(alignment: .leading, spacing: 11) {
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
                                    },
                                    onToggleKeyboard: { newValue in
                                        viewModel.setKeyboardModel(cfg.id, newValue)
                                    }
                                )
                            } label: {
                                MobileProviderSummaryRow(config: cfg)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                watchSyncCard
                // AI 键盘:配置共享开关(卡片实现在 KeyboardConfigBridge.swift,此处只挂一行)。
                KeyboardBridgeSettingsCard { viewModel.setKeyboardBridgeEnabled($0) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
    }

    @State private var watchSyncDone = false
    /// Apple Watch 独立表盘:把当前 OpenAI 兼容模型推送到表盘(共享 App Group)。
    private var watchSyncCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Apple Watch", systemImage: "applewatch")
                .font(.headline)
            Text("把一个 OpenAI 兼容、已填 API Key 的模型同步给表盘,即可在手表上独立提问(语音输入 + 朗读回答)。改动模型会自动同步,也可手动推送。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                watchSyncDone = viewModel.syncWatchProvider()
            } label: {
                Label(watchSyncDone ? "已同步" : "同步到 Apple Watch",
                      systemImage: watchSyncDone ? "checkmark.circle.fill" : "arrow.up.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var mobileProviderHero: some View {
        let total = viewModel.providers.count
        let enabled = viewModel.providers.filter(\.enabled).count
        let tint = enabled == 0 ? Color.orange : tab.tint
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
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
                .frame(width: 42, height: 42)
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

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                mobileHeroChip(title: "启用", value: "\(enabled)/\(total)", color: enabled == 0 ? .orange : .green)
                mobileHeroChip(title: "总数", value: "\(total)", color: .secondary)
                if let chair = viewModel.providers.first(where: \.isChair) {
                    mobileHeroChip(title: "Chair", value: chair.displayName, color: .orange)
                }
            }
        }
        .padding(11)
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
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
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
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: 132, alignment: .leading)
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

    private var settingsSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索设置或输入关键字", text: $settingsSearchQuery)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if !settingsSearchQuery.isEmpty {
                Button {
                    settingsSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空设置搜索")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.platformControlBackground.opacity(0.62), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityLabel("搜索设置")
    }

    private var settingsSearchEmptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text("没有匹配的设置项")
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var desktopTabSections: [(title: String, tabs: [Tab])] {
        [
            ("基础", [.providers, .modelDoctor, .prompts, .skills, .skillPackages, .deviceTools, .github]),
            ("工作台", [.connectorHub, .agentRuns, .meetingWorkflow, .deliverables]),
            ("工作流", [.personas, .chains, .mcp, .webSearch, .tts, .scheduler, .performance]),
            ("数据", [.secretStore, .sync, .backup, .memory, .favorites, .privacy]),
            ("洞察", [.usage, .dashboard, .leaderboard, .eval]),
            ("版本", [.updates, .changelog, .debugLog])
        ]
        .map { section in
            (title: section.0, tabs: section.1.filter { availableTabs.contains($0) })
        }
        .filter { !$0.tabs.isEmpty }
    }

    private var desktopSidebar: some View {
        VStack(alignment: .leading, spacing: 13) {
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

            settingsSearchField

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if filteredDesktopTabSections.isEmpty {
                        settingsSearchEmptyState
                    } else {
                        ForEach(Array(filteredDesktopTabSections.enumerated()), id: \.offset) { _, section in
                            desktopTabSection(title: section.title, tabs: section.tabs)
                        }
                    }

                    sidebarStatusCard
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
        }
        // macOS sheet 会压在宿主窗口工具栏下方,这里额外下移,避免顶部控件贴边或被裁。
        .padding(.top, Self.desktopSheetTopPadding)
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .frame(width: 230)
        .background(.ultraThinMaterial)
    }

    private func desktopTabSection(title: String, tabs: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
            ForEach(tabs) { t in
                desktopTabButton(t)
            }
        }
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
                    .frame(width: 22, height: 22)
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
            .padding(.vertical, 8)
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
        return VStack(alignment: .leading, spacing: 8) {
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.58), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var desktopHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tab.tint.opacity(0.24), tab.tint.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: tab.symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tab.tint)
            }
            .frame(width: 44, height: 44)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tab.tint.opacity(0.22), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(tab.label)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        .padding(.horizontal, 20)
        // 与侧栏一致:避开宿主窗口工具栏下缘,给顶部标题和按钮留出呼吸感。
        .padding(.top, Self.desktopSheetTopPadding)
        .padding(.bottom, 13)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var desktopContent: some View {
        Group {
            switch tab {
            case .providers:
                providersList
            case .modelDoctor:
                ModelDoctorView(viewModel: viewModel)
            case .prompts:
                PromptLibraryView(viewModel: promptLibrary)
            case .skills:
                SkillsLibraryView(store: viewModel.skillsStore, viewModel: viewModel)
            case .connectorHub:
                ConnectorHubView()
            case .agentRuns:
                AgentRunCenterView(embeddedInSettings: true)
            case .meetingWorkflow:
                MeetingWorkflowView(
                    title: "会议闭环示例",
                    attendees: ["我", "团队"],
                    transcript: "我们决定先上线连接器中心。下周三前补齐 Agent 运行中心。风险是入口太分散,需要统一到设置页。",
                    embeddedInSettings: true
                )
            case .deliverables:
                DeliverableStudioView(request: DeliverableRequest(title: "路线图交付物", sourceKind: .research, sourceText: "# 结论\nKown 下一步应把连接器、Agent 运行、会议闭环、交付物和技能包串成闭环。"))
            case .skillPackages:
                SkillPackageMarketView(onInstallPackage: installSkillPackage)
            case .personas:
                PersonaSettingsView(viewModel: viewModel)
            case .deviceTools:
                DeviceToolsSettingsView(viewModel: viewModel)
            case .mcp:
                MCPSettingsView(viewModel: viewModel)
            case .github:
                gitHubTab
            case .chains:
                ChainView()
            case .webSearch:
                WebSearchSettingsView(viewModel: viewModel)
            case .tts:
                TTSSettingsView()
            case .secretStore:
                SecretStoreSettingsView(viewModel: viewModel)
            case .sync:
                ICloudSyncSettingsView(viewModel: viewModel)
            case .backup:
                BackupSettingsView(viewModel: viewModel)
            case .usage:
                UsageSettingsView()
            case .dashboard:
                UsageDashboardView()
            case .memory:
                MemorySettingsView(viewModel: viewModel)
            case .favorites:
                FavoritesSettingsView()
            case .leaderboard:
                LeaderboardView(viewModel: viewModel)
            case .routing:
                ModelRoutingSettingsView(viewModel: viewModel)
            case .eval:
                EvalView(viewModel: viewModel)
            case .scheduler:
                SchedulerView(viewModel: viewModel)
            case .performance:
                PerformanceSettingsView()
            case .updates:
                #if os(macOS)
                UpdateSettingsView(onRequestUpdate: {
                    // 先关掉设置 sheet,再触发 Sparkle —— 否则 modal sheet 挡住安装/重启的 terminate。
                    dismiss()
                    UpdaterService.shared.checkForUpdates()
                })
                #else
                EmptyView()
                #endif
            case .changelog:
                ChangelogView(embeddedInSettings: true)
            case .debugLog:
                DebugLogSettingsView()
            // MARK: - [PII]
            case .privacy:
                PrivacySettingsView()
            // MARK: - [PII] end
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
                providerSetupCard
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

    private var providerSetupCard: some View {
        let enabled = viewModel.providers.filter(\.enabled).count
        let total = viewModel.providers.count
        let tint = enabled == 0 ? Color.orange : Color.green
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                providerSetupTitle(enabled: enabled, total: total, tint: tint)
                Spacer(minLength: 8)
                providerSetupSteps(tint: tint)
                addProviderMenu
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            }

            VStack(alignment: .leading, spacing: 14) {
                providerSetupTitle(enabled: enabled, total: total, tint: tint)
                providerSetupSteps(tint: tint)
                addProviderMenu
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.11), Color.platformControlBackground.opacity(0.20), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        }
    }

    private func providerSetupTitle(enabled: Int, total: Int, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: enabled == 0 ? "wand.and.rays" : "checkmark.seal.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(enabled == 0 ? "三步完成模型配置" : "模型配置已就绪")
                    .font(.headline.weight(.bold))
                Text(enabled == 0 ? "先添加厂商,再填 Model / API Key,最后保存并测试。" : "\(enabled)/\(total) 家 Provider 已启用,仍可继续补充备用模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 220, alignment: .leading)
    }

    private func providerSetupSteps(tint: Color) -> some View {
        HStack(spacing: 8) {
            setupStep("1", "添加厂商", tint: tint)
            setupStep("2", "填模型和 Key", tint: tint)
            setupStep("3", "保存后测试", tint: tint)
        }
    }

    private func setupStep(_ number: String, _ title: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Text(number)
                .font(.caption2.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(tint, in: Circle())
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.platformControlBackground.opacity(0.58), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
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

    /// GitHub 连接设置页:连接卡片 + 用法说明。(macOS / iOS 共用)
    private var gitHubTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GitHubConnectionCard(viewModel: viewModel)
                VStack(alignment: .leading, spacing: 8) {
                    Label("怎么用", systemImage: "info.circle")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("""
                    1. 点「连接」,在浏览器输入验证码完成授权(授权范围 repo,可读写你的仓库)。
                    2. 回到对话,在输入栏的「选仓库」里选一个目标仓库。
                    3. 让模型把定稿内容写进文件 —— 它会用 kown:write 块,系统自动提交到该仓库,\
                    并在聊天里显示每个文件的 +/- 行数与 commit 链接。

                    提示:本会话同时设了本地 workspace 时,以本地写入优先。
                    """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
    }

    private var headerSubtitle: String { headerSubtitle(for: tab) }

    private func headerSubtitle(for tab: Tab) -> String {
        switch tab {
        case .providers:   return "管理连接、密钥和每个模型的默认生成参数。"
        case .modelDoctor: return "批量检测模型是否真能用,并给出 Key、模型名、Base URL、限流和 CLI 的修复建议。"
        case .prompts:     return "保存可复用的 Prompt 模板,用 {{变量}} 占位,填充后一键复制。"
        case .skills:      return "技能 = 系统提示 + 可用工具。可按输入自动触发,也可绑定到当前会话。"
        case .connectorHub: return "统一查看 GitHub、Web、MCP、知识库、iCloud、日历提醒和设备工具的连接状态与权限。"
        case .agentRuns:   return "集中查看长任务、深度研究、定时任务、工具调用和会议任务的运行记录、步骤、审批和成本。"
        case .meetingWorkflow: return "把会议从会前准备、会中捕获到会后行动项追踪串成闭环。"
        case .deliverables: return "把回答、研究或会议内容整理成 Markdown、HTML、网页、PDF/PPT 大纲。"
        case .skillPackages: return "导入、导出和预览 .kownskill 技能包,包含提示词、变量、示例和所需工具权限。"
        case .personas:    return "Persona = 系统提示词 + 默认模型 + 工具/技能/知识库 打包成档案,输入栏按会话一键切换。"
        case .deviceTools: return "让模型在你的系统「提醒事项 / 备忘录」里创建条目。需授权;iOS 备忘录走剪贴板+跳转。"
        case .mcp:         return "挂载外部 MCP server,把任意第三方工具暴露给模型。支持远程 HTTP/SSE,macOS 还支持本地 stdio 命令。"
        case .github:      return "连接 GitHub 后,对话里可选仓库,把定稿内容直接提交;聊天显示改动行数与 commit 链接。"
        case .chains:      return "把多个「模型 + 指示」步骤串成流水线,用 {{prev}} / {{input}} 接力,逐步执行。"
        case .webSearch:   return "配置 Firecrawl 让模型在需要时调用 web_search。"
        case .tts:         return "选择朗读引擎与音色:硅基流动 CosyVoice、讯飞语音(均国内直连)或系统语音。"
        case .secretStore: return "显式迁移 API Key / token 的本机存储后端;默认 JSON,可选择系统 Keychain。"
        case .sync:        return "iCloud 同步会话、Provider 配置与 Web Search 配置;API Key 留在本机 secret store。"
        case .backup:      return "把当前配置(不含会话)导出成 JSON 文件,或从备份恢复。可作为多设备同步的离线备选。"
        case .usage:       return "按天 + 模型查看 token 用量。input / output 分别计,辅助估算成本。"
        case .dashboard:   return "用图表对比各模型的用量与成本:成本排行、每日 token 走势与输入/输出内訳。"
        case .memory:      return "管理跨会话长期记忆:开关注入、查看与删除已抽取的记忆条目。默认关闭(隐私优先)。"
        case .favorites:   return "收藏过的回答片段,点星可在回答卡上收藏 / 取消。"
        case .leaderboard: return "Compare 模式裁判判定累计出的模型胜率榜:按胜率排名,看哪家模型更常赢。"
        case .routing:     return "个人口味盲测 + Direct 模式的模型路由开关:盲选攒出你的偏好画像,让「用我的偏好」按类别替你选模型。"
        case .eval:        return "保存「问题 + 期望关键词」评测集,在多个模型上重跑比对,检测版本更新后的回归漂移。"
        case .scheduler:   return "让指定提问在每天固定时刻自动发送、结果存成新会话并发通知。仅在 app 运行期间触发。"
        case .performance: return "流式响应的渲染节奏。机器卡可以拉长刷新间隔降 CPU。"
        case .updates:     return "通过 Sparkle 检查、下载并自动安装最新版本。"
        case .changelog:   return "查看每个版本的新功能、修复和改进。"
        case .debugLog:    return "记录每个网络请求的完整请求体与原始返回,排查空响应等问题。"
        // MARK: - [PII]
        case .privacy:     return "发往云端模型前,在本机把手机号 / 邮箱 / 身份证 / 银行卡(可选人名)替换成占位符,返回时还原。本地模型自动跳过。默认关闭。"
        // MARK: - [PII] end
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

    private func installSkillPackage(_ package: SkillPackage) {
        viewModel.skillsStore.upsert(package.makeSkill(enabled: true, isPreset: false))
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
        // 用真 app 图标(NSApp.applicationIconImage 始终可取)。关键是 scaledToFit 而非
        // scaledToFill:新版 macOS 的图标是「带透明边距的圆角 squircle」,scaledToFill 会撑满
        // 方框把顶部裁掉 → 图标顶被切。scaledToFit 完整显示、不裁。
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            }
        #else
        // iOS 下 `Image("AppIcon")` 取不到 app 图标,改用 LaunchLogo imageset。
        Image("LaunchLogo")
            .resizable()
            .scaledToFit()
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
        HStack(spacing: 10) {
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
                    if !config.kind.isCLI && !config.kind.isAppleFM && !isEndpointComplete {
                        roleChip("待补全", color: .orange)
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 8) {
                statusChip
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
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
        .frame(width: 38, height: 38)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(kindColor.opacity(0.16), lineWidth: 1)
        }
    }

    private var statusChip: some View {
        Text(config.enabled ? "启用" : "关闭")
            .font(.caption.weight(.bold))
            .foregroundStyle(config.enabled ? .green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
        config.kownTint
    }

    private var providerSymbol: String {
        config.kownSymbol
    }
}

private struct MobileProviderEditorView: View {
    @Binding var config: ProviderConfig
    let onDelete: () -> Void
    let onSave: () -> Void
    let onToggleChair: (Bool) -> Void
    let onToggleSummary: (Bool) -> Void
    let onToggleKeyboard: (Bool) -> Void

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
            } else if config.kind.isAppleFM {
                appleFMSection
            } else {
                connectionSection
            }
            roleSection
            if config.kind == .openAICompatible || config.kind == .anthropic {
                keyboardSection
            }
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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        editorHeroTitle
                        Spacer(minLength: 8)
                        editorStatusChip
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        editorHeroTitle
                        editorStatusChip
                    }
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

    private var editorHeroTitle: some View {
        HStack(alignment: .top, spacing: 12) {
            providerMark
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(config.displayName)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text("\(config.kind.displayName) · \(config.model)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
        }
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
                ViewThatFits(in: .horizontal) {
                    keyEditorButtons(axis: .horizontal)
                    keyEditorButtons(axis: .vertical)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private enum ButtonAxis {
        case horizontal
        case vertical
    }

    @ViewBuilder
    private func keyEditorButtons(axis: ButtonAxis) -> some View {
        let buttons = Group {
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

        switch axis {
        case .horizontal:
            HStack(spacing: 10) { buttons }
                .buttonStyle(.bordered)
        case .vertical:
            VStack(alignment: .leading, spacing: 8) { buttons }
                .buttonStyle(.bordered)
        }
    }

    /// Apple 本地模型:无 URL / 无 Key,展示说明 + 可用状态 + 测试按钮。
    private var appleFMSection: some View {
        Section("端侧模型") {
            Text("系统内置端侧模型 — 免 API Key、零成本、全离线,数据不出本机。上下文窗口约 4096 token,适合日常问答与短文本处理。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let notice = AppleFMClient.availabilityNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Label("可用 · 端侧运行", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
            Button {
                runTest()
            } label: {
                if testing {
                    Label("测试中", systemImage: "hourglass")
                } else {
                    Label("测试生成", systemImage: "bolt.horizontal.circle")
                }
            }
            .disabled(testing)
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

    private var keyboardSection: some View {
        Section {
            Toggle("设为键盘模型", isOn: Binding(
                get: { config.isKeyboardModel },
                set: { onToggleKeyboard($0) }
            ))
        } header: {
            Text("AI 键盘")
        } footer: {
            Text("AI 键盘的润色、翻译、截图回复都用这个模型。需先在下方「AI 键盘」卡片打开共享开关。单选:只会有一个模型被键盘使用。")
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
        // Apple 本地模型不需要 Base URL / Key,始终视为配置完整。
        if config.kind.isAppleFM { return true }
        return !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canTest: Bool {
        !testing && isEndpointComplete && (!apiKey.isEmpty || hasStoredKey || !config.kind.needsAPIKey)
    }

    private var kindColor: Color {
        config.kownTint
    }

    private var providerSymbol: String {
        config.kownSymbol
    }

    private func saveKey() {
        do {
            try KeychainStore.save(id: config.id, apiKey: apiKey)
            apiKey = ""
            keyDirty = false
            onSave()
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
        if !config.kind.needsAPIKey {
            resolvedKey = ""
        } else {
            do {
                if !apiKey.isEmpty {
                    try KeychainStore.save(id: config.id, apiKey: apiKey)
                    onSave()
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
