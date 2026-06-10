import AppIntents
import Foundation

/// 翻译目标语言(快捷指令参数)。`auto` = 沿用 Translate 模式的中英智能互译。
enum TranslateLanguageOption: String, AppEnum {
    case auto
    case english
    case japanese
    case french
    case german
    case korean

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "目标语言" }
    static var caseDisplayRepresentations: [TranslateLanguageOption: DisplayRepresentation] {
        [
            .auto:     "自动(中英互译)",
            .english:  "英文",
            .japanese: "日文",
            .french:   "法文",
            .german:   "德文",
            .korean:   "韩文"
        ]
    }

    /// 喂给 `PromptBuilders.buildTranslateInstruction` 的目标语言;nil = 中英智能互译。
    var targetLanguage: String? {
        switch self {
        case .auto:     return nil
        case .english:  return "English"
        case .japanese: return "日本語"
        case .french:   return "Français"
        case .german:   return "Deutsch"
        case .korean:   return "한국어"
        }
    }
}

/// 「用 Kown 翻译」:复用 Translate 模式的提示词,后台直调模型,
/// 直接返回译文字符串,可在快捷指令里继续串联(如「拷贝到剪贴板」「朗读」)。
struct TranslateTextIntent: AppIntent {
    static var title: LocalizedStringResource { "用 Kown 翻译文本" }
    static var description: IntentDescription {
        IntentDescription("用已配置的模型把文本翻译成目标语言,直接返回译文,可在快捷指令中串联使用。")
    }

    @Parameter(title: "文本")
    var text: String

    @Parameter(title: "目标语言", default: .auto)
    var language: TranslateLanguageOption

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$text) 翻译成 \(\.$language)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KownIntentError.emptyInput("没有要翻译的文本,请先传入文字内容。")
        }
        // 太长截断,避免单次快捷指令打爆上下文。
        let maxChars = 12000
        let source = trimmed.count > maxChars
            ? String(trimmed.prefix(maxChars)) + "…(已截断)"
            : trimmed

        // 复用 Translate 模式的系统提示词(纯翻译,不润色)。
        let system = PromptBuilders.buildTranslateInstruction(
            targetLanguage: language.targetLanguage,
            rewrite: false
        )
        let (cfg, apiKey) = try await IntentLLMRunner.resolveProvider()
        let translated = try await IntentLLMRunner.complete(
            prompt: source, system: system, config: cfg, apiKey: apiKey, maxTokens: 4096
        )
        return .result(value: translated, dialog: IntentDialog("\(translated)"))
    }
}
