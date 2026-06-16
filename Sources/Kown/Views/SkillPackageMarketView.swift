import SwiftUI

/// 功能 5 独立 MVP:技能包市场 / 导入导出。
///
/// 该 View 不接导航、不改设置页,默认用本地 `SkillPackageStore` 展示内置推荐包与已导入包。
/// 主代理集成时可通过闭包接入真实文件选择器、分享面板或安装流程。
struct SkillPackageMarketView: View {
    typealias ImportHandler = () -> SkillPackage?
    typealias ExportHandler = (SkillPackage, Data) -> Void
    typealias InstallHandler = (SkillPackage) -> Void

    private let onImportRequested: ImportHandler?
    private let onExportPackage: ExportHandler?
    private let onInstallPackage: InstallHandler?

    @State private var store = SkillPackageStore()
    @State private var selectedPackageID: UUID?
    @State private var statusMessage: String = "选择一个技能包查看详情。"
    @State private var lastExportPreview: String = ""

    @Environment(\.horizontalSizeClass) private var hSizeClass

    init(onImportRequested: ImportHandler? = nil,
         onExportPackage: ExportHandler? = nil,
         onInstallPackage: InstallHandler? = nil) {
        self.onImportRequested = onImportRequested
        self.onExportPackage = onExportPackage
        self.onInstallPackage = onInstallPackage
    }

    var body: some View {
        Group {
            if isCompact {
                compactBody
            } else {
                splitBody
            }
        }
        .onAppear {
            if selectedPackageID == nil {
                selectedPackageID = store.marketPackages.first?.id
            }
        }
    }

    private var isCompact: Bool {
        #if os(iOS)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }

    private var selectedPackage: SkillPackage? {
        store.package(id: selectedPackageID) ?? store.marketPackages.first
    }

    private var splitBody: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 300)
            Divider()
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var compactBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                compactPackagePicker
                if let package = selectedPackage {
                    packageDetail(package)
                } else {
                    emptyState
                }
            }
            .padding(16)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
                .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.marketPackages) { package in
                        packageRow(package)
                    }
                }
                .padding(12)
            }
        }
        .background(.thinMaterial)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("技能包市场")
                        .font(.title2.weight(.bold))
                    Text(".kownskill 导入、导出与权限预览")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(
                        LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }

            HStack(spacing: 8) {
                Button {
                    importTapped()
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                if let package = selectedPackage {
                    Button {
                        exportTapped(package)
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    private var compactPackagePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.marketPackages) { package in
                    Button {
                        selectedPackageID = package.id
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(package.displayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(package.metadata.version)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(width: 170, alignment: .leading)
                        .background(package.id == selectedPackageID ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func packageRow(_ package: SkillPackage) -> some View {
        let selected = package.id == selectedPackageID
        return Button {
            selectedPackageID = package.id
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(package.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    sourceBadge(package)
                }

                Text(package.metadata.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Label("\(package.prompts.count)", systemImage: "text.quote")
                    Label("\(package.requiredToolPermissions.count)", systemImage: "lock.shield")
                    Label(package.metadata.version, systemImage: "tag")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var detailPane: some View {
        ScrollView {
            if let package = selectedPackage {
                packageDetail(package)
                    .padding(22)
                    .frame(maxWidth: 960, alignment: .topLeading)
            } else {
                emptyState
                    .padding(22)
            }
        }
    }

    private func packageDetail(_ package: SkillPackage) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(package.displayName)
                                .font(.largeTitle.weight(.bold))
                                .lineLimit(2)
                            sourceBadge(package)
                        }

                        Text(package.metadata.summary)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    installButton(package)
                }

                tagCloud(package.metadata.tags)
            }
            .padding(18)
            .background(
                LinearGradient(colors: [Color.teal.opacity(0.14), Color.blue.opacity(0.08)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )

            section("提示词") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(package.prompts) { prompt in
                        promptCard(prompt)
                    }
                }
            }

            if !package.variables.isEmpty {
                section("变量") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                        ForEach(package.variables) { variable in
                            variableCard(variable)
                        }
                    }
                }
            }

            section("所需工具权限") {
                if package.requiredToolPermissions.isEmpty {
                    Label("无需额外工具权限", systemImage: "checkmark.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        ForEach(package.requiredToolPermissions) { permission in
                            permissionCard(permission)
                        }
                    }
                }
            }

            if !package.personaReferences.isEmpty || !package.promptChainReferences.isEmpty {
                section("引用") {
                    referenceGrid(package)
                }
            }

            if !package.examples.isEmpty {
                section("示例") {
                    VStack(spacing: 10) {
                        ForEach(package.examples) { example in
                            exampleCard(example)
                        }
                    }
                }
            }

            if !lastExportPreview.isEmpty {
                section("导出预览") {
                    Text(lastExportPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func promptCard(_ prompt: SkillPackage.Prompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(prompt.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(prompt.role.rawValue)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.13), in: Capsule())
            }
            Text(prompt.template)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func variableCard(_ variable: SkillPackage.Variable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("{{\(variable.name)}}")
                    .font(.caption.weight(.bold))
                    .monospaced()
                Spacer()
                if variable.isRequired {
                    Text("必填")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }
            Text(variable.label)
                .font(.subheadline.weight(.semibold))
            if !variable.summary.isEmpty {
                Text(variable.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !variable.defaultValue.isEmpty {
                Text("默认: \(variable.defaultValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func permissionCard(_ permission: SkillPackage.RequiredToolPermission) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: permission.category))
                .font(.title3)
                .foregroundStyle(color(for: permission.riskLevel))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(permission.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(permission.toolName)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
                if !permission.reason.isEmpty {
                    Text(permission.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(permission.riskLevel.rawValue)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(color(for: permission.riskLevel))
                .background(color(for: permission.riskLevel).opacity(0.12), in: Capsule())
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func referenceGrid(_ package: SkillPackage) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
            ForEach(package.personaReferences) { ref in
                referenceCard(title: ref.name, subtitle: ref.summary, icon: "person.text.rectangle")
            }
            ForEach(package.promptChainReferences) { ref in
                referenceCard(title: ref.name,
                              subtitle: ref.stepTitles.isEmpty ? ref.summary : ref.stepTitles.joined(separator: " → "),
                              icon: "arrow.triangle.branch")
            }
        }
    }

    private func referenceCard(title: String, subtitle: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func exampleCard(_ example: SkillPackage.Example) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(example.title)
                .font(.subheadline.weight(.semibold))
            Text(example.input)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !example.output.isEmpty {
                Divider()
                Text(example.output)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tagCloud(_ tags: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.2), in: Capsule())
            }
        }
    }

    private func sourceBadge(_ package: SkillPackage) -> some View {
        Text(sourceTitle(package))
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(sourceColor(package).opacity(0.14), in: Capsule())
            .foregroundStyle(sourceColor(package))
    }

    private func installButton(_ package: SkillPackage) -> some View {
        Button {
            installTapped(package)
        } label: {
            Label(store.isInstalled(package) ? "已导入" : "导入包",
                  systemImage: store.isInstalled(package) ? "checkmark.circle.fill" : "plus.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isInstalled(package))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("暂无技能包")
                .font(.headline)
            Text("导入 .kownskill 文件后会显示在这里。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func importTapped() {
        if let package = onImportRequested?() {
            let installed = store.install(package)
            selectedPackageID = installed.id
            statusMessage = "已导入 \(installed.displayName)"
        } else {
            statusMessage = "导入按钮已触发。集成时在 onImportRequested 中接入文件选择器。"
        }
    }

    private func exportTapped(_ package: SkillPackage) {
        do {
            let data = try store.exportData(for: package)
            onExportPackage?(package, data)
            lastExportPreview = String(data: data.prefix(1_200), encoding: .utf8) ?? "\(data.count) bytes"
            statusMessage = "已生成 \(SkillPackageStore.suggestedExportFilename(for: package)) (\(data.count) bytes)"
        } catch {
            statusMessage = "导出失败: \(error.localizedDescription)"
        }
    }

    private func installTapped(_ package: SkillPackage) {
        let installed = store.install(package)
        selectedPackageID = installed.id
        onInstallPackage?(installed)
        statusMessage = "已导入 \(installed.displayName),主代理可调用 makeSkill() 接入技能库。"
    }

    private func sourceTitle(_ package: SkillPackage) -> String {
        if store.isInstalled(package) { return "已导入" }
        switch package.source {
        case .builtin: return "推荐"
        case .imported: return "导入"
        case .local: return "本地"
        }
    }

    private func sourceColor(_ package: SkillPackage) -> Color {
        if store.isInstalled(package) { return .green }
        switch package.source {
        case .builtin: return .teal
        case .imported: return .blue
        case .local: return .secondary
        }
    }

    private func icon(for category: SkillPackage.PermissionCategory) -> String {
        switch category {
        case .network: return "network"
        case .deviceTool: return "iphone.gen3"
        case .localFile: return "folder"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .generation: return "wand.and.stars"
        case .other: return "lock.shield"
        }
    }

    private func color(for risk: SkillPackage.RiskLevel) -> Color {
        switch risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}
