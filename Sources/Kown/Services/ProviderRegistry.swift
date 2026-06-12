import Foundation

enum ProviderRegistry {
    static func client(for kind: ProviderKind) -> LLMClient {
        switch kind {
        case .openAICompatible: return OpenAICompatibleClient()
        case .anthropic:        return AnthropicClient()
        case .gemini:           return GeminiClient()
        case .appleFM:          return AppleFMClient()
        case .cliCommand:
            #if os(macOS)
            return CLICommandClient()
            #else
            // iOS 沙箱不能起子进程 — 返回一个直接 fail 的 dummy。
            return UnsupportedCLIClient()
            #endif
        }
    }
}

#if !os(macOS)
private struct UnsupportedCLIClient: LLMClient {
    func stream(prompt: String, options: ChatOptions, config: ProviderConfig, apiKey: String)
        -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { c in
            c.yield(.toolEvent("⚠ CLI provider 在 iOS 上不可用"))
            c.finish(throwing: LLMError.badURL("CLI provider 仅支持 macOS"))
        }
    }
}
#endif
