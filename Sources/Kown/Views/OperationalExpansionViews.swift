import SwiftUI

/// 设置 ▸ 项目启动台:把当前项目/会话的模型、连接器、知识库、Workspace 和自动化准备度放到一张图里。
struct ProjectLaunchpadView: View {
    @Bindable var viewModel: AppViewModel
    @State private var connectorSnapshot = ConnectorHubService.snapshot()

    private let tint = Color(red: 0.14, green: 0.58, blue: 0.56)
    private let warmTint = Color(red: 0.88, green: 0.52, blue: 0.20)

    private var selectedConversation: Conversation? { viewModel.selectedConversation }
    private var currentProject: ConversationFolder? {
        selectedConversation.flatMap { viewModel.projectFolder(of: $0) }
    }
    private var effectiveKnowledgeFolder: KnowledgeFolder? {
        viewModel.currentKnowledgeFolder ?? selectedConversation.flatMap { viewModel.projectKnowledgeFolder(of: $0) }
    }

    private var readinessItems: [OpsStatusItem] {
        let enabledProviders = viewModel.providers.filter(\.enabled)
        let readyConnectors = connectorSnapshot.readyConnectors.count
        let webReady = connectorSnapshot.connectors.first(where: { $0.kind == .web })?.isReadyForAgent == true
        let mcpReady = connectorSnapshot.connectors.first(where: { $0.kind == .mcp })?.isReadyForAgent == true
        return [
            OpsStatusItem(
                title: "模型",
                detail: enabledProviders.isEmpty ? "没有启用的 Provider" : "\(enabledProviders.count) 家可发送",
                state: enabledProviders.isEmpty ? .bad : .good,
                icon: enabledProviders.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
            ),
            OpsStatusItem(
                title: "项目空间",
                detail: currentProject?.name ?? "当前会话未归入项目空间",
                state: currentProject == nil ? .warn : .good,
                icon: "folder.fill"
            ),
            OpsStatusItem(
                title: "知识库",
                detail: effectiveKnowledgeFolder.map { "\($0.name) · \($0.docs.count) 篇" } ?? "未绑定资料夹",
                state: effectiveKnowledgeFolder == nil ? .warn : .good,
                icon: "books.vertical.fill"
            ),
            OpsStatusItem(
                title: "Workspace",
                detail: viewModel.currentWorkspaceDisplayPath ?? "未授权本地工作目录",
                state: viewModel.currentWorkspaceDisplayPath == nil ? .warn : .good,
                icon: "externaldrive.fill"
            ),
            OpsStatusItem(
                title: "Agent 工具",
                detail: "\(readyConnectors)/\(connectorSnapshot.connectors.count) 个连接器可用",
                state: readyConnectors == 0 ? .bad : (webReady || mcpReady ? .good : .warn),
                icon: "point.3.connected.trianglepath.dotted"
            )
        ]
    }

    var body: some View {
        OpsPage(tint: tint) {
            OpsHero(
                title: "项目启动台",
                subtitle: selectedConversation?.title ?? "选择一个会话后可看到项目上下文",
                icon: "rectangle.3.group.bubble.left.fill",
                tint: tint,
                trailing: {
                    Button {
                        connectorSnapshot = ConnectorHubService.snapshot()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 10)], spacing: 10) {
                OpsMetricTile(title: "启用模型", value: "\(viewModel.providers.filter(\.enabled).count)", detail: "Provider", icon: "bolt.fill", tint: tint)
                OpsMetricTile(title: "连接器", value: connectorSnapshot.healthSummary, detail: "Agent 可用", icon: "powerplug.fill", tint: warmTint)
                OpsMetricTile(title: "项目空间", value: "\(viewModel.conversationFolders.count)", detail: "分组配置", icon: "folder.fill", tint: .blue)
                OpsMetricTile(title: "知识文档", value: "\(viewModel.knowledgeFolders.reduce(0) { $0 + $1.docs.count })", detail: "RAG 资料", icon: "doc.text.fill", tint: .green)
            }

            OpsSectionHeader(title: "准备度", subtitle: "当前会话进入 Agent 工作前需要确认的上下文。")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                ForEach(readinessItems) { item in
                    OpsStatusRow(item: item)
                }
            }

            if !connectorSnapshot.suggestedActions.isEmpty {
                OpsSectionHeader(title: "优先补齐", subtitle: "来自连接器中心的建议动作。")
                LazyVStack(spacing: 10) {
                    ForEach(connectorSnapshot.suggestedActions.prefix(6)) { action in
                        OpsActionRow(
                            title: action.title,
                            detail: "\(action.connector.displayName) · \(action.detail)",
                            icon: action.connector.systemImage,
                            tint: action.priority == .high ? .orange : tint
                        )
                    }
                }
            }
        }
    }
}

/// 设置 ▸ 知识摄取:检查知识库资料夹是否有空文档、重复名、缺页码/分块和过旧资料。
struct KnowledgeIntakeAuditView: View {
    @Bindable var viewModel: AppViewModel
    @State private var message: String?

    private let tint = Color(red: 0.22, green: 0.56, blue: 0.82)
    private let greenTint = Color(red: 0.20, green: 0.62, blue: 0.38)

    private var docCount: Int { viewModel.knowledgeFolders.reduce(0) { $0 + $1.docs.count } }
    private var charCount: Int { viewModel.knowledgeFolders.reduce(0) { $0 + $1.totalChars } }

    private var issues: [KnowledgeIntakeIssue] {
        var rows: [KnowledgeIntakeIssue] = []
        let staleCutoff = Date().addingTimeInterval(-180 * 24 * 3600)
        for folder in viewModel.knowledgeFolders {
            if folder.docs.isEmpty {
                rows.append(.init(folder: folder.name, document: nil, title: "空资料夹", detail: "还没有可检索文档", severity: .warn))
            }
            let grouped = Dictionary(grouping: folder.docs, by: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            for docs in grouped.values where docs.count > 1 {
                rows.append(.init(folder: folder.name, document: docs[0].name, title: "重复文档名", detail: "\(docs.count) 篇同名文档", severity: .warn))
            }
            for doc in folder.docs {
                let trimmed = doc.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count < 80 {
                    rows.append(.init(folder: folder.name, document: doc.name, title: "正文过短", detail: "可能是空抓取或解析失败", severity: .bad))
                }
                if doc.charCount > 20_000 && (doc.chunks?.isEmpty ?? true) {
                    rows.append(.init(folder: folder.name, document: doc.name, title: "大文档未预切块", detail: "\(opsCompactCount(doc.charCount)) 字符", severity: .warn))
                }
                if doc.addedAt < staleCutoff {
                    rows.append(.init(folder: folder.name, document: doc.name, title: "资料过旧", detail: opsRelativeDate(doc.addedAt), severity: .info))
                }
                if doc.sourceFile == nil && doc.pageCount == nil && doc.text.localizedCaseInsensitiveContains("来源:") == false {
                    rows.append(.init(folder: folder.name, document: doc.name, title: "来源线索不足", detail: "没有文件名、页码或来源前缀", severity: .info))
                }
            }
        }
        return rows.sorted { $0.severity.rank < $1.severity.rank }
    }

    var body: some View {
        OpsPage(tint: tint) {
            OpsHero(
                title: "知识摄取审计",
                subtitle: "\(viewModel.knowledgeFolders.count) 个资料夹 · \(docCount) 篇文档",
                icon: "tray.and.arrow.down.fill",
                tint: tint,
                trailing: {
                    HStack(spacing: 8) {
                        Button {
                            createInboxIfNeeded()
                        } label: {
                            Label("收件箱", systemImage: "tray.fill")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            preindexAll()
                        } label: {
                            Label("预热向量", systemImage: "bolt.horizontal.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(greenTint)
                    }
                }
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 10)], spacing: 10) {
                OpsMetricTile(title: "资料夹", value: "\(viewModel.knowledgeFolders.count)", detail: "Knowledge", icon: "books.vertical.fill", tint: tint)
                OpsMetricTile(title: "文档", value: "\(docCount)", detail: "可检索", icon: "doc.text.fill", tint: greenTint)
                OpsMetricTile(title: "字符", value: opsCompactCount(charCount), detail: "总正文", icon: "text.alignleft", tint: .blue)
                OpsMetricTile(title: "提醒", value: "\(issues.count)", detail: issues.isEmpty ? "健康" : "待处理", icon: issues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill", tint: issues.isEmpty ? .green : .orange)
            }

            if let message {
                OpsNotice(text: message, tint: greenTint)
            }

            OpsSectionHeader(title: "摄取问题", subtitle: issues.isEmpty ? "没有明显问题。" : "优先处理正文过短和重复资料。")
            if issues.isEmpty {
                OpsEmptyState(title: "知识库状态不错", detail: "当前资料具备基本可检索条件。", icon: "checkmark.seal.fill", tint: greenTint)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(issues.prefix(18)) { issue in
                        OpsActionRow(
                            title: issue.title,
                            detail: "\(issue.folder)\(issue.document.map { " · \($0)" } ?? "") · \(issue.detail)",
                            icon: issue.severity.icon,
                            tint: issue.severity.tint
                        )
                    }
                }
            }
        }
    }

    private func createInboxIfNeeded() {
        if let existing = viewModel.knowledgeFolders.first(where: { $0.name == "资料收件箱" }) {
            message = "资料收件箱已存在: \(existing.docs.count) 篇文档"
            return
        }
        _ = viewModel.createKnowledgeFolder(name: "资料收件箱")
        message = "已创建资料收件箱"
    }

    private func preindexAll() {
        for folder in viewModel.knowledgeFolders where !folder.docs.isEmpty {
            viewModel.schedulePreindex(folderID: folder.id)
        }
        message = viewModel.knowledgeFolders.isEmpty ? "还没有知识库资料夹" : "已提交 \(viewModel.knowledgeFolders.count) 个资料夹的向量预热"
    }
}

/// 设置 ▸ 自动化模板:一键安装常用的晨报、周报、竞品监控和会议跟进定时任务。
struct AutomationTemplateHubView: View {
    @Bindable var viewModel: AppViewModel
    @Bindable private var scheduler = SchedulerService.shared
    @State private var message: String?

    private let tint = Color(red: 0.88, green: 0.46, blue: 0.20)
    private let blueTint = Color(red: 0.18, green: 0.52, blue: 0.86)

    private var templates: [AutomationTemplate] {
        AutomationTemplate.builtIns(activeMode: viewModel.activeMode)
    }

    var body: some View {
        OpsPage(tint: tint) {
            OpsHero(
                title: "自动化模板",
                subtitle: "\(scheduler.tasks.count) 条定时任务 · \(scheduler.tasks.filter(\.enabled).count) 条启用",
                icon: "calendar.badge.plus",
                tint: tint,
                trailing: { EmptyView() }
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 10)], spacing: 10) {
                OpsMetricTile(title: "模板", value: "\(templates.count)", detail: "可安装", icon: "square.stack.3d.up.badge.plus", tint: tint)
                OpsMetricTile(title: "已安装", value: "\(templates.filter(isInstalled).count)", detail: "同名去重", icon: "checkmark.circle.fill", tint: .green)
                OpsMetricTile(title: "Agent 任务", value: "\(scheduler.tasks.filter(\.isAgent).count)", detail: "后台执行", icon: "gearshape.2.fill", tint: blueTint)
                OpsMetricTile(title: "增量模式", value: "\(scheduler.tasks.filter(\.incrementalMode).count)", detail: "避免重复", icon: "arrow.triangle.2.circlepath", tint: .purple)
            }

            if let message {
                OpsNotice(text: message, tint: blueTint)
            }

            OpsSectionHeader(title: "模板库", subtitle: "安装后会进入设置 ▸ 定时任务继续编辑。")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                ForEach(templates) { template in
                    automationCard(template)
                }
            }
        }
    }

    private func automationCard(_ template: AutomationTemplate) -> some View {
        let installed = isInstalled(template)
        return KownGlassCard(tint: installed ? .green : template.tint, cornerRadius: 18, intensity: 0.07) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: template.icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(template.tint)
                        .frame(width: 34, height: 34)
                        .background(template.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.title)
                            .font(.headline.weight(.bold))
                            .lineLimit(1)
                        Text(template.scheduleText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text(template.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    OpsChip(template.kindLabel, tint: template.tint)
                    OpsChip(template.toolLabel, tint: .secondary)
                    Spacer(minLength: 0)
                    Button {
                        install(template)
                    } label: {
                        Label(installed ? "已安装" : "安装", systemImage: installed ? "checkmark" : "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(installed ? .green : template.tint)
                    .disabled(installed)
                }
            }
            .padding(14)
        }
    }

    private func isInstalled(_ template: AutomationTemplate) -> Bool {
        scheduler.tasks.contains { $0.title == template.title }
    }

    private func install(_ template: AutomationTemplate) {
        guard !isInstalled(template) else { return }
        scheduler.add(template.makeTask())
        message = "已安装「\(template.title)」"
    }
}

/// 设置 ▸ Prompt 质检:扫描 Prompt 库里的变量、输出约束、证据要求和重复标题。
struct PromptQualityView: View {
    @Bindable var store: PromptLibraryStore
    @State private var message: String?

    private let tint = Color(red: 0.58, green: 0.40, blue: 0.86)
    private let greenTint = Color(red: 0.20, green: 0.62, blue: 0.38)

    private var audits: [PromptAudit] {
        let titleCounts = Dictionary(grouping: store.templates, by: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            .mapValues(\.count)
        return store.templates.map { template in
            PromptAudit(template: template, duplicateTitleCount: titleCounts[template.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? 1)
        }
        .sorted { $0.score < $1.score }
    }

    private var issueCount: Int { audits.reduce(0) { $0 + $1.issues.count } }

    var body: some View {
        OpsPage(tint: tint) {
            OpsHero(
                title: "Prompt 质检",
                subtitle: "\(store.templates.count) 条模板 · \(issueCount) 个提醒",
                icon: "text.badge.checkmark",
                tint: tint,
                trailing: {
                    Button {
                        addEvidenceTemplate()
                    } label: {
                        Label("证据模板", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(greenTint)
                }
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 10)], spacing: 10) {
                OpsMetricTile(title: "模板", value: "\(store.templates.count)", detail: "Prompt 库", icon: "doc.on.doc.fill", tint: tint)
                OpsMetricTile(title: "平均分", value: "\(averageScore)", detail: "结构完整度", icon: "gauge.with.dots.needle.50percent", tint: averageScore >= 80 ? .green : .orange)
                OpsMetricTile(title: "变量", value: "\(store.templates.reduce(0) { $0 + $1.variableNames.count })", detail: "{{占位符}}", icon: "curlybraces", tint: .blue)
                OpsMetricTile(title: "提醒", value: "\(issueCount)", detail: issueCount == 0 ? "清爽" : "待优化", icon: issueCount == 0 ? "checkmark.seal.fill" : "exclamationmark.bubble.fill", tint: issueCount == 0 ? .green : .orange)
            }

            if let message {
                OpsNotice(text: message, tint: greenTint)
            }

            OpsSectionHeader(title: "质检结果", subtitle: audits.isEmpty ? "Prompt 库为空。" : "低分模板排在前面。")
            if audits.isEmpty {
                OpsEmptyState(title: "还没有 Prompt 模板", detail: "去 Prompt 库添加模板后这里会自动分析。", icon: "text.badge.plus", tint: tint)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(audits.prefix(18)) { audit in
                        promptAuditRow(audit)
                    }
                }
            }
        }
    }

    private var averageScore: Int {
        guard !audits.isEmpty else { return 0 }
        return audits.reduce(0) { $0 + $1.score } / audits.count
    }

    private func promptAuditRow(_ audit: PromptAudit) -> some View {
        KownGlassCard(tint: audit.tint, cornerRadius: 16, intensity: 0.055) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(audit.template.title.isEmpty ? "未命名模板" : audit.template.title)
                        .font(.callout.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(audit.score)")
                        .font(.caption.weight(.black))
                        .monospacedDigit()
                        .foregroundStyle(audit.tint)
                }
                if audit.issues.isEmpty {
                    Text("结构完整,变量和输出约束清晰。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(audit.issues.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    OpsChip("\(audit.template.variableNames.count) 变量", tint: .blue)
                    OpsChip("\(audit.template.body.count) 字符", tint: .secondary)
                    OpsChip(opsRelativeDate(audit.template.updatedAt), tint: .secondary)
                }
            }
            .padding(13)
        }
    }

    private func addEvidenceTemplate() {
        let title = "证据锁定研究回答"
        if store.templates.contains(where: { $0.title == title }) {
            message = "证据模板已存在"
            return
        }
        store.add(title: title, body: """
        请基于下面的问题产出一份可验证研究回答。

        问题:
        {{问题}}

        要求:
        1. 先给结论摘要,再给证据链;
        2. 所有事实、数字、日期和强判断都必须带来源;
        3. 对不确定内容明确标注不确定性;
        4. 最后列出「仍需验证」清单。
        """)
        message = "已添加「\(title)」"
    }
}

/// 设置 ▸ 成本预算:汇总月度花费、预算阈值、未知价格模型和省钱建议。
struct CostBudgetCenterView: View {
    @Bindable private var store = UsageStore.shared
    @Bindable var viewModel: AppViewModel

    @AppStorage("kown.budget.monthlyCapUSD") private var monthlyCapUSD: Double = 0
    @AppStorage("kown.budget.warnPercent") private var warnPercent: Int = 80

    private let tint = Color(red: 0.22, green: 0.62, blue: 0.36)
    private let orangeTint = Color(red: 0.90, green: 0.48, blue: 0.18)

    private var monthSpend: Double { store.monthToDateCostUSD(scope: .all) }
    private var totalCost: CostBreakdown { store.totalCost(scope: .all) }
    private var budgetRatio: Double {
        guard monthlyCapUSD > 0 else { return 0 }
        return min(1, monthSpend / monthlyCapUSD)
    }

    private var topCosts: [(key: String, value: CostBreakdown)] {
        store.costByModel(scope: .all).sorted { $0.value.knownCostUSD > $1.value.knownCostUSD }
    }

    private var recommendations: [OpsStatusItem] {
        var rows: [OpsStatusItem] = []
        if monthlyCapUSD <= 0 {
            rows.append(.init(title: "设置月度预算", detail: "预算为 0 表示不提醒", state: .warn, icon: "dollarsign.circle.fill"))
        } else if monthSpend >= monthlyCapUSD * Double(warnPercent) / 100 {
            rows.append(.init(title: "接近预算阈值", detail: "\(CostFormat.usd(monthSpend)) / \(CostFormat.usd(monthlyCapUSD))", state: .bad, icon: "exclamationmark.triangle.fill"))
        } else {
            rows.append(.init(title: "预算健康", detail: "\(Int(budgetRatio * 100))% 已使用", state: .good, icon: "checkmark.seal.fill"))
        }
        if !viewModel.autoRouteEnabled {
            rows.append(.init(title: "开启自动路由", detail: "Direct 模式可按难度选更合适的模型", state: .warn, icon: "arrow.triangle.branch"))
        }
        if !viewModel.costCascadeEnabled {
            rows.append(.init(title: "启用省钱级联", detail: "低成本初答不佳时再升级旗舰", state: .info, icon: "arrow.up.forward.circle.fill"))
        }
        if totalCost.hasUnknown {
            rows.append(.init(title: "补齐价格表", detail: "\(opsCompactCount(totalCost.unknownTokens)) token 无法估价", state: .warn, icon: "questionmark.circle.fill"))
        }
        return rows
    }

    var body: some View {
        OpsPage(tint: tint) {
            OpsHero(
                title: "成本预算",
                subtitle: "本月 \(CostFormat.usd(monthSpend)) · 全部 \(CostFormat.usd(totalCost.knownCostUSD))",
                icon: "chart.pie.fill",
                tint: tint,
                trailing: {
                    Button {
                        store.reload()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 10)], spacing: 10) {
                OpsMetricTile(title: "本月", value: CostFormat.usd(monthSpend), detail: "已知成本", icon: "calendar", tint: tint)
                OpsMetricTile(title: "预算", value: monthlyCapUSD <= 0 ? "未设" : CostFormat.usd(monthlyCapUSD), detail: "\(warnPercent)% 提醒", icon: "gauge.with.dots.needle.67percent", tint: orangeTint)
                OpsMetricTile(title: "调用", value: "\(store.grandTotal(scope: .all).callCount)", detail: "全部设备", icon: "bolt.fill", tint: .blue)
                OpsMetricTile(title: "设备", value: "\(store.deviceCount)", detail: "Usage 文件", icon: "macbook.and.iphone", tint: .purple)
            }

            budgetControls

            OpsSectionHeader(title: "省钱建议", subtitle: "根据本地设置和用量生成。")
            LazyVStack(spacing: 10) {
                ForEach(recommendations) { item in
                    OpsStatusRow(item: item)
                }
            }

            OpsSectionHeader(title: "成本 Top 模型", subtitle: topCosts.isEmpty ? "暂无用量记录。" : "按已知价格估算。")
            if topCosts.isEmpty {
                OpsEmptyState(title: "还没有成本数据", detail: "模型调用完成后会在这里出现。", icon: "chart.bar.xaxis", tint: tint)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(topCosts.prefix(8), id: \.key) { row in
                        let split = UsageStore.splitKey(row.key)
                        OpsActionRow(
                            title: split.model,
                            detail: "\(split.providerKind) · \(CostFormat.usd(row.value.knownCostUSD))",
                            icon: "cpu.fill",
                            tint: row.value.hasUnknown ? .orange : tint
                        )
                    }
                }
            }
        }
    }

    private var budgetControls: some View {
        KownGlassCard(tint: orangeTint, cornerRadius: 18, intensity: 0.06) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("月度预算", systemImage: "dollarsign.circle.fill")
                        .font(.headline.weight(.bold))
                    Spacer()
                    Text(monthlyCapUSD <= 0 ? "不限制" : CostFormat.usd(monthlyCapUSD))
                        .font(.caption.weight(.black))
                        .monospacedDigit()
                        .foregroundStyle(orangeTint)
                }
                Slider(value: $monthlyCapUSD, in: 0...500, step: 5)
                    .tint(orangeTint)
                HStack {
                    Text("提醒阈值")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(warnPercent) }, set: { warnPercent = Int($0) }), in: 50...100, step: 5)
                        .tint(tint)
                    Text("\(warnPercent)%")
                        .font(.caption.weight(.black))
                        .monospacedDigit()
                }
            }
            .padding(14)
        }
    }
}

/// 设置 ▸ 证据覆盖:扫描近期回答是否绑定 Web / 知识库 / 可信度报告 / 事实核查。
struct EvidenceCoverageView: View {
    @Bindable var viewModel: AppViewModel
    @State private var message: String?

    private let tint = Color(red: 0.16, green: 0.54, blue: 0.76)
    private let redTint = Color(red: 0.86, green: 0.34, blue: 0.22)

    private var analyzedRows: [EvidenceTurnRow] {
        viewModel.activeConversations.flatMap { conversation in
            conversation.turns.map { EvidenceTurnRow(conversation: conversation, turn: $0) }
        }
        .filter(\.hasAnswer)
        .sorted { $0.turn.timestamp > $1.turn.timestamp }
    }

    private var gapRows: [EvidenceTurnRow] {
        analyzedRows.filter { $0.needsEvidence && !$0.hasEvidence }
    }

    private var coveragePercent: Int {
        guard !analyzedRows.isEmpty else { return 0 }
        let covered = analyzedRows.filter(\.hasEvidence).count
        return Int((Double(covered) / Double(analyzedRows.count) * 100).rounded())
    }

    var body: some View {
        OpsPage(tint: tint) {
            OpsHero(
                title: "证据覆盖",
                subtitle: "\(coveragePercent)% 回答已有证据绑定",
                icon: "checkmark.shield.fill",
                tint: tint,
                trailing: {
                    Button {
                        tagGapConversations()
                    } label: {
                        Label("标记缺口", systemImage: "tag.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(gapRows.isEmpty ? .green : redTint)
                    .disabled(gapRows.isEmpty)
                }
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 10)], spacing: 10) {
                OpsMetricTile(title: "已回答轮次", value: "\(analyzedRows.count)", detail: "会话历史", icon: "bubble.left.and.bubble.right.fill", tint: tint)
                OpsMetricTile(title: "覆盖率", value: "\(coveragePercent)%", detail: "有证据", icon: "checkmark.seal.fill", tint: coveragePercent >= 70 ? .green : .orange)
                OpsMetricTile(title: "Web 来源", value: "\(analyzedRows.filter(\.hasWebSources).count)", detail: "引用结果", icon: "globe", tint: .blue)
                OpsMetricTile(title: "缺口", value: "\(gapRows.count)", detail: "建议补证", icon: gapRows.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", tint: gapRows.isEmpty ? .green : redTint)
            }

            if let message {
                OpsNotice(text: message, tint: tint)
            }

            OpsSectionHeader(title: "证据缺口", subtitle: gapRows.isEmpty ? "近期高风险回答都有证据线索。" : "包含数字、日期或强判断但缺少来源。")
            if gapRows.isEmpty {
                OpsEmptyState(title: "没有明显证据缺口", detail: "事实核查、可信度报告、Web 来源或知识来源都计入覆盖。", icon: "checkmark.shield.fill", tint: .green)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(gapRows.prefix(14)) { row in
                        OpsActionRow(
                            title: row.conversation.title,
                            detail: row.promptSummary,
                            icon: "quote.bubble.fill",
                            tint: redTint
                        )
                    }
                }
            }
        }
    }

    private func tagGapConversations() {
        let ids = Set(gapRows.prefix(20).map(\.conversation.id))
        for id in ids {
            guard let conv = viewModel.conversations.first(where: { $0.id == id }) else { continue }
            var tags = conv.tags
            if !tags.contains("证据缺口") { tags.append("证据缺口") }
            viewModel.setTags(id, tags: tags)
        }
        message = ids.isEmpty ? "没有需要标记的会话" : "已给 \(ids.count) 个会话添加「证据缺口」标签"
    }
}

/// 设置 ▸ 发布检查:发版前把版本号、更新日志、连接器、预算和手动验证项收束到一张清单。
struct ReleaseReadinessView: View {
    @Bindable var viewModel: AppViewModel
    @Bindable private var changelog = ChangelogService.shared
    @State private var connectorSnapshot = ConnectorHubService.snapshot()

    @AppStorage("kown.release.check.swiftTest") private var swiftTestPassed = false
    @AppStorage("kown.release.check.macBuild") private var macBuildPassed = false
    @AppStorage("kown.release.check.iosBuild") private var iosBuildPassed = false
    @AppStorage("kown.release.check.tagReady") private var tagReady = false

    private let tint = Color(red: 0.82, green: 0.46, blue: 0.22)
    private let greenTint = Color(red: 0.20, green: 0.62, blue: 0.38)

    private var checklist: [OpsStatusItem] {
        [
            OpsStatusItem(
                title: "版本号",
                detail: changelog.currentVersion,
                state: changelog.currentVersion == "?" ? .bad : .good,
                icon: "number.circle.fill"
            ),
            OpsStatusItem(
                title: "更新日志",
                detail: changelog.fullText?.contains("## \(changelog.currentVersion)") == true ? "已包含当前版本" : "未找到当前版本条目",
                state: changelog.fullText?.contains("## \(changelog.currentVersion)") == true ? .good : .bad,
                icon: "doc.text.fill"
            ),
            OpsStatusItem(
                title: "GitHub",
                detail: connectorSnapshot.connectors.first(where: { $0.kind == .github })?.subtitle ?? "未知",
                state: GitHubAuth.isConnected() ? .good : .warn,
                icon: "chevron.left.forwardslash.chevron.right"
            ),
            OpsStatusItem(
                title: "模型",
                detail: "\(viewModel.providers.filter(\.enabled).count) 家 Provider 启用",
                state: viewModel.providers.contains(where: \.enabled) ? .good : .bad,
                icon: "bolt.fill"
            ),
            OpsStatusItem(
                title: "密钥存储",
                detail: viewModel.secretStoreKeyCount.map { "\($0) 个 key 可读" } ?? "无法读取状态",
                state: viewModel.secretStoreKeyCount == nil ? .warn : .good,
                icon: "key.fill"
            )
        ]
    }

    private var manualDoneCount: Int {
        [swiftTestPassed, macBuildPassed, iosBuildPassed, tagReady].filter { $0 }.count
    }

    var body: some View {
        OpsPage(tint: tint) {
            OpsHero(
                title: "发布检查",
                subtitle: "版本 \(changelog.currentVersion) · 手动项 \(manualDoneCount)/4",
                icon: "checklist.checked",
                tint: tint,
                trailing: {
                    Button {
                        connectorSnapshot = ConnectorHubService.snapshot()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 10)], spacing: 10) {
                OpsMetricTile(title: "当前版本", value: changelog.currentVersion, detail: "Bundle", icon: "number", tint: tint)
                OpsMetricTile(title: "检查项", value: "\(checklist.filter { $0.state == .good }.count)/\(checklist.count)", detail: "自动", icon: "checkmark.seal.fill", tint: greenTint)
                OpsMetricTile(title: "手动项", value: "\(manualDoneCount)/4", detail: "验证", icon: "hammer.fill", tint: manualDoneCount == 4 ? .green : .orange)
                OpsMetricTile(title: "连接器", value: connectorSnapshot.healthSummary, detail: "发布前状态", icon: "powerplug.fill", tint: .blue)
            }

            OpsSectionHeader(title: "自动检查", subtitle: "来自本地配置、Bundle 和连接器快照。")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                ForEach(checklist) { item in
                    OpsStatusRow(item: item)
                }
            }

            OpsSectionHeader(title: "手动验证", subtitle: "这些开关只记录你本地的发版确认。")
            KownGlassCard(tint: tint, cornerRadius: 18, intensity: 0.06) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("swift test 已通过", isOn: $swiftTestPassed)
                    Toggle("macOS Debug build 已通过", isOn: $macBuildPassed)
                    Toggle("iOS Simulator build 已通过", isOn: $iosBuildPassed)
                    Toggle("tag / release notes 已准备", isOn: $tagReady)
                }
                .toggleStyle(.switch)
                .padding(14)
            }
        }
    }
}

// MARK: - Data Models

private struct KnowledgeIntakeIssue: Identifiable {
    let id = UUID()
    var folder: String
    var document: String?
    var title: String
    var detail: String
    var severity: OpsSeverity
}

private struct AutomationTemplate: Identifiable {
    var id: String { title }
    var title: String
    var detail: String
    var icon: String
    var tint: Color
    var task: ScheduledTask

    var scheduleText: String { task.scheduleText }
    var kindLabel: String {
        switch task.kind {
        case .plainPrompt: return "固定 Prompt"
        case .morningBriefing: return "晨间简报"
        case .agentTask: return "Agent 任务"
        }
    }
    var toolLabel: String {
        task.isAgent ? task.agentToolsText : task.mode.localizedDisplayName
    }

    func makeTask() -> ScheduledTask { task }

    static func builtIns(activeMode: ConversationMode) -> [AutomationTemplate] {
        [
            AutomationTemplate(
                title: "每日晨间简报",
                detail: "整合日程、长期关注点和订阅话题,适合每天打开 Kown 时自动补跑。",
                icon: "sun.max.fill",
                tint: Color(red: 0.92, green: 0.54, blue: 0.20),
                task: ScheduledTask(
                    title: "每日晨间简报",
                    prompt: "请把今天最值得注意的事项按优先级整理成简报。",
                    kind: .morningBriefing,
                    briefingTopics: ["AI 产品动态", "本周项目风险", "需要跟进的人和事"],
                    mode: .direct,
                    hour: 8,
                    minute: 30
                )
            ),
            AutomationTemplate(
                title: "每周项目复盘",
                detail: "周五下午回看本周目标、完成事项、阻塞点和下周第一步。",
                icon: "calendar.badge.clock",
                tint: Color(red: 0.18, green: 0.52, blue: 0.86),
                task: ScheduledTask(
                    title: "每周项目复盘",
                    prompt: """
                    请帮我做一份本周项目复盘:
                    1. 已完成的关键进展
                    2. 仍然阻塞的事项
                    3. 下周最值得先做的三件事
                    4. 需要主动提醒/约人的跟进行动
                    """,
                    kind: .plainPrompt,
                    mode: activeMode,
                    hour: 17,
                    minute: 30,
                    weekday: 6
                )
            ),
            AutomationTemplate(
                title: "竞品变化监控",
                detail: "作为订阅式 Agent 跟进指定对象,每次只报告新增变化。",
                icon: "binoculars.fill",
                tint: Color(red: 0.42, green: 0.50, blue: 0.86),
                task: ScheduledTask(
                    title: "竞品变化监控",
                    prompt: """
                    请追踪我关注的竞品/同类产品最近一周的新变化。
                    输出:重要变化、可信来源、对 Kown 的启发、下一步建议。
                    """,
                    kind: .agentTask,
                    mode: .direct,
                    hour: 9,
                    minute: 20,
                    weekday: 2,
                    agentWebSearch: true,
                    agentMCP: false,
                    agentDeviceTools: false,
                    agentDeepMode: true
                )
            ),
            AutomationTemplate(
                title: "会议行动项追踪",
                detail: "每天傍晚提醒自己梳理会议决策、负责人和逾期风险。",
                icon: "person.2.wave.2.fill",
                tint: Color(red: 0.18, green: 0.62, blue: 0.58),
                task: ScheduledTask(
                    title: "会议行动项追踪",
                    prompt: """
                    请检查最近会议里的行动项:
                    - 哪些需要今天推进
                    - 哪些缺负责人或截止时间
                    - 哪些应该创建提醒事项
                    """,
                    kind: .agentTask,
                    mode: .direct,
                    hour: 18,
                    minute: 10,
                    agentWebSearch: false,
                    agentMCP: false,
                    agentDeviceTools: true,
                    agentDeepMode: true
                )
            ),
            AutomationTemplate(
                title: "技术雷达周报",
                detail: "周一早上收集框架、模型和开发者工具的变化,沉淀成决策素材。",
                icon: "antenna.radiowaves.left.and.right",
                tint: Color(red: 0.56, green: 0.40, blue: 0.86),
                task: ScheduledTask(
                    title: "技术雷达周报",
                    prompt: """
                    请生成技术雷达周报:
                    1. 本周值得关注的模型/框架/开发工具
                    2. 真实影响和不确定性
                    3. 值得试用的 3 个实验
                    4. 引用来源
                    """,
                    kind: .agentTask,
                    mode: .direct,
                    hour: 9,
                    minute: 0,
                    weekday: 2,
                    agentWebSearch: true,
                    agentMCP: true,
                    agentDeviceTools: false,
                    agentDeepMode: true
                )
            )
        ]
    }
}

private struct PromptAudit: Identifiable {
    var id: UUID { template.id }
    var template: PromptTemplate
    var duplicateTitleCount: Int

    var issues: [String] {
        var out: [String] = []
        let body = template.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("缺标题") }
        if body.count < 80 { out.append("正文过短") }
        if body.count > 4_000 { out.append("正文过长") }
        if template.variableNames.isEmpty { out.append("没有变量") }
        if duplicateTitleCount > 1 { out.append("标题重复") }
        let outputWords = ["输出", "格式", "表格", "JSON", "清单", "步骤", "结构"]
        if !outputWords.contains(where: { body.localizedCaseInsensitiveContains($0) }) {
            out.append("缺输出约束")
        }
        let evidenceWords = ["研究", "事实", "数据", "报告", "来源", "证据"]
        if evidenceWords.contains(where: { body.localizedCaseInsensitiveContains($0) }) &&
            !body.localizedCaseInsensitiveContains("来源") &&
            !body.localizedCaseInsensitiveContains("证据") {
            out.append("缺证据要求")
        }
        return out
    }

    var score: Int {
        max(0, 100 - issues.count * 14 - (template.variableNames.isEmpty ? 8 : 0))
    }

    var tint: Color {
        if score >= 85 { return .green }
        if score >= 65 { return .orange }
        return .red
    }
}

private struct EvidenceTurnRow: Identifiable {
    var id: UUID { turn.id }
    var conversation: Conversation
    var turn: Turn

    var hasAnswer: Bool {
        !turn.responses.values.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !(turn.chairSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            !(turn.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var answerText: String {
        ([turn.chairSummary, turn.summaryText] + Array(turn.responses.values))
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    var hasWebSources: Bool {
        !(turn.sources?.isEmpty ?? true) || (turn.sourcesByProvider?.values.contains(where: { !$0.isEmpty }) == true)
    }

    var hasKnowledgeSources: Bool {
        !(turn.knowledgeSources?.isEmpty ?? true)
    }

    var hasEvidence: Bool {
        hasWebSources || hasKnowledgeSources || turn.factCheck != nil || turn.answerTrustReport != nil
    }

    var needsEvidence: Bool {
        let text = "\(turn.prompt)\n\(answerText)"
        let digits = text.rangeOfCharacter(from: .decimalDigits) != nil
        let triggerWords = ["最新", "最近", "价格", "法律", "政策", "数据", "事实", "研究", "报告", "市场", "竞品", "发布"]
        return digits || triggerWords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    var promptSummary: String {
        let trimmed = turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 90 else { return trimmed.isEmpty ? opsRelativeDate(turn.timestamp) : trimmed }
        return String(trimmed.prefix(90)) + "..."
    }
}

// MARK: - Shared UI

private struct OpsPage<Content: View>: View {
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                content
            }
            #if os(iOS)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            #else
            .padding(20)
            #endif
            .frame(maxWidth: 1040, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }
}

private struct OpsHero<Trailing: View>: View {
    var title: String
    var subtitle: String
    var icon: String
    var tint: Color
    @ViewBuilder var trailing: Trailing

    var body: some View {
        KownGlassCard(tint: tint, cornerRadius: 24, intensity: 0.08) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    mark
                    copy
                    Spacer(minLength: 12)
                    trailing
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        mark
                        copy
                    }
                    trailing
                }
            }
            .padding(16)
        }
    }

    private var mark: some View {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(
                LinearGradient(colors: [tint, tint.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
            }
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.black))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OpsSectionHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.black))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct OpsMetricTile: View {
    var title: String
    var value: String
    var detail: String
    var icon: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.headline.weight(.black))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.72)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(Color.platformControlBackground.opacity(0.52), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct OpsStatusItem: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var state: OpsState
    var icon: String
}

private enum OpsState {
    case good
    case warn
    case bad
    case info

    var tint: Color {
        switch self {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        case .info: return .blue
        }
    }

    var label: String {
        switch self {
        case .good: return "OK"
        case .warn: return "注意"
        case .bad: return "需处理"
        case .info: return "信息"
        }
    }
}

private enum OpsSeverity {
    case bad
    case warn
    case info

    var rank: Int {
        switch self {
        case .bad: return 0
        case .warn: return 1
        case .info: return 2
        }
    }

    var tint: Color {
        switch self {
        case .bad: return .red
        case .warn: return .orange
        case .info: return .blue
        }
    }

    var icon: String {
        switch self {
        case .bad: return "xmark.octagon.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

private struct OpsStatusRow: View {
    var item: OpsStatusItem

    var body: some View {
        OpsActionRow(
            title: item.title,
            detail: "\(item.state.label) · \(item.detail)",
            icon: item.icon,
            tint: item.state.tint
        )
    }
}

private struct OpsActionRow: View {
    var title: String
    var detail: String
    var icon: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.bold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.platformControlBackground.opacity(0.48), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct OpsChip: View {
    var text: String
    var tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.black))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.14), lineWidth: 1)
            }
    }
}

private struct OpsNotice: View {
    var text: String
    var tint: Color

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.14), lineWidth: 1)
            }
    }
}

private struct OpsEmptyState: View {
    var title: String
    var detail: String
    var icon: String
    var tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            Text(title)
                .font(.headline.weight(.bold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.platformControlBackground.opacity(0.46), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.12), lineWidth: 1)
        }
    }
}

private func opsCompactCount(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
    return "\(count)"
}

private func opsRelativeDate(_ date: Date?) -> String {
    guard let date else { return "从未" }
    let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
    if days <= 0 { return "今天" }
    if days == 1 { return "昨天" }
    if days < 30 { return "\(days) 天前" }
    if days < 365 { return "\(days / 30) 个月前" }
    return "\(days / 365) 年前"
}
