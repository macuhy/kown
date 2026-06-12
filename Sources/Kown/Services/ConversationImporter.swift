import Foundation

/// 聊天记录导入器(`ConversationExporter` 的对称面):把外部导出的聊天记录解析成本地 `Conversation`。
///
/// 支持三种来源:
/// - **ChatGPT 官方导出**:导出包里的 `conversations.json`(mapping 树结构,取 `current_node`
///   回溯出主线,user/assistant 轮配对;保留标题与时间戳)。
/// - **Claude 官方导出**:`conversations.json`(`uuid` / `name` / `chat_messages` 数组,
///   sender 为 human/assistant)。
/// - **Kown 单会话 JSON**:`ConversationExporter.json(for:)` 的逆操作,导入时重新生成
///   会话与轮次 id,防止和本机已有会话冲突。
///
/// 全部**本地解析**,不发任何网络请求。容错策略:单条会话解析失败只计入 `skipped`,
/// 不让整个导入失败。zip 解压依赖 `/usr/bin/unzip` 子进程,**仅 macOS 可用**;
/// iOS 无 `Process`,需要用户先解压导出包再选择其中的 `conversations.json`。
enum ConversationImporter {

    // MARK: - 来源 / 结果 / 错误

    /// 导入来源(决定用哪套解析器)。
    enum Source: String, CaseIterable, Sendable {
        case chatGPT
        case claude
        case kown

        /// 导入后会话里展示「对方」的名字(providerSnapshot 的 displayName)。
        var assistantDisplayName: String {
            switch self {
            case .chatGPT: return "ChatGPT(导入)"
            case .claude:  return "Claude(导入)"
            case .kown:    return "Kown(导入)"
            }
        }
    }

    /// 解析结果:成功的会话列表 + 跳过(解析失败/无内容)条数。
    struct ImportResult: Sendable {
        var conversations: [Conversation] = []
        var skipped: Int = 0
    }

    enum ImportError: LocalizedError {
        /// 整个文件无法当作该来源的 JSON 读取。
        case invalidFormat(String)
        /// zip 包里找不到 conversations.json。
        case zipEntryNotFound
        /// 当前平台不支持 zip 解压(iOS)。
        case zipUnsupported

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let detail):
                return "文件格式无法识别:\(detail)"
            case .zipEntryNotFound:
                return "压缩包里没有找到 conversations.json"
            case .zipUnsupported:
                return "此设备不支持解压 zip,请先在文件 App 里解压导出包,再选择其中的 conversations.json"
            }
        }
    }

    // MARK: - 入口

    /// 从文件 URL 导入:zip(magic `PK`)走解压取 conversations.json(仅 macOS),
    /// 其余按 JSON 直接解析。调用方负责安全作用域与临时文件清理。
    static func importFile(at url: URL, source: Source) throws -> ImportResult {
        let data = try Data(contentsOf: url)
        // zip 魔数 "PK\x03\x04"
        if data.count >= 4, data[0] == 0x50, data[1] == 0x4B {
            #if os(macOS)
            let json = try extractConversationsJSON(fromZip: url)
            return try parse(json, source: source)
            #else
            throw ImportError.zipUnsupported
            #endif
        }
        return try parse(data, source: source)
    }

    /// 解析 JSON 数据(已解压/本来就是 .json)。
    static func parse(_ data: Data, source: Source) throws -> ImportResult {
        switch source {
        case .chatGPT: return try parseChatGPT(data)
        case .claude:  return try parseClaude(data)
        case .kown:    return try parseKown(data)
        }
    }

    // MARK: - ChatGPT

    /// ChatGPT 官方导出的 `conversations.json`:顶层是会话数组(也兼容单个会话对象)。
    /// 每个会话是 `mapping` 树(nodeID → { message, parent, children }),从 `current_node`
    /// 沿 parent 回溯得到当前主线;缺 `current_node` 时从根一路取最后一个 child 兜底。
    static func parseChatGPT(_ data: Data) throws -> ImportResult {
        let top = try JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let array = top as? [[String: Any]] {
            items = array
        } else if let dict = top as? [String: Any], dict["mapping"] != nil {
            items = [dict]
        } else {
            throw ImportError.invalidFormat("不是 ChatGPT 导出的 conversations.json")
        }

        var result = ImportResult()
        for item in items {
            if let conv = chatGPTConversation(from: item) {
                result.conversations.append(conv)
            } else {
                result.skipped += 1
            }
        }
        return result
    }

    /// 解析单个 ChatGPT 会话;结构不对 / 主线里没有任何有效消息 → 返回 nil(计入跳过)。
    private static func chatGPTConversation(from dict: [String: Any]) -> Conversation? {
        guard let mapping = dict["mapping"] as? [String: [String: Any]], !mapping.isEmpty else {
            return nil
        }

        // 1) 找主线叶子:优先 current_node;没有就从根沿「最后一个 child」走到底。
        var leafID: String? = (dict["current_node"] as? String).flatMap { mapping[$0] != nil ? $0 : nil }
        if leafID == nil {
            // 根 = parent 为空的节点(取第一个即可)
            var cursor = mapping.first(where: { ($0.value["parent"] as? String) == nil })?.key
            var guard_ = 0
            while let cur = cursor, guard_ < mapping.count + 1 {
                guard_ += 1
                let children = mapping[cur]?["children"] as? [String] ?? []
                guard let next = children.last, mapping[next] != nil else { break }
                cursor = next
            }
            leafID = cursor
        }
        guard var nodeID = leafID else { return nil }

        // 2) 从叶子回溯到根,得到主线节点序(防环:visited + 步数上限)。
        var chain: [String] = []
        var visited = Set<String>()
        while visited.insert(nodeID).inserted, chain.count <= mapping.count {
            chain.append(nodeID)
            guard let parent = mapping[nodeID]?["parent"] as? String, mapping[parent] != nil else { break }
            nodeID = parent
        }
        chain.reverse()

        // 3) 主线消息 → user/assistant 轮配对。
        let convCreated = epochDate(dict["create_time"]) ?? Date()
        let convUpdated = epochDate(dict["update_time"]) ?? convCreated
        let pid = UUID().uuidString
        let snapshot = importedSnapshot(id: pid, source: .chatGPT)

        var turns: [Turn] = []
        var pendingPrompt: String?
        var pendingTime: Date?

        func flushTurn(response: String?, at time: Date?) {
            guard pendingPrompt != nil || response != nil else { return }
            var turn = Turn(
                timestamp: pendingTime ?? time ?? convCreated,
                prompt: pendingPrompt ?? "",
                systemPrompt: "",
                providerSnapshot: [pid: snapshot],
                panelOrder: [pid]
            )
            if let response { turn.responses[pid] = response }
            turns.append(turn)
            pendingPrompt = nil
            pendingTime = nil
        }

        for id in chain {
            guard let message = mapping[id]?["message"] as? [String: Any],
                  let author = message["author"] as? [String: Any],
                  let role = author["role"] as? String else { continue }
            let text = chatGPTMessageText(message)
            guard !text.isEmpty else { continue }
            let time = epochDate(message["create_time"])

            switch role {
            case "user":
                // 连续两条 user → 前一条单独成轮(无回答)
                if pendingPrompt != nil { flushTurn(response: nil, at: nil) }
                pendingPrompt = text
                pendingTime = time
            case "assistant":
                flushTurn(response: text, at: time)
            default:
                continue // system / tool 等不进轮
            }
        }
        if pendingPrompt != nil { flushTurn(response: nil, at: nil) }

        guard !turns.isEmpty else { return nil }

        let rawTitle = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Conversation(
            title: rawTitle.isEmpty ? "导入的会话" : rawTitle,
            mode: .direct,
            createdAt: convCreated,
            updatedAt: convUpdated,
            turns: turns
        )
    }

    /// 取一条 ChatGPT 消息的纯文本:content.parts 里的字符串拼接
    /// (multimodal 时跳过非字符串 part);text 字段兜底。
    private static func chatGPTMessageText(_ message: [String: Any]) -> String {
        if let content = message["content"] as? [String: Any] {
            if let parts = content["parts"] as? [Any] {
                let texts = parts.compactMap { $0 as? String }
                let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { return joined }
            }
            if let text = content["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    // MARK: - Claude

    /// Claude 官方导出的 `conversations.json`:顶层是会话数组(也兼容单个会话对象),
    /// 每个会话含 `uuid` / `name` / `chat_messages`,消息 sender 为 human/assistant。
    static func parseClaude(_ data: Data) throws -> ImportResult {
        let top = try JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let array = top as? [[String: Any]] {
            items = array
        } else if let dict = top as? [String: Any], dict["chat_messages"] != nil {
            items = [dict]
        } else {
            throw ImportError.invalidFormat("不是 Claude 导出的 conversations.json")
        }

        var result = ImportResult()
        for item in items {
            if let conv = claudeConversation(from: item) {
                result.conversations.append(conv)
            } else {
                result.skipped += 1
            }
        }
        return result
    }

    /// 解析单个 Claude 会话;缺 chat_messages / 没有任何有效消息 → nil(计入跳过)。
    private static func claudeConversation(from dict: [String: Any]) -> Conversation? {
        guard let messages = dict["chat_messages"] as? [[String: Any]] else { return nil }

        let convCreated = isoDate(dict["created_at"]) ?? Date()
        let convUpdated = isoDate(dict["updated_at"]) ?? convCreated
        let pid = UUID().uuidString
        let snapshot = importedSnapshot(id: pid, source: .claude)

        var turns: [Turn] = []
        var pendingPrompt: String?
        var pendingTime: Date?

        func flushTurn(response: String?, at time: Date?) {
            guard pendingPrompt != nil || response != nil else { return }
            var turn = Turn(
                timestamp: pendingTime ?? time ?? convCreated,
                prompt: pendingPrompt ?? "",
                systemPrompt: "",
                providerSnapshot: [pid: snapshot],
                panelOrder: [pid]
            )
            if let response { turn.responses[pid] = response }
            turns.append(turn)
            pendingPrompt = nil
            pendingTime = nil
        }

        for message in messages {
            guard let sender = message["sender"] as? String else { continue }
            let text = claudeMessageText(message)
            guard !text.isEmpty else { continue }
            let time = isoDate(message["created_at"])

            switch sender {
            case "human":
                if pendingPrompt != nil { flushTurn(response: nil, at: nil) }
                pendingPrompt = text
                pendingTime = time
            case "assistant":
                flushTurn(response: text, at: time)
            default:
                continue
            }
        }
        if pendingPrompt != nil { flushTurn(response: nil, at: nil) }

        guard !turns.isEmpty else { return nil }

        let rawTitle = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Conversation(
            title: rawTitle.isEmpty ? "导入的会话" : rawTitle,
            mode: .direct,
            createdAt: convCreated,
            updatedAt: convUpdated,
            turns: turns
        )
    }

    /// 取一条 Claude 消息的纯文本:优先顶层 `text`;空则拼 `content` 数组里 type=text 的段。
    private static func claudeMessageText(_ message: [String: Any]) -> String {
        if let text = (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let content = message["content"] as? [[String: Any]] {
            let texts = content.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: - Kown 单会话 JSON

    /// `ConversationExporter.json(for:)` 的逆操作:解码后**重新生成会话 / 轮次 id**,
    /// 防止重复导入或导回原机时和已有会话冲突。也兼容顶层是会话数组的文件。
    static func parseKown(_ data: Data) throws -> ImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var decoded: [Conversation] = []
        if let one = try? decoder.decode(Conversation.self, from: data) {
            decoded = [one]
        } else if let many = try? decoder.decode([Conversation].self, from: data) {
            decoded = many
        } else {
            throw ImportError.invalidFormat("不是 Kown 导出的会话 JSON")
        }

        var result = ImportResult()
        for conv in decoded {
            if conv.turns.isEmpty && conv.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.skipped += 1
                continue
            }
            result.conversations.append(regenerateIDs(conv))
        }
        return result
    }

    /// 复制会话并换新 id(会话 + 每轮)。providerSnapshot 的 key 是历史快照引用,保持原样即可正确渲染。
    static func regenerateIDs(_ source: Conversation) -> Conversation {
        let turns = source.turns.map { regenerateTurnID($0) }
        return Conversation(
            id: UUID(),
            title: source.title,
            mode: source.mode,
            createdAt: source.createdAt,
            updatedAt: source.updatedAt,
            turns: turns,
            contextSummary: source.contextSummary,
            summarizedThroughTurnCount: source.summarizedThroughTurnCount,
            systemPrompt: source.systemPrompt,
            tags: source.tags,
            structuredSchema: source.structuredSchema,
            translateTargetLanguage: source.translateTargetLanguage,
            translateRewrite: source.translateRewrite,
            compressedContextSummary: source.compressedContextSummary,
            compressedThroughTurnCount: source.compressedThroughTurnCount
        )
    }

    /// 复制一轮并换新 id(其余字段原样保留;图片等引用照搬,文件不存在时 UI 自行降级)。
    private static func regenerateTurnID(_ t: Turn) -> Turn {
        Turn(
            id: UUID(),
            timestamp: t.timestamp,
            prompt: t.prompt,
            systemPrompt: t.systemPrompt,
            responses: t.responses,
            errors: t.errors,
            chairProviderID: t.chairProviderID,
            chairSummary: t.chairSummary,
            chairError: t.chairError,
            summaryProviderID: t.summaryProviderID,
            summaryText: t.summaryText,
            summaryError: t.summaryError,
            providerSnapshot: t.providerSnapshot,
            panelOrder: t.panelOrder,
            debateRounds: t.debateRounds,
            tournamentRounds: t.tournamentRounds,
            appliedWrites: t.appliedWrites,
            images: t.images,
            sources: t.sources,
            reasoningByProvider: t.reasoningByProvider,
            tokenUsage: t.tokenUsage,
            councilVotes: t.councilVotes,
            sourcesByProvider: t.sourcesByProvider,
            generatedImages: t.generatedImages,
            compareVerdict: t.compareVerdict,
            consensusAnalysis: t.consensusAnalysis,
            generatedImagesByProvider: t.generatedImagesByProvider,
            imageGenErrors: t.imageGenErrors,
            selfRevision: t.selfRevision,
            factCheck: t.factCheck,
            knowledgeSources: t.knowledgeSources,
            escalationSuggestion: t.escalationSuggestion,
            toolSteps: t.toolSteps,
            synthesizedConclusion: t.synthesizedConclusion,
            routeNote: t.routeNote,
            autoEscalation: t.autoEscalation
        )
    }

    // MARK: - zip 解压(仅 macOS)

    #if os(macOS)
    /// 用 `/usr/bin/unzip -p` 把导出包里的 `conversations.json` 解到内存
    /// (不落临时文件;-p 输出到 stdout)。包里没有该文件时抛 `zipEntryNotFound`。
    static func extractConversationsJSON(fromZip url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -p:解到 stdout;通配前缀兼容导出包带顶层目录的情况。
        process.arguments = ["-p", url.path, "conversations.json", "*/conversations.json"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        // 先读完 stdout 再 wait,避免大文件把管道写满造成死锁。
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !data.isEmpty else { throw ImportError.zipEntryNotFound }
        return data
    }
    #endif

    // MARK: - 小工具

    /// 导入会话里「对方」的展示快照(不入 providers 列表,仅随 Turn 留痕供渲染显示名)。
    private static func importedSnapshot(id: String, source: Source) -> ProviderConfig {
        ProviderConfig(
            id: UUID(uuidString: id) ?? UUID(),
            displayName: source.assistantDisplayName,
            kind: source == .claude ? .anthropic : .openAICompatible,
            enabled: false
        )
    }

    /// epoch 秒(Double / Int)→ Date。
    private static func epochDate(_ value: Any?) -> Date? {
        if let d = value as? Double { return Date(timeIntervalSince1970: d) }
        if let i = value as? Int { return Date(timeIntervalSince1970: Double(i)) }
        return nil
    }

    /// ISO8601 字符串(带 / 不带小数秒)→ Date。
    private static func isoDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
