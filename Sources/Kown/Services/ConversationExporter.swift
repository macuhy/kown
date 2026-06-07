import Foundation

/// 整会话导出器:把一个 `Conversation` 渲染成 Markdown 或 JSON。
///
/// - Markdown 按 `conversation.mode` 分别排版:
///   - Direct:顺序气泡
///   - Compare:各模型分栏小节并列
///   - Council:列各成员回答 + Chair + Summary
///   - Debate:按轮次 ROUND 组织
/// - JSON 直接复用 `Conversation` 的 `Codable`(prettyPrinted)。
///
/// provider 的显示名优先从每个 `Turn.providerSnapshot` 里的 `ProviderConfig.displayName` 取,
/// 缺失时回退到截断的 providerID,因此导出逻辑是纯函数,不依赖 view / viewModel。
enum ConversationExporter {

    // MARK: - 导出格式

    enum Format: String, CaseIterable, Sendable {
        case markdown
        case html
        case json

        /// 文件扩展名(不含点)
        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .html:     return "html"
            case .json:     return "json"
            }
        }

        /// 菜单/按钮上的标题
        var menuTitle: String {
            switch self {
            case .markdown: return "导出为 Markdown"
            case .html:     return "导出为网页(HTML)"
            case .json:     return "导出为 JSON"
            }
        }

        var symbol: String {
            switch self {
            case .markdown: return "doc.richtext"
            case .html:     return "safari"
            case .json:     return "curlybraces"
            }
        }
    }

    // MARK: - 入口

    /// 按格式生成导出内容(UTF-8 文本)。JSON 编码失败时回退到空串。
    static func text(for conversation: Conversation, format: Format) -> String {
        switch format {
        case .markdown: return markdown(for: conversation)
        case .html:     return HTMLExporter.html(for: conversation)
        case .json:     return jsonString(for: conversation)
        }
    }

    /// 由会话标题派生一个安全的文件名(含扩展名)。
    /// 去掉路径分隔符与文件系统不友好字符,空标题回退到 "Conversation"。
    static func suggestedFileName(for conversation: Conversation, format: Format) -> String {
        let raw = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = raw.isEmpty ? "Conversation" : raw
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safe = cleaned.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = safe.count > 80 ? String(safe.prefix(80)) : safe
        return "\(trimmed).\(format.fileExtension)"
    }

    // MARK: - JSON 导出

    /// 直接复用 `Conversation` 的 `Codable`,人类可读输出。
    static func json(for conversation: Conversation) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(conversation)
    }

    /// JSON 字符串(编码或 UTF-8 解码失败时回退到空串)。
    static func jsonString(for conversation: Conversation) -> String {
        guard let data = try? json(for: conversation),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    // MARK: - Markdown 导出

    /// 把全部会话拼成一份 Markdown(各会话之间用分隔线),用于「导出全部会话」。
    static func markdownForAll(_ conversations: [Conversation]) -> String {
        guard !conversations.isEmpty else { return "# Kown 全部会话\n\n_(暂无会话)_\n" }
        var out = "# Kown 全部会话(\(conversations.count))\n\n"
        out += conversations.map { markdown(for: $0) }.joined(separator: "\n\n---\n\n")
        return out
    }

    /// 把整会话渲染成 Markdown。
    static func markdown(for conversation: Conversation) -> String {
        var out = ""

        // ── 头部元信息 ──
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "# \(title.isEmpty ? "Conversation" : title)\n\n"
        out += "- 模式: \(conversation.mode.displayName)\n"
        out += "- 创建: \(format(conversation.createdAt))\n"
        out += "- 更新: \(format(conversation.updatedAt))\n"
        out += "- 轮次: \(conversation.turns.count)\n"
        if let summary = conversation.contextSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            out += "\n> 上下文摘要: \(summary)\n"
        }
        out += "\n---\n"

        // ── 逐轮渲染 ──
        for (index, turn) in conversation.turns.enumerated() {
            out += "\n## 第 \(index + 1) 轮 · \(format(turn.timestamp))\n\n"
            out += renderPrompt(turn)

            switch conversation.mode {
            case .direct:
                out += renderDirect(turn)
            case .compare:
                out += renderCompare(turn)
            case .council:
                out += renderCouncil(turn)
            case .debate:
                out += renderDebate(turn)
            case .structured:
                out += renderCompare(turn)
            case .tournament:
                out += renderTournament(turn)
            }

            out += "\n---\n"
        }

        return out
    }

    // MARK: - 单轮报告

    /// 单轮报告:渲染一个 Turn(用户问题 + 该模式的回答/结论)为 Markdown。
    /// 用于 Council / Debate 的「导出报告」,复用整会话的逐轮渲染逻辑。
    static func turnReportMarkdown(_ turn: Turn, mode: ConversationMode, index: Int? = nil) -> String {
        var out = ""
        let header = index.map { "第 \($0 + 1) 轮" } ?? "单轮报告"
        out += "# \(header) · \(format(turn.timestamp))\n\n"
        out += "- 模式: \(mode.displayName)\n\n---\n\n"
        out += renderPrompt(turn)
        switch mode {
        case .direct:  out += renderDirect(turn)
        case .compare: out += renderCompare(turn)
        case .council: out += renderCouncil(turn)
        case .debate:  out += renderDebate(turn)
        case .structured: out += renderCompare(turn)
        case .tournament: out += renderTournament(turn)
        }
        out += "\n"
        return out
    }

    /// 单轮报告的建议文件名(会话标题 + -report.md)。
    static func suggestedTurnReportFileName(_ turn: Turn, conversationTitle: String) -> String {
        let raw = conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = raw.isEmpty ? "Conversation" : raw
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safe = cleaned.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = safe.count > 60 ? String(safe.prefix(60)) : safe
        return "\(trimmed)-report.md"
    }

    // MARK: - 各模式渲染

    /// 用户 prompt(含 system prompt / 图片附件提示)。
    private static func renderPrompt(_ turn: Turn) -> String {
        var out = ""
        let prompt = turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "**用户**\n\n"
        out += prompt.isEmpty ? "_(空)_\n" : "\(prompt)\n"

        if let images = turn.images, !images.isEmpty {
            out += "\n附带图片: "
            out += images.map { "`\($0.fileName)` (\($0.pixelWidth)×\($0.pixelHeight))" }
                .joined(separator: ", ")
            out += "\n"
        }

        let system = turn.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            out += "\n> System: \(system)\n"
        }
        out += "\n"
        return out
    }

    /// Direct:单模型顺序气泡。
    private static func renderDirect(_ turn: Turn) -> String {
        var out = ""
        let order = orderedIDs(turn)
        if order.isEmpty {
            return "_(无回答)_\n"
        }
        for pid in order {
            out += "**\(name(pid, in: turn))**\n\n"
            out += body(for: pid, responses: turn.responses, errors: turn.errors)
            out += "\n"
        }
        return out
    }

    /// Compare:两个(或多个)模型分栏并列。Markdown 没有真正的分栏,用并列小节模拟,
    /// 标题统一三级缩进,便于阅读对比。
    private static func renderCompare(_ turn: Turn) -> String {
        var out = ""
        let order = orderedIDs(turn)
        if order.isEmpty {
            return "_(无回答)_\n"
        }
        for pid in order {
            out += "### ▌\(name(pid, in: turn))\n\n"
            out += body(for: pid, responses: turn.responses, errors: turn.errors)
            out += "\n"
        }
        return out
    }

    /// Council:列各成员回答 + Chair 综合 + Summary 中立汇总。
    private static func renderCouncil(_ turn: Turn) -> String {
        var out = ""
        let order = orderedIDs(turn)
        if order.isEmpty && turn.chairSummary == nil && turn.summaryText == nil {
            return "_(无回答)_\n"
        }

        out += "### 成员回答\n\n"
        if order.isEmpty {
            out += "_(无成员回答)_\n\n"
        } else {
            for pid in order {
                out += "#### \(name(pid, in: turn))\n\n"
                out += body(for: pid, responses: turn.responses, errors: turn.errors)
                out += "\n"
            }
        }

        // Chair 综合
        if let pid = turn.chairProviderID {
            out += "### 🪑 Chair · \(name(pid, in: turn))\n\n"
            out += chairOrSummaryBody(text: turn.chairSummary, error: turn.chairError)
        } else if let text = turn.chairSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            out += "### 🪑 Chair\n\n\(text)\n\n"
        }

        // Summary 中立汇总
        if let pid = turn.summaryProviderID {
            out += "### 📝 Summary · \(name(pid, in: turn))\n\n"
            out += chairOrSummaryBody(text: turn.summaryText, error: turn.summaryError)
        } else if let text = turn.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            out += "### 📝 Summary\n\n\(text)\n\n"
        }

        // 投票打分(若有)
        if let votes = turn.councilVotes, !votes.scores.isEmpty {
            out += "### ✅ 投票打分\n\n"
            out += "| 排名 | 模型 | 准确 | 完整 | 可执行 | 清晰 | 总分 |\n"
            out += "|---|---|---|---|---|---|---|\n"
            let ranked = votes.scores.sorted { $0.value.total > $1.value.total }
            for (i, item) in ranked.enumerated() {
                let s = item.value
                out += "| \(i + 1) | \(name(item.key, in: turn)) | \(s.accuracy) | \(s.completeness) | \(s.actionability) | \(s.clarity) | \(s.total) |\n"
            }
            if !votes.rationale.isEmpty {
                out += "\n> \(votes.rationale)\n"
            }
            out += "\n"
        }

        return out
    }

    /// Debate:按轮次 ROUND 组织。优先用 `debateRounds`,旧会话无该字段时回退到 `responses`。
    private static func renderDebate(_ turn: Turn) -> String {
        var out = ""
        let rounds = turn.debateRounds ?? []

        if rounds.isEmpty {
            // 回退:把 responses 当作单轮发言
            let order = orderedIDs(turn)
            if order.isEmpty && turn.chairSummary == nil {
                out += "_(无发言)_\n"
            } else {
                for pid in order {
                    out += "**\(name(pid, in: turn))**\n\n"
                    out += body(for: pid, responses: turn.responses, errors: turn.errors)
                    out += "\n"
                }
            }
        } else {
            for round in rounds.sorted(by: { $0.index < $1.index }) {
                let roundTitle = round.title.trimmingCharacters(in: .whitespacesAndNewlines)
                out += "### ROUND \(round.index + 1)"
                if !roundTitle.isEmpty { out += " · \(roundTitle)" }
                out += "\n\n"

                let order = round.panelOrder.isEmpty
                    ? Array(round.responses.keys).sorted()
                    : round.panelOrder
                if order.isEmpty {
                    out += "_(本轮无发言)_\n\n"
                } else {
                    for pid in order {
                        out += "**\(name(pid, in: turn))**\n\n"
                        out += body(for: pid, responses: round.responses, errors: round.errors)
                        out += "\n"
                    }
                }
            }
        }

        // 辩论的主持结论(Chair)
        if let text = turn.chairSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let pid = turn.chairProviderID {
                out += "### ⚖️ 结论 · \(name(pid, in: turn))\n\n\(text)\n\n"
            } else {
                out += "### ⚖️ 结论\n\n\(text)\n\n"
            }
        } else if let err = turn.chairError?.trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
            out += "### ⚖️ 结论\n\n> 错误: \(err)\n\n"
        }

        return out
    }

    /// Tournament:种子回答(各家原始回答)+ 逐轮对决(胜者 + 理由)+ 冠军。
    private static func renderTournament(_ turn: Turn) -> String {
        var out = ""
        let rounds = (turn.tournamentRounds ?? []).sorted { $0.index < $1.index }

        // 冠军(最后一轮唯一对决的胜者)。
        if let champKey = rounds.last?.matches.last?.winnerProviderID {
            out += "### 🏆 冠军 · \(name(champKey, in: turn))\n\n"
        }

        // 种子回答。
        let order = orderedIDs(turn)
        if !order.isEmpty {
            out += "### 种子回答\n\n"
            for pid in order {
                out += "**\(name(pid, in: turn))**\n\n"
                out += body(for: pid, responses: turn.responses, errors: turn.errors)
                out += "\n"
            }
        }

        // 赛程。
        for round in rounds {
            let roundTitle = round.title.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "### ROUND \(round.index) · \(roundTitle.isEmpty ? "对决" : roundTitle)\n\n"
            for match in round.matches {
                let aName = name(match.aProviderID, in: turn)
                let bName = match.bProviderID.map { name($0, in: turn) } ?? "轮空"
                out += "- **\(aName)** vs **\(bName)** → "
                if let err = match.error, !err.isEmpty {
                    out += "_(裁判失败: \(err))_\n"
                } else if let w = match.winnerProviderID {
                    out += "胜者 **\(name(w, in: turn))**"
                    let r = match.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !r.isEmpty { out += " — \(r)" }
                    out += "\n"
                } else {
                    out += "_(未裁定)_\n"
                }
            }
            out += "\n"
        }

        if rounds.isEmpty && order.isEmpty {
            out += "_(无对决记录)_\n"
        }
        return out
    }

    // MARK: - 小工具

    /// 取一轮的发言顺序:优先 `panelOrder`,否则用 responses 的 key 排序兜底。
    private static func orderedIDs(_ turn: Turn) -> [String] {
        if !turn.panelOrder.isEmpty { return turn.panelOrder }
        return Array(turn.responses.keys).sorted()
    }

    /// 取某 provider 这一轮的正文:有错误显示错误,有回答显示回答,都没有显示占位。
    private static func body(for pid: String,
                             responses: [String: String],
                             errors: [String: String]) -> String {
        if let err = errors[pid]?.trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
            return "> 错误: \(err)\n"
        }
        if let text = responses[pid]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return "\(text)\n"
        }
        return "_(无回答)_\n"
    }

    /// Chair / Summary 正文(错误优先)。
    private static func chairOrSummaryBody(text: String?, error: String?) -> String {
        if let err = error?.trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
            return "> 错误: \(err)\n\n"
        }
        if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return "\(t)\n\n"
        }
        return "_(无内容)_\n\n"
    }

    /// providerID → 显示名:优先从该轮 `providerSnapshot` 取 `displayName`,缺失时回退到截断 ID。
    private static func name(_ pid: String, in turn: Turn) -> String {
        if let cfg = turn.providerSnapshot[pid], !cfg.displayName.isEmpty {
            return cfg.displayName
        }
        return String(pid.prefix(8))
    }

    /// 统一的日期格式(本地化、中等长度)。
    private static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
