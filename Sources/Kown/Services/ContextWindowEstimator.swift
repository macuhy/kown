import Foundation

/// 上下文窗口用量估算:
/// - token 数用启发式估(CJK 按字符 ×0.6,其余按字符 /4),只求量级正确,不追求精确;
/// - 各模型上下文窗口大小走内置保守表(按模型名前缀匹配),查不到一律按 128k 算;
/// - 多模型(Council / Compare 等)按所选模型里**窗口最小**的那个算 — 它先爆。
/// 纯函数 + 静态表,无状态,供输入栏的用量条与上下文菜单消费。
enum ContextWindowEstimator {

    // MARK: - token 启发式估算

    /// 估算一段文本的 token 数:CJK(中日韩 + 全角符号)按字符 ×0.6,其余字符按 /4。
    /// 与各家 tokenizer 的真实切分有出入,但量级足够支撑「百分比 + 变色」的提示用途。
    static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF,       // CJK 部首 / 假名 / 统一表意文字
                 0xF900...0xFAFF,       // CJK 兼容表意文字
                 0xFF00...0xFFEF,       // 全角符号
                 0x20000...0x3FFFF:     // CJK 扩展 B+
                cjk += 1
            default:
                other += 1
            }
        }
        return Int((Double(cjk) * 0.6 + Double(other) / 4.0).rounded(.up))
    }

    // MARK: - 各模型上下文窗口表

    /// 未知模型的保守默认窗口。
    static let defaultContextWindow = 128_000

    /// 模型名前缀 → 上下文窗口(token)。取**保守**公开值,宁可低估让提示早一点变色;
    /// 同一模型命中多个前缀时取最长前缀(更具体的优先)。
    static let contextWindowTable: [String: Int] = [
        // Anthropic(Claude 系列)
        "claude-": 200_000,
        // OpenAI
        "gpt-5": 256_000,
        "gpt-4o": 128_000,
        "o3": 200_000,
        // Google(Gemini 全系长上下文)
        "gemini-": 1_000_000,
        // DeepSeek
        "deepseek-v4": 128_000,
        "deepseek-chat": 64_000,
        "deepseek-reasoner": 64_000,
        // Moonshot Kimi
        "kimi-k2": 256_000,
        "moonshot-v1-128k": 128_000,
        "moonshot-v1-32k": 32_000,
        "moonshot-v1-8k": 8_000,
        // 智谱 GLM
        "glm-5": 200_000,
        "glm-": 128_000,
        // 阿里通义 Qwen
        "qwen": 128_000,
    ]

    /// 查某模型的上下文窗口:按前缀匹配(最长前缀优先),查不到回退 `defaultContextWindow`。
    static func contextWindow(forModel model: String) -> Int {
        var best: (prefixLength: Int, window: Int)?
        for (prefix, window) in contextWindowTable where model.hasPrefix(prefix) {
            if best == nil || prefix.count > best!.prefixLength {
                best = (prefix.count, window)
            }
        }
        return best?.window ?? defaultContextWindow
    }

    // MARK: - 用量

    /// 一次「下次发送会占多少上下文」的估算结果。
    struct Usage: Hashable, Sendable {
        /// 估算的发送 token 总量(系统提示 + 摘要 + 最近轮原文 + 当前输入)。
        let estimatedTokens: Int
        /// 参与计算的窗口大小(多模型时取最小)。
        let windowTokens: Int
        /// 窗口最小的那个模型名(多模型时按它算,给用户解释「为什么是这个分母」)。
        let limitingModel: String

        /// 0...1 的占比(超过 1 夹紧,UI 进度条用)。
        var fraction: Double {
            min(1.0, Double(estimatedTokens) / Double(max(1, windowTokens)))
        }
        /// 百分比整数(不夹紧,>100 时如实显示「已超出」)。
        var percent: Int {
            Int((Double(estimatedTokens) / Double(max(1, windowTokens)) * 100).rounded())
        }
    }

    /// 估算下次发送的上下文用量。
    /// - Parameters:
    ///   - systemPrompt: 生效的系统提示(会话级覆盖或全局)。
    ///   - contextSummary: 将注入的摘要(滚动/压缩,经截断闸过滤后的结果)。
    ///   - priorTurns: 将以 user/assistant 原文重放的最近轮。
    ///   - draftPrompt: 输入框里的当前草稿。
    ///   - models: 本次发送涉及的模型名(多模型按窗口最小者算)。
    static func usage(systemPrompt: String,
                      contextSummary: String?,
                      priorTurns: [PriorTurn],
                      draftPrompt: String,
                      models: [String]) -> Usage? {
        guard !models.isEmpty else { return nil }
        var tokens = estimateTokens(systemPrompt) + estimateTokens(draftPrompt)
        if let s = contextSummary { tokens += estimateTokens(s) }
        for turn in priorTurns {
            tokens += estimateTokens(turn.userText) + estimateTokens(turn.assistantText)
        }
        // 多模型:按窗口最小的模型算(它最先被撑爆)。
        var limiting = models[0]
        var window = contextWindow(forModel: limiting)
        for m in models.dropFirst() {
            let w = contextWindow(forModel: m)
            if w < window { window = w; limiting = m }
        }
        return Usage(estimatedTokens: tokens, windowTokens: window, limitingModel: limiting)
    }
}
