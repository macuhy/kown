#if os(macOS)
import SwiftUI
import AppKit

/// 菜单栏剪贴板动作(macOS 专用)。
///
/// 从菜单栏面板对「当前剪贴板里的文字」一键执行「翻译 / 总结 / 解释」,
/// 用一个小模型(优先 chair,其次第一个 enabled 的非 CLI provider)流式生成,
/// 结果就地在菜单栏面板里显示,可一键「复制结果」。
///
/// 全部逻辑 `#if os(macOS)`,不引入新依赖(沿用 `ProviderRegistry` + `ChatOptions`),
/// 也不触碰 iOS。
enum ClipboardAction: String, CaseIterable, Identifiable {
    case translate
    case summarize
    case explain

    var id: String { rawValue }

    /// 菜单/按钮上的中文标题。
    var title: String {
        switch self {
        case .translate: return "翻译剪贴板"
        case .summarize: return "总结剪贴板"
        case .explain:   return "解释剪贴板"
        }
    }

    var systemImage: String {
        switch self {
        case .translate: return "character.book.closed"
        case .summarize: return "text.append"
        case .explain:   return "lightbulb"
        }
    }

    /// 拼给小模型的指令 —— 把剪贴板文字作为待处理内容附在后面。
    func prompt(for text: String) -> String {
        switch self {
        case .translate:
            return """
            你是专业翻译。判断下面文本的语言:中文则翻成自然流畅的英文,其它语言一律翻成简体中文。
            只输出译文,不要解释、不要加引号或前后缀。

            待翻译文本:
            \(text)
            """
        case .summarize:
            return """
            用简体中文,把下面的文本总结成几条要点(必要时一句话概述),抓住核心信息。
            只输出总结,不要复述原文、不要加前后缀。

            待总结文本:
            \(text)
            """
        case .explain:
            return """
            用简体中文,通俗清楚地解释下面这段文本的含义;如有术语、缩写或难懂概念,一并说明。
            直接给解释,不要加前后缀。

            待解释文本:
            \(text)
            """
        }
    }
}

/// 菜单栏剪贴板动作的运行状态 —— 由 `QuickAskView` 持有并展示。
@MainActor
@Observable
final class ClipboardActionRunner {
    /// 正在运行的动作(nil = 空闲)。
    private(set) var runningAction: ClipboardAction?
    /// 流式累积的结果文本。
    private(set) var result: String = ""
    /// 出错文案(nil = 无错误)。
    private(set) var errorText: String?
    /// 本次动作使用的剪贴板原文(用于面板上回显「正在处理…」)。
    private(set) var sourcePreview: String = ""
    /// 用到的 provider 显示名(展示「由 XXX 生成」)。
    private(set) var providerName: String = ""

    var isRunning: Bool { runningAction != nil }
    var hasOutput: Bool { !result.isEmpty || errorText != nil }

    private var task: Task<Void, Never>?

    /// 选「小模型」:优先 chair,其次第一个 enabled 的非 CLI provider。
    /// CLI provider 不走这里(菜单栏轻动作要直接拿文本结果)。
    private func smallModel(from viewModel: AppViewModel) -> ProviderConfig? {
        if let chair = viewModel.chairProvider, !chair.kind.isCLI { return chair }
        return viewModel.providers.first { $0.enabled && !$0.kind.isCLI }
    }

    /// 执行一个剪贴板动作。读 `NSPasteboard.general`,空则报错。
    func run(_ action: ClipboardAction, viewModel: AppViewModel) {
        task?.cancel()

        let clip = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clip.isEmpty else {
            runningAction = nil
            result = ""
            providerName = ""
            sourcePreview = ""
            errorText = "剪贴板里没有文字。先复制一段文本再试。"
            return
        }

        guard let cfg = smallModel(from: viewModel) else {
            runningAction = nil
            result = ""
            providerName = ""
            sourcePreview = String(clip.prefix(120))
            errorText = "没有可用的模型,先到设置里启用一个(CLI 除外)。"
            return
        }

        // 太长截断,避免菜单栏轻动作打爆上下文。
        let maxChars = 8000
        let text = clip.count > maxChars ? String(clip.prefix(maxChars)) + "…(已截断)" : clip

        runningAction = action
        result = ""
        errorText = nil
        sourcePreview = String(clip.prefix(120))
        providerName = cfg.displayName

        let prompt = action.prompt(for: text)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let apiKey = (try? KeychainStore.load(id: cfg.id)) ?? ""
                let client = ProviderRegistry.client(for: cfg.kind)
                let options = ChatOptions(systemPrompt: nil, temperature: 0.3, maxTokens: 1024)
                var collected = ""
                for try await chunk in client.stream(prompt: prompt, options: options,
                                                     config: cfg, apiKey: apiKey) {
                    if Task.isCancelled { break }
                    if case .text(let t) = chunk {
                        collected += t
                        self.result = collected
                    }
                }
                if Task.isCancelled, self.errorText == nil, collected.isEmpty {
                    self.errorText = "已取消"
                }
            } catch {
                if !Task.isCancelled {
                    self.errorText = error.localizedDescription
                }
            }
            self.runningAction = nil
        }
    }

    /// 复制当前结果到剪贴板。
    func copyResult() {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Platform.copyText(trimmed)
    }

    /// 清空面板(回到只剩三个动作按钮的状态)。
    func clear() {
        task?.cancel()
        task = nil
        runningAction = nil
        result = ""
        errorText = nil
        sourcePreview = ""
        providerName = ""
    }
}

/// 菜单栏面板里的「剪贴板动作」区块:三个按钮 + 结果展示 + 复制。
struct ClipboardActionsSection: View {
    @Bindable var viewModel: AppViewModel
    @Bindable var runner: ClipboardActionRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.tint)
                Text("剪贴板动作")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if runner.hasOutput || runner.isRunning {
                    Button {
                        runner.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空")
                }
            }

            HStack(spacing: 6) {
                ForEach(ClipboardAction.allCases) { action in
                    Button {
                        runner.run(action, viewModel: viewModel)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(runner.isRunning)
                }
            }

            if runner.isRunning || runner.hasOutput {
                resultArea
            } else {
                Text("对剪贴板里的文字一键翻译 / 总结 / 解释。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !runner.sourcePreview.isEmpty {
                Text("原文:\(runner.sourcePreview)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let err = runner.errorText {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                ScrollView {
                    Text(runner.result.isEmpty && runner.isRunning ? "生成中…" : runner.result)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .foregroundStyle(runner.result.isEmpty ? .secondary : .primary)
                }
                .frame(maxHeight: 180)

                HStack {
                    if !runner.providerName.isEmpty {
                        Text("由 \(runner.providerName) 生成")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        runner.copyResult()
                    } label: {
                        Label("复制结果", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(runner.isRunning || runner.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(8)
        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
#endif
