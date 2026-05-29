import SwiftUI

/// 用户提问气泡（每个 turn 顶部）
struct PromptBubble: View {
    let prompt: String
    let timestamp: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.14))
                Image(systemName: "person.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let timestamp {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(prompt)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            Color.accentColor.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
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

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(accentColor.opacity(0.6)).frame(height: 3)
            header
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
            Divider()
            body_
                .padding(14)
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .background(
            Color.platformControlBackground.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accentColor.opacity(0.22), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accentColor.opacity(0.14))
                Image(systemName: providerSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentColor)
            }
            .frame(width: 28, height: 28)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.20), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(config.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(config.model)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if error != nil {
                Text("失败")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.red.opacity(0.12), in: Capsule())
                    .foregroundStyle(.red)
            }
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else if text.isEmpty {
            Text("(空响应)")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarkdownText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            if !text.isEmpty {
                Text("\(text.count) 字")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer()
            Button {
                Platform.copyText(text)
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
            .disabled(text.isEmpty)
        }
    }

    private var accentColor: Color {
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

/// 一组"已应用到 workspace 的文件写入"卡片。
/// model 在响应里通过 ```kown:write <path>``` 提议改动,被 WorkspaceManager 自动落盘后,
/// 在 Turn 下方展示一组小卡片表明已应用,带文件路径 + create/update 标签 + 成功/失败 icon。
struct AppliedWritesStrip: View {
    let writes: [AppliedWrite]
    @State private var expandedIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                Text("Workspace 写入(\(writes.count))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.teal)
                Spacer()
            }
            ForEach(writes) { w in
                AppliedWriteCard(write: w,
                                 expanded: expandedIDs.contains(w.id),
                                 onToggleExpand: {
                                     if expandedIDs.contains(w.id) {
                                         expandedIDs.remove(w.id)
                                     } else {
                                         expandedIDs.insert(w.id)
                                     }
                                 })
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.teal.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.30), lineWidth: 1)
        }
    }
}

/// 单条 AppliedWrite 卡片。点 path 那一行展开看新内容。
struct AppliedWriteCard: View {
    let write: AppliedWrite
    let expanded: Bool
    let onToggleExpand: () -> Void
    @State private var copied = false

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
                    HStack {
                        Text("新内容(\(write.newContent.count) 字)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
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
        .padding(10)
        .background(
            Color.platformControlBackground.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(role.tint.opacity(0.18))
                    Image(systemName: role.icon)
                        .foregroundStyle(role.tint)
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("\(role.prefix) · \(config.displayName)")
                            .font(.subheadline.weight(.semibold))
                        Text(role.badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(role.tint.opacity(0.16), in: Capsule())
                            .foregroundStyle(role.tint)
                    }
                    Text(config.model)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(role.streamingHint).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            role.tint.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(role.tint.opacity(0.45), lineWidth: 1.2)
        }
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
            Text("正在综合各模型回答...")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let text, !text.isEmpty {
            MarkdownText(text: text)
        }
    }
}
