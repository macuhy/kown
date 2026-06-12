import SwiftUI
import UniformTypeIdentifiers

/// Settings → "配置备份" tab。
/// 导出当前 Provider/Web Search/Preference 配置(API Key 可选)→ 一个 JSON 文件;
/// 导入时支持"覆盖"或"合并"。两端通用(SwiftUI fileExporter / fileImporter)。
/// 另含"自动备份"(关闭/每日/每周)与"立即备份" + 最近备份列表。
struct BackupSettingsView: View {
    @Bindable var viewModel: AppViewModel

    @State private var includeAPIKeys: Bool = true
    @State private var pendingExportDocument: BackupDocument?
    @State private var pendingExportFilename: String = ""
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingImportData: Data?
    @State private var showImportModeDialog = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    // 导入聊天记录(ChatGPT / Claude / Kown)
    @State private var chatImportSource: ConversationImporter.Source = .chatGPT
    @State private var showChatImporter = false
    @State private var chatImporting = false

    // 自动备份状态(镜像 BackupStore 的持久化偏好,binding 改动即写回)。
    @State private var autoFrequency: BackupFrequency = .off
    @State private var keepCount: Int = BackupStore.defaultKeepCount
    @State private var lastBackupDate: Date?
    @State private var snapshots: [BackupSnapshot] = []

    private let tint = Color(red: 0.91, green: 0.55, blue: 0.20)
    private let secondaryTint = Color(red: 0.57, green: 0.42, blue: 0.82)

    var body: some View {
        platformBody
            .onAppear { onAppearSetup() }
            .fileExporter(
                isPresented: $showExporter,
                document: pendingExportDocument,
                contentType: .json,
                defaultFilename: pendingExportFilename
            ) { result in
                switch result {
                case .success(let url):
                    resultMessage = "已导出到 \(url.lastPathComponent)"
                    errorMessage = nil
                case .failure(let err):
                    errorMessage = "导出失败: \(err.localizedDescription)"
                }
                pendingExportDocument = nil
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json, .data]
            ) { result in
                handleImportResult(result.map { [$0] })
            }
            .background {
                // 第二个 fileImporter 不能挂在同一个节点上(会相互覆盖),挂到 background 的空视图。
                Color.clear
                    .fileImporter(
                        isPresented: $showChatImporter,
                        allowedContentTypes: chatImportContentTypes
                    ) { result in
                        handleChatImportResult(result)
                    }
            }
            .confirmationDialog(
                "如何导入?",
                isPresented: $showImportModeDialog,
                titleVisibility: .visible
            ) {
                Button("覆盖现有配置", role: .destructive) {
                    applyImport(mode: .replace)
                }
                Button("合并(仅新增)") {
                    applyImport(mode: .merge)
                }
                Button("取消", role: .cancel) {
                    pendingImportData = nil
                }
            } message: {
                Text("覆盖:用备份完全替换当前所有 provider / web search / 偏好。\n合并:只新增备份里有而本机没有的 provider,不动现有的。\nAPI Key 两种模式下都会补充进 Keychain。")
            }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(iOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                heroCard
                autoBackupCard
                exportCard
                importCard
                chatImportCard
                if resultMessage != nil || errorMessage != nil {
                    statusCard
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(mobileSettingsBackground.ignoresSafeArea())
        .scrollIndicators(.hidden)
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                autoBackupCard
                exportCard
                importCard
                chatImportCard
                if resultMessage != nil || errorMessage != nil {
                    statusCard
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .topLeading)
        }
        #endif
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroCard: some View {
        #if os(iOS)
        mobileHeroCard
        #else
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                iconTile("shippingbox.and.arrow.backward.fill", tint: tint, secondary: secondaryTint)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("导入 / 导出配置")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        statusBadge("JSON 备份", icon: "doc.text.fill", color: tint)
                    }
                    Text("把当前 Provider、Web Search 和偏好导出成一个备份文件,或从备份恢复。适合作为 iCloud 同步之外的离线迁移方案。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                statusBadge(includeAPIKeys ? "包含 Key" : "不含 Key",
                            icon: includeAPIKeys ? "key.fill" : "key.slash",
                            color: includeAPIKeys ? .orange : .secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                metricTile(title: "导出内容",
                           value: "配置",
                           detail: "Provider / Web Search / Preference",
                           icon: "square.and.arrow.up.fill",
                           color: tint)
                metricTile(title: "API Key",
                           value: includeAPIKeys ? "明文" : "跳过",
                           detail: includeAPIKeys ? "请妥善保存备份文件" : "新设备需重新填写",
                           icon: includeAPIKeys ? "lock.open.fill" : "lock.fill",
                           color: includeAPIKeys ? .orange : .secondary)
                metricTile(title: "导入策略",
                           value: "覆盖 / 合并",
                           detail: "导入时再选择模式",
                           icon: "arrow.triangle.merge",
                           color: secondaryTint)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(heroBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.09), radius: 22, x: 0, y: 12)
        #endif
    }

    #if os(iOS)
    private var mobileHeroCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                compactIconTile("shippingbox.and.arrow.backward.fill", tint: tint, secondary: secondaryTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("导入 / 导出")
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                    Text("JSON 配置备份")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                statusBadge(includeAPIKeys ? "包含 Key" : "不含 Key",
                            icon: includeAPIKeys ? "key.fill" : "key.slash",
                            color: includeAPIKeys ? .orange : .secondary)
            }

            Text("导出 Provider、Web Search 和偏好;也可以从备份恢复。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 7) {
                compactMetricRow(title: "导出内容",
                                 value: "配置",
                                 detail: "Provider / Web Search / Preference",
                                 icon: "square.and.arrow.up.fill",
                                 color: tint)
                compactMetricRow(title: "API Key",
                                 value: includeAPIKeys ? "明文" : "跳过",
                                 detail: includeAPIKeys ? "请妥善保存备份文件" : "新设备需重新填写",
                                 icon: includeAPIKeys ? "lock.open.fill" : "lock.fill",
                                 color: includeAPIKeys ? .orange : .secondary)
                compactMetricRow(title: "导入策略",
                                 value: "覆盖 / 合并",
                                 detail: "导入时再选择模式",
                                 icon: "arrow.triangle.merge",
                                 color: secondaryTint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(heroBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.06), radius: 12, x: 0, y: 7)
    }
    #endif

    // MARK: - 自动备份

    /// 自动备份控件(频率 / 保留份数 / 立即备份 / 最近时间 + 列表)。
    private var autoBackupControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("自动备份频率", selection: $autoFrequency) {
                ForEach(BackupFrequency.allCases) { freq in
                    Text(freq.displayName).tag(freq)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: autoFrequency) { _, newValue in
                BackupStore.autoBackupFrequency = newValue
            }

            if autoFrequency != .off {
                Stepper(value: $keepCount, in: 1...50) {
                    HStack {
                        Text("保留份数").font(.body.weight(.semibold))
                        Spacer()
                        Text("\(keepCount)").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: keepCount) { _, newValue in
                    BackupStore.autoBackupKeepCount = newValue
                }
            }

            HStack {
                Text("最近备份").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text(lastBackupText).font(.caption).foregroundStyle(.secondary)
            }

            Button {
                runBackupNow()
            } label: {
                Label("立即备份", systemImage: "externaldrive.badge.plus")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(secondaryTint)

            if snapshots.isEmpty {
                Text("暂无自动备份。开启频率后会在打开本页 / 进入后台时按计划生成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近 \(snapshots.count) 份")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    ForEach(snapshots) { snapshot in
                        snapshotRow(snapshot)
                    }
                }
            }
        }
    }

    private func snapshotRow(_ snapshot: BackupSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(secondaryTint)
                .frame(width: 25, height: 25)
                .background(secondaryTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.dateText(snapshot.createdAt))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(Self.sizeText(snapshot.size))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button {
                BackupStore.deleteSnapshot(snapshot)
                refreshSnapshots()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(secondaryTint.opacity(0.14), lineWidth: 1)
        }
    }

    // MARK: - 共用片段

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $includeAPIKeys) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("包含 API Key").font(.body.weight(.semibold))
                    Text(includeAPIKeys
                         ? "导出文件含明文 Key,等同于完整凭据,请妥善保管。"
                         : "导出后到新设备需要重新填入各家 API Key。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                triggerExport()
            } label: {
                Label("一键全量导出...", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var importControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("从 .kownbackup / .json 文件还原配置。导入后可选'覆盖'当前全部设置,或'合并'(只新增不存在的 provider)。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                statusBadge("覆盖", icon: "arrow.clockwise", color: .orange)
                statusBadge("合并", icon: "plus.square.on.square", color: secondaryTint)
            }
            Button {
                showImporter = true
            } label: {
                Label("导入配置...", systemImage: "square.and.arrow.down")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    /// 「导入聊天记录」的三个入口 + 说明。
    private var chatImportControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(macOS)
            Text("把在别处的聊天搬进来:支持 ChatGPT / Claude 官方导出包(.zip 或解压后的 conversations.json)和 Kown 导出的单会话 JSON。全部本地解析,导入的会话归入「已导入」项目。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("把在别处的聊天搬进来:请先解压 ChatGPT / Claude 官方导出包,选择其中的 conversations.json;也支持 Kown 导出的单会话 JSON。全部本地解析,导入的会话归入「已导入」项目。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif

            VStack(alignment: .leading, spacing: 8) {
                chatImportButton(.chatGPT,
                                 title: chatImportTitle("ChatGPT 导出包"),
                                 icon: "bubble.left.and.text.bubble.right")
                chatImportButton(.claude,
                                 title: chatImportTitle("Claude 导出包"),
                                 icon: "sparkles")
                chatImportButton(.kown,
                                 title: "Kown 会话 JSON…",
                                 icon: "doc.text")
            }

            if chatImporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("解析中,大文件可能需要一会儿…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 入口标题:macOS 支持 zip,iOS 只收解压后的 json。
    private func chatImportTitle(_ name: String) -> String {
        #if os(macOS)
        return "\(name)(.zip / .json)…"
        #else
        return "\(name)(conversations.json)…"
        #endif
    }

    private func chatImportButton(_ source: ConversationImporter.Source,
                                  title: String,
                                  icon: String) -> some View {
        Button {
            chatImportSource = source
            showChatImporter = true
        } label: {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(chatImporting)
    }

    /// 文件类型:macOS 收 zip + json;iOS 没法解压,只收 json。
    private var chatImportContentTypes: [UTType] {
        #if os(macOS)
        return [.zip, .json, .data]
        #else
        return [.json, .data]
        #endif
    }

    @ViewBuilder
    private var statusContent: some View {
        if let errorMessage {
            messageBanner(errorMessage, icon: "exclamationmark.triangle.fill", color: .red)
        } else if let resultMessage {
            messageBanner(resultMessage, icon: "checkmark.circle.fill", color: .green)
        }
    }

    // MARK: - iOS Form sections

    #if os(iOS)
    private var mobileSettingsBackground: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [tint.opacity(0.13), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 420
            )
            RadialGradient(
                colors: [secondaryTint.opacity(0.10), Color.clear],
                center: .bottomTrailing,
                startRadius: 50,
                endRadius: 520
            )
        }
    }

    private var heroSection: some View {
        Section {
            heroCard
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }
    private var exportSection: some View {
        Section { exportControls } header: { Text("导出") }
    }
    private var importSection: some View {
        Section { importControls } header: { Text("导入") }
    }
    @ViewBuilder
    private var statusSection: some View {
        if resultMessage != nil || errorMessage != nil {
            Section { statusContent }
        }
    }
    #endif

    // MARK: - macOS cards

    private var autoBackupCard: some View {
        cardShell(tint: secondaryTint) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("自动备份",
                              subtitle: "按频率在打开本页 / 进入后台时把配置写入 backups 目录,仅保留最近若干份。",
                              icon: "clock.arrow.circlepath",
                              color: secondaryTint)
                autoBackupControls
            }
        }
    }
    private var exportCard: some View {
        cardShell(tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("导出", subtitle: "生成一个可移动的配置备份文件。", icon: "square.and.arrow.up.fill", color: tint)
                exportControls
            }
        }
    }
    private var importCard: some View {
        cardShell(tint: secondaryTint) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("导入", subtitle: "选择备份文件后,再决定覆盖或只合并新增项。", icon: "square.and.arrow.down.fill", color: secondaryTint)
                importControls
            }
        }
    }
    private var chatImportCard: some View {
        cardShell(tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("导入聊天记录",
                              subtitle: "从 ChatGPT / Claude 官方导出包或 Kown 会话 JSON 搬家,导入后归入「已导入」项目。",
                              icon: "tray.and.arrow.down.fill",
                              color: tint)
                chatImportControls
            }
        }
    }
    private var statusCard: some View {
        cardShell(tint: errorMessage == nil ? .green : .red) { statusContent }
    }

    // MARK: - Styling helpers

    private var heroBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: heroCornerRadius, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: heroCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.16), secondaryTint.opacity(0.10), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var heroCornerRadius: CGFloat {
        #if os(iOS)
        return 20
        #else
        return 28
        #endif
    }

    #if os(iOS)
    private func compactIconTile(_ symbol: String, tint: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), secondary.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 42, height: 42)
    }
    #endif

    private func iconTile(_ symbol: String, tint: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), secondary.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 58, height: 58)
        .shadow(color: tint.opacity(0.20), radius: 14, x: 0, y: 8)
    }

    private func sectionHeader(_ title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metricTile(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        }
    }

    private func compactMetricRow(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 25, height: 25)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(color.opacity(0.14), lineWidth: 1)
        }
    }

    private func statusBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .overlay { Capsule().strokeBorder(color.opacity(0.18), lineWidth: 1) }
            .fixedSize()
    }

    private func messageBanner(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(color.opacity(0.18), lineWidth: 1)
            }
    }

    @ViewBuilder
    private func cardShell<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(cardPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.08), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 1)
            }
    }

    private var cardPadding: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 18
        #endif
    }

    private var cardCornerRadius: CGFloat {
        #if os(iOS)
        return 18
        #else
        return 22
        #endif
    }

    // MARK: - Auto-backup actions

    private func onAppearSetup() {
        autoFrequency = BackupStore.autoBackupFrequency
        keepCount = BackupStore.autoBackupKeepCount
        // 进入设置时:执行到期的自动备份。备份内容用现有导出能力按当前 include 选项生成。
        // App 启动 / 进入后台的钩子见文件底部说明。
        BackupStore.runScheduledBackupIfNeeded {
            try viewModel.exportBackup(includeAPIKeys: includeAPIKeys)
        }
        refreshState()
    }

    private func refreshState() {
        lastBackupDate = BackupStore.lastAutoBackupDate
        refreshSnapshots()
    }

    private func refreshSnapshots() {
        snapshots = BackupStore.listSnapshots()
    }

    private func runBackupNow() {
        do {
            let data = try viewModel.exportBackup(includeAPIKeys: includeAPIKeys)
            try BackupStore.writeSnapshot(data)
            resultMessage = "已创建备份。"
            errorMessage = nil
            refreshState()
        } catch {
            errorMessage = "备份失败: \(error.localizedDescription)"
            resultMessage = nil
        }
    }

    private var lastBackupText: String {
        guard let date = lastBackupDate else { return "从未" }
        return Self.dateText(date)
    }

    private static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Export / Import actions

    private func triggerExport() {
        do {
            let data = try viewModel.exportBackup(includeAPIKeys: includeAPIKeys)
            pendingExportDocument = BackupDocument(data: data)
            pendingExportFilename = "kown-config-\(Self.dateStamp()).\(KownBackup.fileExtension)"
            showExporter = true
            errorMessage = nil
        } catch {
            errorMessage = "导出失败: \(error.localizedDescription)"
            resultMessage = nil
        }
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            errorMessage = "选择文件失败: \(err.localizedDescription)"
            resultMessage = nil
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let needsScope = url.startAccessingSecurityScopedResource()
                defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                pendingImportData = data
                showImportModeDialog = true
                errorMessage = nil
            } catch {
                errorMessage = "读取文件失败: \(error.localizedDescription)"
                resultMessage = nil
            }
        }
    }

    // MARK: - 导入聊天记录

    /// 选中文件后:先在安全作用域内把文件拷到临时目录(选完作用域就会失效),
    /// 再丢后台解析(大导出包几十 MB,不能卡 UI),完成回主线程入库 + 提示。
    private func handleChatImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let err):
            errorMessage = "选择文件失败: \(err.localizedDescription)"
            resultMessage = nil
        case .success(let url):
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kown-chat-import-\(UUID().uuidString)")
                .appendingPathExtension(url.pathExtension.isEmpty ? "json" : url.pathExtension)
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: url, to: tempURL)
            } catch {
                errorMessage = "读取文件失败: \(error.localizedDescription)"
                resultMessage = nil
                return
            }
            performChatImport(tempURL: tempURL, source: chatImportSource)
        }
    }

    /// 后台解析 + 主线程入库。临时文件用完即删。
    private func performChatImport(tempURL: URL, source: ConversationImporter.Source) {
        chatImporting = true
        errorMessage = nil
        resultMessage = nil
        let vm = viewModel
        Task {
            defer { try? FileManager.default.removeItem(at: tempURL) }
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    try ConversationImporter.importFile(at: tempURL, source: source)
                }.value
                let added = vm.importChatConversations(parsed.conversations)
                chatImporting = false
                if added == 0 && parsed.skipped == 0 {
                    errorMessage = "文件里没有可导入的会话。"
                } else {
                    resultMessage = "导入完成:成功 \(added) 条,跳过 \(parsed.skipped) 条。已归入「已导入」项目。"
                }
            } catch {
                chatImporting = false
                errorMessage = "导入失败: \(error.localizedDescription)"
            }
        }
    }

    private func applyImport(mode: BackupImportMode) {
        guard let data = pendingImportData else { return }
        do {
            let result = try viewModel.importBackup(data, mode: mode)
            let action = mode == .replace ? "覆盖" : "合并"
            resultMessage = "已\(action)导入 \(result.providers) 个 provider,补充 \(result.importedKeys) 个 API Key。"
            errorMessage = nil
        } catch {
            errorMessage = "导入失败: \(error.localizedDescription)"
            resultMessage = nil
        }
        pendingImportData = nil
    }
}

/// 让 fileExporter 接受我们的 Data 备份。
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = d
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// 说明:自动备份的"到期触发"目前在本视图 onAppear 调用 BackupStore.runScheduledBackupIfNeeded。
// 若需在 App 启动 / 进入后台时也触发(无需打开本页),可在 App 入口(KownApp.swift)对
// scenePhase 变化时调用同一方法,例如:
//   .onChange(of: scenePhase) { _, phase in
//       if phase == .background {
//           BackupStore.runScheduledBackupIfNeeded { try viewModel.exportBackup(includeAPIKeys: true) }
//       }
//   }
// 该接线需改动 App 入口文件,不在本任务的独占文件范围内,故未实施。
