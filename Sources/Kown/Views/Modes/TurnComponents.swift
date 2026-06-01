import SwiftUI

/// 回答操作栏:Sources 小药丸 + 朗读 / 图片(复制) / 复制。独立 View 自带 @State,
/// 供没有自带 footer 的卡片(如 Direct 气泡)复用。
struct AnswerFooterBar: View {
    let text: String
    let providerName: String
    let model: String
    var sources: [SourceRef] = []
    var tint: Color = .secondary

    @State private var copied = false
    @State private var imageCopied = false
    @ObservedObject private var speech = SpeechService.shared

    var body: some View {
        HStack(spacing: 8) {
            if !sources.isEmpty { SourcesChip(sources: sources) }
            Spacer(minLength: 6)
            let reading = speech.speakingText == text
            Button { speech.toggle(text) } label: {
                chip(reading ? "停止" : "朗读", systemImage: reading ? "stop.fill" : "speaker.wave.2",
                     color: reading ? tint : .secondary)
            }.buttonStyle(.borderless)
            Button {
                if AnswerImageExporter.copyToClipboard(providerName: providerName, model: model, text: text) {
                    withAnimation { imageCopied = true }
                    Task { @MainActor in try? await Task.sleep(for: .seconds(1.4)); withAnimation { imageCopied = false } }
                }
            } label: {
                chip(imageCopied ? "已复制" : "图片", systemImage: imageCopied ? "checkmark" : "photo",
                     color: imageCopied ? .green : .secondary)
            }.buttonStyle(.borderless)
            Button {
                Platform.copyText(text)
                withAnimation { copied = true }
                Task { @MainActor in try? await Task.sleep(for: .seconds(1.4)); withAnimation { copied = false } }
            } label: {
                chip(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc",
                     color: copied ? .green : .secondary)
            }.buttonStyle(.borderless)
        }
    }

    private func chip(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold)).lineLimit(1).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule()).fixedSize()
    }
}

/// 整轮折叠的共享小工具(各模式视图共用 collapsedTurns: Set<UUID>)。
enum TurnFold {
    static func preview(_ turn: Turn) -> String {
        let p = turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return "(已折叠)" }
        return "“" + String(p.prefix(40)) + (p.count > 40 ? "…" : "") + "”"
    }
    static func toggle(_ id: UUID, in set: inout Set<UUID>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }
}

/// 用户提问气泡（每个 turn 顶部）
struct PromptBubble: View {
    let prompt: String
    let timestamp: Date?
    var images: [TurnImage] = []
    /// 历史 turn 才传:从这条消息分支出新会话。live turn 不传(为 nil 时不显示)。
    var onFork: (() -> Void)? = nil
    /// 历史 turn 才传:编辑这条消息并从此处重新生成(截断其后各轮)。
    var onEdit: (() -> Void)? = nil
    /// 历史 turn 才传:基于该轮结论追问(聚焦输入,必要时先分支)。
    var onFollowUp: (() -> Void)? = nil
    /// 历史 turn 才传:把该轮导出成单轮报告。
    var onExportReport: (() -> Void)? = nil

    private var hasMenu: Bool {
        onFork != nil || onEdit != nil || onFollowUp != nil || onExportReport != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.92), Color.accentColor.opacity(0.54)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "person.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: Color.accentColor.opacity(0.18), radius: 10, x: 0, y: 5)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("You")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.11), in: Capsule())
                    if let timestamp {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if hasMenu {
                        Spacer(minLength: 8)
                        Menu {
                            if let onEdit {
                                Button { onEdit() } label: { Label("编辑并重发", systemImage: "pencil") }
                            }
                            if let onFollowUp {
                                Button { onFollowUp() } label: { Label("追问", systemImage: "arrowshape.turn.up.left") }
                            }
                            if let onFork {
                                Button { onFork() } label: { Label("从这里分支", systemImage: "arrow.triangle.branch") }
                            }
                            if let onExportReport {
                                Button { onExportReport() } label: { Label("导出本轮报告", systemImage: "square.and.arrow.up") }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                if !prompt.isEmpty {
                    Text(prompt)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ConversationImagesRow(images: images)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.09), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 1)
        }
    }
}

/// 历史回答卡片（已落盘文本，纯展示）
struct HistoricalResponseCard: View {
    let config: ProviderConfig
    let text: String
    let error: String?
    /// 失败时显示的"重试"按钮回调。nil 表示不显示重试。
    var onRetry: (() -> Void)? = nil
    /// 正在重试该卡片(从外部传入,UI 显示加载态)。
    var isRetrying: Bool = false
    /// 「换模型重答」候选 provider。空 = 不显示该入口。
    var regenerateProviders: [ProviderConfig] = []
    /// 选了某个 provider 换答的回调(传入新 provider id)。
    var onRegenerate: ((UUID) -> Void)? = nil
    /// 本轮该 provider 的思考过程(可选)。
    var reasoning: String? = nil
    /// 本轮该 provider 的 token 用量(可选,用于成本角标)。
    var tokenUsage: TurnTokenUsage? = nil
    /// 本轮引用来源(footer 显示 Sources 小药丸)。
    var sources: [SourceRef] = []

    @State private var copied = false
    @State private var imageCopied = false
    @State private var expanded = false
    @State private var bodyCollapsed = false
    @ObservedObject private var speech = SpeechService.shared
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// iOS 紧凑宽度:footer 动作按钮只显示图标,避免窄卡片里文字被逐字竖排。
    private var compactFooter: Bool {
        #if os(iOS)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }
    /// 超过此长度的回答默认折叠(底部渐隐 + 展开全部),防超长回答撑爆布局。
    private static let collapseThreshold = 4000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(accentGradient)
                .frame(height: 4)
            header
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 11)
            if !bodyCollapsed {
                softDivider
                VStack(alignment: .leading, spacing: 10) {
                    if let reasoning, !reasoning.isEmpty {
                        ReasoningDisclosure(reasoning: reasoning, streaming: false, tint: accentColor)
                    }
                    body_
                }
                .padding(16)
                .background(bodyBackground)
                softDivider
                footer
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.08), Color.platformControlBackground.opacity(0.34), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(accentColor.opacity(error == nil ? 0.20 : 0.42), lineWidth: 1)
        }
        .shadow(color: accentColor.opacity(0.06), radius: 18, x: 0, y: 10)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.88), accentColor.opacity(0.42)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: providerSymbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(config.displayName)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    providerKindBadge
                    Text(config.model)
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if error != nil {
                statusBadge("失败", icon: "xmark.octagon.fill", color: .red)
            } else {
                statusBadge("已完成", icon: "checkmark.seal.fill", color: .green)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { bodyCollapsed.toggle() }
            } label: {
                Image(systemName: bodyCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(bodyCollapsed ? "展开这条回答" : "折叠这条回答")
        }
    }

    @ViewBuilder
    private var body_: some View {
        if let error {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("请求失败", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer()
                    if let onRetry {
                        Button {
                            onRetry()
                        } label: {
                            HStack(spacing: 4) {
                                if isRetrying {
                                    ProgressView().controlSize(.small)
                                    Text("重试中")
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                    Text("重试")
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 1))
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(isRetrying)
                    }
                }
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else if text.isEmpty {
            Label("(空响应)", systemImage: "text.bubble")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let isLong = text.count > Self.collapseThreshold
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: (isLong && !expanded) ? 360 : nil, alignment: .top)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        if isLong && !expanded {
                            LinearGradient(colors: [.clear, Color.platformControlBackground],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 48)
                                .allowsHitTesting(false)
                        }
                    }
                if isLong {
                    Button(expanded ? "收起" : "展开全部(\(text.count) 字)") {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !text.isEmpty {
                metricPill("\(text.count) 字", icon: "text.alignleft")
            }
            if let tokenUsage, tokenUsage.input > 0 || tokenUsage.output > 0 {
                TokenCostPill(usage: tokenUsage, model: config.model, providerKind: config.kind)
            }
            Spacer(minLength: 6)
            if !sources.isEmpty {
                SourcesChip(sources: sources)
            }
            if let onRegenerate, !regenerateProviders.isEmpty {
                Menu {
                    ForEach(regenerateProviders) { p in
                        Button("\(p.displayName) · \(p.model)") { onRegenerate(p.id) }
                    }
                } label: {
                    chipLabel("换模型", systemImage: "arrow.triangle.2.circlepath", tint: .secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if !text.isEmpty {
                Button {
                    if AnswerImageExporter.copyToClipboard(providerName: config.displayName, model: config.model, text: text) {
                        withAnimation { imageCopied = true }
                        Task { @MainActor in try? await Task.sleep(for: .seconds(1.4)); withAnimation { imageCopied = false } }
                    }
                } label: {
                    chipLabel(imageCopied ? "已复制" : "图片", systemImage: imageCopied ? "checkmark" : "photo",
                              tint: imageCopied ? .green : .secondary)
                }
                .buttonStyle(.borderless)
            }
            if !text.isEmpty {
                let reading = speech.speakingText == text
                Button {
                    speech.toggle(text)
                } label: {
                    chipLabel(reading ? "停止" : "朗读",
                              systemImage: reading ? "stop.fill" : "speaker.wave.2",
                              tint: reading ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
            }
            Button {
                Platform.copyText(text)
                withAnimation { copied = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation { copied = false }
                }
            } label: {
                chipLabel(copied ? "已复制" : "复制",
                          systemImage: copied ? "checkmark" : "doc.on.doc",
                          tint: copied ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(text.isEmpty)
        }
    }

    /// footer 动作按钮的统一外观:单行不换行 + 固定尺寸;iOS 紧凑宽度只显示图标。
    @ViewBuilder
    private func chipLabel(_ title: String, systemImage: String, tint: Color) -> some View {
        let base = Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(tint)
        Group {
            if compactFooter {
                base.labelStyle(.iconOnly)
            } else {
                base.labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
        .fixedSize()
    }

    private var accentColor: Color {
        switch config.kind {
        case .openAICompatible: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .anthropic:        return Color(red: 0.83, green: 0.38, blue: 0.18)
        case .gemini:           return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .cliCommand:       return Color(red: 0.55, green: 0.45, blue: 0.78)
        }
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentColor.opacity(0.95), accentColor.opacity(0.30)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var bodyBackground: some View {
        LinearGradient(
            colors: [Color.platformTextBackground.opacity(0.26), accentColor.opacity(0.035)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var softDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }

    private var providerKindBadge: some View {
        Text(config.kind.displayName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(accentColor)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(accentColor.opacity(0.11), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(accentColor.opacity(0.18), lineWidth: 1)
            }
    }

    private func statusBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.11), in: Capsule())
            .overlay {
                Capsule().strokeBorder(color.opacity(0.18), lineWidth: 1)
            }
    }

    private func metricPill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08), in: Capsule())
            .fixedSize()
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

/// 一组"已应用到 workspace 的文件写入"卡片。
/// model 在响应里通过 ```kown:write <path>``` 提议改动,被 WorkspaceManager 自动落盘后,
/// 在 Turn 下方展示一组小卡片表明已应用,带文件路径 + create/update 标签 + 成功/失败 icon。
struct AppliedWritesStrip: View {
    let writes: [AppliedWrite]
    /// 撤销某条改动的回调(历史 turn 才传;nil = 不显示撤销按钮)。
    var onUndo: ((AppliedWrite) -> Void)? = nil
    @State private var expandedIDs: Set<UUID> = []
    /// 整组默认收起,点标题展开。
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.teal)
                    Text("Workspace 写入(\(writes.count))")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.teal)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.teal)
                    Spacer()
                    Text("Applied")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.teal.opacity(0.11), in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(writes) { w in
                    AppliedWriteCard(write: w,
                                     expanded: expandedIDs.contains(w.id),
                                     onToggleExpand: {
                                         if expandedIDs.contains(w.id) {
                                             expandedIDs.remove(w.id)
                                         } else {
                                             expandedIDs.insert(w.id)
                                         }
                                     },
                                     onUndo: onUndo.map { cb in { cb(w) } })
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.teal.opacity(0.10), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.24), lineWidth: 1)
        }
    }
}

/// 在 Turn 回答下方渲染「引用来源」卡片 —— 当 `turn.sources` 非空时显示 `SourcesStrip`。
/// 与 `AppliedWritesStrip` 同构,各模式视图(Direct / Council / Compare / Debate)在
/// 渲染完回答(及 AppliedWritesStrip)后,直接 `TurnSourcesStrip(turn: turn)` 即可。
/// turn.sources 为 nil / 空时返回 EmptyView,不占布局。
struct TurnSourcesStrip: View {
    let turn: Turn

    var body: some View {
        // 来源改为只在回答正文内联展示(模型已把来源写进内容,裸 URL 现在会渲染成可点击链接),
        // 不再在回答下方单独成块,避免重复占屏。
        EmptyView()
    }
}

/// 单条 AppliedWrite 卡片。点 path 那一行展开看新内容。
struct AppliedWriteCard: View {
    let write: AppliedWrite
    let expanded: Bool
    let onToggleExpand: () -> Void
    /// 撤销回调(nil = 不显示撤销按钮,例如非历史 turn 或无 workspace)。
    var onUndo: (() -> Void)? = nil
    @State private var copied = false
    @State private var showDiff = false

    private var isReverted: Bool { write.reverted == true }
    private var canDiff: Bool { write.action == .update && (write.oldContent != nil) }
    private var canUndo: Bool { onUndo != nil && write.success && write.action != .skipped && !isReverted }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.body.weight(.semibold))
                Text(write.relativePath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                actionBadge
                if isReverted {
                    Text("已撤销")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.16), in: Capsule())
                }
                Spacer()
                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if let err = write.error, !write.success {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if canDiff {
                            Picker("", selection: $showDiff) {
                                Text("新内容").tag(false)
                                Text("Diff").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        } else {
                            Text("新内容(\(write.newContent.count) 字)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if canUndo, let onUndo {
                            Button(role: .destructive) {
                                onUndo()
                            } label: {
                                Label("撤销", systemImage: "arrow.uturn.backward")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            .help(write.action == .update ? "把文件还原到本轮修改前的内容" : "删除本轮新建的文件")
                        }
                        Button {
                            Platform.copyText(write.newContent)
                            withAnimation { copied = true }
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.4))
                                withAnimation { copied = false }
                            }
                        } label: {
                            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(copied ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    if showDiff && canDiff {
                        diffView
                    } else {
                        ScrollView {
                            Text(write.newContent)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 200)
                        .background(Color.platformTextBackground.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(10)
        .background(
            Color.platformControlBackground.opacity(0.48),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(statusColor.opacity(write.success ? 0.16 : 0.34), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var diffView: some View {
        let lines = TextDiff.diff(old: write.oldContent ?? "", new: write.newContent)
        let stats = TextDiff.stats(lines)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("+\(stats.added)").foregroundStyle(.green)
                Text("−\(stats.removed)").foregroundStyle(.red)
            }
            .font(.caption2.weight(.bold).monospacedDigit())
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Text((prefix(line.kind)) + line.text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(color(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 1)
                            .background(bg(line.kind))
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 240)
            .background(Color.platformTextBackground.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func prefix(_ k: TextDiff.Kind) -> String {
        switch k {
        case .equal:  return "  "
        case .insert: return "+ "
        case .delete: return "- "
        }
    }
    private func color(_ k: TextDiff.Kind) -> Color {
        switch k {
        case .equal:  return .secondary
        case .insert: return .green
        case .delete: return .red
        }
    }
    private func bg(_ k: TextDiff.Kind) -> Color {
        switch k {
        case .equal:  return .clear
        case .insert: return Color.green.opacity(0.10)
        case .delete: return Color.red.opacity(0.10)
        }
    }

    private var statusIcon: String {
        if !write.success { return "exclamationmark.triangle.fill" }
        switch write.action {
        case .create:  return "plus.square.fill"
        case .update:  return "pencil.tip.crop.circle.fill"
        case .skipped: return "minus.circle.fill"
        }
    }
    private var statusColor: Color {
        if !write.success { return .red }
        switch write.action {
        case .create:  return .green
        case .update:  return Color.accentColor
        case .skipped: return .orange
        }
    }
    private var actionLabel: String {
        switch write.action {
        case .create:  return "create"
        case .update:  return "update"
        case .skipped: return "skipped"
        }
    }
    private var actionBadge: some View {
        Text(actionLabel)
            .font(.caption2.weight(.bold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(statusColor.opacity(0.14), in: Capsule())
    }
}

/// Chair 综合块（金色边框 + 王冠）。Council 显示"综合",Compare 显示"裁判"。
struct ChairSummaryCard: View {
    let config: ProviderConfig
    /// nil = 正在生成（用 liveState 渲染），text = 完成的文本
    let text: String?
    let error: String?
    /// 流式中的 live state（非 nil 时优先显示）
    let liveText: String?
    let isStreaming: Bool
    /// 角色身份。.chair = "Chair · 综合"; .judge = "Judge · 裁判"; .summary = "Summary · 汇总"; .moderator = "Moderator · 评审"
    var role: Role = .chair
    /// 失败时的重试回调。nil 表示不显示重试按钮(例如 live 阶段)。
    var onRetry: (() -> Void)? = nil
    /// 正在重试 — UI 显示加载态。
    var isRetrying: Bool = false
    /// 思考过程(live 传 liveState.reasoning,历史传 turn.reasoningByProvider[id])。
    var reasoning: String? = nil
    /// token 用量(可选,用于成本角标)。
    var tokenUsage: TurnTokenUsage? = nil
    /// 本轮引用来源(footer Sources 小药丸)。
    var sources: [SourceRef] = []

    @State private var copied = false
    @State private var imageCopied = false
    @ObservedObject private var speech = SpeechService.shared

    /// 最终可朗读 / 复制的文本(历史 text 或流式 liveText)。
    private var shownText: String { (text ?? liveText) ?? "" }

    enum Role {
        case chair, judge, summary, moderator
        var prefix: String {
            switch self {
            case .chair: return "Chair"
            case .judge: return "Judge"
            case .summary: return "Summary"
            case .moderator: return "Moderator"
            }
        }
        var badge: String {
            switch self {
            case .chair: return "综合"
            case .judge: return "裁判"
            case .summary: return "汇总"
            case .moderator: return "评审"
            }
        }
        var streamingHint: String {
            switch self {
            case .chair: return "综合中"
            case .judge: return "评判中"
            case .summary: return "汇总中"
            case .moderator: return "主持总结中"
            }
        }
        var icon: String {
            switch self {
            case .chair: return "crown.fill"
            case .judge: return "scale.3d"
            case .summary: return "list.bullet.rectangle.fill"
            case .moderator: return "person.2.wave.2.fill"
            }
        }
        var tint: Color {
            switch self {
            case .chair, .judge: return .orange
            case .summary: return .teal
            case .moderator: return .indigo
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [role.tint.opacity(0.92), role.tint.opacity(0.48)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: role.icon)
                        .foregroundStyle(.white)
                        .font(.system(size: 15, weight: .bold))
                }
                .frame(width: 38, height: 38)
                .shadow(color: role.tint.opacity(0.18), radius: 12, x: 0, y: 6)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("\(role.prefix) · \(config.displayName)")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                        Text(role.badge)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(role.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(role.tint.opacity(0.14), in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(role.tint.opacity(0.20), lineWidth: 1)
                            }
                    }
                    Text(config.model)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let tokenUsage, tokenUsage.input > 0 || tokenUsage.output > 0 {
                    TokenCostPill(usage: tokenUsage, model: config.model, providerKind: config.kind)
                }
                if isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(role.streamingHint)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(role.tint)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(role.tint.opacity(0.10), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(role.tint.opacity(0.16), lineWidth: 1)
                    }
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            if let reasoning, !reasoning.isEmpty {
                ReasoningDisclosure(reasoning: reasoning, streaming: isStreaming, tint: role.tint)
            }

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            if !isStreaming, error == nil, !shownText.isEmpty {
                chairFooter
            }
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [role.tint.opacity(0.12), Color.platformControlBackground.opacity(0.28), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(role.tint.opacity(0.30), lineWidth: 1)
        }
        .shadow(color: role.tint.opacity(0.08), radius: 20, x: 0, y: 10)
    }

    /// 综合 / 总结 卡的操作栏:朗读 / 图片(复制) / 复制 + Sources。
    private var chairFooter: some View {
        HStack(spacing: 8) {
            if !sources.isEmpty { SourcesChip(sources: sources) }
            Spacer(minLength: 6)
            let reading = speech.speakingText == shownText
            Button { speech.toggle(shownText) } label: {
                footerChip(reading ? "停止" : "朗读", systemImage: reading ? "stop.fill" : "speaker.wave.2",
                           tint: reading ? role.tint : .secondary)
            }
            .buttonStyle(.borderless)
            Button {
                if AnswerImageExporter.copyToClipboard(providerName: "\(role.prefix) · \(config.displayName)", model: config.model, text: shownText) {
                    withAnimation { imageCopied = true }
                    Task { @MainActor in try? await Task.sleep(for: .seconds(1.4)); withAnimation { imageCopied = false } }
                }
            } label: {
                footerChip(imageCopied ? "已复制" : "图片", systemImage: imageCopied ? "checkmark" : "photo",
                           tint: imageCopied ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            Button {
                Platform.copyText(shownText)
                withAnimation { copied = true }
                Task { @MainActor in try? await Task.sleep(for: .seconds(1.4)); withAnimation { copied = false } }
            } label: {
                footerChip(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc",
                           tint: copied ? .green : .secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private func footerChip(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.10), in: Capsule())
            .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            HStack(alignment: .top, spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        HStack(spacing: 4) {
                            if isRetrying {
                                ProgressView().controlSize(.small)
                                Text("重试中")
                            } else {
                                Image(systemName: "arrow.clockwise")
                                Text("重试")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(role.tint.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(role.tint.opacity(0.40), lineWidth: 1))
                        .foregroundStyle(role.tint)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRetrying)
                }
            }
        } else if let liveText, !liveText.isEmpty {
            MarkdownText(text: liveText, streaming: isStreaming)
        } else if isStreaming {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在综合各模型回答...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(role.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if let text, !text.isEmpty {
            MarkdownText(text: text)
        }
    }
}

/// Shared outer shell for a complete turn in Council / Compare / Debate modes.
struct ModeTurnCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let isLive: Bool
    /// 整轮折叠:nil = 不可折叠;非 nil 时头部显示折叠箭头,collapsed 时只留头部。
    var collapsed: Bool = false
    var onToggleCollapse: (() -> Void)? = nil
    private let content: Content

    init(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        isLive: Bool = false,
        collapsed: Bool = false,
        onToggleCollapse: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.isLive = isLive
        self.collapsed = collapsed
        self.onToggleCollapse = onToggleCollapse
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                if let onToggleCollapse {
                    Button { onToggleCollapse() } label: {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(tint)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.86), tint.opacity(0.44)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
                .shadow(color: tint.opacity(0.16), radius: 12, x: 0, y: 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 10)
                if isLive {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Live")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.11), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 1)
                    }
                }
            }

            if !collapsed {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(isLive ? 0.13 : 0.08), Color.platformControlBackground.opacity(0.30), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(tint.opacity(isLive ? 0.30 : 0.15), lineWidth: 1)
        }
        .shadow(color: tint.opacity(isLive ? 0.11 : 0.06), radius: 24, x: 0, y: 12)
    }
}
