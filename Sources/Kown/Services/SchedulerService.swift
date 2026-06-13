import Foundation
import Observation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// 简易定时任务调度器。**仅在 app 运行(前台或被系统短暂保活)期间发火**:
/// 后台常驻定时受 OS 限制(macOS 可后台跑,iOS 被 suspend 后定时器停摆),
/// 所以本服务定位为「app 运行时每 60 秒检查一次,补跑当天到点且未跑过的任务」。
///
/// 发火 = 用任务里的 prompt + mode 新建一个会话并发送(走 `AppViewModel` 既有发送流程),
/// 更新该任务的 `lastRun`,并发一条本地通知提醒用户。
@Observable
@MainActor
final class SchedulerService {
    static let shared = SchedulerService()

    /// 任务列表(最新添加的在最前)。设置页与本服务共享(同 `MemoryStore.shared` 模式)。
    private(set) var tasks: [ScheduledTask]

    /// 绑定的 AppViewModel(start 时注入)。发火时用它新建会话 + 发送。
    private weak var viewModel: AppViewModel?

    /// 检查定时器(每 60 秒一次)。
    private var timer: Timer?

    /// 是否已申请过通知权限(惰性,首次设置任务时申请)。
    private var permissionAsked = false

    /// [增量记忆] 待采收的运行结果:会话 ID → 任务 ID。
    /// 普通 / 简报任务走 `vm.send()` 既有管线,本服务拿不到完成回调 —— 发火时登记,
    /// 之后每个巡检 tick 检查该会话是否已落盘第一轮,完成后把答案摘要写回任务。
    /// 仅存内存:app 中途退出最多丢一次摘要,下次运行退化为全量,无害。
    private var pendingDigestHarvests: [UUID: UUID] = [:]

    private init() {
        self.tasks = ScheduledTaskStore.load()
    }

    // MARK: - 生命周期

    /// 启动调度:注入 viewModel,跑一次即时检查,并起每 60 秒的定时器。重复调用安全(先停旧定时器)。
    func start(viewModel: AppViewModel) {
        self.viewModel = viewModel
        // 通知点按路由:点开「Agent 任务完成」通知时定位到结果会话。
        UNUserNotificationCenter.current().delegate = SchedulerNotificationDelegate.shared
        // 上次 app 退出时还在跑的 Agent 任务永远等不到结果了:把滞留的「运行中」改判为失败留痕,
        // 否则列表会永远显示「运行中」误导用户。
        var staleFixed = false
        for idx in tasks.indices where tasks[idx].lastRunStatus == .running {
            tasks[idx].lastRunStatus = .failure
            tasks[idx].lastRunSummary = "上次运行中断(app 中途退出),未拿到结果"
            staleFixed = true
        }
        if staleFixed { persist() }
        timer?.invalidate()
        // 启动即检查一次(补跑「app 没开着时错过、但今天还没跑」的到点任务)。
        checkAndFire()
        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAndFire() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - CRUD(设置页用)

    /// 重新从磁盘载入(iCloud 同步拉到新文件后调用)。
    func reload() {
        tasks = ScheduledTaskStore.load()
    }

    private func persist() {
        ScheduledTaskStore.save(tasks)
    }

    /// 添加一条任务(最新在前)。首次添加时申请通知权限。
    func add(_ task: ScheduledTask) {
        ensureNotificationPermission()
        tasks.insert(task, at: 0)
        persist()
    }

    /// 整条覆盖更新(编辑保存用)。
    func update(_ task: ScheduledTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx] = task
        persist()
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    /// 切换启用状态。
    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].enabled = enabled
        persist()
    }

    // MARK: - 调度核心

    /// 检查所有任务,把「启用 + 已到今天的触发时刻 + 当天还没跑过」的逐个发火。
    /// 顺带采收上一轮已完成的运行结果摘要(增量记忆)。
    func checkAndFire() {
        harvestPendingDigests()
        let now = Date()
        let cal = Calendar.current
        for task in tasks where task.enabled {
            guard isDue(task, now: now, calendar: cal) else { continue }
            fire(task, now: now)
        }
    }

    /// 是否到点该发火:当前时间 >= 今天的 HH:mm,且 lastRun 不是今天(或 lastRun 早于今天的触发点)。
    private func isDue(_ task: ScheduledTask, now: Date, calendar cal: Calendar) -> Bool {
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = task.hour
        comps.minute = task.minute
        comps.second = 0
        guard let fireToday = cal.date(from: comps) else { return false }
        // 每周任务:今天的星期几必须匹配,否则跳过。
        if let wd = task.weekday {
            let today = cal.component(.weekday, from: now)
            guard today == wd else { return false }
        }
        // 还没到今天的触发时刻 → 不发。
        guard now >= fireToday else { return false }
        // 今天已经跑过(lastRun 落在今天触发点之后)→ 不重复。
        if let last = task.lastRun, last >= fireToday { return false }
        return true
    }

    /// 真正发火:用任务的 prompt + mode 新建会话并发送;更新 lastRun;发本地通知。
    /// 简报任务(`morningBriefing`)需异步组装(读日历是 async),故整段发送放进 `Task`。
    /// Agent 任务(`agentTask`)走独立的后台执行管线(不占用 / 打断用户当前的发送)。
    private func fire(_ task: ScheduledTask, now: Date) {
        // 任务可能来自 iCloud 同步(本机从未走过 add()),发火前兜底申请一次通知权限(已授权时是无感 no-op)。
        ensureNotificationPermission()
        // 先标记 lastRun,避免同一分钟内定时器再次触发重复发(即便发送失败也算「今天已尝试」)。
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].lastRun = now
            persist()
        }

        if task.kind == .agentTask {
            fireAgentTask(task, now: now)
            return
        }

        let vm = viewModel
        Task { @MainActor [weak self] in
            let promptText: String
            switch task.kind {
            case .morningBriefing:
                promptText = await Self.buildBriefingPrompt(task: task)
            case .plainPrompt, .agentTask:
                // [增量记忆] 固定 prompt 后附「上次运行回顾」,引导只报新增与变化。
                let base = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if base.isEmpty {
                    promptText = ""
                } else if let inc = task.incrementalPromptBlock {
                    promptText = base + "\n\n" + inc
                } else {
                    promptText = base
                }
            }
            if let vm, !promptText.isEmpty {
                // 新建该模式会话 → 填 prompt → 走既有发送流程。
                vm.newConversation(mode: task.mode)
                // 晨报会话登记:回答完成后由 WidgetBridge 提取要点发布到 iOS 桌面小组件。
                if task.kind == .morningBriefing {
                    WidgetBridge.pendingBriefingConversationID = vm.selectedConversationID
                }
                vm.prompt = promptText
                vm.send()
                // [增量记忆] 登记结果采收:回答落盘后(下个巡检 tick)把答案摘要写回任务。
                if let self, let convID = vm.selectedConversationID {
                    self.pendingDigestHarvests[convID] = task.id
                }
            }
        }

        notify(task: task)
    }

    // MARK: - 晨间简报组装

    /// 把今日日程 + 长期关注点 + 订阅话题拼成一份简报 prompt。各部分缺失时优雅跳过。
    /// 纯组装,不直接调模型 —— 拼好后交给 `vm.send()` 走既有发送流程。
    static func buildBriefingPrompt(task: ScheduledTask) async -> String {
        var sections: [String] = []

        // 1) 今日日程(读系统日历;未授权/无日程则跳过)。
        #if canImport(EventKit)
        let events = await EventKitService.shared.listEvents(daysAhead: 1, limit: 20)
        if !events.isEmpty {
            let df = DateFormatter()
            df.locale = Locale(identifier: "zh_CN")
            df.dateFormat = "HH:mm"
            let lines = events.map { e -> String in
                let t = e.start.map { df.string(from: $0) } ?? "全天"
                let loc = (e.location?.isEmpty == false) ? " @ \(e.location!)" : ""
                return "- \(t) \(e.title)\(loc)"
            }
            sections.append("【今日日程】\n" + lines.joined(separator: "\n"))
        }
        #endif

        // 2) 长期关注点 / 偏好(来自跨会话沉淀的记忆)。
        let mem = MemoryStore.shared.items.prefix(12).map { "- " + $0.text }
        if !mem.isEmpty {
            sections.append("【我的长期关注点 / 偏好】\n" + mem.joined(separator: "\n"))
        }

        // 3) 订阅话题。
        let topics = task.briefingTopics
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !topics.isEmpty {
            sections.append("【我订阅的话题(请逐条简报最新进展)】\n"
                + topics.map { "- " + $0 }.joined(separator: "\n"))
        }

        // 4) 用户的额外指示(可选)。
        let extra = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            sections.append("【额外指示】\n" + extra)
        }

        // 5) [增量记忆] 上次简报回顾:订阅话题只报新增与变化,不重复昨天已讲过的。
        if let inc = task.incrementalPromptBlock {
            sections.append(inc)
        }

        let context = sections.isEmpty
            ? "(暂无日程 / 关注点 / 话题数据)"
            : sections.joined(separator: "\n\n")

        return """
        你是我的私人晨间助理。请基于下面的资料,给我写一份简短、可执行的「今日晨报」:
        1. 先用一句话概括今天的重点;
        2. 若有日程,按时间梳理并提醒可能的冲突或需提前准备的事项;
        3. 若有订阅话题,逐条给最新进展 / 值得关注的点(可联网核实);
        4. 结尾给 1-3 条今天的小建议。
        语气简洁友好,用中文,控制在合理篇幅,不要复述原始资料。

        ===== 今日资料 =====
        \(context)
        """
    }

    // MARK: - Agent 任务执行

    /// 一次 Agent 运行收集到的全部产物(在后台流式循环里累积,完成后整体带回主线程归档)。
    struct AgentRunResult: Sendable {
        var text = ""
        var reasoning = ""
        var toolSteps: [ToolStep] = []
        var sources: [SourceRef] = []
        var inputTokens = 0
        var outputTokens = 0
        var cachedInputTokens = 0
        var error: String? = nil
    }

    /// 到点执行一个 Agent 任务:按任务勾选的工具组装工具集,在后台跑「深入模式」工具循环,
    /// 结果落成一个新会话(标题 = 任务名 + 日期,工具步骤树一并存档),并发带结果摘要的本地通知。
    /// 失败同样留痕:会话里记错误 + 通知里说明原因,绝不静默。
    private func fireAgentTask(_ task: ScheduledTask, now: Date) {
        let taskID = task.id
        let taskTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = taskTitle.isEmpty ? "Agent 任务" : taskTitle
        let promptText = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !promptText.isEmpty else {
            setRunResult(taskID, status: .failure, summary: "任务没有填写指令,无法执行")
            notifyAgentResult(taskTitle: displayTitle, success: false,
                              summary: "任务没有填写指令,请编辑任务补上要做的事", conversationID: nil)
            return
        }
        // [增量记忆] 目标后附「上次运行回顾」,Agent 聚焦上次之后的新增与变化。
        let fullPrompt = task.incrementalPromptBlock.map { promptText + "\n\n" + $0 } ?? promptText
        guard let vm = viewModel else { return }
        // 选执行模型:优先第一个启用的非 CLI provider(CLI 沙箱差异大且不支持工具循环),兜底任意启用项。
        guard let provider = vm.providers.first(where: { $0.enabled && !$0.kind.isCLI })
                ?? vm.providers.first(where: \.enabled) else {
            setRunResult(taskID, status: .failure, summary: "没有可用的模型(请先启用一个 Provider)")
            notifyAgentResult(taskTitle: displayTitle, success: false,
                              summary: "没有可用的模型,请先在设置里启用一个 Provider", conversationID: nil)
            return
        }

        // 主线程只做轻量快照:API key / 联网会话 / MCP server 配置 / 工具集。
        let apiKey = provider.kind.isCLI ? "" : ((try? KeychainStore.load(id: provider.id)) ?? "")
        let webSession: WebSearchSession? = task.agentWebSearch
            ? WebSearchSession.makeIfReady(userToggle: true) : nil
        let mcpServers: [MCPServerConfig] = task.agentMCP ? vm.mcpStore.enabledServers : []
        let baseTools = ToolCatalog.enabledTools(
            webSearch: webSession,
            deviceTools: task.agentDeviceTools,
            extraToolNames: [])
        let deep = task.agentDeepMode
        let providerSnapshot = provider

        setRunResult(taskID, status: .running, summary: nil)

        Task { @MainActor [weak self] in
            // MCP 连接(网络 / 子进程)与流式循环都是 async,await 期间不占主线程。
            var tools = baseTools
            var ctx = ToolContext(webSearch: webSession)
            var mcpSession: MCPSession? = nil
            if !mcpServers.isEmpty, let mcp = await MCPSession.connect(servers: mcpServers) {
                mcpSession = mcp
                tools.append(contentsOf: mcp.tools)
                ctx.mcp = mcp
            }
            var options = ChatOptions(
                systemPrompt: nil,
                temperature: providerSnapshot.temperature,
                maxTokens: providerSnapshot.maxTokens)
            options.tools = tools
            // 没有任何工具可用时不建 context(客户端据此跳过工具循环);Agent 退化为一次普通深入回答。
            options.toolContext = tools.isEmpty ? nil : ctx
            options.maxToolRounds = deep ? 12 : 6
            options.agentInstruction = deep ? AppViewModel.deepAgentInstruction : nil

            // 流式收集在后台 executor 跑(nonisolated static),不碰主线程。
            let result = await Self.collectAgentRun(
                prompt: fullPrompt, provider: providerSnapshot, apiKey: apiKey, options: options)
            if let mcp = mcpSession { await mcp.closeAll() }

            self?.archiveAgentRun(
                taskID: taskID, taskTitle: displayTitle, prompt: fullPrompt,
                provider: providerSnapshot, result: result, firedAt: now)
        }
    }

    /// 在后台 executor 跑一次带工具循环的流式调用,把文本 / 思考 / 工具步骤 / 来源 / 用量全部收集回来。
    /// 错误不抛出,统一写进 `result.error`(调用方据此留痕 + 通知)。
    nonisolated private static func collectAgentRun(
        prompt: String,
        provider: ProviderConfig,
        apiKey: String,
        options: ChatOptions
    ) async -> AgentRunResult {
        var result = AgentRunResult()
        let client = ProviderRegistry.client(for: provider.kind)
        do {
            for try await chunk in client.stream(prompt: prompt, options: options, config: provider, apiKey: apiKey) {
                switch chunk {
                case .text(let t):
                    // 封顶(CPU / 内存不变量):异常超长输出直接截断,避免后续归档 / 渲染被拖死。
                    if result.text.count < 400_000 { result.text += t }
                case .reasoning(let r):
                    if result.reasoning.count < 80_000 { result.reasoning += r }
                case .toolEvent:
                    break
                case .toolStep(let step):
                    // 按 id upsert:running → done/error 更新到同一步(与 ResponseState.upsertToolStep 同语义)。
                    if let idx = result.toolSteps.firstIndex(where: { $0.id == step.id }) {
                        result.toolSteps[idx] = step
                    } else {
                        result.toolSteps.append(step)
                    }
                case .sources(let refs):
                    let known = Set(result.sources.map(\.url))
                    result.sources.append(contentsOf: refs.filter { !known.contains($0.url) })
                case .usage(let input, let output, let cached):
                    result.inputTokens = max(result.inputTokens, input)
                    result.outputTokens = max(result.outputTokens, output)
                    result.cachedInputTokens = max(result.cachedInputTokens, cached)
                }
            }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    /// 把一次 Agent 运行归档:建会话(含工具步骤树 / 来源 / 思考 / 用量)插进侧栏 + 落盘,
    /// 更新任务的运行状态,并发带摘要的本地通知(点开定位到该会话)。失败也走同一条路留痕。
    private func archiveAgentRun(
        taskID: UUID,
        taskTitle: String,
        prompt: String,
        provider: ProviderConfig,
        result: AgentRunResult,
        firedAt: Date
    ) {
        let pid = provider.id.uuidString
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var responses: [String: String] = [:]
        var errors: [String: String] = [:]
        if !text.isEmpty { responses[pid] = result.text }
        if let err = result.error {
            errors[pid] = err
        } else if text.isEmpty {
            errors[pid] = "(空响应)"
        }

        let turn = Turn(
            timestamp: firedAt,
            prompt: prompt,
            systemPrompt: "",
            responses: responses,
            errors: errors,
            providerSnapshot: [pid: provider],
            panelOrder: [pid],
            sources: result.sources.isEmpty ? nil : result.sources,
            reasoningByProvider: result.reasoning.isEmpty ? nil : [pid: result.reasoning],
            tokenUsage: (result.inputTokens > 0 || result.outputTokens > 0)
                ? [pid: TurnTokenUsage(input: result.inputTokens, output: result.outputTokens,
                                       cachedInput: result.cachedInputTokens)]
                : nil,
            toolSteps: result.toolSteps.isEmpty ? nil : result.toolSteps
        )

        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd"
        var conv = Conversation(
            title: "\(taskTitle) \(df.string(from: firedAt))",
            mode: .direct,
            turns: [turn]
        )
        conv.updatedAt = Date()
        // 插进侧栏但不抢焦点(用户可能正在别的会话里工作);通知点开时再跳转。
        viewModel?.conversations.insert(conv, at: 0)
        ConversationStore.save(conv)

        // 记一笔用量(成本面板);UsageStore 是 @MainActor,在这里(主线程)记。
        if result.inputTokens > 0 || result.outputTokens > 0 {
            UsageStore.shared.record(
                providerKind: provider.kind,
                model: provider.model,
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens,
                cachedTokens: result.cachedInputTokens)
        }

        let success = (result.error == nil) && !text.isEmpty
        let summary = success
            ? Self.oneLineSummary(text)
            : (result.error ?? "模型返回了空响应")
        setRunResult(taskID, status: success ? .success : .failure, summary: summary)
        // [增量记忆] 成功的运行写回「完成时间 + 结果摘要(~800 字)」;失败不覆盖上次有效摘要。
        if success {
            setLastRunDigest(taskID, digest: Self.makeDigest(text), date: Date())
        }
        notifyAgentResult(taskTitle: taskTitle, success: success, summary: summary, conversationID: conv.id)
    }

    /// 更新任务的「上次运行状态 + 一句话摘要」(列表展示用)并落盘。
    private func setRunResult(_ id: UUID, status: ScheduledTask.RunStatus, summary: String?) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].lastRunStatus = status
        tasks[idx].lastRunSummary = summary
        persist()
    }

    // MARK: - 增量记忆(结果摘要写回 + 采收)

    /// 写回一次运行的「完成时间 + 结果摘要」(增量模式下注入下次运行)并落盘。
    /// [趋势洞察] 同时把 (时间, 摘要) 追到历史序列(最新在前,封顶 `maxRunDigestHistory` 条),
    /// 供 `TrendDigestService` 产出走势报告。空摘要不入历史(失败轮已在上游被挡)。
    private func setLastRunDigest(_ id: UUID, digest: String, date: Date) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].lastRunDate = date
        tasks[idx].lastRunDigest = digest
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var history = tasks[idx].runDigestHistory ?? []
            history.insert(DatedDigest(date: date, digest: digest), at: 0)
            if history.count > ScheduledTask.maxRunDigestHistory {
                history.removeLast(history.count - ScheduledTask.maxRunDigestHistory)
            }
            tasks[idx].runDigestHistory = history
        }
        persist()
    }

    /// 采收普通 / 简报任务的运行结果:发火时登记的会话一旦落盘了第一轮,
    /// 就把最佳答案截成摘要写回任务。失败轮(没有任何答案文本)不覆盖上次有效摘要。
    private func harvestPendingDigests() {
        guard !pendingDigestHarvests.isEmpty, let vm = viewModel else { return }
        for (convID, taskID) in pendingDigestHarvests {
            guard let conv = vm.conversations.first(where: { $0.id == convID }) else {
                pendingDigestHarvests.removeValue(forKey: convID)   // 会话被删 → 放弃采收
                continue
            }
            // 任务发火时新建的会话,第一轮即任务结果;还没落盘说明仍在跑,下个 tick 再看。
            guard let turn = conv.turns.first else { continue }
            pendingDigestHarvests.removeValue(forKey: convID)
            let answer = Self.bestAnswerText(turn)
            guard !answer.isEmpty else { continue }
            setLastRunDigest(taskID, digest: Self.makeDigest(answer), date: turn.timestamp)
        }
    }

    /// 一轮的最佳答案文本:主持人综合 > 总结列 > 第一个非空回答。全空(失败轮)返回 ""。
    private static func bestAnswerText(_ turn: Turn) -> String {
        if let s = turn.chairSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        if let s = turn.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        for key in turn.panelOrder {
            if let t = turn.responses[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
        }
        return ""
    }

    /// 把运行结果截成可注入的摘要:保留段落结构,截断到约 `maxChars` 字。
    nonisolated static func makeDigest(_ text: String, maxChars: Int = 800) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxChars else { return t }
        return String(t.prefix(maxChars)) + "…"
    }

    /// 把多行回答压成一行摘要(通知正文 / 列表用):合并空白、去掉常见 Markdown 记号、截断到 100 字。
    nonisolated static func oneLineSummary(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count > 100 ? String(collapsed.prefix(100)) + "…" : collapsed
    }

    /// 发 Agent 任务的结果通知:正文带一句结果摘要;userInfo 带会话 ID,点开跳转到该会话。
    private func notifyAgentResult(taskTitle: String, success: Bool, summary: String, conversationID: UUID?) {
        let content = UNMutableNotificationContent()
        content.title = success ? "Agent 任务完成" : "Agent 任务失败"
        let line = summary.isEmpty ? (success ? "已生成结果" : "运行失败") : summary
        content.body = "「\(taskTitle)」\(line)"
        content.sound = .default
        if let id = conversationID {
            content.userInfo = [SchedulerNotificationDelegate.conversationIDKey: id.uuidString]
        }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    /// 通知点开后跳转到结果会话(由 `SchedulerNotificationDelegate` 调用)。
    func openConversationFromNotification(_ id: UUID) {
        guard let vm = viewModel, vm.conversations.contains(where: { $0.id == id }) else { return }
        vm.selectConversation(id)
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    // MARK: - 本地通知

    /// 首次需要时申请通知权限(惰性,跨平台)。
    func ensureNotificationPermission() {
        guard !permissionAsked else { return }
        permissionAsked = true
        // @Sendable:本类是 @MainActor,裸闭包会继承隔离,通知中心在后台队列回调时会执行器断言崩溃。
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }
    }

    /// 发一条本地通知,告知该定时任务已触发。
    private func notify(task: ScheduledTask) {
        let content = UNMutableNotificationContent()
        content.title = task.isBriefing ? "晨间简报已生成" : "定时任务已触发"
        let name = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.isBriefing {
            content.body = name.isEmpty
                ? "今日晨报已为你准备好(\(task.timeText))"
                : "「\(name)」已生成(\(task.timeText))"
        } else {
            content.body = name.isEmpty
                ? "已自动发送一条定时提问(\(task.timeText))"
                : "「\(name)」已自动发送(\(task.timeText))"
        }
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }
}

/// 本地通知的点按路由:Agent 任务结果通知 userInfo 里带会话 ID,点开后跳转到该会话。
/// 同时让通知在 app 前台时也能以横幅形式展示(否则前台默认不显示)。
final class SchedulerNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    // 无任何可变状态(@unchecked Sendable 安全):跳转逻辑全部 hop 回 MainActor 执行。
    static let shared = SchedulerNotificationDelegate()
    /// 通知 userInfo 里携带目标会话 ID 的 key。
    static let conversationIDKey = "kownConversationID"

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let idString = response.notification.request.content
            .userInfo[Self.conversationIDKey] as? String
        if let idString, let id = UUID(uuidString: idString) {
            Task { @MainActor in
                SchedulerService.shared.openConversationFromNotification(id)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
