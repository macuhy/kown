import Foundation

/// 把会议/录音的转写文字交给 LLM,提炼成结构化纪要(摘要 / 关键决议 / 行动项)。
///
/// 走 `StructuredOutput` 的「prompt 指令 + JSON 解析」套路(全 provider 通用,不依赖各家 response_format),
/// 调用方式参照 `ConversationSummarizer` / `MemoryExtractor`:选 provider → 取 key → `client.stream`。
/// 选不到 provider / 失败时抛错,由 UI 转成可读提示。
enum MeetingNotesSummarizer {

    enum SummarizeError: LocalizedError {
        case noProvider
        case emptyTranscript
        case parseFailed(String)
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .noProvider:       return "没有可用的模型,请先在设置里配置并启用一个云端模型(CLI 模型不支持)。"
            case .emptyTranscript:  return "转写内容为空,无法生成纪要。"
            case .parseFailed(let m): return "纪要解析失败:\(m)"
            case .underlying(let m): return m
            }
        }
    }

    /// 纪要用的 JSON Schema(给模型看的结构说明)。
    static let schema = """
    {
      "summary": "string — 整场会议的摘要,3-6 句话,中文",
      "decisions": ["string — 关键决议,逐条列出;没有就给空数组"],
      "action_items": [
        {
          "task": "string — 要做的事",
          "owner": "string — 负责人姓名;没提到就给空字符串",
          "due": "string — 截止日期(尽量给 YYYY-MM-DD;只有相对时间如「下周五」也照实写;没有就给空字符串)"
        }
      ]
    }
    """

    /// 跑一次提炼。`provider` 由调用方挑好(chair > 第一家 enabled 非 CLI)。
    @MainActor
    static func summarize(
        transcript: String,
        provider: ProviderConfig
    ) async throws -> MeetingNotes {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummarizeError.emptyTranscript }
        guard !provider.kind.isCLI else { throw SummarizeError.noProvider }

        let userPrompt = """
        下面是一段会议/通话的语音转写文字(可能有识别错误、缺标点、口语化)。
        请理解其意图,提炼成会议纪要。要求:
        - summary:整场会议在讲什么、得出什么结论。
        - decisions:明确拍板的决定 / 共识,逐条;没有就空数组。
        - action_items:接下来要做的事;尽量识别负责人(owner)和截止时间(due)。
          若转写里没提负责人或时间,对应字段给空字符串,不要编造。
        - 全部用中文。

        【转写文字】
        \(snippet(trimmed, max: 12000))
        """
        let prompt = StructuredOutput.buildStructuredPrompt(userPrompt: userPrompt, schema: schema)

        let key = try KeychainStore.load(id: provider.id)
        let client = ProviderRegistry.client(for: provider.kind)
        let options = ChatOptions(
            systemPrompt: "你是一个会议纪要助手。只输出一个严格合法的 JSON 对象,不要任何解释或 markdown 围栏。",
            temperature: 0.2,
            maxTokens: 1500
        )

        var collected = ""
        do {
            for try await chunk in client.stream(
                prompt: prompt, options: options, config: provider, apiKey: key
            ) {
                if case .text(let t) = chunk { collected += t }
                if collected.count >= 8000 { break }
            }
        } catch {
            throw SummarizeError.underlying(error.localizedDescription)
        }

        guard let notes = parse(collected) else {
            throw SummarizeError.parseFailed("模型没有返回可解析的 JSON")
        }
        return notes
    }

    // MARK: - 解析

    /// 从模型回答里抽 JSON 并映射成 `MeetingNotes`。失败返回 nil。
    static func parse(_ raw: String) -> MeetingNotes? {
        guard let json = StructuredOutput.extractJSON(from: raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let summary = (obj["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let decisions: [String] = (obj["decisions"] as? [Any] ?? []).compactMap {
            ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        let items: [MeetingNotes.ActionItem] = (obj["action_items"] as? [Any] ?? []).compactMap { el in
            guard let d = el as? [String: Any] else { return nil }
            let task = (d["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !task.isEmpty else { return nil }
            let owner = nonEmpty(d["owner"] as? String)
            let dueText = nonEmpty(d["due"] as? String)
            return MeetingNotes.ActionItem(
                task: task,
                owner: owner,
                dueText: dueText,
                dueDate: dueText.flatMap { parseDueDate($0) }
            )
        }

        let notes = MeetingNotes(summary: summary, decisions: decisions, actionItems: items)
        return notes.isEmpty ? nil : notes
    }

    private static func nonEmpty(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// 尽量把模型给的 due 文本解析成 `Date`。只认明确的绝对日期(YYYY-MM-DD / YYYY/MM/DD,
    /// 可带 HH:mm),解析不出就返回 nil —— 相对时间(「下周五」)留给用户在 UI 里手动挑。
    static func parseDueDate(_ text: String) -> Date? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let formats = [
            "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm", "yyyy/MM/dd",
            "yyyy年MM月dd日 HH:mm", "yyyy年MM月dd日"
        ]
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        for f in formats {
            fmt.dateFormat = f
            if let d = fmt.date(from: t) { return d }
        }
        return nil
    }

    private static func snippet(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max)) + "…"
    }
}
