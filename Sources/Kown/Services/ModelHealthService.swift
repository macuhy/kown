import Foundation

struct ModelHealthReport: Identifiable, Hashable, Sendable {
    enum Status: String, Hashable, Sendable {
        case ready
        case warning
        case failed
        case skipped

        var displayName: String {
            switch self {
            case .ready: return "可用"
            case .warning: return "需注意"
            case .failed: return "失败"
            case .skipped: return "跳过"
            }
        }
    }

    var id: UUID { providerID }
    let providerID: UUID
    var providerName: String
    var model: String
    var kind: ProviderKind
    var enabled: Bool
    var status: Status
    var latencyMS: Int?
    var sample: String
    var checks: [String]
    var suggestions: [String]
    var testedAt: Date

    var isHealthy: Bool { status == .ready || status == .warning }
}

enum ModelHealthService {
    @MainActor
    static func check(config: ProviderConfig) async -> ModelHealthReport {
        var checks: [String] = []
        var suggestions: [String] = []

        if config.enabled {
            checks.append("已启用")
        } else {
            suggestions.append("当前未启用;测试通过后可打开启用开关。")
        }

        if config.kind.isCLI {
            if (config.cliCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return report(config, status: .failed, checks: checks,
                              suggestions: suggestions + ["CLI 命令为空,请填入 claude / gemini / codex 等命令。"])
            }
            checks.append("CLI 命令已填写")
        } else if config.kind.isAppleFM {
            checks.append("端侧模型免 API Key")
        } else {
            if config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return report(config, status: .failed, checks: checks,
                              suggestions: suggestions + ["Base URL 为空,请使用厂商默认地址或 OpenAI 兼容地址。"])
            }
            checks.append("Base URL 已填写")
            if config.kind.needsAPIKey && !KeychainStore.hasKey(id: config.id) && config.vendor != "ollama" {
                return report(config, status: .failed, checks: checks,
                              suggestions: suggestions + ["缺少 API Key,请在 Provider 卡片里保存 Key 后重测。"])
            }
            checks.append(config.kind.needsAPIKey && config.vendor != "ollama" ? "API Key 已保存" : "免 Key / 本地端点")
        }

        let started = Date()
        do {
            let key = config.kind.needsAPIKey ? ((try? KeychainStore.load(id: config.id)) ?? "") : ""
            let sample = try await AppViewModel.testProvider(config: config, apiKey: key)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            checks.append("ping 成功")
            if latency > 8_000 {
                suggestions.append("首包耗时较长,可作为备用模型或调低 max tokens。")
                return report(config, status: .warning, latencyMS: latency, sample: sample,
                              checks: checks, suggestions: suggestions)
            }
            return report(config, status: .ready, latencyMS: latency, sample: sample,
                          checks: checks, suggestions: suggestions)
        } catch {
            suggestions.append(diagnose(error.localizedDescription, config: config))
            return report(config, status: .failed, sample: error.localizedDescription,
                          checks: checks, suggestions: suggestions)
        }
    }

    private static func report(_ config: ProviderConfig,
                               status: ModelHealthReport.Status,
                               latencyMS: Int? = nil,
                               sample: String = "",
                               checks: [String],
                               suggestions: [String]) -> ModelHealthReport {
        ModelHealthReport(
            providerID: config.id,
            providerName: config.displayName,
            model: config.model,
            kind: config.kind,
            enabled: config.enabled,
            status: status,
            latencyMS: latencyMS,
            sample: sample,
            checks: checks,
            suggestions: suggestions.isEmpty ? ["配置看起来正常。"] : suggestions,
            testedAt: Date()
        )
    }

    private static func diagnose(_ message: String, config: ProviderConfig) -> String {
        let lower = message.lowercased()
        if lower.contains("401") || lower.contains("unauthorized") {
            return "认证失败:检查 API Key 是否过期或填错。"
        }
        if lower.contains("403") || lower.contains("permission") {
            return "权限不足:检查账号是否有该模型权限。"
        }
        if lower.contains("404") || lower.contains("not found") {
            return "端点或模型名可能不对:核对 Base URL 与 model。"
        }
        if lower.contains("429") || lower.contains("rate") {
            return "触发限流:稍后重试,或切换备用模型。"
        }
        if lower.contains("timed") || lower.contains("network") || lower.contains("could not connect") {
            return config.kind.isCLI ? "CLI 启动或返回超时:确认命令在终端可运行。" : "网络连接失败:检查代理、Base URL 或本地服务是否启动。"
        }
        return "请求失败: \(message)"
    }
}
