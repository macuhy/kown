import Foundation
import Observation

/// 单步执行的运行时状态(供 UI 观察)。
enum ChainStepPhase: Sendable, Equatable {
    case pending          // 还没轮到
    case running          // 正在流式
    case finished         // 成功完成
    case failed(String)   // 失败(含错误信息)
    case skipped          // 因前序失败/取消被跳过
}

@Observable
@MainActor
final class ChainStepRun: Identifiable {
    let id: UUID
    let title: String
    /// 解析出的实际执行模型描述(给 UI 标注「用了哪个模型」)。
    var modelLabel: String
    /// 实际喂给模型的完整 prompt(占位符已替换),便于排查。
    var resolvedPrompt: String = ""
    /// 流式累计的输出文本。
    var output: String = ""
    var phase: ChainStepPhase = .pending

    init(id: UUID, title: String, modelLabel: String) {
        self.id = id
        self.title = title
        self.modelLabel = modelLabel
    }
}

/// 链式工作流执行器:把一条 `PromptChain` 的步骤**逐次**跑完,
/// `{{prev}}`(上一步输出)/ `{{input}}`(最初输入)做文本替换,
/// 每步的输出/状态/错误都暴露给 UI;支持取消;每步用量记进 `UsageStore`。
@Observable
@MainActor
final class ChainRunner {
    /// 当前这次运行的各步状态,顺序与 chain.steps 一致。
    private(set) var runs: [ChainStepRun] = []
    /// 是否正在执行。
    private(set) var isRunning = false
    /// 整次运行级别的错误(例如没有可用 provider)。
    private(set) var runError: String?

    private var task: Task<Void, Never>?

    /// 取数据用:已启用、非 CLI 的 provider(默认模型从这里挑第一家)。
    private let providers: [ProviderConfig]

    init(providers: [ProviderConfig]) {
        self.providers = providers
    }

    /// 用占位符替换:`{{input}}` → 初始输入,`{{prev}}` → 上一步输出。
    static func fill(_ template: String, input: String, prev: String) -> String {
        template
            .replacingOccurrences(of: "{{input}}", with: input)
            .replacingOccurrences(of: "{{prev}}", with: prev)
    }

    /// 把一个步骤解析成「实际用哪个 ProviderConfig」。
    /// 指定了 choice 就用对应 provider(并覆写 model);否则取第一个已启用、非 CLI 的 provider。
    private func resolveConfig(for step: ChainStep) -> ProviderConfig? {
        if let choice = step.providerModelChoice,
           var cfg = providers.first(where: { $0.id == choice.providerID }) {
            cfg.model = choice.model
            return cfg
        }
        return providers.first(where: { $0.enabled && !$0.kind.isCLI })
    }

    /// 启动一条 chain。`input` 是最初输入(注入 `{{input}}`)。
    func run(chain: PromptChain, input: String) {
        guard !isRunning else { return }
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        runError = nil

        // 预建每步状态(顺序与 chain 一致)。
        runs = chain.steps.map { step in
            let label = modelLabel(for: step)
            return ChainStepRun(id: step.id, title: step.title, modelLabel: label)
        }
        guard !chain.steps.isEmpty else {
            runError = "工作流没有任何步骤"
            return
        }

        isRunning = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var prev = ""
            var aborted = false

            for (idx, step) in chain.steps.enumerated() {
                if Task.isCancelled { aborted = true; break }
                let runState = self.runs[idx]

                guard let cfg = self.resolveConfig(for: step) else {
                    runState.phase = .failed("没有可用模型(请先在「厂商」里启用一个非 CLI 的 Provider)")
                    aborted = true
                    break
                }
                runState.modelLabel = "\(cfg.displayName) · \(cfg.model)"

                let prompt = Self.fill(step.instruction, input: trimmedInput, prev: prev)
                runState.resolvedPrompt = prompt
                runState.phase = .running
                runState.output = ""

                let result = await self.runStep(config: cfg, prompt: prompt, into: runState)
                switch result {
                case .success(let text):
                    runState.output = text
                    runState.phase = .finished
                    prev = text
                case .failure(let message):
                    runState.phase = .failed(message)
                    aborted = true
                }
                if aborted { break }
            }

            // 中断后把还没跑的步骤标记为「跳过」。
            if aborted {
                for r in self.runs where r.phase == .pending {
                    r.phase = .skipped
                }
            }

            self.isRunning = false
            self.task = nil
        }
    }

    /// 取消当前运行。正在流式的步骤会被标记为失败「已取消」。
    func cancel() {
        task?.cancel()
        task = nil
        for r in runs where r.phase == .running {
            r.phase = .failed("已取消")
        }
        for r in runs where r.phase == .pending {
            r.phase = .skipped
        }
        isRunning = false
    }

    private enum StepResult {
        case success(String)
        case failure(String)
    }

    /// 跑单个步骤的流式;边收边写 `runState.output`;末尾把 usage 记进 UsageStore。
    private func runStep(config: ProviderConfig, prompt: String, into runState: ChainStepRun) async -> StepResult {
        var collected = ""
        do {
            let apiKey = config.kind.isCLI ? "" : (try KeychainStore.load(id: config.id))
            let client = ProviderRegistry.client(for: config.kind)
            let options = ChatOptions(systemPrompt: nil,
                                      temperature: config.temperature,
                                      maxTokens: config.maxTokens)
            for try await chunk in client.stream(prompt: prompt, options: options, config: config, apiKey: apiKey) {
                if Task.isCancelled { return .failure("已取消") }
                switch chunk {
                case .text(let t):
                    collected += t
                    runState.output = collected
                case .usage(let input, let output, let cached):
                    UsageStore.shared.record(
                        providerKind: config.kind,
                        model: config.model,
                        inputTokens: input,
                        outputTokens: output,
                        cachedTokens: cached
                    )
                default:
                    break
                }
            }
            if Task.isCancelled { return .failure("已取消") }
            return .success(collected)
        } catch is CancellationError {
            return .failure("已取消")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// 给一个步骤生成「将用哪个模型」的标注(UI 预览用,运行时会再刷新成解析后的真值)。
    private func modelLabel(for step: ChainStep) -> String {
        if let choice = step.providerModelChoice,
           let cfg = providers.first(where: { $0.id == choice.providerID }) {
            return "\(cfg.displayName) · \(choice.model)"
        }
        if let def = providers.first(where: { $0.enabled && !$0.kind.isCLI }) {
            return "默认 · \(def.displayName)"
        }
        return "默认模型"
    }
}
