import SwiftUI

/// 输入栏的「上下文用量条」:细进度条 + 百分比,点开是上下文管理菜单
/// (压缩早期历史 / 从下一轮开始全新上下文 / 各自的撤销)。
/// 颜色:≥90% 红、≥70% 橙、其余灰;<50% 时只显示细进度条不显示数字,不抢注意力,
/// 细节(估算 token / 分母模型)hover(macOS .help)或点开菜单可见。
struct ContextUsageBadge: View {
    @Bindable var viewModel: AppViewModel
    var buttonSize: CGFloat = 30

    var body: some View {
        if let usage = viewModel.contextUsageForCurrentSend {
            let menu = Menu {
                menuContent(usage)
            } label: {
                label(usage)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            #if os(macOS)
            menu
                .menuStyle(.borderlessButton)
                .help(helpText(usage))
            #else
            menu
                .accessibilityLabel("上下文用量 \(usage.percent)%")
            #endif
        }
    }

    // MARK: - 胶囊 label(细进度条 + 百分比)

    private func label(_ usage: ContextWindowEstimator.Usage) -> some View {
        let color = tint(usage)
        return HStack(spacing: 5) {
            if viewModel.isCompressingContext {
                Image(systemName: "hourglass")
                    .font(.system(size: 11, weight: .bold))
            } else {
                // 细进度条:低占用时它就是全部内容,够低调。
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 30, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color)
                            .frame(width: max(2, 30 * usage.fraction), height: 4)
                    }
            }
            if usage.percent >= 50 || viewModel.hasContextCutoff {
                Text(usage.percent > 100 ? "超出" : "\(usage.percent)%")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(usage.percent >= 70 ? color : .secondary)
        .padding(.horizontal, 9)
        .frame(height: buttonSize)
        .background(color.opacity(usage.percent >= 70 ? 0.13 : 0.0), in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                (usage.percent >= 70 ? color : Color.primary).opacity(usage.percent >= 70 ? 0.28 : 0.07),
                lineWidth: 1
            )
        }
        .contentShape(Capsule())
    }

    private func tint(_ usage: ContextWindowEstimator.Usage) -> Color {
        if usage.percent >= 90 { return .red }
        if usage.percent >= 70 { return .orange }
        return .secondary
    }

    private func helpText(_ usage: ContextWindowEstimator.Usage) -> String {
        "上下文约 \(formatTokens(usage.estimatedTokens)) / \(formatTokens(usage.windowTokens)) tokens(\(usage.percent)%)\n点开可压缩早期历史或开始全新上下文"
    }

    // MARK: - 菜单

    @ViewBuilder
    private func menuContent(_ usage: ContextWindowEstimator.Usage) -> some View {
        Section("上下文用量(估算)") {
            Text("约 \(formatTokens(usage.estimatedTokens)) / \(formatTokens(usage.windowTokens)) tokens(\(usage.percent)%)")
            Text("按窗口最小的模型算:\(usage.limitingModel)")
        }
        Divider()
        Button {
            viewModel.compressEarlyHistory()
        } label: {
            Label(viewModel.isCompressingContext ? "正在压缩早期历史…" : "压缩早期历史(保留最近 \(ConversationSummarizer.compressionKeepRecent) 轮)",
                  systemImage: "arrow.down.right.and.arrow.up.left")
        }
        .disabled(!viewModel.canCompressContext || viewModel.isCompressingContext)
        if viewModel.selectedConversation?.compressedContextSummary != nil {
            Button {
                viewModel.clearCompressedContext()
            } label: {
                Label("清除压缩摘要,恢复发送原文", systemImage: "arrow.uturn.backward")
            }
        }
        Divider()
        if viewModel.hasContextCutoff {
            Button {
                viewModel.clearContextCutoff()
            } label: {
                Label("撤销截断,恢复完整上下文", systemImage: "arrow.uturn.backward.circle")
            }
        } else {
            Button {
                viewModel.setContextCutoff()
            } label: {
                Label("从下一轮开始全新上下文", systemImage: "scissors")
            }
            .disabled(viewModel.selectedConversation?.turns.isEmpty ?? true)
        }
        if let err = viewModel.contextCompressionError {
            Divider()
            Text(err)
        }
    }

    /// token 数的紧凑显示:≥1000 用 k(如 12.5k),其余原样。
    private func formatTokens(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000.0
            return k >= 100 ? "\(Int(k.rounded()))k" : String(format: "%.1fk", k)
        }
        return "\(n)"
    }
}
