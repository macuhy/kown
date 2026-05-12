import Foundation

enum ProviderRegistry {
    static func client(for kind: ProviderKind) -> LLMClient {
        switch kind {
        case .openAICompatible: return OpenAICompatibleClient()
        case .anthropic:        return AnthropicClient()
        case .gemini:           return GeminiClient()
        }
    }
}
