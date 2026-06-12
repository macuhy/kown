import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple FoundationModels 端侧模型 client — 免 API Key、零成本、全离线。
///
/// 仅 macOS 26 / iOS 26 且开启 Apple Intelligence 的设备可用;其余情况
/// (老系统 / 设备不支持 / 未开启 / 模型未下载)统一抛出清晰的中文错误。
/// 端侧模型上下文窗口约 4096 token,历史过长时只携带最近若干轮并在
/// instructions 里注明,尽量避免直接撞 `exceededContextWindowSize`。
/// 不支持工具调用与图片附件(上层带了会以 toolEvent 提示后忽略)。
struct AppleFMClient: LLMClient {

    func stream(prompt: String,
                options: ChatOptions,
                config: ProviderConfig,
                apiKey: String) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return modernStream(prompt: prompt, options: options, config: config)
        }
        #endif
        // 编译环境没有 FoundationModels,或运行系统低于 26 — 给出统一中文提示。
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: AppleFMError.systemTooOld)
        }
    }

    /// 当前设备 Apple 本地模型可用状态的中文说明;nil = 可用。
    /// 设置页用它在卡片里直接展示「为什么不可用」。
    static var availabilityNotice: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                return Self.mapUnavailable(reason).errorDescription
            }
        }
        #endif
        return AppleFMError.systemTooOld.errorDescription
    }
}

/// Apple 本地模型的错误 — 全部给中文文案,UI 直接展示 `localizedDescription`。
enum AppleFMError: Error, LocalizedError {
    /// 系统低于 macOS 26 / iOS 26(或编译环境没有 FoundationModels)。
    case systemTooOld
    /// 设备硬件不支持 Apple Intelligence。
    case deviceNotEligible
    /// 系统支持但用户没开 Apple Intelligence。
    case intelligenceNotEnabled
    /// 模型资产还没下载完。
    case modelNotReady
    /// 其他不可用原因(系统新加的 case)。
    case unavailableUnknown
    /// 超出端侧模型 4096 token 上下文窗口。
    case contextExceeded
    /// 触发系统安全护栏,拒绝生成。
    case guardrailViolation
    /// 其他生成错误(带原始信息)。
    case generation(String)

    var errorDescription: String? {
        switch self {
        case .systemTooOld:
            return "Apple 本地模型需要 macOS 26 / iOS 26 及以上系统,且开启 Apple Intelligence"
        case .deviceNotEligible:
            return "此设备不支持 Apple Intelligence,无法使用 Apple 本地模型"
        case .intelligenceNotEnabled:
            return "请先在「系统设置 → Apple Intelligence 与 Siri」中开启 Apple Intelligence"
        case .modelNotReady:
            return "Apple 本地模型尚未就绪(系统正在后台下载),请保持联网并稍后再试"
        case .unavailableUnknown:
            return "Apple 本地模型当前不可用,请稍后再试"
        case .contextExceeded:
            return "对话内容超出 Apple 本地模型的上下文窗口(约 4096 token)。请新建对话,或缩短本次输入后重试"
        case .guardrailViolation:
            return "内容触发了 Apple 本地模型的安全限制,换个问法试试"
        case .generation(let message):
            return "Apple 本地模型生成失败: \(message)"
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
extension AppleFMClient {

    /// 端侧上下文窗口 4096 token。中文 1 字往往不止 1 token,这里按字符做
    /// 保守预算:全部入参(instructions + 历史 + 当前问题)控制在 ~4500 字以内,
    /// 留出余量给模型输出。超了就从最旧的历史开始丢。
    private static let totalBudgetChars = 4_500
    /// 单轮历史里 user / assistant 各自的截断上限 — 防止一条长回答吃光预算。
    private static let perUserChars = 500
    private static let perAssistantChars = 800
    /// instructions(system + 摘要)截断上限。
    private static let instructionsBudgetChars = 1_500

    fileprivate func modernStream(prompt: String,
                                  options: ChatOptions,
                                  config: ProviderConfig) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1) 可用性:设备不支持 / 未开启 / 模型没下完,各自给中文提示。
                    let model = SystemLanguageModel.default
                    switch model.availability {
                    case .available:
                        break
                    case .unavailable(let reason):
                        throw Self.mapUnavailable(reason)
                    }

                    // 端侧模型不支持工具调用与图片 — 上层带了就提示一句,然后忽略。
                    if options.toolContext != nil, !options.tools.isEmpty {
                        continuation.yield(.toolEvent("⚠ Apple 本地模型不支持工具调用,本次跳过"))
                    }
                    if !options.images.isEmpty {
                        continuation.yield(.toolEvent("⚠ Apple 本地模型不支持图片附件,已忽略"))
                    }

                    // 2) 拼 instructions + 出站 prompt(历史按预算裁剪)。
                    let payload = Self.buildPayload(prompt: prompt, options: options)
                    let session: LanguageModelSession
                    if let instructions = payload.instructions {
                        session = LanguageModelSession(model: model, instructions: instructions)
                    } else {
                        session = LanguageModelSession(model: model)
                    }

                    var genOptions = GenerationOptions(temperature: options.temperature ?? config.temperature)
                    if let maxTokens = options.maxTokens ?? config.maxTokens {
                        genOptions.maximumResponseTokens = maxTokens
                    }

                    // 3) 流式:snapshot 是「到目前为止的全文」,转成增量再发。
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: payload.outbound, options: genOptions) {
                        let full = snapshot.content
                        if full.count > emitted.count {
                            continuation.yield(.text(String(full.dropFirst(emitted.count))))
                            emitted = full
                        }
                        try Task.checkCancellation()
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: Self.mapGeneration(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 不可用原因 → 中文错误。
    static func mapUnavailable(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> AppleFMError {
        switch reason {
        case .deviceNotEligible:            return .deviceNotEligible
        case .appleIntelligenceNotEnabled:  return .intelligenceNotEnabled
        case .modelNotReady:                return .modelNotReady
        @unknown default:                   return .unavailableUnknown
        }
    }

    /// 生成错误 → 中文错误(重点捕获超上下文)。
    static func mapGeneration(_ error: LanguageModelSession.GenerationError) -> AppleFMError {
        switch error {
        case .exceededContextWindowSize:    return .contextExceeded
        case .guardrailViolation:           return .guardrailViolation
        case .assetsUnavailable:            return .modelNotReady
        default:                            return .generation(error.localizedDescription)
        }
    }

    /// 把 system / 摘要 / 多轮历史压进 4096 token 预算:
    /// - 历史从最近往前收,装不下就停(最旧的先丢),单轮文本也截断;
    /// - 有裁剪时在 instructions 末尾注明,提示模型「更早内容可能缺失」;
    /// - 当前问题原样保留(单条就超窗的极端情况交给 contextExceeded 错误兜底)。
    static func buildPayload(prompt: String, options: ChatOptions) -> (instructions: String?, outbound: String) {
        // 历史:从最近一轮往前装,超预算即止。
        var kept: [PriorTurn] = []
        var used = prompt.count
        var truncatedText = false
        for turn in options.priorTurns.reversed() {
            let user = String(turn.userText.prefix(perUserChars))
            let assistant = String(turn.assistantText.prefix(perAssistantChars))
            if user.count < turn.userText.count || assistant.count < turn.assistantText.count {
                truncatedText = true
            }
            if used + user.count + assistant.count > totalBudgetChars { break }
            kept.insert(PriorTurn(userText: user, assistantText: assistant), at: 0)
            used += user.count + assistant.count
        }
        let dropped = options.priorTurns.count - kept.count

        var parts: [String] = []
        if let system = combineSystem(userSystem: options.systemPrompt,
                                      summary: options.contextSummary,
                                      agentInstruction: options.agentInstruction) {
            parts.append(String(system.prefix(instructionsBudgetChars)))
        }
        if dropped > 0 || truncatedText {
            let note = dropped > 0
                ? "注意:对话历史较长,受端侧模型上下文限制,仅保留了最近 \(kept.count) 轮,更早的内容可能缺失。"
                : "注意:部分较长的历史消息已被截断,细节可能缺失。"
            parts.append(note)
        }
        let instructions = parts.isEmpty ? nil : parts.joined(separator: "\n\n")

        // 历史以平铺文本注入(摘要已并进 instructions,这里不重复)。
        let outbound = kept.isEmpty
            ? prompt
            : flattenPromptForCLI(prompt: prompt, summary: nil, priorTurns: kept)
        return (instructions, outbound)
    }
}
#endif
