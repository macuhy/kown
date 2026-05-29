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
        Form {
            exportSection
            importSection
            statusSection
        }
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                exportCard
                importCard
                if resultMessage != nil || errorMessage != nil {
                    statusCard
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .topLeading)
        }
        #endif
    }

    // MARK: - 共用片段

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $includeAPIKeys) {
                VStack(alignment: .leading, spacing: 2) {
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
        VStack(alignment: .leading, spacing: 10) {
            Text("从 .kownbackup / .json 文件还原配置。导入后可选'覆盖'当前全部设置,或'合并'(只新增不存在的 provider)。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if let resultMessage {
            Label(resultMessage, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .textSelection(.enabled)
        }
    }

    // MARK: - iOS Form sections

    #if os(iOS)
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
        cardShell {
            VStack(alignment: .leading, spacing: 10) {
                Text("导出").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                exportControls
            }
        }
    }
    private var importCard: some View {
        cardShell {
            VStack(alignment: .leading, spacing: 10) {
                Text("导入").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                importControls
            }
        }
    }
    private var statusCard: some View {
        cardShell { statusContent }
    }

    @ViewBuilder
    private func cardShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                Color.platformControlBackground.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
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
