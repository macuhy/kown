import Foundation

/// LLM 智能重排配置(知识库设置页可改)。
/// - `enabled` 默认开;但没有可用 provider 时重排静默跳过,检索永不因此失败。
/// - `providerID` 可选指定重排用的 provider;`model` 可选覆盖该 provider 的模型名。
///   两者缺省时自动从「已启用 + 有 key(或本地端点)」的 provider 里挑便宜(budget)档模型。
struct RAGRerankConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var providerID: UUID?
    var model: String?

    init(enabled: Bool = true, providerID: UUID? = nil, model: String? = nil) {
        self.enabled = enabled
        self.providerID = providerID
        self.model = model
    }

    // Codable 容错:字段一律 decodeIfPresent(仓库惯例),旧/缺字段 JSON 解出默认值。
    enum CodingKeys: String, CodingKey { case enabled, providerID, model }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled    = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.providerID = try c.decodeIfPresent(UUID.self, forKey: .providerID)
        self.model      = try c.decodeIfPresent(String.self, forKey: .model)
    }

    static let `default` = RAGRerankConfig()
}

/// 配置持久化:`syncedDataDir/rag-rerank.json`(与 web_search.json 等同类配置同一惯例)。
@MainActor
enum RAGRerankConfigStore {
    private static var configURL: URL {
        Platform.syncedDataDir.appendingPathComponent("rag-rerank.json")
    }

    static func load() -> RAGRerankConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(RAGRerankConfig.self, from: data)
        else { return .default }
        return cfg
    }

    static func save(_ cfg: RAGRerankConfig) {
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        try? data.write(to: configURL, options: .atomic)
    }
}

/// 知识库检索的 **LLM 智能重排**:RRF 融合产出候选后,取 top≈20 交给便宜模型按
/// 与查询的相关度重排,再取 top-K 注入。紧凑 prompt(编号 + 每块前 ~300 字 + 查询)→
/// 模型只回 JSON 序号数组 → 解析重排。
///
/// **永不让检索失败**:超时(5s)/ 解析失败 / 无可用 provider / 配置关闭 → 一律返回 nil,
/// 调用方(`LocalRAG.retrieveChunks`)静默保持 RRF 顺序。
enum RAGReranker {
    /// 进入重排的候选上限(RRF 顺序的前这么多个)。
    static let candidateLimit = 20
    /// 每个候选片段进 prompt 的字符数上限。
    static let snippetChars = 300
    /// 整个重排调用(含流式收包)的超时。
    static let timeoutSeconds: Double = 5

    /// 对候选片段做 LLM 重排。`candidates` 是按 RRF 顺序排列的片段文本(已截断),
    /// 返回**候选数组的 0-based 下标**新顺序;任何失败返回 nil(调用方保持原顺序)。
    nonisolated static func rerank(query: String, candidates: [String], topK: Int) async -> [Int]? {
        guard !isRunningUnderXCTest else { return nil }   // 测试不得依赖网络
        guard candidates.count > topK, candidates.count > 1 else { return nil }
        guard let (provider, apiKey) = await loadSetup() else { return nil }

        let prompt = buildPrompt(query: query, candidates: candidates, topK: topK)
        let options = ChatOptions(
            systemPrompt: "你是检索片段重排器。只输出一个 JSON 数组,不要任何其他文字。",
            temperature: 0.0,
            maxTokens: 200
        )
        do {
            let raw: String = try await withTimeout(seconds: timeoutSeconds) {
                let client = ProviderRegistry.client(for: provider.kind)
                var collected = ""
                for try await chunk in client.stream(
                    prompt: prompt, options: options, config: provider, apiKey: apiKey
                ) {
                    if case .text(let t) = chunk { collected += t }
                    if collected.count >= 600 { break }   // 序号数组用不了这么多,防失控
                }
                return collected
            }
            return parseOrder(raw, candidateCount: candidates.count)
        } catch {
            return nil   // 超时 / 网络 / provider 报错 → 静默回退 RRF 顺序
        }
    }

    // MARK: - Provider 解析

    /// 主线程读配置 + provider + key(都是 @MainActor 的小文件读,开销可忽略;
    /// 真正的 LLM 流式调用在调用方的后台上下文进行)。
    private static func loadSetup() async -> (provider: ProviderConfig, apiKey: String)? {
        await MainActor.run { () -> (ProviderConfig, String)? in
            let cfg = RAGRerankConfigStore.load()
            guard cfg.enabled else { return nil }
            let providers = ProviderConfigStore.load()
            var provider: ProviderConfig?
            if cfg.providerID != nil {
                // 用户显式指定:尊重选择(key 缺失也尝试,失败自有静默回退)。
                provider = resolveProvider(config: cfg, providers: providers)
            } else {
                // 自动挑选:只在「有 key 或本地端点」的 provider 里挑,避免白发必败请求。
                let usable = providers.filter {
                    KeychainStore.hasKey(id: $0.id) || isLocalEndpoint($0.baseURL)
                }
                provider = autoPick(from: usable)
            }
            guard var picked = provider else { return nil }
            if let m = cfg.model, !m.isEmpty { picked.model = m }
            let key = (try? KeychainStore.load(id: picked.id)) ?? ""
            return (picked, key)
        }
    }

    /// 解析显式指定的 provider(必须仍启用且非 CLI);没指定走 `autoPick`。纯函数可测。
    static func resolveProvider(config: RAGRerankConfig, providers: [ProviderConfig]) -> ProviderConfig? {
        if let pid = config.providerID {
            return providers.first { $0.id == pid && $0.enabled && !$0.kind.isCLI }
        }
        return autoPick(from: providers)
    }

    /// 自动挑重排模型:已启用、非 CLI;优先当前模型就是 budget 档的 provider;
    /// 其次从该厂模型目录里找一个 budget 档替换;都没有就用第一个可用的。纯函数可测。
    static func autoPick(from providers: [ProviderConfig]) -> ProviderConfig? {
        let usable = providers.filter { $0.enabled && !$0.kind.isCLI }
        guard !usable.isEmpty else { return nil }
        if let budget = usable.first(where: { ModelTier.heuristic($0.model) == .budget }) {
            return budget
        }
        for p in usable {
            if let m = ProviderModelCatalog.knownModels(for: p)
                .first(where: { ModelTier.heuristic($0) == .budget }) {
                var copy = p
                copy.model = m
                return copy
            }
        }
        return usable.first
    }

    /// 本地端点(Ollama 等)不需要 key。
    static func isLocalEndpoint(_ baseURL: String) -> Bool {
        let lower = baseURL.lowercased()
        return lower.contains("localhost") || lower.contains("127.0.0.1") || lower.contains("0.0.0.0")
    }

    // MARK: - Prompt 与解析

    /// 紧凑重排 prompt:查询 + 编号片段(每块截前 `snippetChars` 字),要求只回 JSON 序号数组。
    static func buildPrompt(query: String, candidates: [String], topK: Int) -> String {
        var lines: [String] = []
        lines.append("根据与查询的相关程度,把下列片段从高到低排序,输出最相关的前 \(topK) 个片段编号。")
        lines.append("只输出一个 JSON 数组(1-based 编号),例如 [3,1,7]。不要解释,不要其他文字。")
        lines.append("")
        lines.append("【查询】\(String(query.prefix(300)))")
        lines.append("")
        lines.append("【片段】")
        for (i, c) in candidates.enumerated() {
            let flat = c.replacingOccurrences(of: "\n", with: " ")
            lines.append("[\(i + 1)] \(String(flat.prefix(snippetChars)))")
        }
        return lines.joined(separator: "\n")
    }

    /// 解析模型输出的 JSON 序号数组(1-based)→ 0-based 下标顺序。
    /// 容错:提取第一个 `[...]`(自动跳过 ``` 围栏 / 前后废话)、整数或浮点都收、
    /// 去重、越界丢弃;没解出任何有效序号 → nil(调用方回退 RRF 顺序)。
    static func parseOrder(_ raw: String, candidateCount: Int) -> [Int]? {
        guard candidateCount > 0 else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]") else { return nil }
        let body = String(text[open...close])
        guard let data = body.data(using: .utf8) else { return nil }

        var nums = (try? JSONDecoder().decode([Int].self, from: data))
        if nums == nil, let ds = try? JSONDecoder().decode([Double].self, from: data) {
            nums = ds.map { Int($0) }
        }
        guard let parsed = nums else { return nil }

        var out: [Int] = []
        var seen = Set<Int>()
        for n in parsed {
            let idx = n - 1
            guard idx >= 0, idx < candidateCount, seen.insert(idx).inserted else { continue }
            out.append(idx)
        }
        return out.isEmpty ? nil : out
    }
}
