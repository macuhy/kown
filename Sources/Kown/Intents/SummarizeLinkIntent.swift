import AppIntents
import Foundation

/// 「让 Kown 总结链接」:Firecrawl 抓网页正文 → 模型生成结构化总结,后台运行,
/// 返回总结文本可在快捷指令里继续串联。与 app 内「抓取并总结」走同一抓取链路。
struct SummarizeLinkIntent: AppIntent {
    static var title: LocalizedStringResource { "让 Kown 总结链接" }
    static var description: IntentDescription {
        IntentDescription("用 Firecrawl 抓取网页正文,再让已配置的模型生成结构化总结。需先在设置 ▸ Web Search 配置 Firecrawl。")
    }

    @Parameter(title: "链接")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("总结网页 \(\.$url)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // 1) Firecrawl 配置检查(未启用 / 没 Key → 清晰中文报错)。
        let firecrawl = try await IntentLLMRunner.resolveFirecrawl()
        // 提前解析 provider:抓取要 10+ 秒,先把「没配模型」这类错误暴露出来。
        let (cfg, apiKey) = try await IntentLLMRunner.resolveProvider()

        // 2) 抓正文。
        let scrape: FirecrawlScrape
        do {
            scrape = try await firecrawl.scrape(url: url.absoluteString)
        } catch let e as KownIntentError {
            throw e
        } catch {
            throw KownIntentError.scrapeFailed(error.localizedDescription)
        }

        // 3) 正文截断后生成结构化总结。
        let maxChars = 24000
        var content = scrape.markdown
        if content.count > maxChars {
            content = String(content.prefix(maxChars)) + "\n\n…(网页正文过长已截断)"
        }
        let system = """
        你是网页内容总结助手。阅读抓取到的网页正文,用简体中文输出结构化总结,Markdown 格式:
        **一句话概述**:这个页面讲什么。
        **核心要点**:3-6 条 bullet,抓住主干信息。
        **关键事实 / 数据**:正文里出现的数字、日期、人名、结论等硬信息(没有就省略这一节)。
        只基于正文内容总结,不要编造;正文若被截断,按已有部分总结即可。
        """
        let prompt = """
        【网页标题】\(scrape.title)
        【网页地址】\(url.absoluteString)

        【网页正文】
        \(content)
        """
        let summary = try await IntentLLMRunner.complete(
            prompt: prompt, system: system, config: cfg, apiKey: apiKey, maxTokens: 2048
        )
        return .result(value: summary, dialog: IntentDialog("\(summary)"))
    }
}
