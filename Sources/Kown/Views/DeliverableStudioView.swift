import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct DeliverableStudioView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var request: DeliverableRequest
    @State private var deliverable: Deliverable
    @State private var copied = false
    @State private var publishPayload: ArtifactPublishPayload?
    @State private var exportStatus: String?
    private let showsCloseButton: Bool
    #if os(iOS)
    @State private var sharePayload: DeliverableSharePayload?
    #endif

    init(request: DeliverableRequest = DeliverableRequest(), showsCloseButton: Bool = false) {
        let generated = DeliverableStudioService.generate(request)
        _request = State(initialValue: request)
        _deliverable = State(initialValue: generated)
        self.showsCloseButton = showsCloseButton
    }

    init(title: String, sourceKind: DeliverableSourceKind = .answer, sourceText: String, showsCloseButton: Bool = false) {
        self.init(
            request: DeliverableRequest(title: title, sourceKind: sourceKind, sourceText: sourceText),
            showsCloseButton: showsCloseButton
        )
    }

    var body: some View {
        ZStack {
            studioBackground
            VStack(spacing: 0) {
                header
                contentArea
            }
        }
        #if os(macOS)
        .frame(
            minWidth: showsCloseButton ? 1040 : nil,
            idealWidth: showsCloseButton ? 1120 : nil,
            minHeight: showsCloseButton ? 720 : nil,
            idealHeight: showsCloseButton ? 760 : nil
        )
        #endif
        .onChange(of: request) { _, _ in regenerate() }
        .sheet(item: $publishPayload) { payload in
            ArtifactPublishSheet(payload: payload)
        }
        #if os(iOS)
        .presentationDetents([.large])
        .sheet(item: $sharePayload) { payload in
            DeliverableShareSheet(activityItems: [payload.url])
        }
        #endif
    }

    private var studioTint: Color { Color(red: 0.08, green: 0.58, blue: 0.52) }
    private var studioWarm: Color { Color(red: 0.95, green: 0.49, blue: 0.16) }
    private var sourceCharacterCount: Int { request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).count }

    private var studioBackground: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [studioTint.opacity(0.16), Color.clear],
                center: .topLeading,
                startRadius: 40,
                endRadius: 520
            )
            RadialGradient(
                colors: [studioWarm.opacity(0.12), Color.clear],
                center: .bottomTrailing,
                startRadius: 60,
                endRadius: 560
            )
            LinearGradient(
                colors: [Color.white.opacity(0.05), Color.clear, Color.black.opacity(0.03)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                headerTitle
                Spacer(minLength: 20)
                headerControls
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    headerTitle
                    Spacer(minLength: 8)
                    if showsCloseButton { closeButton }
                }
                moreMenu
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var headerTitle: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [studioWarm.opacity(0.96), studioTint.opacity(0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
            }
            .shadow(color: studioWarm.opacity(0.24), radius: 18, x: 0, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DELIVERABLE STUDIO")
                        .font(.caption2.weight(.black))
                        .tracking(1.2)
                        .foregroundStyle(studioTint)
                    Text("交付物工作台")
                        .font(.title2.weight(.bold))
                    Text("把回答、研究或会议内容整理成可交付、可发布、可导出的正式材料。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    metadataPill(request.sourceKind.displayName, systemImage: "tray.full", tint: studioTint)
                    metadataPill(request.targetKind.displayName, systemImage: request.targetKind.systemImage, tint: studioWarm)
                    metadataPill("素材 \(sourceCharacterCount) 字", systemImage: "text.alignleft", tint: .secondary)
                }
            }
        }
    }

    private var headerControls: some View {
        HStack(spacing: 10) {
            moreMenu
            if showsCloseButton { closeButton }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("复制内容") { copy(deliverable.content) }
            Button("复制文件名") { copy(deliverable.suggestedFileName) }
            Button("导出文件…") { exportFile() }
            Button("发布为网页") { preparePublish() }
            Divider()
            Button("重新生成") { regenerate() }
        } label: {
            Label("更多操作", systemImage: "ellipsis")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("关闭交付物工作台")
        .help("关闭交付物工作台")
    }

    private var contentArea: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                formPane
                    .frame(width: 372)
                previewPane
                    .frame(minWidth: 540, maxWidth: .infinity)
            }

            ScrollView {
                VStack(spacing: 16) {
                    formPane
                    previewPane
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private var formPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionCard(title: "输出形态", icon: "square.grid.2x2.fill") {
                    formatGrid
                }

                sectionCard(title: "来源", icon: "tray.full.fill") {
                    Picker("来源", selection: $request.sourceKind) {
                        ForEach(DeliverableSourceKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                sectionCard(title: "命名与用途", icon: "target") {
                    VStack(spacing: 10) {
                        styledTextField("交付物标题", text: $request.title)
                        styledTextField("受众：产品团队 / 投资人 / 客户", text: $request.audience)
                        styledTextField("目标：快速对齐结论并推动决策", text: $request.goal)
                    }
                }

                sectionCard(title: "原始素材", icon: "text.alignleft") {
                    TextEditor(text: $request.sourceText)
                        .font(.system(.callout, design: .monospaced))
                        .lineSpacing(3)
                        .frame(minHeight: 220)
                        .padding(10)
                        .scrollContentBackground(.hidden)
                        .background(Color.platformTextBackground.opacity(0.68), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                }
            }
            .padding(14)
        }
        .background {
            panelBackground(tint: studioTint, cornerRadius: 24)
        }
        .frame(maxHeight: .infinity)
    }

    private var formatGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 9)], spacing: 9) {
            ForEach(DeliverableKind.allCases) { kind in
                formatCard(kind)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: request.targetKind)
    }

    private func formatCard(_ kind: DeliverableKind) -> some View {
        let selected = request.targetKind == kind
        return Button {
            request.targetKind = kind
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: kind.systemImage)
                        .font(.caption.weight(.bold))
                    Text(kind.displayName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(kind.shortDescription)
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.white.opacity(0.82) : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(11)
            .frame(minHeight: 86, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        selected
                        ? LinearGradient(colors: [studioTint, studioWarm.opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color.platformControlBackground.opacity(0.58), Color.platformTextBackground.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder((selected ? Color.white : Color.primary).opacity(selected ? 0.26 : 0.08), lineWidth: 1)
            }
            .shadow(color: selected ? studioTint.opacity(0.18) : Color.clear, radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            previewToolbar
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let exportStatus {
                        statusBanner(exportStatus)
                    }
                    summaryCard
                    contentPreviewCard
                }
                .padding(16)
            }
        }
        .background {
            panelBackground(tint: studioWarm, cornerRadius: 24)
        }
        .frame(maxHeight: .infinity)
    }

    private var previewToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                previewTitle
                Spacer(minLength: 14)
                previewActions
            }

            VStack(alignment: .leading, spacing: 12) {
                previewTitle
                previewActions
            }
        }
        .padding(16)
    }

    private var previewTitle: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(studioWarm.opacity(0.13))
                Image(systemName: deliverable.kind.systemImage)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(studioWarm)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 5) {
                Text(deliverable.title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    metadataPill(deliverable.suggestedFileName, systemImage: "doc", tint: .secondary)
                    metadataPill("\(deliverable.content.count) 字", systemImage: "number", tint: studioTint)
                }
            }
        }
    }

    private var previewActions: some View {
        HStack(spacing: 8) {
            if copied {
                Label("已复制", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color.green.opacity(0.10), in: Capsule(style: .continuous))
            }
            previewActionButton("复制", systemImage: "doc.on.doc") { copy(deliverable.content) }
            previewActionButton("导出", systemImage: "square.and.arrow.down") { exportFile() }
            previewActionButton("发布", systemImage: "globe") { preparePublish() }
            previewActionButton("刷新", systemImage: "arrow.clockwise") { regenerate() }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(studioTint)
                Text("提炼摘要")
                    .font(.caption.weight(.black))
                    .tracking(0.4)
                Spacer()
                Text(deliverable.sourceKind.displayName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(studioTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(studioTint.opacity(0.11), in: Capsule(style: .continuous))
            }
            Text(deliverable.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(studioTint.opacity(0.14), lineWidth: 1)
        }
    }

    private var contentPreviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color.red.opacity(0.68)).frame(width: 8, height: 8)
                Circle().fill(Color.yellow.opacity(0.80)).frame(width: 8, height: 8)
                Circle().fill(Color.green.opacity(0.75)).frame(width: 8, height: 8)
                Text(deliverable.suggestedFileName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 4)
                Spacer()
                Text(deliverable.kind.displayName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(studioWarm)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.platformControlBackground.opacity(0.42))

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            Text(deliverable.content)
                .font(.system(.callout, design: .monospaced))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
        }
        .background(Color.platformTextBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.04), radius: 18, x: 0, y: 10)
    }

    private func sectionCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(studioTint)
                Text(title)
                    .font(.subheadline.weight(.bold))
                Spacer()
            }
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformTextBackground.opacity(0.48), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func styledTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.callout)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Color.platformTextBackground.opacity(0.70), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    private func metadataPill(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 1)
            }
    }

    private func previewActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.platformControlBackground.opacity(0.72), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func statusBanner(_ text: String) -> some View {
        let isError = text.hasPrefix("导出失败")
        let tint = isError ? Color.orange : Color.green
        return Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.18), lineWidth: 1)
            }
    }

    private func panelBackground(tint: Color, cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.08), Color.platformControlBackground.opacity(0.22), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.08), radius: 20, x: 0, y: 10)
    }

    private func regenerate() {
        deliverable = DeliverableStudioService.generate(request)
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copied = false
        }
    }

    private func preparePublish() {
        let html = DeliverableStudioService.publishableHTML(for: deliverable)
        let key = publishKey(for: deliverable)
        let previous = ArtifactPublishMemory.slug(for: key)
        let slug = previous ?? GitHubPagesPublisher.defaultSlug(
            title: deliverable.title,
            fallbackSeed: "\(deliverable.title)\n\(deliverable.kind.rawValue)\n\(deliverable.content)"
        )
        publishPayload = ArtifactPublishPayload(
            html: html,
            defaultSlug: slug,
            artifactKey: key,
            previousSlug: previous
        )
    }

    private func publishKey(for deliverable: Deliverable) -> String {
        let seed = [
            deliverable.title,
            deliverable.sourceKind.rawValue,
            deliverable.kind.rawValue,
            request.sourceText
        ].joined(separator: "\n")
        return "deliverable-\(GitHubPagesPublisher.shortHash(seed))"
    }

    private func exportFile() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = deliverable.suggestedFileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try DeliverableFileExporter.write(deliverable, to: url)
                exportStatus = "已导出 \(url.lastPathComponent)"
            } catch {
                exportStatus = "导出失败: \(error.localizedDescription)"
            }
        }
        #else
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(deliverable.suggestedFileName)
            try DeliverableFileExporter.write(deliverable, to: url)
            sharePayload = DeliverableSharePayload(url: url)
            exportStatus = "已生成 \(url.lastPathComponent)"
        } catch {
            exportStatus = "导出失败: \(error.localizedDescription)"
        }
        #endif
    }
}

#if os(iOS)
private struct DeliverableSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DeliverableShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

/// Small reusable launcher for "turn this content into a deliverable".
/// The studio itself owns the final GitHub Pages publish step, so callers only
/// need to provide source text and a sensible default format.
struct DeliverableStudioSheetButton: View {
    let title: String
    let sourceKind: DeliverableSourceKind
    let sourceText: String
    var targetKind: DeliverableKind = .markdown
    var audience: String = ""
    var goal: String = ""
    var label: String = "交付"
    var systemImage: String = "shippingbox.and.arrow.backward"
    var tint: Color = .secondary
    var compact: Bool = false

    @State private var showingStudio = false

    var body: some View {
        let isDisabled = sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Button {
            showingStudio = true
        } label: {
            HStack(spacing: compact ? 0 : 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.black))
                if !compact {
                    Text(label)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(tint)
            .frame(width: compact ? 28 : nil, height: compact ? 28 : nil)
            .padding(.horizontal, compact ? 0 : 10)
            .padding(.vertical, compact ? 0 : 6)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.16), tint.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.45 : 1)
        .disabled(isDisabled)
        .help(isDisabled ? "没有可转换的内容" : "整理为交付物并发布/导出")
        .sheet(isPresented: $showingStudio) {
            DeliverableStudioView(request: DeliverableRequest(
                title: title,
                sourceKind: sourceKind,
                targetKind: targetKind,
                sourceText: sourceText,
                audience: audience,
                goal: goal
            ), showsCloseButton: true)
        }
    }
}

#Preview("Deliverable Studio") {
    DeliverableStudioView(request: DeliverableRequest(
        title: "季度研究摘要",
        sourceKind: .research,
        targetKind: .webpage,
        sourceText: "# 结论\nKown 应优先补齐连接器中心和 Agent 运行中心。\n# 下一步\n把研究、会议和交付物串成闭环。",
        audience: "产品团队",
        goal: "确定下个版本路线图"
    ))
    .frame(width: 980, height: 680)
}
