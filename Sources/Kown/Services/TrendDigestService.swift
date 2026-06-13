import Foundation

/// [趋势洞察] 把一个订阅任务的**历史运行摘要序列**(`ScheduledTask.runDigestHistory`)喂给 LLM,
/// 产出一份「走势报告」—— 盯一件事几周后,报告它怎么变化、出现了什么新信号、趋势往哪走,
/// 而不是每天给一份孤立快照。
///
/// 设计与 `ConversationSummarizer` 对齐:一次性流式调用、选 chair / 第一个非 CLI provider、
/// 失败返回 nil(UI 据此显示错误文案,不崩)。**纯计算/网络**,不碰持久化,产物只回 UI 展示。
enum TrendDigestService {
    /// 趋势报告的最大字符(防止异常超长把 UI 拖死;与其它一次性调用一致地封顶)。
    static let maxOutputChars = 8000

    /// 历史序列里最多取最近多少条喂模型(再多 token 也吃不下,且越久远越没参考意义)。
    static let maxHistoryForPrompt = 24

    /// 趋势分析失败原因(给 UI 看)。
    enum TrendError: Error, LocalizedError {
        case notEnoughHistory
        case noProvider
        case emptyReply
        case provider(String)

        var errorDescription: String? {
            switch self {
            case .notEnoughHistory: return "至少需要两次运行记录才能分析走势,等任务多跑几次再来看。"
            case .noProvider:       return "没有可用的 API provider:趋势分析需要带 API key 的 provider(CLI 不支持)。到设置里启用一个。"
            case .emptyReply:       return "模型没有返回趋势内容,换个 provider 或稍后再试。"
            case .provider(let m):  return "趋势分析失败:\(m)"
            }
        }
    }

    /// 给定任务,基于其历史摘要序列产出一份趋势报告(Markdown)。
    /// `provider` 由调用方在主线程选好(chair 优先,否则第一个 enabled 非 CLI)。
    @MainActor
    static func trendReport(for task: ScheduledTask, provider: ProviderConfig?) async -> Result<String, TrendError> {
        let history = task.chronologicalDigestHistory
        guard history.count >= 2 else { return .failure(.notEnoughHistory) }
        guard let provider, !provider.kind.isCLI else { return .failure(.noProvider) }

        let prompt = buildPrompt(taskTitle: task.title, taskPrompt: task.prompt, history: history)
        do {
            let key = provider.kind.needsAPIKey ? (try KeychainStore.load(id: provider.id)) : ""
            let client = ProviderRegistry.client(for: provider.kind)
            let options = ChatOptions(
                systemPrompt: "你是一名趋势分析师。任务是从一系列按时间排列的观察摘要里,提炼出『随时间的变化与走势』,而不是复述每条快照。用中文,简洁、结构化。",
                temperature: 0.3,
                maxTokens: 1500
            )
            var collected = ""
            for try await chunk in client.stream(prompt: prompt, options: options, config: provider, apiKey: key) {
                if case .text(let t) = chunk { collected += t }
                if collected.count >= maxOutputChars { break }
            }
            let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.emptyReply) }
            return .success(trimmed)
        } catch {
            return .failure(.provider(error.localizedDescription))
        }
    }

    /// 把历史序列拼成趋势分析 prompt:逐条标日期 + 摘要,要求模型输出「趋势概览 / 关键变化 / 新信号 / 展望」。
    /// `nonisolated`:纯字符串拼接,可在任意上下文调用(本身不依赖隔离状态)。
    nonisolated static func buildPrompt(taskTitle: String, taskPrompt: String, history: [DatedDigest]) -> String {
        // 取最近 N 条(history 已是时间正序,从尾部取最近的,再保持正序)。
        let recent = history.count > maxHistoryForPrompt
            ? Array(history.suffix(maxHistoryForPrompt))
            : history

        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd HH:mm"

        // 单条摘要再截断,避免历史很长时 prompt 爆掉(每条留 ~600 字够看出变化)。
        let entries = recent.enumerated().map { (i, item) -> String in
            let when = df.string(from: item.date)
            let body = item.digest.count > 600 ? String(item.digest.prefix(600)) + "…" : item.digest
            return "【第 \(i + 1) 次 · \(when)】\n\(body)"
        }.joined(separator: "\n\n")

        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let header: String = {
            var lines: [String] = []
            if !title.isEmpty { lines.append("订阅主题:\(title)") }
            if !goal.isEmpty { lines.append("盯的事:\(goal)") }
            return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        }()

        return """
        下面是我对同一件事的若干次定期观察(按时间从早到晚排列,每条是当次的结果摘要)。
        \(header)
        请基于这一**时间序列**给我一份「走势报告」,不要逐条复述快照,而是看变化:
        1. **趋势概览**:用一两句话概括这段时间整体往哪个方向走(上升 / 下降 / 反复 / 停滞 / 转折)。
        2. **关键变化**:按时间点出几处最值得注意的变化(从什么变成什么),可标注大致时间。
        3. **新信号**:最近几次里新出现、之前没有的东西。
        4. **展望 / 建议**:基于走势给 1-3 条判断或下一步建议。
        若数据太少或几乎没有变化,如实说明「变化不明显」,不要硬编。

        ===== 时间序列观察 =====
        \(entries)
        """
    }
}
