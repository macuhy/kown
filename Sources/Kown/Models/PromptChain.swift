import Foundation

/// 链式工作流的单步:一个模型 + 一段指示模板。
/// `instruction` 里用 `{{prev}}` 注入上一步输出、`{{input}}` 注入最初的输入。
/// `providerModelChoice == nil` 表示「用默认模型」(运行时挑第一个已启用、非 CLI 的 provider)。
struct ChainStep: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    /// 指定的 (provider, model);nil = 默认模型。
    var providerModelChoice: ProviderModelChoice?
    /// 指示模板,可含 `{{prev}}` / `{{input}}` 占位符。
    var instruction: String

    init(id: UUID = UUID(),
         title: String = "新步骤",
         providerModelChoice: ProviderModelChoice? = nil,
         instruction: String = "") {
        self.id = id
        self.title = title
        self.providerModelChoice = providerModelChoice
        self.instruction = instruction
    }
}

/// 一条链式工作流:有序的多个步骤。
struct PromptChain: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var steps: [ChainStep]

    init(id: UUID = UUID(), name: String = "新工作流", steps: [ChainStep] = []) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    /// 一个开箱即用的示例:草稿 → 批评 → 修订。
    static func sample() -> PromptChain {
        PromptChain(
            name: "草稿 → 批评 → 修订",
            steps: [
                ChainStep(
                    title: "草稿",
                    instruction: "请根据下面的需求写一份初稿:\n\n{{input}}"
                ),
                ChainStep(
                    title: "批评",
                    instruction: "你是严格的审稿人。指出下面这份初稿的问题、漏洞和可改进之处,逐条列出:\n\n{{prev}}"
                ),
                ChainStep(
                    title: "修订",
                    instruction: "请结合下面的批评意见,把初稿改写成更好的最终稿(只输出最终稿):\n\n原始需求:\n{{input}}\n\n批评意见:\n{{prev}}"
                ),
            ]
        )
    }
}

/// 工作流列表持久化:`syncedDataDir/prompt-chains.json`(随 iCloud 同步)。
@MainActor
enum PromptChainStore {
    private static var url: URL {
        Platform.syncedDataDir.appendingPathComponent("prompt-chains.json")
    }

    static func load() -> [PromptChain] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([PromptChain].self, from: data) else { return [] }
        return list
    }

    static func save(_ chains: [PromptChain]) {
        guard let data = try? JSONEncoder().encode(chains) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
