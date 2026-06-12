import SwiftUI

// MARK: - 代码块一键运行(状态控制器 + 结果面板)

/// 单个代码块的运行状态。**每个代码块视图自持一个**(挂在 `@State` 上),
/// 与会话数据完全解耦 —— 运行状态/结果不落盘,卡片销毁(切会话/滚出复用)即消失。
/// 用 @Observable 让状态变化只重渲**当前代码块**,不触发历史列表整列重渲
/// (模式同 StreamingMarkdownText 的性能修复:别把高频状态挂到共享对象上)。
@MainActor
@Observable
final class CodeRunController {
    enum Phase: Equatable {
        case idle       // 从未运行 / 已清除
        case running
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var result: CodeRunResult?
    /// 结果区折叠(仅隐藏输出正文,保留状态行)。
    var collapsed = false

    @ObservationIgnored private var task: Task<Void, Never>?
    /// 代际计数:重复点运行会取消上一次,旧任务即使已越过 await 也不允许写回结果。
    @ObservationIgnored private var generation = 0

    /// 运行一段代码。再次调用会先取消上一次(同一代码块重复点运行只保留最新一次)。
    func run(language: String, code: String) {
        task?.cancel()
        generation += 1
        let gen = generation
        phase = .running
        result = nil
        collapsed = false
        task = Task { [weak self] in
            let r = await CodeSandboxService.run(language: language, code: code)
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.result = r
            self.phase = .finished
            self.task = nil
        }
    }

    /// 停止等待当前这次运行(macOS 子进程仍由服务层的 30s 超时强杀兜底)。
    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        if phase == .running { phase = .idle }
    }

    /// 关闭结果区,回到未运行状态。
    func clear() {
        cancel()
        result = nil
        phase = .idle
    }
}

/// 代码围栏语言 → CodeSandboxService 的语言标识。返回 nil 表示当前平台不可运行(不显示按钮)。
/// 常见别名(py / js / node…)都归一;最终以服务声明的 supportedLanguages 为准
/// (iOS 只有 javascript,python 块自然不出现运行按钮)。
@MainActor
func runnableLanguage(forFence fence: String?) -> String? {
    guard let raw = fence?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
    let canonical: String
    switch raw {
    case "python", "python3", "py":          canonical = "python"
    case "javascript", "js", "node", "nodejs": canonical = "javascript"
    default: return nil
    }
    return CodeSandboxService.supportedLanguages.contains(canonical) ? canonical : nil
}

/// 代码块下方的内嵌运行结果区:状态行(运行中转圈 / 成功 / 失败 / 超时 + 耗时)+
/// 可折叠的 stdout / stderr 输出(等宽字体)。失败时提供「让 AI 修复」——
/// 把代码 + 报错拼成追问预填进输入框(复用 QuoteReplyCenter 管线),不自动发送。
struct CodeRunResultPanel: View {
    let controller: CodeRunController
    /// 归一后的语言标识(python / javascript),拼修复追问的围栏标签用。
    let language: String
    let code: String

    /// 输出展示上限(字符)。服务层已截到 20KB,这里再为内嵌区收紧,
    /// 避免超长输出把聊天列表撑爆(iOS 上尤其影响滚动/键盘布局)。
    private static let displayCharLimit = 4000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            if !controller.collapsed, controller.phase == .finished {
                outputBody
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: 状态行

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if controller.phase == .running {
                Button("停止") { controller.cancel() }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            if didFail {
                fixButton
            }
            if controller.phase == .finished {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { controller.collapsed.toggle() }
                } label: {
                    Image(systemName: controller.collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                }
                .buttonStyle(.plain)
                .help(controller.collapsed ? "展开输出" : "折叠输出")
                .accessibilityLabel(controller.collapsed ? "展开输出" : "折叠输出")
            }
            Button {
                controller.clear()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(3)
            }
            .buttonStyle(.plain)
            .help("关闭结果")
            .accessibilityLabel("关闭结果")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch controller.phase {
        case .running:
            ProgressView().controlSize(.small)
        case .finished:
            if didFail {
                Image(systemName: result?.timedOut == true ? "clock.badge.exclamationmark" : "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }
        case .idle:
            EmptyView()
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .running:
            return "运行中…"
        case .finished:
            guard let r = result else { return "" }
            if r.failureReason != nil { return "无法运行" }
            if r.timedOut { return "运行超时(\(Int(CodeSandboxService.timeoutSeconds))s,已强制终止)" }
            let elapsed = formatDuration(r.durationMS)
            return r.exitCode == 0 ? "运行成功 · \(elapsed)" : "运行失败(退出码 \(r.exitCode))· \(elapsed)"
        case .idle:
            return ""
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000)
    }

    private var result: CodeRunResult? { controller.result }

    private var didFail: Bool {
        guard controller.phase == .finished, let r = result else { return false }
        return r.exitCode != 0 || r.timedOut || r.failureReason != nil
    }

    // MARK: 输出正文

    @ViewBuilder
    private var outputBody: some View {
        if let r = result {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                if let reason = r.failureReason {
                    outputText(reason, color: .orange)
                } else {
                    if !r.stdout.isEmpty {
                        outputText(displayClipped(r.stdout), color: .primary)
                    }
                    if !r.stderr.isEmpty {
                        outputText(displayClipped(r.stderr), color: .orange)
                    }
                    if r.stdout.isEmpty && r.stderr.isEmpty {
                        Text("(无输出)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private func outputText(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 内嵌区展示截断(完整输出仍在「让 AI 修复」/服务层 20KB 截断范围内)。
    private func displayClipped(_ s: String) -> String {
        guard s.count > Self.displayCharLimit else { return s }
        return String(s.prefix(Self.displayCharLimit)) + "\n…(输出过长,内嵌区已截断)"
    }

    // MARK: 让 AI 修复

    private var fixButton: some View {
        Button {
            QuoteReplyCenter.shared.prefill(fixPrompt)
        } label: {
            Label("让 AI 修复", systemImage: "wand.and.stars")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help("把代码和报错拼成追问预填到输入框")
        .accessibilityLabel("让 AI 修复")
    }

    /// 代码 + 报错拼成的修复追问(预填,不自动发送)。
    private var fixPrompt: String {
        var error = ""
        if let r = result {
            if let reason = r.failureReason {
                error = reason
            } else {
                var parts: [String] = []
                if r.timedOut { parts.append("执行超时(\(Int(CodeSandboxService.timeoutSeconds))s)被强制终止") }
                if !r.stderr.isEmpty { parts.append(r.stderr) }
                if parts.isEmpty { parts.append("退出码 \(r.exitCode),无错误输出") }
                error = parts.joined(separator: "\n")
            }
        }
        return """
        以下\(language == "python" ? "Python" : "JavaScript")代码运行报错,请帮我修复并给出修正后的完整代码:

        ```\(language)
        \(code)
        ```

        报错输出:
        ```
        \(error)
        ```
        """
    }
}
