import Foundation
import Observation

@Observable
@MainActor
final class CouncilViewModel {
    var providers: [ProviderConfig]
    var states: [UUID: ResponseState] = [:]
    var prompt: String = ""
    var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: Self.systemPromptKey) }
    }
    var isRunning: Bool = false

    private static let systemPromptKey = "kown.systemPrompt.v1"

    private var runningTask: Task<Void, Never>?

    init() {
        let loaded = ProviderConfigStore.load()
        self.providers = loaded
        self.systemPrompt = UserDefaults.standard.string(forKey: Self.systemPromptKey) ?? ""
        for cfg in loaded {
            states[cfg.id] = ResponseState(id: cfg.id)
        }
    }

    // MARK: - 配置管理

    func saveProviders() {
        ProviderConfigStore.save(providers)
        // 同步 states:新加的厂商补一个状态,删掉的清掉 + 删 Keychain
        let ids = Set(providers.map(\.id))
        for id in states.keys where !ids.contains(id) {
            states.removeValue(forKey: id)
            KeychainStore.delete(id: id)
        }
        for cfg in providers where states[cfg.id] == nil {
            states[cfg.id] = ResponseState(id: cfg.id)
        }
    }

    func addProvider(kind: ProviderKind) {
        let cfg = ProviderConfig(displayName: kind.displayName, kind: kind)
        providers.append(cfg)
        states[cfg.id] = ResponseState(id: cfg.id)
        saveProviders()
    }

    func removeProvider(_ id: UUID) {
        providers.removeAll { $0.id == id }
        saveProviders()
    }

    // MARK: - 并发请求

    func send() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        runningTask?.cancel()
        isRunning = true

        let snapshot = trimmed
        let active = providers.filter(\.enabled)

        // 先为所有要参与的厂商重置状态(让 UI 立刻看到"开始")
        for cfg in active {
            let state = states[cfg.id] ?? ResponseState(id: cfg.id)
            state.reset()
            states[cfg.id] = state
        }

        runningTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for cfg in active {
                    group.addTask { [weak self] in
                        await self?.runOne(config: cfg, prompt: snapshot)
                    }
                }
            }
            self.isRunning = false
        }
    }

    func cancel() {
        runningTask?.cancel()
        runningTask = nil
        isRunning = false
        for state in states.values where isStreaming(state) {
            state.fail("已取消")
        }
    }

    private func isStreaming(_ state: ResponseState) -> Bool {
        if case .streaming = state.phase { return true }
        return false
    }

    private func runOne(config: ProviderConfig, prompt: String) async {
        let state = states[config.id]!
        do {
            let key = try KeychainStore.load(id: config.id)
            let client = ProviderRegistry.client(for: config.kind)
            let options = optionsFor(config: config)
            for try await chunk in client.stream(prompt: prompt, options: options, config: config, apiKey: key) {
                if Task.isCancelled { break }
                state.append(chunk)
            }
            if Task.isCancelled {
                state.fail("已取消")
            } else {
                state.finish()
            }
        } catch is CancellationError {
            state.fail("已取消")
        } catch {
            state.fail(error.localizedDescription)
        }
    }

    private func optionsFor(config: ProviderConfig) -> ChatOptions {
        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatOptions(
            systemPrompt: sys.isEmpty ? nil : sys,
            temperature: config.temperature,
            maxTokens: config.maxTokens
        )
    }

    // MARK: - 单家测试(用于 Settings 中的「测试」按钮)

    /// 用一次最小流式调用验证配置是否可用。返回首个收到的文本片段。
    static func testProvider(config: ProviderConfig, apiKey: String) async throws -> String {
        let client = ProviderRegistry.client(for: config.kind)
        let options = ChatOptions(systemPrompt: nil, temperature: nil, maxTokens: 32)
        var sample = ""
        for try await chunk in client.stream(prompt: "ping", options: options, config: config, apiKey: apiKey) {
            sample += chunk
            if sample.count >= 24 { break }
        }
        return sample.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
