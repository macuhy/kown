import SwiftUI
import UniformTypeIdentifiers

/// Settings → "配置备份" tab。
/// 导出当前 Provider/Web Search/Preference 配置(API Key 可选)→ 一个 JSON 文件;
/// 导入时支持"覆盖"或"合并"。两端通用(SwiftUI fileExporter / fileImporter)。
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

    private let tint = Color(red: 0.91, green: 0.55, blue: 0.20)
    private let secondaryTint = Color(red: 0.57, green: 0.42, blue: 0.82)

    var body: some View {
        platformBody
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
                exportCard
                importCard
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
                exportCard
                importCard
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
                Label("导出配置...", systemImage: "square.and.arrow.up")
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

    // MARK: - Actions

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
