import Foundation

/// 一次运行结果摘要 + 它实际发生的时间,构成订阅任务的**历史序列**(走势分析的原料)。
/// 与 `ScheduledTask.lastRunDigest`(只存最近一次)是两套:本结构按时间累积成一串,
/// 供 `TrendDigestService` 喂给 LLM 产出「盯了几周的趋势」而非每日快照。Codable + 加性。
struct DatedDigest: Codable, Hashable, Sendable, Identifiable {
    /// 该次运行的实际发生时间(用任务真正跑完采到结果的时间,不是发火时间)。
    var date: Date
    /// 该次运行结果的摘要(与 lastRunDigest 同口径,~800 字截断)。
    var digest: String

    /// 以时间戳 + 摘要前缀派生稳定 id(SwiftUI ForEach 用;同一条目恒定)。
    var id: String { "\(date.timeIntervalSince1970)-\(digest.prefix(24))" }

    init(date: Date, digest: String) {
        self.date = date
        self.digest = digest
    }
}

/// 一条「定时 / 周期任务」:把一段固定的 prompt 在每天指定时刻自动发出,
/// 结果落成一个新会话,并发一条本地通知提醒用户。
///
/// **重要:仅在 app 运行(前台或被系统短暂保活)期间发火** —— 后台常驻定时执行受 OS 限制
/// (macOS 可后台跑,iOS 被 suspend 后定时器停摆),所以本功能定位为「打开 app 时补跑当天该跑的任务」。
struct ScheduledTask: Identifiable, Codable, Hashable, Sendable {
    /// 任务类型:普通定时提问 vs 主动助理「晨间简报」 vs 订阅式「Agent 任务」。
    /// 简报任务会在发火时即时组装(今日日程 + 长期关注点 + 订阅话题),`prompt` 仅作可选的额外指示。
    /// Agent 任务到点后在后台用「深入模式 + 工具」自主完成 `prompt` 描述的目标,结果落成新会话 + 通知摘要。
    enum Kind: String, Codable, Sendable {
        case plainPrompt        // 固定 prompt 原样发出(旧行为,默认)
        case morningBriefing    // 主动助理:组装日程/记忆/话题成一份简报
        case agentTask          // 订阅式 Agent:带工具自主执行,结果存档 + 通知摘要
    }

    /// 一次运行的结果状态(目前仅 Agent 任务记录;其余任务类型恒为 nil)。
    enum RunStatus: String, Codable, Sendable {
        case running    // 正在执行(到点已发起,还没拿到结果)
        case success    // 上次运行成功
        case failure    // 上次运行失败(模型报错 / 空响应 / 没有可用 provider)
    }

    let id: UUID
    /// 任务名(列表展示用)。
    var title: String
    /// 要发送的 prompt 正文。简报任务里这是「额外指示」,可为空。
    var prompt: String
    /// 任务类型。旧 JSON 没有该字段 → 默认 `.plainPrompt`,完全兼容。
    var kind: Kind
    /// 简报订阅话题(仅 `morningBriefing` 用):每条会被要求「联网/凭知识简报一下最新进展」。
    var briefingTopics: [String]
    /// 用哪个对话模式发(council / direct / compare / debate / structured)。
    var mode: ConversationMode
    /// 触发时刻 — 小时(0...23)。
    var hour: Int
    /// 触发时刻 — 分钟(0...59)。
    var minute: Int
    /// 每天重复。当前实现固定为按天重复(预留位,关掉后即一次性任务)。
    var repeatsDaily: Bool
    /// 每周触发的星期几(Calendar 约定:1=周日 … 7=周六)。nil = 每天触发(默认,沿用旧行为)。
    /// 设了具体星期时,仅当天为该星期 + 到点 + 当天未跑过才发火 → 支持「每周一早上总结」式订阅。
    var weekday: Int?
    /// 是否启用(关掉后不发火)。
    var enabled: Bool
    /// 上次实际发火的时间(用于「当天已跑过就不再重复」判断)。
    var lastRun: Date?

    // MARK: Agent 任务专属配置(仅 `kind == .agentTask` 时生效)

    /// Agent 可用「联网搜索」工具(需用户已在设置里配置好搜索服务)。
    var agentWebSearch: Bool
    /// Agent 可用已启用的 MCP server 工具。
    var agentMCP: Bool
    /// Agent 可用设备工具(提醒事项 / 日历 / 备忘录)。
    var agentDeviceTools: Bool
    /// 深入模式:抬高工具循环上限并注入「规划→执行→自检→交付」Agent 指令。
    var agentDeepMode: Bool
    /// 上次运行的状态(仅 Agent 任务写;running → success/failure)。
    var lastRunStatus: RunStatus?
    /// 上次运行的一句话结果摘要(成功 = 答案摘要;失败 = 错误信息)。
    var lastRunSummary: String?

    // MARK: 增量记忆(所有任务类型通用)

    /// 上次运行**拿到有效结果**的时间。与 `lastRun` 不同:lastRun 是发火时间(失败也写,
    /// 用于「当天已跑过」判断);本字段只在采收到结果时与 `lastRunDigest` 成对写回。
    var lastRunDate: Date?
    /// 上次运行结果的摘要(截断约 800 字)。增量模式下注入下次运行的 prompt,
    /// 让模型聚焦新增与变化,不重复已报告内容。
    var lastRunDigest: String?
    /// 增量模式(默认开):下次运行自动带上上次摘要。关掉则每次都从零开始回答。
    var incrementalMode: Bool

    /// [趋势洞察] 历史运行摘要序列(最新在前),封顶 `maxRunDigestHistory` 条。
    /// SchedulerService 每次采到有效结果时追加一条;`TrendDigestService` 把整串喂 LLM
    /// 产出走势报告。加性 optional —— 旧 JSON 缺该键解出 nil,完全兼容。
    var runDigestHistory: [DatedDigest]?

    /// 历史序列封顶条数(超出从最旧丢弃)。盯一件事几周的体量足够,又不让 JSON 膨胀。
    static let maxRunDigestHistory = 30

    init(
        id: UUID = UUID(),
        title: String = "",
        prompt: String = "",
        kind: Kind = .plainPrompt,
        briefingTopics: [String] = [],
        mode: ConversationMode = .direct,
        hour: Int = 9,
        minute: Int = 0,
        repeatsDaily: Bool = true,
        weekday: Int? = nil,
        enabled: Bool = true,
        lastRun: Date? = nil,
        agentWebSearch: Bool = true,
        agentMCP: Bool = false,
        agentDeviceTools: Bool = false,
        agentDeepMode: Bool = true,
        lastRunStatus: RunStatus? = nil,
        lastRunSummary: String? = nil,
        lastRunDate: Date? = nil,
        lastRunDigest: String? = nil,
        incrementalMode: Bool = true,
        runDigestHistory: [DatedDigest]? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.kind = kind
        self.briefingTopics = briefingTopics
        self.mode = mode
        self.hour = hour
        self.minute = minute
        self.repeatsDaily = repeatsDaily
        self.weekday = weekday
        self.enabled = enabled
        self.lastRun = lastRun
        self.agentWebSearch = agentWebSearch
        self.agentMCP = agentMCP
        self.agentDeviceTools = agentDeviceTools
        self.agentDeepMode = agentDeepMode
        self.lastRunStatus = lastRunStatus
        self.lastRunSummary = lastRunSummary
        self.lastRunDate = lastRunDate
        self.lastRunDigest = lastRunDigest
        self.incrementalMode = incrementalMode
        self.runDigestHistory = runDigestHistory
    }

    // 兼容旧 JSON(缺字段容错,避免整份解码失败丢任务)。
    enum CodingKeys: String, CodingKey {
        case id, title, prompt, kind, briefingTopics, mode, hour, minute, repeatsDaily, weekday, enabled, lastRun
        case agentWebSearch, agentMCP, agentDeviceTools, agentDeepMode, lastRunStatus, lastRunSummary
        case lastRunDate, lastRunDigest, incrementalMode, runDigestHistory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .plainPrompt
        self.briefingTopics = try c.decodeIfPresent([String].self, forKey: .briefingTopics) ?? []
        self.mode = try c.decodeIfPresent(ConversationMode.self, forKey: .mode) ?? .direct
        self.hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 9
        self.minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        self.repeatsDaily = try c.decodeIfPresent(Bool.self, forKey: .repeatsDaily) ?? true
        self.weekday = try c.decodeIfPresent(Int.self, forKey: .weekday)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        self.agentWebSearch = try c.decodeIfPresent(Bool.self, forKey: .agentWebSearch) ?? true
        self.agentMCP = try c.decodeIfPresent(Bool.self, forKey: .agentMCP) ?? false
        self.agentDeviceTools = try c.decodeIfPresent(Bool.self, forKey: .agentDeviceTools) ?? false
        self.agentDeepMode = try c.decodeIfPresent(Bool.self, forKey: .agentDeepMode) ?? true
        self.lastRunStatus = try c.decodeIfPresent(RunStatus.self, forKey: .lastRunStatus)
        self.lastRunSummary = try c.decodeIfPresent(String.self, forKey: .lastRunSummary)
        self.lastRunDate = try c.decodeIfPresent(Date.self, forKey: .lastRunDate)
        self.lastRunDigest = try c.decodeIfPresent(String.self, forKey: .lastRunDigest)
        self.incrementalMode = try c.decodeIfPresent(Bool.self, forKey: .incrementalMode) ?? true
        self.runDigestHistory = try c.decodeIfPresent([DatedDigest].self, forKey: .runDigestHistory)
    }

    /// [趋势洞察] 历史序列(最旧→最新),供趋势分析/图表用。存储里最新在前,这里翻转成时间正序。
    var chronologicalDigestHistory: [DatedDigest] {
        (runDigestHistory ?? []).sorted { $0.date < $1.date }
    }

    /// 是否已有足够样本做趋势分析(至少 2 次运行才能谈「走势」)。
    var hasTrendData: Bool {
        (runDigestHistory?.count ?? 0) >= 2
    }

    /// 是否为简报任务。
    var isBriefing: Bool { kind == .morningBriefing }

    /// 是否为订阅式 Agent 任务。
    var isAgent: Bool { kind == .agentTask }

    /// Agent 任务勾选的工具,中文顿号串(给 UI 展示)。一个都没勾返回「无工具」。
    var agentToolsText: String {
        var names: [String] = []
        if agentWebSearch { names.append("联网搜索") }
        if agentMCP { names.append("MCP") }
        if agentDeviceTools { names.append("设备工具") }
        return names.isEmpty ? "无工具" : names.joined(separator: "、")
    }

    /// 触发时刻的展示文本,如 `09:05`。
    var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// 周期的展示文本:`每天 09:05` / `每周一 09:05`。
    var scheduleText: String {
        if let wd = weekday, let name = Self.weekdayName(wd) {
            return "每\(name) \(timeText)"
        }
        return "每天 \(timeText)"
    }

    /// Calendar weekday(1=周日…7=周六)→ 中文(周日…周六)。越界返回 nil。
    static func weekdayName(_ wd: Int) -> String? {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        guard wd >= 1, wd <= 7 else { return nil }
        return "周" + names[wd - 1]
    }

    /// [增量记忆] 注入下次运行 prompt 的「上次运行回顾」段:
    /// 增量模式开 + 有上次摘要时返回;否则 nil(首跑 / 关增量 / 上次失败没采到摘要)。
    var incrementalPromptBlock: String? {
        guard incrementalMode,
              let digest = lastRunDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
              !digest.isEmpty else { return nil }
        let when: String
        if let d = lastRunDate ?? lastRun {
            let df = DateFormatter()
            df.locale = Locale(identifier: "zh_CN")
            df.dateFormat = "yyyy-MM-dd HH:mm"
            when = df.string(from: d)
        } else {
            when = "此前"
        }
        return """
        【上次运行回顾 · \(when)】
        \(digest)
        ——
        以上是上次运行已报告过的内容。本次请聚焦**上次之后的新增与变化**,不要重复已报告的信息;\
        若没有实质性新进展,请直接说明「与上次相比无明显变化」。
        """
    }
}

/// 定时任务列表持久化:`syncedDataDir/scheduled-tasks.json`(随 iCloud 同步)。
/// 同 `ConversationFolderStore` 的 @MainActor + JSONEncoder + .atomic 模式。
@MainActor
enum ScheduledTaskStore {
    private static var url: URL {
        Platform.syncedDataDir.appendingPathComponent("scheduled-tasks.json")
    }

    static func load() -> [ScheduledTask] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ScheduledTask].self, from: data) else { return [] }
        return list
    }

    static func save(_ tasks: [ScheduledTask]) {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
