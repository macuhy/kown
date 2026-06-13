import Foundation

/// 语音随手记自动归档(跨平台)。
///
/// 把一段语音便签的转写文字交给 LLM,自动**起一个短标题 + 按主题/项目打标签**,
/// 便于之后归档进知识库并被语义召回。走 `StructuredOutput` 的「prompt 指令 + JSON 解析」套路
/// (全 provider 通用,不依赖各家 response_format),与 `MeetingNotesSummarizer` 同一调用范式。
///
/// 录音本身复用 `SpeechRecognizer.shared`(由 UI 驱动);本服务只负责「转写 → 打标」这一步,
/// 归档进 `KnowledgeFolder` 由 `AppViewModel+VoiceJournal` 完成。
enum VoiceJournalService {

    /// 自动打标结果(纯值类型,跨平台)。
    struct Tagging: Sendable, Equatable {
        /// 给这条随手记起的短标题(用作知识库文档名)。
        var title: String
        /// 主题 / 项目标签(已去重、去空)。
        var tags: [String]
        /// 一句话摘要(可空)。
        var summary: String?
    }

    enum TagError: LocalizedError {
        case noProvider
        case empty
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .noProvider: return "没有可用的模型,请先在设置里启用一个云端模型(CLI 模型不支持)。"
            case .empty:      return "随手记内容为空。"
            case .underlying(let m): return m
            }
        }
    }

    /// 打标用的 JSON Schema(给模型看的结构说明)。
    static let schema = """
    {
      "title": "string — 给这条随手记起的简短标题(不超过 20 字,中文)",
      "tags": ["string — 主题或项目标签,2-5 个,简短名词,如「产品」「健身」「XX 项目」"],
      "summary": "string — 一句话概括(可空,中文)"
    }
    """

    /// 跑一次自动打标。`provider` 由调用方挑好(chair > 第一家 enabled 非 CLI)。
    /// 失败 / 没 provider 时抛错;UI 可回退到「无标签直接存」。
    @MainActor
    static func tag(transcript: String, provider: ProviderConfig) async throws -> Tagging {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TagError.empty }
        guard !provider.kind.isCLI else { throw TagError.noProvider }

        let userPrompt = """
        下面是一段语音随手记的转写文字(口语、可能缺标点、有识别错误)。
        请理解其意图,为它起一个简短标题,并按主题/项目打 2-5 个标签,再给一句话摘要。
        - title:不超过 20 字,能一眼看出讲的是什么。
        - tags:简短名词,主题或项目维度(如「产品」「读书」「XX 项目」「日常」),不要句子。
        - summary:一句话概括;内容太短可留空。
        - 全部用中文。

        【随手记】
        \(snippet(trimmed, max: 4000))
        """
        let prompt = StructuredOutput.buildStructuredPrompt(userPrompt: userPrompt, schema: schema)

        let key = (try? KeychainStore.load(id: provider.id)) ?? ""
        let client = ProviderRegistry.client(for: provider.kind)
        let options = ChatOptions(
            systemPrompt: "你是一个随手记整理助手。只输出一个严格合法的 JSON 对象,不要任何解释或 markdown 围栏。",
            temperature: 0.3,
            maxTokens: 400
        )

        var collected = ""
        do {
            for try await chunk in client.stream(
                prompt: prompt, options: options, config: provider, apiKey: key
            ) {
                if case .text(let t) = chunk { collected += t }
                if collected.count >= 2000 { break }
            }
        } catch {
            throw TagError.underlying(error.localizedDescription)
        }

        guard let tagging = parse(collected) else {
            throw TagError.underlying("模型没有返回可解析的 JSON")
        }
        return tagging
    }

    /// 从模型回答里抽 JSON 并映射成 `Tagging`。失败返回 nil。
    static func parse(_ raw: String) -> Tagging? {
        guard let json = StructuredOutput.extractJSON(from: raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tags: [String] = (obj["tags"] as? [Any] ?? []).compactMap {
            ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let dedupTags = tags.filter { seen.insert($0).inserted }
        let summaryRaw = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (summaryRaw?.isEmpty == false) ? summaryRaw : nil
        // 标题兜底:模型没给标题时用摘要 / 正文首句。
        let finalTitle = title.isEmpty ? (summary ?? "") : title
        return Tagging(title: finalTitle, tags: dedupTags, summary: summary)
    }

    /// 把转写 + 标签拼成入库正文(标签写进正文头,RAG 检索时能命中标签词)。
    static func archiveBody(transcript: String, tagging: Tagging, date: Date) -> String {
        var head: [String] = []
        let stamp = dateLabel(date)
        head.append("语音随手记 · \(stamp)")
        if !tagging.tags.isEmpty {
            head.append("标签:" + tagging.tags.map { "#\($0)" }.joined(separator: " "))
        }
        if let s = tagging.summary, !s.isEmpty {
            head.append("摘要:\(s)")
        }
        return head.joined(separator: "\n") + "\n\n" + transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 给文档起名:有标题用标题,否则用「随手记 + 日期」。
    static func docName(tagging: Tagging, date: Date) -> String {
        let t = tagging.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t.count > 40 ? String(t.prefix(40)) : t }
        return "随手记 · \(dateLabel(date))"
    }

    private static func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func snippet(_ text: String, max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max)) + "…"
    }
}
