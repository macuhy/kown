import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct DeliverableStudioView: View {
    @State private var request: DeliverableRequest
    @State private var deliverable: Deliverable
    @State private var copied = false
    @State private var publishPayload: ArtifactPublishPayload?

    init(request: DeliverableRequest = DeliverableRequest()) {
        let generated = DeliverableStudioService.generate(request)
        _request = State(initialValue: request)
        _deliverable = State(initialValue: generated)
    }

    init(title: String, sourceKind: DeliverableSourceKind = .answer, sourceText: String) {
        self.init(request: DeliverableRequest(title: title, sourceKind: sourceKind, sourceText: sourceText))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                formPane
                    .frame(minWidth: 280, idealWidth: 330, maxWidth: 380)
                Divider()
                previewPane
            }
        }
        .onChange(of: request) { _, _ in regenerate() }
        .sheet(item: $publishPayload) { payload in
            ArtifactPublishSheet(payload: payload)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
                .frame(width: 40, height: 40)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("交付物工作台")
                    .font(.title3.weight(.bold))
                Text("把回答、研究或会议内容整理成 Markdown、网页、PDF/PPT 大纲。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("复制内容") { copy(deliverable.content) }
                Button("复制文件名") { copy(deliverable.suggestedFileName) }
                Button("发布为网页") { preparePublish() }
                Divider()
                Button("重新生成") { regenerate() }
            } label: {
                Label("操作", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)
        }
        .padding(16)
    }

    private var formPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("目标格式")
                        .font(.headline)
                    Picker("目标格式", selection: $request.targetKind) {
                        ForEach(DeliverableKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(request.targetKind.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("来源")
                        .font(.headline)
                    Picker("来源", selection: $request.sourceKind) {
                        ForEach(DeliverableSourceKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("标题")
                        .font(.headline)
                    TextField("交付物标题", text: $request.title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("受众与目标")
                        .font(.headline)
                    TextField("例如：产品团队 / 投资人 / 客户", text: $request.audience)
                        .textFieldStyle(.roundedBorder)
                    TextField("例如：快速对齐结论并推动决策", text: $request.goal)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("原始素材")
                        .font(.headline)
                    TextEditor(text: $request.sourceText)
                        .font(.body.monospaced())
                        .frame(minHeight: 220)
                        .padding(8)
                        .background(Color.platformControlBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                }
            }
            .padding(16)
        }
        .background(Color.platformControlBackground.opacity(0.45))
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(deliverable.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(deliverable.kind.displayName) · \(deliverable.suggestedFileName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if copied {
                    Label("已复制", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                Button {
                    copy(deliverable.content)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Button {
                    preparePublish()
                } label: {
                    Label("发布", systemImage: "globe")
                }
                Button {
                    regenerate()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(deliverable.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text(deliverable.content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color.platformControlBackground.opacity(0.62), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                }
                .padding(18)
            }
        }
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
