import AppIntents
import Foundation

// MARK: - 跨进程/跨入口通知

extension Notification.Name {
    /// 快捷指令(App Intents)在后台直接写了 `KnowledgeStore` 之后广播。
    /// app 进程若存活,`AppViewModel` 收到后重读 `knowledgeFolders`,
    /// 避免内存里的旧状态在下次 `saveKnowledge()` 时把新文档覆盖掉。
    static let kownKnowledgeDidChangeExternally = Notification.Name("kown.knowledge.didChangeExternally")
}

// MARK: - 快捷指令错误(人话中文)

/// App Intents 后台运行时的统一错误:每种失败都给用户一句能看懂、知道去哪修的话。
enum KownIntentError: Error, LocalizedError {
    /// 一个 enabled 的非 CLI provider 都没有。
    case noProvider
    /// 选中的 provider 没配 API Key。
    case missingAPIKey(providerName: String)
    /// Firecrawl(Web Search)未启用或没配 Key。
    case webSearchNotConfigured
    /// 网络 / 上游服务失败。
    case network(String)
    /// 输入为空(附具体提示)。
    case emptyInput(String)
    /// 模型返回了空结果。
    case emptyResult
    /// 网页抓取失败。
    case scrapeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProvider:
            return "没有可用的模型。请先打开 Kown ▸ 设置,启用一个已配置好的模型(CLI 类型除外)。"
        case .missingAPIKey(let name):
            return "模型「\(name)」还没配 API Key。请打开 Kown ▸ 设置,填入 Key 后再试。"
        case .webSearchNotConfigured:
            return "还没配置网页抓取。请打开 Kown ▸ 设置 ▸ Web Search,启用联网搜索并填入 Firecrawl API Key。"
        case .network(let detail):
            return "网络请求失败:\(detail)"
        case .emptyInput(let hint):
            return hint
        case .emptyResult:
            return "模型没有返回内容,请稍后重试。"
        case .scrapeFailed(let detail):
            return "网页抓取失败:\(detail)"
        }
    }
}

// MARK: - 无 UI 的 LLM 调用入口

/// App Intents 专用的轻量 LLM 入口:**不依赖 AppViewModel**,直接读落盘配置
/// (`ProviderConfigStore` / `KeychainStore` / `WebSearchConfigStore`),
/// 支持快捷指令在后台运行而不必拉起前台 UI。
/// 选模型策略与菜单栏剪贴板动作一致:优先 chair,其次第一个 enabled 的非 CLI provider。
enum IntentLLMRunner {

    /// 解析可用的 (provider, apiKey)。本地端点(Ollama / localhost)允许无 Key。
    @MainActor
    static func resolveProvider() throws -> (config: ProviderConfig, apiKey: String) {
        let providers = ProviderConfigStore.load()
        let pick = providers.first { $0.isChair && $0.enabled && !$0.kind.isCLI }
            ?? providers.first { $0.enabled && !$0.kind.isCLI }
        guard let cfg = pick else { throw KownIntentError.noProvider }
        let key = (try? KeychainStore.load(id: cfg.id)) ?? ""
        if key.isEmpty && !isKeyOptional(cfg) {
            throw KownIntentError.missingAPIKey(providerName: cfg.displayName)
        }
        return (cfg, key)
    }

    /// 本地端点(Ollama / localhost 自建)不强制要求 Key。
    private static func isKeyOptional(_ cfg: ProviderConfig) -> Bool {
        if cfg.vendor == "ollama" { return true }
        let url = cfg.baseURL.lowercased()
        return url.contains("localhost") || url.contains("127.0.0.1")
    }

    /// 读取 Firecrawl 配置(需「已启用 + 已配 Key」,与 app 内抓取链路同一判定)。
    @MainActor
    static func resolveFirecrawl() throws -> FirecrawlClient {
        let cfg = WebSearchConfigStore.load()
        guard cfg.enabled, let key = try? WebSearchKey.load(), !key.isEmpty else {
            throw KownIntentError.webSearchNotConfigured
        }
        return FirecrawlClient(baseURL: cfg.baseURL, apiKey: key)
    }

    /// 非流式拿完整文本:聚合 stream 的 `.text` 块;网络错误 / 空结果转成人话。
    static func complete(
        prompt: String,
        system: String?,
        config: ProviderConfig,
        apiKey: String,
        maxTokens: Int = 2048
    ) async throws -> String {
        let client = ProviderRegistry.client(for: config.kind)
        let options = ChatOptions(systemPrompt: system, temperature: 0.3, maxTokens: maxTokens)
        var collected = ""
        do {
            for try await chunk in client.stream(prompt: prompt, options: options,
                                                 config: config, apiKey: apiKey) {
                if case .text(let t) = chunk { collected += t }
            }
        } catch let e as KownIntentError {
            throw e
        } catch let e as URLError {
            throw KownIntentError.network(e.localizedDescription)
        } catch {
            throw KownIntentError.network(error.localizedDescription)
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KownIntentError.emptyResult }
        return trimmed
    }
}

// MARK: - macOS 端快捷指令短语

#if os(macOS)
/// macOS 端的 Siri / 快捷指令短语。每个 app target 只能有一个 `AppShortcutsProvider`:
/// iOS 端的同名 provider 在 `AskKownIntent.swift`(`#if os(iOS)`,含依赖 SharedInbox 的「问 Kown」系列);
/// mac 端只暴露三个可后台运行的无 UI Intent。
struct KownShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TranslateTextIntent(),
            phrases: [
                "用 \(.applicationName) 翻译",
                "让 \(.applicationName) 翻译"
            ],
            shortTitle: "翻译文本",
            systemImageName: "globe"
        )
        AppShortcut(
            intent: SummarizeLinkIntent(),
            phrases: [
                "让 \(.applicationName) 总结链接",
                "用 \(.applicationName) 总结网页"
            ],
            shortTitle: "总结链接",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: SaveToKnowledgeIntent(),
            phrases: [
                "存到 \(.applicationName) 知识库",
                "用 \(.applicationName) 收藏笔记"
            ],
            shortTitle: "存入知识库",
            systemImageName: "books.vertical.fill"
        )
    }
}
#endif
