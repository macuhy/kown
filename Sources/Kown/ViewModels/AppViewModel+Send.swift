import Foundation

// 发送 / 重试 / 流式编排 —— 从 AppViewModel 抽出的「SendCoordinator」关注点(同类型扩展,
// 不改 View 绑定:liveStates 等仍在 AppViewModel 上)。纯粹按职责分文件,零行为变化。
extension AppViewModel {
    /// 预算闸文案:本月累计成本达到「上限 × 阈值%」时返回提示;未设上限或未达阈值返回 nil。
    /// 读 @AppStorage 同 key(kown.budget.*),直接走 UserDefaults(ViewModel 非 View)。
    func budgetGateMessage() -> (message: String, hard: Bool)? {
        let cap = UserDefaults.standard.double(forKey: "kown.budget.monthlyCapUSD")
        guard cap > 0 else { return nil }
        let warnPct = (UserDefaults.standard.object(forKey: "kown.budget.warnPercent") as? Int) ?? 80
        let spent = UsageStore.shared.monthToDateCostUSD()
        guard spent >= cap * Double(warnPct) / 100.0 else { return nil }
        let pct = Int((spent / cap * 100).rounded())
        if spent >= cap {
            return (String(format: "本月已用 $%.2f,已超出预算上限 $%.2f(%d%%)。仍要继续发送吗?", spent, cap, pct), true)
        }
        return (String(format: "本月已用 $%.2f / 上限 $%.2f(%d%%),已接近预算。仍要继续发送吗?", spent, cap, pct), false)
    }

    /// 用户在预算提醒里点「仍要发送」:跳过本次预算闸并重发。
    func confirmBudgetAndSend() {
        budgetGate = nil
        bypassBudgetOnce = true
        send()
    }

    // MARK: - 自动升级建议(建议式)的重答动作

    /// 「换更强模型重答」:用同一 prompt 在当前 Direct 会话里再发一轮,本次把模型强制升到旗舰档。
    func escalateToStrongerModel(turnID: UUID) {
        guard let conv = conversations.first(where: { $0.id == selectedConversationID }),
              let turn = conv.turns.first(where: { $0.id == turnID }) else { return }
        forceFlagshipOnce = true
        prompt = turn.prompt
        send()
    }

    /// 「转 Council 重答」:用同一 prompt 新建一个 Council 会话再问一遍(会话模式固定,故新建会话)。
    func escalateToCouncil(turnID: UUID) {
        guard let conv = conversations.first(where: { $0.id == selectedConversationID }),
              let turn = conv.turns.first(where: { $0.id == turnID }) else { return }
        let p = turn.prompt
        newConversation(mode: .council)
        prompt = p
        send()
    }

    /// 深入模式注入到 system prompt 最前面的 Agent 指令:规划 → 多轮工具 → 自检 → 交付。
    static let deepAgentInstruction = """
    你现在处于「深入模式」,作为一个自主 Agent 工作。请按以下方式完成用户的任务:
    1. 规划:先想清楚要达成的目标,把它拆成几个步骤(复杂任务才需要明说计划)。
    2. 执行:主动、多次使用可用的工具(联网搜索 / 读写文件 / MCP 工具 / 日历提醒等)收集事实与证据,\
    不要凭记忆臆断可验证的信息;一个工具不够就接着调下一个,直到信息足够。
    3. 自检:给出结论前,回看已有证据是否真的支撑结论,有没有遗漏、矛盾或没核实的关键点;不够就继续调工具补齐。
    4. 交付:给出完整、准确、可执行的最终答案,并在结尾用一句话说明你做了哪些核查、置信度如何。
    在目标真正达成前不要轻易停下;但也不要无意义地重复调用工具。
    """

    func send() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var (panel, chair) = providersForCurrentSend()
        guard !panel.isEmpty else { return }

        // 成本预算闸:本月花费接近/超过上限时先弹确认。bypassBudgetOnce 让确认后的重发跳过本检查。
        if bypassBudgetOnce {
            bypassBudgetOnce = false
        } else if let gate = budgetGateMessage() {
            budgetGate = BudgetGate(message: gate.message, isHardLimit: gate.hard)
            return
        }

        // Persona:会话激活的 Agent 档案(系统提示 / 技能 / 工具开关 / 知识库 / 模型覆盖)。
        // 解析成快照后在下方各注入点消费;模型覆盖仅单模型路径(Direct/Translate)生效,先于自动路由。
        let personaFx = personaEffectsForSend()
        panel = personaFx.applyingModelOverride(to: panel, mode: currentMode)

        // Direct 模式 + 自动路由:按问题难度在当前 provider 的 vendor 内换 model(便宜↔旗舰)。
        // 本地胜率榜样本足够时走学习型成本路由(同档位选「胜率相当且更便宜」,带中文理由落盘展示);
        // 样本不足时 CostRouter 内部回退静态规则,行为与原 QuestionRouter 完全一致(reason = nil)。
        var routeNoteForSend: String? = nil
        if autoRouteEnabled, currentMode == .direct, let first = panel.first {
            let routed = CostRouter.route(first, prompt: trimmed)
            if routed.changed { panel[0] = routed.config }
            routeNoteForSend = routed.reason
        }
        // 「换更强模型重答」:本次发送把 Direct panel[0] 强制换成该 vendor 的旗舰档(发完即复位)。
        if forceFlagshipOnce {
            forceFlagshipOnce = false
            if currentMode == .direct, let first = panel.first,
               let flagship = QuestionRouter.routedModel(for: first, difficulty: .hard),
               flagship != first.model {
                var c = first; c.model = flagship; panel[0] = c
            }
        }

        // 省钱级联(实验,仅 Direct):本轮实际要用的模型不是旗舰档、且该 vendor 有旗舰可升时,
        // 预先算好「裁判 + 旗舰档配置 + 阈值」,初答完成后由 runSend 打分并按需自动升级重答。
        var cascadePlanForSend: CostRouter.CascadePlan? = nil
        if costCascadeEnabled, currentMode == .direct, let first = panel.first, !first.kind.isCLI,
           ModelTier.heuristic(first.model) != .flagship,
           let flagship = QuestionRouter.routedModel(for: first, difficulty: .hard),
           flagship != first.model {
            let judge = chairProvider.flatMap { ($0.enabled && !$0.kind.isCLI) ? $0 : nil }
                ?? providers.first(where: { $0.enabled && !$0.kind.isCLI })
            if let judge {
                var fl = first
                fl.model = flagship
                cascadePlanForSend = CostRouter.CascadePlan(
                    judge: judge, flagship: fl, threshold: CostRouter.defaultCascadeThreshold)
            }
        }

        // 没有当前会话就新建
        if selectedConversationID == nil {
            newConversation(mode: activeMode)
        }
        guard let convIdx = conversations.firstIndex(where: { $0.id == selectedConversationID }) else { return }

        // Structured 模式:发送前校验本会话的 JSON Schema,不合法直接拦截(不清空输入),把错误透出给 UI。
        if currentMode == .structured {
            let schema = conversations[convIdx].structuredSchema ?? StructuredOutput.defaultSchema
            if let err = StructuredOutput.schemaError(schema) {
                structuredSchemaError = err
                return
            }
            structuredSchemaError = nil
        }

        // ---- send():采集 live 输入 + 算 snapshot,把发送编排交给 runSend ----
        // 把文件附件文本拼到 prompt 前面；图片走 options.images
        let fileBlocks = attachments.compactMap { att -> String? in
            switch att {
            case .file(let f):
                return "<attached file=\"\(f.name)\">\n\(f.content)\n</attached>"
            case .pdf(let p):
                return "<attached pdf=\"\(p.name)\" pages=\(p.pageCount)>\n\(p.extractedText)\n</attached>"
            case .image:
                return nil
            }
        }
        let imagePayloads = attachments.compactMap { att -> Attachment.ImagePayload? in
            if case .image(let i) = att { return i }
            return nil
        }
        let composedPrompt: String
        if fileBlocks.isEmpty {
            composedPrompt = trimmed
        } else {
            composedPrompt = fileBlocks.joined(separator: "\n\n") + "\n\n" + trimmed
        }

        let promptSnapshot = composedPrompt
        // Workspace / 知识库 / 长期记忆 的上下文打包**挪到后台**(见 runSend → assembleSystemPrompt):
        // 扫文件树 / 本地 RAG(切块+NLEmbedding)/ 记忆 BM25 在大输入上能卡主线程 0.5–2s。
        // 这里只在主线程捕获**轻量**的原始输入,真正的打包在 runSend 的后台任务里做。
        let workspaceURLForSend = currentWorkspaceURL          // 双用途:① 上下文打包 ② kown:write 落盘
        // GitHub 写入目标:本会话绑定了仓库且已连接 GitHub 时启用(与本地 workspace 互斥,本地优先)。
        let gitHubTargetForSend: GitHubWriteTarget? = (workspaceURLForSend == nil)
            ? GitHubWriteTarget.make(
                repoFullName: conversations[convIdx].gitHubRepo,
                branch: conversations[convIdx].gitHubBranch,
                token: GitHubAuth.token())
            : nil
        // 知识库:会话自己绑定的优先;其次 Persona 绑定的资料夹;最后回退所属项目空间绑定的资料夹。
        let knowledgeFolderForSend = currentKnowledgeFolder ?? personaFx.knowledgeFolder
            ?? projectKnowledgeFolder(of: conversations[convIdx])
        // memory items 取一份快照(O(1) COW),供后台 BM25 打分,避免触碰 @MainActor 的 MemoryStore。
        let memoryItemsForSend: [MemoryItem] = memoryInjectionEnabled ? MemoryStore.shared.items : []
        let memoryQueryForSend: String? = memoryInjectionEnabled ? trimmed : nil
        // 跨对话召回:取 conversations 值快照(COW,O(1)),后台用纯函数打分。排除当前会话避免自召回。
        let recallCorpusForSend: [Conversation] = recallEnabled ? conversations : []
        let recallQueryForSend: String? = recallEnabled ? trimmed : nil
        let recallExcludeID = conversations[convIdx].id
        // 生效技能:手动绑定优先,否则(开了自动触发时)按输入启发式路由。
        let manualSkill = skillsStore.skill(id: conversations[convIdx].selectedSkillID)
        let activeSkill: Skill? = manualSkill
            ?? (skillAutoTriggerEnabled
                ? SkillRouter.match(prompt: trimmed, skills: skillsStore.enabledSkills)
                : nil)
        // 命中自动技能时记一笔,供 UI 显示当前生效技能徽标(手动绑定不覆盖)。
        autoTriggeredSkillID = (manualSkill == nil) ? activeSkill?.id : nil
        let skillInstructions = activeSkill.map { skillsStore.render($0, values: [:]) } ?? ""
        // Translate 模式:把翻译/改写指令前置进 system prompt(目标语言 + 是否润色取会话级设置)。
        let translateInstruction: String = (currentMode == .translate)
            ? PromptBuilders.buildTranslateInstruction(
                targetLanguage: conversations[convIdx].translateTargetLanguage
                    ?? UserDefaults.standard.string(forKey: Self.translateLangKey),
                rewrite: conversations[convIdx].translateRewrite)
            : ""
        // 基础系统提示(翻译指令 → Persona(提示词+绑定技能) → 技能 → 会话级 / 项目级 / 全局);
        // 优先级:会话级显式设置 > 项目空间的项目级提示 > 全局默认。上下文片段在后台前置到它前面。
        let baseSystemPrompt: String = {
            let convPrompt = conversations[convIdx].systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectPrompt = projectFolder(of: conversations[convIdx])?
                .projectSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            let base: String
            if let convPrompt, !convPrompt.isEmpty {
                base = convPrompt
            } else if let projectPrompt, !projectPrompt.isEmpty {
                base = projectPrompt
            } else {
                base = systemPrompt
            }
            return [translateInstruction, personaFx.systemPromptPrefix, skillInstructions, base]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }()
        let imageSnapshot = imagePayloads
        // 把本轮图片字节落盘到同步目录,拿到轻量引用 → 历史里能看到 + 随 iCloud 同步。
        let turnImages = persistTurnImages(imageSnapshot)
        // 上下文摘要 + 最近原文多轮:摘要进 system prompt;原文进真正的 messages[user/assistant]
        let contextSummarySnapshot = ConversationSummarizer.summaryForNextSend(conversations[convIdx])
        let priorTurnsSnapshot = ConversationSummarizer.priorTurnsForReplay(conversations[convIdx])
        // 工具集:web_search(开 🌐 + Firecrawl 已配置)+ 设备工具(总开关或当前技能点名)。
        // Persona 激活时其默认工具开关与输入栏开关取「或」(自动点亮,只增不减)。
        let webSessionSnapshot = WebSearchSession.makeIfReady(
            userToggle: webSearchEnabledForNextSend || personaFx.webSearch)
        let skillToolNames = Set(activeSkill?.allowedTools ?? []).union(personaFx.extraToolNames)
        // 本地文件工具(macOS):开关开 + 已授权目录时,带上 bookmark。
        #if os(macOS)
        let fileToolsBookmark: Data? = (fileToolsEnabledForNextSend && LocalFileToolState.shared.isAuthorized)
            ? LocalFileToolState.shared.bookmark : nil
        #else
        let fileToolsBookmark: Data? = nil
        #endif
        // 代码执行工具(设置 ▸ 设备工具 ▸ 代码执行;默认关闭)。
        let codeExecForSend = CodeExecToolState.shared.isEnabled
        let toolsSnapshot: [LLMTool] = ToolCatalog.enabledTools(
            webSearch: webSessionSnapshot,
            deviceTools: deviceToolsEnabledForNextSend || personaFx.deviceTools,
            extraToolNames: skillToolNames,
            gitHub: gitHubTargetForSend != nil,
            fileSystem: fileToolsBookmark != nil,
            codeExec: codeExecForSend)
        // 有任一工具才建 context;否则 nil(客户端据此跳过工具循环、不注入当前时间)。
        // 注:MCP 工具在 runSend 的后台任务里异步连接后再并入,这里不计入「是否建 context」的判断。
        let toolContextSnapshot: ToolContext? = toolsSnapshot.isEmpty
            ? nil : ToolContext(webSearch: webSessionSnapshot, github: gitHubTargetForSend,
                                localFileBookmark: fileToolsBookmark,
                                codeExec: codeExecForSend)
        // MCP:开关开(或 Persona 点亮)时,带上已启用的 server 配置快照,连接 + tools/list 在后台做。
        let mcpServersForSend: [MCPServerConfig] =
            (mcpEnabledForNextSend || personaFx.mcp) ? mcpStore.enabledServers : []
        // 深度研究(仅 Direct):需 Firecrawl 配置就绪;引擎自驱「搜索→抓取→提炼→缺口」循环,
        // 不依赖输入栏 🌐 开关(研究本身必然要联网,userToggle 恒 true)。
        let researchSessionForSend: WebSearchSession? = (currentMode == .direct && deepResearchEnabledForNextSend)
            ? WebSearchSession.makeIfReady(userToggle: true) : nil
        // 深入模式(仅 Direct):抬高工具循环上限 + 注入 Agent 规划/自检指令。深度研究激活时让位
        // (研究引擎自己编排循环,不走工具 Agent 链,也不起 Live Activity)。
        let deepAgentForSend = (currentMode == .direct && deepAgentEnabledForNextSend && researchSessionForSend == nil)
        let modeSnapshot = currentMode
        let debateRoundsSnapshot = debateRoundsForNextSend
        // Summary 只在 Council 模式跑
        let summarySnapshot = (modeSnapshot == .council) ? summaryProvider : nil
        // Structured 模式的 schema 快照(其它模式为 nil)
        let structuredSchemaSnapshot: String? = (modeSnapshot == .structured)
            ? (conversations[convIdx].structuredSchema ?? StructuredOutput.defaultSchema)
            : nil

        // 清空 prompt 输入框 + 附件(🌐 状态保留,跨发送/跨重启持久化)
        prompt = ""
        attachments = []
        followUpSuggestions = []
        followUpError = nil

        let convID = conversations[convIdx].id
        runSend(
            convID: convID, panel: panel, chair: chair, summary: summarySnapshot,
            promptText: promptSnapshot, systemPromptText: baseSystemPrompt, mode: modeSnapshot,
            turnImages: turnImages, imagePayloads: imageSnapshot,
            contextSummary: contextSummarySnapshot, priorTurns: priorTurnsSnapshot,
            toolContext: toolContextSnapshot, tools: toolsSnapshot,
            debateRoundsCount: debateRoundsSnapshot, workspaceURL: workspaceURLForSend,
            structuredSchema: structuredSchemaSnapshot,
            gitHubTarget: gitHubTargetForSend,
            workspaceContextURL: workspaceURLForSend,
            knowledgeFolder: knowledgeFolderForSend,
            knowledgeQuery: trimmed,
            memoryItems: memoryItemsForSend,
            memoryQuery: memoryQueryForSend,
            recallCorpus: recallCorpusForSend,
            recallQuery: recallQueryForSend,
            recallExcludeID: recallExcludeID,
            mcpServers: mcpServersForSend,
            deepAgent: deepAgentForSend,
            researchSession: researchSessionForSend,
            routeNote: routeNoteForSend,
            cascadePlan: cascadePlanForSend
        )
    }

    /// 在后台线程把 workspace / 知识库 / 长期记忆 上下文打包,前置到基础 system prompt 前面。
    /// `nonisolated`:三段都是纯计算 / 文件 I/O / actor(RAGVectorCache),不碰 @MainActor 状态,
    /// 整体在 global executor 跑 —— 把原来卡在 send() 主线程的扫树 / RAG / BM25 全部挪走。
    /// 顺序与历史一致:workspace 上下文 → 知识库片段 → 长期记忆 → 基础 system prompt。
    /// 三段来源都为空时直接返回 base(edit/retry 路径走这里,行为不变)。
    nonisolated private static func assembleSystemPrompt(
        base: String,
        workspaceContextURL: URL?,
        gitHubTarget: GitHubWriteTarget?,
        knowledgeFolder: KnowledgeFolder?,
        knowledgeQuery: String,
        memoryItems: [MemoryItem],
        memoryQuery: String?,
        recallCorpus: [Conversation] = [],
        recallQuery: String? = nil,
        recallExcludeID: UUID? = nil
    ) async -> (prompt: String, knowledgeSources: [KnowledgeSourceRef]) {
        var parts: [String] = []
        var knowledgeSources: [KnowledgeSourceRef] = []
        if let url = workspaceContextURL, let ctx = WorkspaceManager.buildContext(workspaceURL: url) {
            parts.append(ctx)
        }
        if let gh = gitHubTarget {
            // 拉一次文件树注入指令块(让模型知道仓库里有什么 + 改前先 github_read_file 读现状)。
            // 失败 / 大仓库降级:listTree 返回空 → 指令块不带文件树,功能不受影响。
            let paths = (try? await GitHubClient(token: gh.token)
                .listTree(owner: gh.owner, repo: gh.repo, branch: gh.branch)) ?? []
            parts.append(GitHubClient.writeInstructions(repo: gh.fullName, branch: gh.branch, paths: paths))
        }
        if let folder = knowledgeFolder {
            let hits = await LocalRAG.retrieveDetailed(query: knowledgeQuery, folder: folder, topK: 4)
            if !hits.isEmpty {
                // 给每个片段编号 [n],并要求模型在引用某片段时用 [n] 标注 → 答案可句级溯源。
                var blocks: [String] = []
                for (i, h) in hits.enumerated() {
                    let n = i + 1
                    // [DocRAG] 大文档分块入库的命中带页码,注入与溯源都标注「第 N 页」。
                    let pageLabel = h.page.map { " · 第 \($0) 页" } ?? ""
                    blocks.append("[\(n)] 【\(h.docName)\(pageLabel)】\n\(h.text)")
                    knowledgeSources.append(KnowledgeSourceRef(
                        index: n, docId: h.docId, docName: h.docName, excerpt: h.text, page: h.page))
                }
                parts.append("""
                [相关资料 — 来自知识库「\(folder.name)」,回答时优先参考以下片段。\
                **当某句话的依据直接来自某个片段时,请在该句末尾用 [n] 标注对应编号**(n = 片段前的数字),\
                方便用户点开核对原文;没有用到的片段不必标注]

                \(blocks.joined(separator: "\n\n---\n\n"))
                """)
            }
        }
        if let q = memoryQuery, let mem = MemoryStore.relevanceBlock(items: memoryItems, query: q) {
            parts.append(mem)
        }
        if let rq = recallQuery, !recallCorpus.isEmpty,
           let recall = ConversationRecall.recallBlock(
               corpus: recallCorpus, query: rq, excluding: recallExcludeID) {
            parts.append(recall)
        }
        if !base.isEmpty { parts.append(base) }
        return (parts.joined(separator: "\n\n"), knowledgeSources)
    }

    /// 真正执行一次发送编排:种 live 状态 → 跑 panel/chair/summary → 建 Turn 落盘。
    /// send()(新输入)和 editAndRegenerate(改历史轮)都复用这里。
    /// 铁律:本方法只引用其参数与 self.conversations / self.live* / self.running*,
    /// 不读 self.prompt / self.attachments / self.systemPrompt / self.*ForNextSend。
    private func runSend(
        convID: UUID,
        panel: [ProviderConfig],
        chair: ProviderConfig?,
        summary: ProviderConfig?,
        promptText: String,
        systemPromptText: String,
        mode: ConversationMode,
        turnImages: [TurnImage],
        imagePayloads: [Attachment.ImagePayload],
        contextSummary: String?,
        priorTurns: [PriorTurn],
        toolContext: ToolContext?,
        tools: [LLMTool],
        debateRoundsCount: Int,
        workspaceURL: URL?,
        structuredSchema: String? = nil,
        // GitHub 写入目标(本会话绑定了仓库时才传);kown:write 块提交到该仓库而非本地 workspace。
        gitHubTarget: GitHubWriteTarget? = nil,
        // 上下文来源(主发送路径才传;edit/retry 用默认空值 → 不二次注入,沿用 systemPromptText 原样)。
        // 在后台 assembleSystemPrompt 里前置到 systemPromptText 前面。
        workspaceContextURL: URL? = nil,
        knowledgeFolder: KnowledgeFolder? = nil,
        knowledgeQuery: String = "",
        memoryItems: [MemoryItem] = [],
        memoryQuery: String? = nil,
        // 跨对话召回(主发送路径才传;edit/retry 用默认空值 → 不召回)。
        recallCorpus: [Conversation] = [],
        recallQuery: String? = nil,
        recallExcludeID: UUID? = nil,
        // 本次发送启用的 MCP server(已启用 + 开关开时才非空);连接在后台任务里做。
        mcpServers: [MCPServerConfig] = [],
        // 深入模式(仅 Direct):多步 Agent 长链。
        deepAgent: Bool = false,
        // 深度研究(仅 Direct):非 nil 时本次发送走 DeepResearchEngine(自带 Firecrawl 会话快照)。
        researchSession: WebSearchSession? = nil,
        // 学习型成本路由的中文理由(仅 Direct + 自动选模型且学习决策生效时非 nil),随 Turn 落盘展示。
        routeNote: String? = nil,
        // 省钱级联(实验)计划:非 nil 时初答完成后裁判打分,低于阈值自动旗舰档重答(edit/retry 不传)。
        cascadePlan: CostRouter.CascadePlan? = nil
    ) {
        guard !panel.isEmpty else { return }
        // 别名:让下方异步体与原 send() 逐行一致,降低抽取风险
        let promptSnapshot = promptText
        let modeSnapshot = mode
        let imageSnapshot = imagePayloads
        let contextSummarySnapshot = contextSummary
        let priorTurnsSnapshot = priorTurns
        let toolsSnapshot = tools
        let toolContextSnapshot = toolContext
        let debateRoundsSnapshot = debateRoundsCount
        let summarySnapshot = summary
        let workspaceURLForSend = workspaceURL
        let structuredSchemaSnapshot = structuredSchema

        runningTask?.cancel()
        isRunning = true
        runningConvID = convID

        // iOS:申请通知权限(首次)+ 拿后台 token + 启动无声音频保活(切到后台仍能跑网络)
        BackgroundCompanion.shared.ensureNotificationPermission()
        BackgroundAudioKeepalive.shared.start()
        BackgroundCompanion.shared.beginIfNeeded { [weak self] in
            // 系统给的后台时间到了 — 取消流并让 UI 显示"被系统挂起"
            guard let self else { return }
            for state in self.liveStates.values where self.isStreaming(state) {
                state.fail("iOS 后台时间已到,流被系统挂起 — 切回前台重发可继续")
            }
            self.liveChairState.map { if self.isStreaming($0) { $0.fail("已挂起") } }
            self.liveSummaryState.map { if self.isStreaming($0) { $0.fail("已挂起") } }
            self.runningTask?.cancel()
            self.runningTask = nil
            self.isRunning = false
            self.runningConvID = nil
            BackgroundAudioKeepalive.shared.stop()
            // 深入模式的 Live Activity(若有)同步收掉;没有时是 no-op。
            DeepTaskEvents.postEnded(success: false)
        }

        let roundDate = Date()
        let roundID = String(UUID().uuidString.prefix(8))

        // 初始化 live 状态
        liveStates.removeAll()
        liveChairState = nil
        liveSummaryState = nil
        liveDebateRounds.removeAll()
        liveTournamentRounds.removeAll()
        liveTurnPrompt = promptSnapshot
        liveTurnImages = turnImages
        liveSources.removeAll()
        for cfg in panel {
            let s = ResponseState(id: cfg.id)
            s.reset()
            liveStates[cfg.id] = s
        }
        if let chair {
            let s = ResponseState(id: chair.id)
            // Chair 先空着,等 panel 完成再 reset
            liveChairState = s
        }
        if let s = summarySnapshot {
            let st = ResponseState(id: s.id)
            liveSummaryState = st
        }

        // 如果会话标题还是默认的，用首问截断作标题
        if let titleIdx = conversations.firstIndex(where: { $0.id == convID }),
           conversations[titleIdx].title == "New Conversation" || conversations[titleIdx].title.isEmpty {
            conversations[titleIdx].title = String(promptSnapshot.prefix(30))
        }

        runningTask = Task { [weak self] in
            guard let self else { return }

            // 上下文打包(扫 workspace 文件树 / 知识库 RAG / 记忆 BM25)挪到后台线程算,避免卡主线程。
            // live 卡已在上面同步种好,这里只是把最终 system prompt 算出来再发网络。
            let assembled = await Self.assembleSystemPrompt(
                base: systemPromptText,
                workspaceContextURL: workspaceContextURL,
                gitHubTarget: gitHubTarget,
                knowledgeFolder: knowledgeFolder,
                knowledgeQuery: knowledgeQuery,
                memoryItems: memoryItems,
                memoryQuery: memoryQuery,
                recallCorpus: recallCorpus,
                recallQuery: recallQuery,
                recallExcludeID: recallExcludeID
            )
            let sysSnapshot = assembled.prompt
            let knowledgeSourcesSnapshot = assembled.knowledgeSources
            if Task.isCancelled {
                self.liveStates.values.forEach { $0.fail("已取消") }
                self.isRunning = false
                self.runningConvID = nil
                return
            }

            // MCP:连接已启用的 server、拉工具,并入本次工具集 + 上下文(连不上的 server 自动跳过)。
            // 连接是网络 / 子进程操作,放在这里(后台任务)做;只有 panel 工具循环用得到。
            let mcpSession: MCPSession? = mcpServers.isEmpty ? nil : await MCPSession.connect(servers: mcpServers)
            var effectiveTools = toolsSnapshot
            var effectiveToolContext = toolContextSnapshot
            if let mcp = mcpSession {
                effectiveTools.append(contentsOf: mcp.tools)
                var ctx = effectiveToolContext ?? ToolContext()
                ctx.mcp = mcp
                effectiveToolContext = ctx
            }
            // 深入模式:抬高工具循环上限,并注入 Agent 规划/执行/自检指令(仅 Direct,见 send())。
            let agentMaxRounds = deepAgent ? 12 : 6
            let agentInstructionForSend: String? = deepAgent ? Self.deepAgentInstruction : nil
            // 深入模式 → Live Activity(灵动岛):iOS target 侧 LiveActivityController 订阅此事件。
            if deepAgent { DeepTaskEvents.postStarted(title: String(promptSnapshot.prefix(40)), totalRounds: agentMaxRounds) }

            var responses: [String: String] = [:]
            var errors: [String: String] = [:]
            // 思考过程 + token 用量,key = providerID(uuidString),panel/chair/summary 共用。
            var reasoningByProvider: [String: String] = [:]
            var tokenUsage: [String: TurnTokenUsage] = [:]
            var sourcesByProvider: [String: [SourceRef]] = [:]
            var councilVotes: CouncilVote? = nil
            var snapshot: [String: ProviderConfig] = [:]
            for cfg in panel {
                snapshot[cfg.id.uuidString] = cfg
            }
            if let chair {
                snapshot[chair.id.uuidString] = chair
            }
            let panelOrder = panel.map { $0.id.uuidString }

            let convTitleSnapshot = self.conversations.first(where: { $0.id == convID })?.title ?? ""
            let convIDString = convID.uuidString
            let modeAtSend = modeSnapshot

            // 1) 跑 panel。Debate 模式跑 N 轮(用户配置,1-4);其他模式只跑一轮。
            //    N=1 仅立论;N>=2 立论 + (N-1) 轮反驳/修正。
            //    panel<=1 时反驳轮没有意义,自动降级为 1 轮。
            var debateRounds: [DebateRound]? = nil
            if modeAtSend == .debate {
                let totalRounds = panel.count > 1
                    ? max(1, min(4, debateRoundsSnapshot))
                    : 1
                var rounds: [DebateRound] = []

                roundLoop: for roundIndex in 1...totalRounds {
                    if Task.isCancelled { break }
                    if roundIndex > 1 {
                        // 前一轮全部失败/空时,后续轮无意义,提前停。
                        let hasContent = rounds.last?.responses.values.contains(where: {
                            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }) ?? false
                        if !hasContent { break roundLoop }
                    }

                    let title = PromptBuilders.debateRoundTitle(round: roundIndex, total: totalRounds)
                    let prompts = Dictionary(uniqueKeysWithValues: panel.map { cfg -> (UUID, String) in
                        let p: String
                        if roundIndex == 1 {
                            p = PromptBuilders.buildDebateOpeningPrompt(
                                originalPrompt: promptSnapshot,
                                panel: panel,
                                speaker: cfg,
                                totalRounds: totalRounds
                            )
                        } else {
                            p = PromptBuilders.buildDebateRebuttalPrompt(
                                originalPrompt: promptSnapshot,
                                panel: panel,
                                completedRounds: rounds,
                                speaker: cfg,
                                totalRounds: totalRounds
                            )
                        }
                        return (cfg.id, p)
                    })

                    let result = await self.runPanelRound(
                        panel: panel,
                        prompts: prompts,
                        defaultPrompt: promptSnapshot,
                        systemPrompt: sysSnapshot,
                        roundDate: roundDate,
                        roundID: "\(roundID)-debate-r\(roundIndex)",
                        images: imageSnapshot,
                        contextSummary: contextSummarySnapshot,
                        priorTurns: priorTurnsSnapshot,
                        tools: effectiveTools,
                        toolContext: effectiveToolContext,
                        conversationTitle: convTitleSnapshot,
                        conversationID: convIDString
                    )
                    responses = result.responses
                    errors = result.errors
                    let round = DebateRound(
                        index: roundIndex,
                        title: title,
                        responses: result.responses,
                        errors: result.errors,
                        panelOrder: panelOrder
                    )
                    rounds.append(round)
                    self.liveDebateRounds = rounds
                }

                debateRounds = rounds
            } else if let research = researchSession, modeAtSend == .direct, let researchCfg = panel.first {
                // 深度研究(仅 Direct,单模型):DeepResearchEngine 自驱「大纲→搜索→抓取→提炼→缺口」
                // 多轮循环,进度走 ToolStep 步骤树,来源/角标/参考文献沿用现有引用管线。
                let researchResult = await self.runDeepResearch(
                    config: researchCfg,
                    question: promptSnapshot,
                    systemPrompt: sysSnapshot,
                    web: research,
                    roundDate: roundDate,
                    roundID: roundID + "-research",
                    conversationTitle: convTitleSnapshot,
                    conversationID: convIDString
                )
                responses = researchResult.responses
                errors = researchResult.errors
            } else {
                // Structured 模式:给每家拼上「按 schema 返回严格 JSON」的 prompt(全 provider 通用)。
                // 其它模式 prompts 为空,沿用 defaultPrompt。
                let structuredPrompts: [UUID: String]
                if modeAtSend == .structured, let schema = structuredSchemaSnapshot {
                    structuredPrompts = Dictionary(uniqueKeysWithValues: panel.map { cfg in
                        (cfg.id, StructuredOutput.buildStructuredPrompt(userPrompt: promptSnapshot, schema: schema))
                    })
                } else {
                    structuredPrompts = [:]
                }
                let panelResult = await self.runPanelRound(
                    panel: panel,
                    prompts: structuredPrompts,
                    defaultPrompt: promptSnapshot,
                    systemPrompt: sysSnapshot,
                    roundDate: roundDate,
                    roundID: roundID,
                    images: imageSnapshot,
                    contextSummary: contextSummarySnapshot,
                    priorTurns: priorTurnsSnapshot,
                    tools: effectiveTools,
                    toolContext: effectiveToolContext,
                    conversationTitle: convTitleSnapshot,
                    conversationID: convIDString,
                    maxToolRounds: agentMaxRounds,
                    agentInstruction: agentInstructionForSend
                )
                responses = panelResult.responses
                errors = panelResult.errors
            }

            // 采集 panel 各家的思考过程 + token(在 chair 清空 liveStates 之前)。
            // Debate 模式 liveStates 持有最后一轮的状态,与 top-level responses 语义一致。
            for cfg in panel {
                if let s = self.liveStates[cfg.id] {
                    if !s.reasoning.isEmpty { reasoningByProvider[cfg.id.uuidString] = s.reasoning }
                    if s.inputTokens > 0 || s.outputTokens > 0 {
                        tokenUsage[cfg.id.uuidString] = TurnTokenUsage(input: s.inputTokens, output: s.outputTokens, cachedInput: s.cachedInputTokens)
                    }
                    if !s.sources.isEmpty { sourcesByProvider[cfg.id.uuidString] = s.sources }
                }
            }

            // 工具调用步骤树:留主答案(panel 首家)的步骤,落盘进 Turn,刷新会话后仍可见 Agent 轨迹。
            var primaryToolSteps: [ToolStep]? = nil
            if let firstCfg = panel.first, let s = self.liveStates[firstCfg.id], !s.toolSteps.isEmpty {
                primaryToolSteps = s.toolSteps
            }

            // 1.6) 省钱级联(实验,仅 Direct):初答(便宜档)完成后,先让裁判快速打分(复用 Council
            //      打分的调用方式,见 CostRouter.scoreAnswer);低于阈值 → 同 provider 换旗舰档重答一遍。
            //      初答原样保留,升级答存进 Turn.autoEscalation,UI 标注「已自动升级」。
            //      打分失败 / 分数达标 / 取消时不升级,零行为差异。
            // 深度研究轮不参与级联:报告由多轮检索综合而来,旗舰「重答」拿不到研究上下文,只会更差。
            var autoEscalationResult: AutoEscalation? = nil
            if let plan = cascadePlan, modeAtSend == .direct, researchSession == nil, !Task.isCancelled,
               let firstKey = panelOrder.first, errors[firstKey] == nil,
               let firstAnswer = responses[firstKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !firstAnswer.isEmpty,
               let score = await CostRouter.scoreAnswer(
                   question: promptSnapshot, answer: firstAnswer, judge: plan.judge),
               score < plan.threshold {
                let fl = plan.flagship
                var collected = ""
                var flUsage: TurnTokenUsage? = nil
                var flFailure: String? = nil
                do {
                    let apiKey = fl.kind.isCLI ? "" : ((try? KeychainStore.load(id: fl.id)) ?? "")
                    let client = ProviderRegistry.client(for: fl.kind)
                    var opts = self.optionsFor(config: fl, systemPromptOverride: sysSnapshot)
                    opts.contextSummary = contextSummarySnapshot
                    opts.priorTurns = priorTurnsSnapshot
                    // 升级重答同样走出站脱敏(云端 provider + 开关开时),流式还原占位符。
                    var outboundPrompt = promptSnapshot
                    let restorer = self.applyPIIRedaction(config: fl, prompt: &outboundPrompt, options: &opts)
                    for try await chunk in client.stream(prompt: outboundPrompt, options: opts, config: fl, apiKey: apiKey) {
                        if Task.isCancelled { break }
                        switch chunk {
                        case .text(let t):
                            collected += (restorer?.push(t) ?? t)
                        case .usage(let i, let o, let cached):
                            flUsage = TurnTokenUsage(input: i, output: o, cachedInput: cached)
                            UsageStore.shared.record(providerKind: fl.kind, model: fl.model,
                                                     inputTokens: i, outputTokens: o, cachedTokens: cached)
                        default: break
                        }
                    }
                    if let restorer, case let rest = restorer.flush(), !rest.isEmpty { collected += rest }
                } catch is CancellationError {
                    flFailure = "已取消"
                } catch {
                    flFailure = error.localizedDescription
                }
                let fromModel = panelOrder.first.flatMap { snapshot[$0]?.model } ?? ""
                autoEscalationResult = AutoEscalation(
                    score: score, threshold: plan.threshold,
                    fromModel: fromModel, toModel: fl.model,
                    providerKind: fl.kind.rawValue,
                    text: collected, error: flFailure, tokenUsage: flUsage)
            }

            // 1.5) Tournament(擂台 / 淘汰赛):panel 已各自回答,现在让裁判用单淘汰赛两两对决,
            //      逐轮裁定胜者晋级,直到决出冠军。逐对裁定(逐 await),用单独的 liveTournamentRounds 直播。
            var tournamentRounds: [TournamentRound]? = nil
            if modeAtSend == .tournament {
                tournamentRounds = await self.runTournamentJudging(
                    panel: panel,
                    judge: chair,
                    promptSnapshot: promptSnapshot,
                    responses: responses,
                    errors: errors,
                    sysSnapshot: sysSnapshot,
                    contextSummary: contextSummarySnapshot,
                    priorTurns: priorTurnsSnapshot,
                    roundDate: roundDate,
                    roundID: roundID,
                    convTitle: convTitleSnapshot,
                    convIDString: convIDString,
                    reasoningByProvider: &reasoningByProvider,
                    tokenUsage: &tokenUsage,
                    snapshot: &snapshot
                )
            }

            // 2) 如果有 Chair,跑综合 / 裁判 / 主持总结
            var chairSummary: String? = nil
            var chairError: String? = nil
            if let chair, modeAtSend == .council || modeAtSend == .compare || modeAtSend == .debate {
                let nonEmpty = responses.filter { !$0.value.isEmpty }
                if !nonEmpty.isEmpty {
                    // 不清 liveStates —— 否则综合/裁判阶段面板各家答案会从实时视图消失
                    // (CouncilTurnsView 靠 liveStates[cfg.id] 才渲染面板卡)。chair 用单独的
                    // liveChairState,不依赖 liveStates;turn 结束时(后面)会统一清空。
                    self.liveChairState?.reset()
                    let synthesisPrompt: String
                    switch modeAtSend {
                    case .compare:
                        synthesisPrompt = PromptBuilders.buildJudgePrompt(
                            originalPrompt: promptSnapshot,
                            panel: panel, responses: responses, errors: errors
                        )
                    case .debate:
                        synthesisPrompt = PromptBuilders.buildDebateModeratorPrompt(
                            originalPrompt: promptSnapshot,
                            panel: panel,
                            rounds: debateRounds ?? [],
                            finalResponses: responses,
                            finalErrors: errors
                        )
                    default:
                        synthesisPrompt = PromptBuilders.buildChairPrompt(
                            originalPrompt: promptSnapshot,
                            panel: panel, responses: responses, errors: errors
                        )
                    }
                    let result = await self.runOne(
                        config: chair, prompt: synthesisPrompt,
                        systemPrompt: sysSnapshot,
                        roundDate: roundDate, roundID: roundID + "-chair",
                        target: .chair,
                        images: [],
                        contextSummary: contextSummarySnapshot,
                        priorTurns: priorTurnsSnapshot,
                        tools: [],
                        toolContext: nil,
                        conversationTitle: convTitleSnapshot,
                        conversationID: convIDString
                    )
                    chairSummary = result.1
                    chairError = result.2
                    if let s = self.liveChairState {
                        if !s.reasoning.isEmpty { reasoningByProvider[chair.id.uuidString] = s.reasoning }
                        if s.inputTokens > 0 || s.outputTokens > 0 {
                            tokenUsage[chair.id.uuidString] = TurnTokenUsage(input: s.inputTokens, output: s.outputTokens, cachedInput: s.cachedInputTokens)
                        }
                    }
                }
            }

            // 2.5) Summary(总结员) — 只在 Council 模式跑;跑在 chair 之后,可以看到 chair 的产出
            var summaryText: String? = nil
            var summaryError: String? = nil
            if let summary = summarySnapshot, modeAtSend == .council {
                let nonEmpty = responses.filter { !$0.value.isEmpty }
                if !nonEmpty.isEmpty {
                    self.liveSummaryState?.reset()
                    let aggPrompt = PromptBuilders.buildSummaryPrompt(
                        originalPrompt: promptSnapshot,
                        panel: panel, responses: responses, errors: errors,
                        chairSummary: chairSummary
                    )
                    let result = await self.runOne(
                        config: summary, prompt: aggPrompt,
                        systemPrompt: sysSnapshot,
                        roundDate: roundDate, roundID: roundID + "-summary",
                        target: .summary,
                        images: [],
                        contextSummary: contextSummarySnapshot,
                        priorTurns: priorTurnsSnapshot,
                        tools: [],
                        toolContext: nil,
                        conversationTitle: convTitleSnapshot,
                        conversationID: convIDString
                    )
                    summaryText = result.1
                    summaryError = result.2
                    if let s = self.liveSummaryState {
                        if !s.reasoning.isEmpty { reasoningByProvider[summary.id.uuidString] = s.reasoning }
                        if s.inputTokens > 0 || s.outputTokens > 0 {
                            tokenUsage[summary.id.uuidString] = TurnTokenUsage(input: s.inputTokens, output: s.outputTokens, cachedInput: s.cachedInputTokens)
                        }
                    }
                }
            }

            // 2.6) Council 投票打分(可选,开关在性能设置):chair 之后再跑一次,让评审给各家打分。
            if modeAtSend == .council, self.councilVotingEnabled, panel.count >= 2 {
                let nonEmpty = responses.filter { !$0.value.isEmpty }
                if nonEmpty.count >= 2 {
                    let voter = chair ?? summarySnapshot
                        ?? self.providers.first(where: { $0.enabled && !$0.kind.isCLI })
                    if let voter {
                        let votePrompt = PromptBuilders.buildCouncilVotingPrompt(
                            originalPrompt: promptSnapshot, panel: panel,
                            responses: responses, errors: errors
                        )
                        var collected = ""
                        do {
                            let apiKey = voter.kind.isCLI ? "" : ((try? KeychainStore.load(id: voter.id)) ?? "")
                            let client = ProviderRegistry.client(for: voter.kind)
                            var opts = self.optionsFor(config: voter, systemPromptOverride: "")
                            opts.temperature = 0.2
                            for try await chunk in client.stream(prompt: votePrompt, options: opts, config: voter, apiKey: apiKey) {
                                if Task.isCancelled { break }
                                switch chunk {
                                case .text(let t): collected += t
                                case .usage(let i, let o, let cached):
                                    UsageStore.shared.record(providerKind: voter.kind, model: voter.model, inputTokens: i, outputTokens: o, cachedTokens: cached)
                                default: break
                                }
                            }
                            councilVotes = PromptBuilders.parseCouncilVote(from: collected, panel: panel)
                        } catch {
                            // 投票失败不影响主回答,静默降级
                        }
                    }
                }
            }

            // 2.7) Workspace 写文件:扫所有 provider 响应(包括 chair / summary 文本)里
            //      的 ```kown:write 代码块,逐个 apply 到 workspace 文件夹。
            //      默认 auto-apply,UI 里展示结果。仅当 send 时 workspaceURLForSend 存在才跑。
            var appliedWrites: [AppliedWrite]? = nil
            if let workspaceURL = workspaceURLForSend {
                var allTexts: [String] = []
                allTexts.append(contentsOf: responses.values)
                if let cs = chairSummary { allTexts.append(cs) }
                if let st = summaryText { allTexts.append(st) }
                var pendings: [PendingWrite] = []
                for t in allTexts {
                    pendings.append(contentsOf: WorkspaceManager.parseProposedWrites(t))
                }
                // 去重(同路径重复时取最后一个 — model 最后输出的认为是最终版本)
                var seen: [String: PendingWrite] = [:]
                for p in pendings { seen[p.relativePath] = p }
                let applied = seen.values.map { WorkspaceManager.apply($0, workspaceURL: workspaceURL) }
                if !applied.isEmpty {
                    appliedWrites = applied
                } else {
                    // workspace 设置了但 model 没输出 kown:write 块 —
                    // 检查响应里是否含其他 fenced code(说明 model 想写但用错了格式),
                    // 把这个情况做成一条 .skipped 提示,让 UI 显示出来
                    let hasOtherCodeFence = allTexts.contains { $0.contains("```") }
                    if hasOtherCodeFence {
                        appliedWrites = [AppliedWrite(
                            relativePath: "(无)",
                            action: .skipped,
                            success: false,
                            error: "Model 输出了代码块,但都不是 kown:write 格式。提醒它用 kown:write 代码块改文件,或者直接复制内容到目标文件。",
                            newContent: ""
                        )]
                    }
                }
            } else if let gh = gitHubTarget {
                // 2.7') GitHub 写文件:扫响应里的 kown:write 块,逐个提交到绑定仓库。
                var allTexts: [String] = []
                allTexts.append(contentsOf: responses.values)
                if let cs = chairSummary { allTexts.append(cs) }
                if let st = summaryText { allTexts.append(st) }
                var pendings: [PendingWrite] = []
                for t in allTexts {
                    pendings.append(contentsOf: WorkspaceManager.parseProposedWrites(t))
                }
                var seen: [String: PendingWrite] = [:]
                for p in pendings { seen[p.relativePath] = p }
                if !seen.isEmpty {
                    let client = GitHubClient(token: gh.token)
                    var committed: [AppliedWrite] = []
                    for w in seen.values {
                        committed.append(await client.commit(w, owner: gh.owner, repo: gh.repo, branch: gh.branch))
                    }
                    appliedWrites = committed
                } else {
                    let hasOtherCodeFence = allTexts.contains { $0.contains("```") }
                    if hasOtherCodeFence {
                        appliedWrites = [AppliedWrite(
                            relativePath: "(无)",
                            action: .skipped,
                            success: false,
                            error: "Model 输出了代码块,但都不是 kown:write 格式 — 没有内容被提交到 GitHub。",
                            newContent: ""
                        )]
                    }
                }
            }

            // 2.8) 自动升级建议(建议式):仅 Direct 单答 + 开关开时,本地启发式扫低置信/回避信号。
            //      本轮已被省钱级联自动升级过的不再建议(升级答已经在卡片里,重复提示徒增噪音)。
            var escalationSuggestion: EscalationSuggestion? = nil
            if self.escalationSuggestionsEnabled, modeSnapshot == .direct,
               autoEscalationResult == nil,
               let firstKey = panelOrder.first, errors[firstKey] == nil,
               let primary = responses[firstKey] {
                escalationSuggestion = EscalationAdvisor.evaluate(answer: primary)
            }

            // 3) 落盘
            if let idx = self.conversations.firstIndex(where: { $0.id == convID }) {
                if let summary = summarySnapshot {
                    snapshot[summary.id.uuidString] = summary
                }
                let turn = Turn(
                    timestamp: roundDate,
                    prompt: promptSnapshot,
                    systemPrompt: sysSnapshot,
                    responses: responses,
                    errors: errors,
                    chairProviderID: chair?.id.uuidString,
                    chairSummary: chairSummary,
                    chairError: chairError,
                    summaryProviderID: summarySnapshot?.id.uuidString,
                    summaryText: summaryText,
                    summaryError: summaryError,
                    providerSnapshot: snapshot,
                    panelOrder: panelOrder,
                    debateRounds: debateRounds,
                    tournamentRounds: tournamentRounds,
                    appliedWrites: appliedWrites,
                    images: turnImages.isEmpty ? nil : turnImages,
                    sources: self.liveSources.isEmpty ? nil : self.liveSources,
                    reasoningByProvider: reasoningByProvider.isEmpty ? nil : reasoningByProvider,
                    tokenUsage: tokenUsage.isEmpty ? nil : tokenUsage,
                    councilVotes: councilVotes,
                    sourcesByProvider: sourcesByProvider.isEmpty ? nil : sourcesByProvider,
                    knowledgeSources: knowledgeSourcesSnapshot.isEmpty ? nil : knowledgeSourcesSnapshot,
                    escalationSuggestion: escalationSuggestion,
                    toolSteps: primaryToolSteps,
                    routeNote: routeNote,
                    autoEscalation: autoEscalationResult
                )
                self.conversations[idx].turns.append(turn)
                self.conversations[idx].updatedAt = Date()
                ConversationStore.save(self.conversations[idx])
                // 晨报会话:本轮回答即晨报内容 → 提取要点发布到 iOS 桌面小组件(非晨报会话 no-op)。
                WidgetBridge.publishBriefingIfPending(
                    conversationID: convID,
                    answerMarkdown: chairSummary ?? summaryText
                        ?? panelOrder.compactMap { responses[$0] }.first { !$0.isEmpty } ?? "")
                // 把会话顶到列表最前
                let moved = self.conversations.remove(at: idx)
                self.conversations.insert(moved, at: 0)

                // 触发增量摘要(后台跑,不阻塞 UI)
                self.scheduleSummarization(for: convID)
                // 触发跨会话长期记忆抽取(仅当开关开;后台跑,不阻塞 UI)
                self.scheduleMemoryExtraction(for: convID)
                // 首轮后自动起标题(后台跑,仅当标题还是首问截断)
                self.scheduleAutoTitle(for: convID)
                // 首轮后自动打标签(后台跑,仅当开关开且本会话还没有标签)
                self.scheduleAutoTag(for: convID)
            }

            // 完成 — 停无声音频 + 释放后台 token + 后台时通知用户
            BackgroundAudioKeepalive.shared.stop()
            BackgroundCompanion.shared.end()
            let notifyBody = PromptBuilders.notificationPreview(
                summaryText: summaryText,
                chairSummary: chairSummary,
                responses: responses,
                panelOrder: panelOrder
            )
            BackgroundCompanion.shared.notifyIfBackgrounded(
                title: "Kown 回答已完成",
                body: notifyBody
            )

            // 释放 MCP 连接(stdio 子进程退出 / HTTP 会话丢弃)。
            await mcpSession?.closeAll()

            self.liveStates.removeAll()
            self.liveChairState = nil
            self.liveSummaryState = nil
            self.liveDebateRounds.removeAll()
            self.liveTournamentRounds.removeAll()
            self.liveTurnPrompt = nil
            self.liveTurnImages = []
            self.isRunning = false
            self.runningConvID = nil
            // 深入模式:收掉 Live Activity(灵动岛显示「已完成」后自动消失)。
            if deepAgent { DeepTaskEvents.postEnded(success: true) }
        }
    }

    /// 换一个模型重答某轮:把新 provider 加进该轮快照 + panelOrder(空答),再复用 retryProvider 填充。
    /// 新回答作为该轮的额外一栏出现(便于与原答对照)。
    func regenerateWithModel(turnID: UUID, newProviderID: UUID) {
        guard !isRunning,
              let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }),
              let newCfg = providers.first(where: { $0.id == newProviderID }) else { return }
        let key = newProviderID.uuidString
        conversations[convIdx].turns[turnIdx].providerSnapshot[key] = newCfg
        if !conversations[convIdx].turns[turnIdx].panelOrder.contains(key) {
            conversations[convIdx].turns[turnIdx].panelOrder.append(key)
        }
        conversations[convIdx].turns[turnIdx].responses[key] = ""
        conversations[convIdx].turns[turnIdx].errors[key] = nil
        ConversationStore.save(conversations[convIdx])
        retryProvider(turnID: turnID, configID: newProviderID)
    }

    /// Direct 模式「换模型」:用新模型**替换**这轮的单条回答并重答(不像多列模式那样并列追加)。
    func regenerateDirectWithModel(turnID: UUID, newProviderID: UUID) {
        guard !isRunning,
              let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }),
              let newCfg = providers.first(where: { $0.id == newProviderID }) else { return }
        let key = newProviderID.uuidString
        conversations[convIdx].turns[turnIdx].providerSnapshot[key] = newCfg
        conversations[convIdx].turns[turnIdx].panelOrder = [key]   // 单列:替换
        conversations[convIdx].turns[turnIdx].responses[key] = ""
        conversations[convIdx].turns[turnIdx].errors[key] = nil
        // 换了模型重答 → 旧模型的路由理由 / 级联升级留痕都不再成立,一并清掉避免误导。
        conversations[convIdx].turns[turnIdx].routeNote = nil
        conversations[convIdx].turns[turnIdx].autoEscalation = nil
        ConversationStore.save(conversations[convIdx])
        retryProvider(turnID: turnID, configID: newProviderID)
    }

    /// 综合 / 总结 / 裁判 / 主持「换模型」:把该角色换成新模型并重跑。
    func regenerateChairWithModel(turnID: UUID, target: ChairRetryTarget, newProviderID: UUID) {
        guard !isRunning,
              let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }),
              let newCfg = providers.first(where: { $0.id == newProviderID }) else { return }
        let key = newProviderID.uuidString
        conversations[convIdx].turns[turnIdx].providerSnapshot[key] = newCfg
        switch target {
        case .chair:
            conversations[convIdx].turns[turnIdx].chairProviderID = key
            conversations[convIdx].turns[turnIdx].chairSummary = nil
            conversations[convIdx].turns[turnIdx].chairError = nil
        case .summary:
            conversations[convIdx].turns[turnIdx].summaryProviderID = key
            conversations[convIdx].turns[turnIdx].summaryText = nil
            conversations[convIdx].turns[turnIdx].summaryError = nil
        }
        ConversationStore.save(conversations[convIdx])
        retryChair(turnID: turnID, target: target)
    }

    /// 「换模型重答」候选:已启用、非 CLI 的 provider(供回答卡菜单)。
    var regenerateCandidates: [ProviderConfig] {
        providers.filter { $0.enabled && !$0.kind.isCLI }
    }

    /// 撤销某轮的一次 workspace 写入:还原文件(create→删,update→写回旧内容),并标记 reverted。
    @discardableResult
    func undoWrite(turnID: UUID, write: AppliedWrite) -> String? {
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else {
            return "找不到对应会话"
        }
        guard let url = currentWorkspaceURL else {
            return "本会话未设置 workspace,无法撤销"
        }
        let result = WorkspaceManager.revert(write, workspaceURL: url)
        guard result.success else { return result.error ?? "撤销失败" }
        if var writes = conversations[convIdx].turns[turnIdx].appliedWrites,
           let wIdx = writes.firstIndex(where: { $0.id == write.id }) {
            writes[wIdx].reverted = true
            conversations[convIdx].turns[turnIdx].appliedWrites = writes
            conversations[convIdx].updatedAt = Date()
            ConversationStore.save(conversations[convIdx])
        }
        return nil
    }

    /// 编辑历史某轮的用户消息并从该轮重新生成:丢弃该轮(含)之后的所有轮,
    /// 用原轮的 panel/chair/summary 与系统提示、在截断后的历史上重跑(纯文本,不带图片重发,与 retry 一致)。
    /// 截断不可逆 —— UI 侧需二次确认后再调用。
    func editAndRegenerate(turnID: UUID, newPrompt: String) {
        guard !isRunning else { return }
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }),
              let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }
        let trimmed = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let original = conversations[convIdx].turns[turnIdx]
        let panel = original.orderedPanelConfigs
        guard !panel.isEmpty else { return }

        // 截断:丢弃第 N 轮(含)及其后所有轮,从干净历史重跑;立即落盘保持一致。
        conversations[convIdx].turns = Array(conversations[convIdx].turns[..<turnIdx])
        // 摘要水位回退,避免指向已删除的轮(否则摘要器会从错误基线继续)。
        conversations[convIdx].summarizedThroughTurnCount = min(
            conversations[convIdx].summarizedThroughTurnCount,
            conversations[convIdx].turns.count
        )
        conversations[convIdx].updatedAt = Date()
        ConversationStore.save(conversations[convIdx])

        let mode = conversations[convIdx].mode
        activeMode = mode
        let contextSummary = ConversationSummarizer.summaryForNextSend(conversations[convIdx])
        let priorTurns = ConversationSummarizer.priorTurnsForReplay(conversations[convIdx])
        let structuredSchema: String? = (mode == .structured)
            ? (conversations[convIdx].structuredSchema ?? StructuredOutput.defaultSchema)
            : nil

        runSend(
            convID: convID, panel: panel, chair: original.chairConfig, summary: original.summaryConfig,
            promptText: trimmed, systemPromptText: original.systemPrompt, mode: mode,
            turnImages: original.images ?? [], imagePayloads: [],
            contextSummary: contextSummary, priorTurns: priorTurns,
            toolContext: nil, tools: [],
            debateRoundsCount: original.debateRounds?.count ?? debateRoundsForNextSend,
            workspaceURL: currentWorkspaceURL,
            structuredSchema: structuredSchema
        )
    }

    // MARK: - 摘要调度

    /// 首轮回答后用小模型给会话起一个 ≤14 字标题(仅当标题仍是首问截断、未被改名时)。后台异步,失败不动原标题。
    private func scheduleAutoTitle(for convID: UUID) {
        guard !autoTitleTasks.contains(convID),
              let idx = conversations.firstIndex(where: { $0.id == convID }),
              conversations[idx].turns.count == 1 else { return }
        let turn = conversations[idx].turns[0]
        let autoTitle = String(turn.prompt.prefix(30))
        // 只在标题仍是首问截断(说明用户没手动改名)时才覆盖
        guard conversations[idx].title == autoTitle else { return }
        guard let cfg = chairProvider ?? providers.first(where: { $0.enabled && !$0.kind.isCLI }),
              !cfg.kind.isCLI else { return }
        let answer = turn.chairSummary ?? turn.summaryText
            ?? turn.responses.values.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        guard !answer.isEmpty else { return }
        let q = String(turn.prompt.prefix(500))
        let a = String(answer.prefix(500))
        autoTitleTasks.insert(convID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.autoTitleTasks.remove(convID) }
            let apiKey = cfg.kind.isCLI ? "" : ((try? KeychainStore.load(id: cfg.id)) ?? "")
            let prompt = "为下面的对话起一个不超过 14 个字的简洁标题,只输出标题本身,不要引号、标点或解释。\n\n问:\(q)\n答:\(a)"
            let options = ChatOptions(systemPrompt: nil, temperature: 0.3, maxTokens: 32)
            var collected = ""
            do {
                let client = ProviderRegistry.client(for: cfg.kind)
                for try await chunk in client.stream(prompt: prompt, options: options, config: cfg, apiKey: apiKey) {
                    if case .text(let t) = chunk { collected += t }
                }
            } catch { return }
            var title = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            for ch in ["\"", "「", "」", "『", "』", "\n", "。", "："] {
                title = title.replacingOccurrences(of: ch, with: ch == "\n" ? " " : "")
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count > 20 { title = String(title.prefix(20)) }
            // 期间用户没手动改名才写回
            guard !title.isEmpty,
                  let liveIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  self.conversations[liveIdx].title == autoTitle else { return }
            self.conversations[liveIdx].title = title
            ConversationStore.save(self.conversations[liveIdx])
        }
    }

    /// 首轮回答后用小模型给会话推荐 1-3 个标签(仅当开关开 + 本会话还没标签)。后台异步,失败不动。
    /// 与自动起标题独立:标签便于侧栏按主题过滤检索。用户手动设过标签则不覆盖。
    private func scheduleAutoTag(for convID: UUID) {
        guard autoTagEnabled,
              !autoTagTasks.contains(convID),
              let idx = conversations.firstIndex(where: { $0.id == convID }),
              conversations[idx].turns.count == 1,
              conversations[idx].tags.isEmpty else { return }
        let turn = conversations[idx].turns[0]
        guard let cfg = chairProvider ?? providers.first(where: { $0.enabled && !$0.kind.isCLI }),
              !cfg.kind.isCLI else { return }
        let answer = turn.chairSummary ?? turn.summaryText
            ?? turn.responses.values.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let q = String(turn.prompt.prefix(500))
        let a = String(answer.prefix(400))
        autoTagTasks.insert(convID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.autoTagTasks.remove(convID) }
            let apiKey = (try? KeychainStore.load(id: cfg.id)) ?? ""
            let prompt = "根据下面的对话,给它打 1-3 个简短主题标签(每个 2-6 字,如「编程」「健康」「旅行」)。只输出标签,用英文逗号分隔,不要解释、不要序号、不要标点。\n\n问:\(q)\n答:\(a)"
            let options = ChatOptions(systemPrompt: nil, temperature: 0.3, maxTokens: 32)
            var collected = ""
            do {
                let client = ProviderRegistry.client(for: cfg.kind)
                for try await chunk in client.stream(prompt: prompt, options: options, config: cfg, apiKey: apiKey) {
                    if case .text(let t) = chunk { collected += t }
                }
            } catch { return }
            // 解析:按逗号/顿号/换行切,清洗,去重,最多 3 个,每个 ≤8 字。
            let separators = CharacterSet(charactersIn: ",，、\n;；")
            let tags = collected
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #「」『』\"'.。-*")) }
                .filter { !$0.isEmpty && $0.count <= 8 }
                .reduce(into: [String]()) { acc, t in if !acc.contains(t) { acc.append(t) } }
                .prefix(3)
            guard !tags.isEmpty,
                  let liveIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  self.conversations[liveIdx].tags.isEmpty else { return }
            self.conversations[liveIdx].tags = Array(tags)
            self.conversations[liveIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[liveIdx])
        }
    }

    func scheduleSummarization(for convID: UUID) {
        if let running = summarizingTasks[convID], !running.isCancelled { return }
        guard let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        let convSnapshot = conversations[idx]
        // 未总结 turn 累计到阈值才跑(避免每轮都开一次摘要 LLM)
        let remaining = convSnapshot.turns.count - convSnapshot.summarizedThroughTurnCount
        guard remaining >= ConversationSummarizer.triggerThreshold else { return }

        let chair = chairProvider
        let firstEnabled = providers.first(where: { $0.enabled && !$0.kind.isCLI })
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.summarizingTasks.removeValue(forKey: convID) }
            guard let result = await ConversationSummarizer.updatedSummary(
                for: convSnapshot, chair: chair, firstEnabled: firstEnabled
            ) else { return }
            guard let liveIdx = self.conversations.firstIndex(where: { $0.id == convID }) else { return }
            // 只前进 — 防止竞态把新摘要覆盖回旧的
            if result.summarizedThroughTurnCount > self.conversations[liveIdx].summarizedThroughTurnCount {
                self.conversations[liveIdx].contextSummary = result.summary
                self.conversations[liveIdx].summarizedThroughTurnCount = result.summarizedThroughTurnCount
                ConversationStore.save(self.conversations[liveIdx])
            }
        }
        summarizingTasks[convID] = task
    }

    /// 跨会话长期记忆抽取调度:仅在 `memoryInjectionEnabled` 开时跑。
    /// 用小模型从「上次抽取以来的新增轮」里提炼长期有用的事实/偏好,沉淀到 `MemoryStore.shared`。
    /// 与 `scheduleSummarization` 是两套独立水位(`memoryExtractedThroughTurnCount`),互不干扰。
    func scheduleMemoryExtraction(for convID: UUID) {
        guard memoryInjectionEnabled else { return }
        if let running = memoryExtractionTasks[convID], !running.isCancelled { return }
        guard let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        let convSnapshot = conversations[idx]
        // 太短的会话不抽;距上次抽取又攒够增量轮才再抽。
        guard convSnapshot.turns.count >= MemoryExtractor.triggerTurnCount else { return }
        let remaining = convSnapshot.turns.count - convSnapshot.memoryExtractedThroughTurnCount
        guard remaining >= MemoryExtractor.incrementalThreshold
            || (convSnapshot.memoryExtractedThroughTurnCount == 0 && remaining >= 1) else { return }

        let chair = chairProvider
        let firstEnabled = providers.first(where: { $0.enabled && !$0.kind.isCLI })
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.memoryExtractionTasks.removeValue(forKey: convID) }
            guard let result = await MemoryExtractor.extract(
                for: convSnapshot, chair: chair, firstEnabled: firstEnabled
            ) else { return }
            if !result.memories.isEmpty {
                MemoryStore.shared.addMany(result.memories, sourceConversationID: convID)
            }
            // 推进水位(即便没抽到内容也前进,避免重复对同样的轮次调用小模型)。只前进,防竞态回退。
            guard let liveIdx = self.conversations.firstIndex(where: { $0.id == convID }) else { return }
            if result.extractedThroughTurnCount > self.conversations[liveIdx].memoryExtractedThroughTurnCount {
                self.conversations[liveIdx].memoryExtractedThroughTurnCount = result.extractedThroughTurnCount
                ConversationStore.save(self.conversations[liveIdx])
            }
        }
        memoryExtractionTasks[convID] = task
    }

    func cancel() {
        runningTask?.cancel()
        runningTask = nil
        isRunning = false
        runningConvID = nil
        BackgroundAudioKeepalive.shared.stop()
        BackgroundCompanion.shared.end()
        // 深入模式的 Live Activity(若有)同步收掉;没有时是 no-op。
        DeepTaskEvents.postEnded(success: false)
        for state in liveStates.values where isStreaming(state) {
            state.fail("已取消")
        }
        if let summary = liveSummaryState, isStreaming(summary) {
            summary.fail("已取消")
        }
        if let chair = liveChairState, isStreaming(chair) {
            chair.fail("已取消")
        }
        liveDebateRounds.removeAll()
        liveTournamentRounds.removeAll()
    }

    private func isStreaming(_ state: ResponseState) -> Bool {
        if case .streaming = state.phase { return true }
        return false
    }

    // MARK: - 单家失败重试(超时恢复)

    private static func retryTicket(turnID: UUID, configID: UUID, roundIndex: Int?) -> String {
        if let r = roundIndex { return "\(turnID.uuidString):\(configID.uuidString):r\(r)" }
        return "\(turnID.uuidString):\(configID.uuidString)"
    }

    func isRetrying(turnID: UUID, configID: UUID, roundIndex: Int? = nil) -> Bool {
        retryingTickets.contains(Self.retryTicket(turnID: turnID, configID: configID, roundIndex: roundIndex))
    }

    /// 重跑某个 turn 里一家失败的 provider。roundIndex 仅 Debate 模式使用 — 指定要重跑哪一轮。
    /// 重跑成功后原地 patch turn.responses / turn.errors(或对应 round 的),并落盘。
    /// 主发送进行中时(isRunning)拒绝重试,避免状态机交叉。
    func retryProvider(turnID: UUID, configID: UUID, roundIndex: Int? = nil) {
        guard !isRunning else { return }
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        guard let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }

        let ticket = Self.retryTicket(turnID: turnID, configID: configID, roundIndex: roundIndex)
        guard !retryingTickets.contains(ticket) else { return }

        let turn = conversations[convIdx].turns[turnIdx]
        let key = configID.uuidString
        guard let cfg = turn.providerSnapshot[key] else { return }
        let mode = conversations[convIdx].mode
        let panel = turn.orderedPanelConfigs

        // 用 turn 之前的会话状态重建上下文,确保重试不会拿到"未来"的 turn。
        var historicalConv = conversations[convIdx]
        historicalConv.turns = Array(conversations[convIdx].turns[..<turnIdx])
        let contextSummary = ConversationSummarizer.summaryForNextSend(historicalConv)
        let priorTurns = ConversationSummarizer.priorTurnsForReplay(historicalConv)

        // 组 prompt
        let prompt: String
        switch mode {
        case .direct, .council, .compare, .tournament, .translate:
            // Tournament 的 panel 回答就是直接回答原问题(裁判对决另走 retryChair 不在此);重答即重发原问题。
            // Translate:翻译指令在 system prompt 里,重答只需重发原文。
            prompt = turn.prompt
        case .structured:
            // 重试也要带上 schema 指令,否则模型可能不再返回严格 JSON。
            let schema = conversations[convIdx].structuredSchema ?? StructuredOutput.defaultSchema
            prompt = StructuredOutput.buildStructuredPrompt(userPrompt: turn.prompt, schema: schema)
        case .debate:
            let rounds = turn.debateRounds ?? []
            let targetRound = roundIndex ?? rounds.last?.index ?? 1
            let total = max(1, min(4, rounds.count == 0 ? 2 : rounds.count))
            if targetRound <= 1 {
                prompt = PromptBuilders.buildDebateOpeningPrompt(
                    originalPrompt: turn.prompt,
                    panel: panel,
                    speaker: cfg,
                    totalRounds: total
                )
            } else {
                let priorRounds = rounds.filter { $0.index < targetRound }
                prompt = PromptBuilders.buildDebateRebuttalPrompt(
                    originalPrompt: turn.prompt,
                    panel: panel,
                    completedRounds: priorRounds,
                    speaker: cfg,
                    totalRounds: total
                )
            }
        }

        let sysPrompt = turn.systemPrompt
        let convTitle = conversations[convIdx].title
        let convIDString = convID.uuidString
        let roundDate = Date()
        let roundID = "retry-\(String(UUID().uuidString.prefix(8)))"

        retryingTickets.insert(ticket)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.retryingTickets.remove(ticket) }

            var collected = ""
            var collectedReasoning = ""
            var usage: TurnTokenUsage? = nil
            var failure: String? = nil
            do {
                let apiKey = cfg.kind.needsAPIKey ? (try KeychainStore.load(id: cfg.id)) : ""
                let client = ProviderRegistry.client(for: cfg.kind)
                var options = self.optionsFor(config: cfg, systemPromptOverride: sysPrompt)
                options.contextSummary = contextSummary
                options.priorTurns = priorTurns
                // 注:retry 不带 images / tools — 失败的原 turn 已经过初次尝试,简化为干跑文本。
                // 用户若需要带图重跑,可以直接重发整 turn。
                for try await chunk in client.stream(prompt: prompt, options: options, config: cfg, apiKey: apiKey) {
                    switch chunk {
                    case .text(let t): collected += t
                    case .reasoning(let r): collectedReasoning += r
                    case .toolEvent: break
                    case .toolStep: break
                    case .sources: break
                    case .usage(let input, let output, let cached):
                        usage = TurnTokenUsage(input: input, output: output, cachedInput: cached)
                        UsageStore.shared.record(
                            providerKind: cfg.kind,
                            model: cfg.model,
                            inputTokens: input,
                            outputTokens: output,
                            cachedTokens: cached
                        )
                    }
                }
            } catch is CancellationError {
                failure = "已取消"
            } catch {
                failure = error.localizedDescription
            }

            ResponseLogger.writeAsync(.init(
                roundID: roundID,
                timestamp: roundDate,
                providerName: cfg.displayName,
                providerKind: cfg.kind.rawValue,
                baseURL: cfg.baseURL,
                model: cfg.model,
                prompt: prompt,
                systemPrompt: sysPrompt,
                response: collected,
                elapsedSeconds: nil,
                error: failure,
                conversationTitle: convTitle,
                conversationID: convIDString
            ))

            // 重新定位 turn(过程中会话可能被其他操作变更)
            guard let liveConvIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  let liveTurnIdx = self.conversations[liveConvIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }

            if mode == .debate, let rounds = self.conversations[liveConvIdx].turns[liveTurnIdx].debateRounds {
                let targetRound = roundIndex ?? rounds.last?.index ?? 1
                if let rIdx = rounds.firstIndex(where: { $0.index == targetRound }) {
                    if let failure {
                        self.conversations[liveConvIdx].turns[liveTurnIdx].debateRounds?[rIdx].errors[key] = failure
                        self.conversations[liveConvIdx].turns[liveTurnIdx].debateRounds?[rIdx].responses[key] = collected
                    } else {
                        self.conversations[liveConvIdx].turns[liveTurnIdx].debateRounds?[rIdx].errors.removeValue(forKey: key)
                        self.conversations[liveConvIdx].turns[liveTurnIdx].debateRounds?[rIdx].responses[key] = collected
                    }
                    // turn 顶层 responses/errors 缓存的是最后一轮 — 若 retry 的就是最后一轮,同步刷新
                    let isLastRound = (rounds.max(by: { $0.index < $1.index })?.index ?? 0) == targetRound
                    if isLastRound {
                        if let failure {
                            self.conversations[liveConvIdx].turns[liveTurnIdx].errors[key] = failure
                            self.conversations[liveConvIdx].turns[liveTurnIdx].responses[key] = collected
                        } else {
                            self.conversations[liveConvIdx].turns[liveTurnIdx].errors.removeValue(forKey: key)
                            self.conversations[liveConvIdx].turns[liveTurnIdx].responses[key] = collected
                        }
                    }
                }
            } else {
                if let failure {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].errors[key] = failure
                    self.conversations[liveConvIdx].turns[liveTurnIdx].responses[key] = collected
                } else {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].errors.removeValue(forKey: key)
                    self.conversations[liveConvIdx].turns[liveTurnIdx].responses[key] = collected
                }
            }

            // 同步思考过程 / token 用量(顶层,按 providerID)
            self.patchTurnReasoningAndUsage(convIdx: liveConvIdx, turnIdx: liveTurnIdx, key: key,
                                            reasoning: collectedReasoning, usage: usage)
            self.conversations[liveConvIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[liveConvIdx])
        }
    }

    /// 把单次重跑得到的思考过程 / token 用量回填进 turn(顶层 dict,按 providerID)。
    private func patchTurnReasoningAndUsage(convIdx: Int, turnIdx: Int, key: String,
                                            reasoning: String, usage: TurnTokenUsage?) {
        if !reasoning.isEmpty {
            var dict = conversations[convIdx].turns[turnIdx].reasoningByProvider ?? [:]
            dict[key] = reasoning
            conversations[convIdx].turns[turnIdx].reasoningByProvider = dict
        }
        if let usage {
            var dict = conversations[convIdx].turns[turnIdx].tokenUsage ?? [:]
            dict[key] = usage
            conversations[convIdx].turns[turnIdx].tokenUsage = dict
        }
    }

    enum ChairRetryTarget: String {
        case chair      // Council/Debate/Compare 的综合/裁判/主持(turn.chairSummary)
        case summary    // Council 的总结员(turn.summaryText)
    }

    private static func chairRetryTicket(turnID: UUID, target: ChairRetryTarget) -> String {
        "chair:\(turnID.uuidString):\(target.rawValue)"
    }

    func isRetryingChair(turnID: UUID, target: ChairRetryTarget = .chair) -> Bool {
        retryingTickets.contains(Self.chairRetryTicket(turnID: turnID, target: target))
    }

    /// 重跑 turn 的 Chair / Moderator / Judge / Summary。重跑前会拿现 turn 的 panel 答复重建 prompt,
    /// 因此即使 panel 中有一家失败,只要其他家有内容,chair 重试就能继续。
    func retryChair(turnID: UUID, target: ChairRetryTarget = .chair) {
        guard !isRunning else { return }
        guard let convID = selectedConversationID,
              let convIdx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        guard let turnIdx = conversations[convIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }

        let ticket = Self.chairRetryTicket(turnID: turnID, target: target)
        guard !retryingTickets.contains(ticket) else { return }

        let turn = conversations[convIdx].turns[turnIdx]
        let mode = conversations[convIdx].mode

        let targetCfg: ProviderConfig?
        switch target {
        case .chair:
            targetCfg = turn.chairConfig
        case .summary:
            targetCfg = turn.summaryConfig
        }
        guard let cfg = targetCfg else { return }

        let panel = turn.orderedPanelConfigs

        // 用 turn 之前的会话状态重建上下文
        var historicalConv = conversations[convIdx]
        historicalConv.turns = Array(conversations[convIdx].turns[..<turnIdx])
        let contextSummary = ConversationSummarizer.summaryForNextSend(historicalConv)
        let priorTurns = ConversationSummarizer.priorTurnsForReplay(historicalConv)

        // 组 prompt — 与 send() 里的逻辑保持一致
        let prompt: String
        switch target {
        case .chair:
            switch mode {
            case .compare:
                prompt = PromptBuilders.buildJudgePrompt(
                    originalPrompt: turn.prompt,
                    panel: panel,
                    responses: turn.responses,
                    errors: turn.errors
                )
            case .debate:
                prompt = PromptBuilders.buildDebateModeratorPrompt(
                    originalPrompt: turn.prompt,
                    panel: panel,
                    rounds: turn.debateRounds ?? [],
                    finalResponses: turn.responses,
                    finalErrors: turn.errors
                )
            default:
                prompt = PromptBuilders.buildChairPrompt(
                    originalPrompt: turn.prompt,
                    panel: panel,
                    responses: turn.responses,
                    errors: turn.errors
                )
            }
        case .summary:
            prompt = PromptBuilders.buildSummaryPrompt(
                originalPrompt: turn.prompt,
                panel: panel,
                responses: turn.responses,
                errors: turn.errors,
                chairSummary: turn.chairSummary
            )
        }

        let sysPrompt = turn.systemPrompt
        let convTitle = conversations[convIdx].title
        let convIDString = convID.uuidString
        let roundDate = Date()
        let roundID = "retry-chair-\(String(UUID().uuidString.prefix(8)))"

        retryingTickets.insert(ticket)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.retryingTickets.remove(ticket) }

            var collected = ""
            var collectedReasoning = ""
            var usage: TurnTokenUsage? = nil
            var failure: String? = nil
            do {
                let apiKey = cfg.kind.needsAPIKey ? (try KeychainStore.load(id: cfg.id)) : ""
                let client = ProviderRegistry.client(for: cfg.kind)
                var options = self.optionsFor(config: cfg, systemPromptOverride: sysPrompt)
                options.contextSummary = contextSummary
                options.priorTurns = priorTurns
                for try await chunk in client.stream(prompt: prompt, options: options, config: cfg, apiKey: apiKey) {
                    switch chunk {
                    case .text(let t): collected += t
                    case .reasoning(let r): collectedReasoning += r
                    case .toolEvent: break
                    case .toolStep: break
                    case .sources: break
                    case .usage(let input, let output, let cached):
                        usage = TurnTokenUsage(input: input, output: output, cachedInput: cached)
                        UsageStore.shared.record(
                            providerKind: cfg.kind,
                            model: cfg.model,
                            inputTokens: input,
                            outputTokens: output,
                            cachedTokens: cached
                        )
                    }
                }
            } catch is CancellationError {
                failure = "已取消"
            } catch {
                failure = error.localizedDescription
            }

            ResponseLogger.writeAsync(.init(
                roundID: roundID,
                timestamp: roundDate,
                providerName: cfg.displayName,
                providerKind: cfg.kind.rawValue,
                baseURL: cfg.baseURL,
                model: cfg.model,
                prompt: prompt,
                systemPrompt: sysPrompt,
                response: collected,
                elapsedSeconds: nil,
                error: failure,
                conversationTitle: convTitle,
                conversationID: convIDString
            ))

            guard let liveConvIdx = self.conversations.firstIndex(where: { $0.id == convID }),
                  let liveTurnIdx = self.conversations[liveConvIdx].turns.firstIndex(where: { $0.id == turnID }) else { return }

            self.patchTurnReasoningAndUsage(convIdx: liveConvIdx, turnIdx: liveTurnIdx, key: cfg.id.uuidString,
                                            reasoning: collectedReasoning, usage: usage)

            switch target {
            case .chair:
                if let failure {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].chairError = failure
                    self.conversations[liveConvIdx].turns[liveTurnIdx].chairSummary = collected.isEmpty ? nil : collected
                } else {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].chairError = nil
                    self.conversations[liveConvIdx].turns[liveTurnIdx].chairSummary = collected
                }
            case .summary:
                if let failure {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].summaryError = failure
                    self.conversations[liveConvIdx].turns[liveTurnIdx].summaryText = collected.isEmpty ? nil : collected
                } else {
                    self.conversations[liveConvIdx].turns[liveTurnIdx].summaryError = nil
                    self.conversations[liveConvIdx].turns[liveTurnIdx].summaryText = collected
                }
            }

            self.conversations[liveConvIdx].updatedAt = Date()
            ConversationStore.save(self.conversations[liveConvIdx])
        }
    }

    private func startLivePanelRound(_ panel: [ProviderConfig]) {
        liveStates.removeAll()
        for cfg in panel {
            let state = ResponseState(id: cfg.id)
            state.reset()
            liveStates[cfg.id] = state
        }
    }

    private func runPanelRound(
        panel: [ProviderConfig],
        prompts: [UUID: String],
        defaultPrompt: String,
        systemPrompt: String,
        roundDate: Date,
        roundID: String,
        images: [Attachment.ImagePayload],
        contextSummary: String?,
        priorTurns: [PriorTurn],
        tools: [LLMTool],
        toolContext: ToolContext?,
        conversationTitle: String,
        conversationID: String,
        maxToolRounds: Int = 6,
        agentInstruction: String? = nil
    ) async -> (responses: [String: String], errors: [String: String]) {
        startLivePanelRound(panel)

        var responses: [String: String] = [:]
        var errors: [String: String] = [:]
        await withTaskGroup(of: (UUID, String, String?).self) { group in
            for cfg in panel {
                let promptForProvider = prompts[cfg.id] ?? defaultPrompt
                let imagesForProvider = cfg.kind == .openAICompatible ? images : []
                group.addTask { [weak self] in
                    guard let self else { return (cfg.id, "", "释放") }
                    return await self.runOne(
                        config: cfg,
                        prompt: promptForProvider,
                        systemPrompt: systemPrompt,
                        roundDate: roundDate,
                        roundID: roundID,
                        target: .panel,
                        images: imagesForProvider,
                        contextSummary: contextSummary,
                        priorTurns: priorTurns,
                        tools: tools,
                        toolContext: toolContext,
                        conversationTitle: conversationTitle,
                        conversationID: conversationID,
                        maxToolRounds: maxToolRounds,
                        agentInstruction: agentInstruction
                    )
                }
            }
            for await (id, text, err) in group {
                if let err {
                    errors[id.uuidString] = err
                }
                responses[id.uuidString] = text
            }
        }
        return (responses, errors)
    }

    // MARK: - 深度研究(Direct 子模式)

    /// 跑一次深度研究:把直播状态(panel 首家的 ResponseState)交给 `DeepResearchEngine` 驱动,
    /// 来源经回调并入 `liveSources` / `state.sources`(落盘进 Turn.sources,角标 [n] 可点)。
    /// 返回值形状与 `runPanelRound` 一致,后续落盘逻辑零改动复用。
    private func runDeepResearch(
        config: ProviderConfig,
        question: String,
        systemPrompt: String,
        web: WebSearchSession,
        roundDate: Date,
        roundID: String,
        conversationTitle: String,
        conversationID: String
    ) async -> (responses: [String: String], errors: [String: String]) {
        guard let state = liveStates[config.id] else {
            return ([:], [config.id.uuidString: "状态丢失"])
        }
        let apiKey = config.kind.isCLI ? "" : ((try? KeychainStore.load(id: config.id)) ?? "")
        let engine = DeepResearchEngine(
            provider: config, apiKey: apiKey, web: web, state: state,
            onSources: { [weak self, weak state] refs in
                guard let self else { return }
                // 与 runOne 的 .sources 分支同款去重合并:全轮 liveSources + 本卡 state.sources。
                let known = Set(self.liveSources.map(\.url))
                self.liveSources.append(contentsOf: refs.filter { !known.contains($0.url) })
                if let state {
                    let stateKnown = Set(state.sources.map(\.url))
                    state.sources.append(contentsOf: refs.filter { !stateKnown.contains($0.url) })
                }
            }
        )
        let result = await engine.run(question: question, systemPrompt: systemPrompt)
        if let err = result.error {
            state.fail(err)
        } else {
            state.finish()
        }

        ResponseLogger.writeAsync(.init(
            roundID: roundID,
            timestamp: roundDate,
            providerName: config.displayName,
            providerKind: config.kind.rawValue,
            baseURL: config.baseURL,
            model: config.model,
            prompt: question,
            systemPrompt: systemPrompt,
            response: state.text,
            elapsedSeconds: state.elapsedSeconds,
            error: result.error,
            conversationTitle: conversationTitle,
            conversationID: conversationID
        ))

        var errors: [String: String] = [:]
        if let err = result.error { errors[config.id.uuidString] = err }
        return ([config.id.uuidString: state.text], errors)
    }

    // MARK: - Tournament(擂台 / 淘汰赛)裁定

    /// Tournament 模式:panel 各自回答后,由裁判(judge)用单淘汰赛逐对裁定胜者晋级,逐轮决出冠军。
    /// - panel 已经各自回答(responses/errors 是它们对原问题的回答)。
    /// - 每一轮把当前晋级者两两配对;奇数个时最后一个轮空(bye)直接晋级。
    /// - 每场对决调用 judge 取「胜者 + 理由」(逐场 await,顺序进行)。
    /// - 裁判失败/解析失败时降级:取 A 胜(若 B 失败/空)或默认 A,保证赛程能走完。
    /// 逐轮把进度写进 `liveTournamentRounds`(直播展示),最终返回完整的 `[TournamentRound]`。
    private func runTournamentJudging(
        panel: [ProviderConfig],
        judge: ProviderConfig?,
        promptSnapshot: String,
        responses: [String: String],
        errors: [String: String],
        sysSnapshot: String,
        contextSummary: String?,
        priorTurns: [PriorTurn],
        roundDate: Date,
        roundID: String,
        convTitle: String,
        convIDString: String,
        reasoningByProvider: inout [String: String],
        tokenUsage: inout [String: TurnTokenUsage],
        snapshot: inout [String: ProviderConfig]
    ) async -> [TournamentRound] {
        // 裁判:优先 chair,否则第一个 enabled 非 CLI;都没有就用 panel 第一个非 CLI。
        let judgeCfg = judge
            ?? self.providers.first(where: { $0.enabled && !$0.kind.isCLI })
            ?? panel.first(where: { !$0.kind.isCLI })
        if let judgeCfg { snapshot[judgeCfg.id.uuidString] = judgeCfg }

        func label(_ key: String) -> String {
            if let cfg = snapshot[key] { return PromptBuilders.providerLabel(cfg) }
            return "选手"
        }

        // 晋级者队列:初始为 panel 顺序。两两配对直到只剩 1 人(冠军)。
        var contenders: [String] = panel.map { $0.id.uuidString }
        guard contenders.count >= 2 else {
            // 只有 0/1 个选手,无需对决:直接给一轮空赛程(冠军即唯一选手)。
            if let only = contenders.first {
                let round = TournamentRound(index: 1, title: "决赛",
                    matches: [TournamentRound.Match(aProviderID: only, winnerProviderID: only,
                                                    rationale: "仅一位选手,直接夺冠")])
                self.liveTournamentRounds = [round]
                return [round]
            }
            return []
        }

        var rounds: [TournamentRound] = []
        var roundIndex = 1
        while contenders.count >= 2 {
            if Task.isCancelled { break }
            let matchCount = contenders.count / 2
            let isFinalRound = contenders.count == 2
            let title = PromptBuilders.tournamentRoundTitle(matchCount: matchCount, isFinalRound: isFinalRound)
            var round = TournamentRound(index: roundIndex, title: title, matches: [])
            self.liveTournamentRounds = rounds + [round]

            var winners: [String] = []
            var i = 0
            while i < contenders.count {
                if Task.isCancelled { break }
                let aKey = contenders[i]
                // 轮空(奇数个):A 直接晋级。
                if i + 1 >= contenders.count {
                    let m = TournamentRound.Match(aProviderID: aKey, bProviderID: nil,
                                                  winnerProviderID: aKey, rationale: "轮空,直接晋级")
                    round.matches.append(m)
                    winners.append(aKey)
                    self.liveTournamentRounds = rounds + [round]
                    i += 1
                    continue
                }
                let bKey = contenders[i + 1]
                let aErr = errors[aKey]
                let bErr = errors[bKey]
                let aResp = responses[aKey] ?? ""
                let bResp = responses[bKey] ?? ""

                var winnerKey: String
                var rationale: String
                var matchError: String? = nil

                // 一方失败/空 → 对方直接胜(不必调用裁判)。
                let aDead = (aErr?.isEmpty == false) || aResp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let bDead = (bErr?.isEmpty == false) || bResp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if aDead && !bDead {
                    winnerKey = bKey; rationale = "对手失败 / 空响应,直接晋级"
                } else if bDead && !aDead {
                    winnerKey = aKey; rationale = "对手失败 / 空响应,直接晋级"
                } else if aDead && bDead {
                    winnerKey = aKey; rationale = "双方均失败 / 空响应,按签位晋级"
                } else if let judgeCfg {
                    let matchPrompt = PromptBuilders.buildTournamentMatchPrompt(
                        originalPrompt: promptSnapshot,
                        aLabel: label(aKey), aResponse: aResp, aError: aErr,
                        bLabel: label(bKey), bResponse: bResp, bError: bErr
                    )
                    var collected = ""
                    var collectedReasoning = ""
                    do {
                        let apiKey = judgeCfg.kind.isCLI ? "" : ((try? KeychainStore.load(id: judgeCfg.id)) ?? "")
                        let client = ProviderRegistry.client(for: judgeCfg.kind)
                        var opts = self.optionsFor(config: judgeCfg, systemPromptOverride: sysSnapshot)
                        opts.contextSummary = contextSummary
                        opts.priorTurns = priorTurns
                        opts.temperature = 0.2
                        for try await chunk in client.stream(prompt: matchPrompt, options: opts, config: judgeCfg, apiKey: apiKey) {
                            if Task.isCancelled { break }
                            switch chunk {
                            case .text(let t): collected += t
                            case .reasoning(let r): collectedReasoning += r
                            case .usage(let inp, let out, let cached):
                                UsageStore.shared.record(providerKind: judgeCfg.kind, model: judgeCfg.model,
                                                         inputTokens: inp, outputTokens: out, cachedTokens: cached)
                            default: break
                            }
                        }
                    } catch {
                        matchError = error.localizedDescription
                    }
                    if let verdict = PromptBuilders.parseTournamentVerdict(from: collected) {
                        winnerKey = verdict.winnerIsA ? aKey : bKey
                        rationale = verdict.rationale
                    } else {
                        // 解析失败 → 降级取 A(并把裁判原文作理由,便于排查)。
                        winnerKey = aKey
                        rationale = collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "裁判未给出有效判决,按签位晋级"
                            : PromptBuilders.shorten(collected, max: 120)
                    }
                    if !collectedReasoning.isEmpty {
                        reasoningByProvider[judgeCfg.id.uuidString] = collectedReasoning
                    }
                } else {
                    winnerKey = aKey; rationale = "无可用裁判,按签位晋级"
                }

                let m = TournamentRound.Match(aProviderID: aKey, bProviderID: bKey,
                                              winnerProviderID: winnerKey, rationale: rationale, error: matchError)
                round.matches.append(m)
                winners.append(winnerKey)
                self.liveTournamentRounds = rounds + [round]
                i += 2
            }

            rounds.append(round)
            self.liveTournamentRounds = rounds
            contenders = winners
            roundIndex += 1
            if Task.isCancelled { break }
        }

        return rounds
    }

    private enum RunTarget { case panel, chair, summary }

    /// 跑一个 provider 的流式；返回 (id, finalText, error?)。
    private func runOne(
        config: ProviderConfig, prompt: String,
        systemPrompt: String, roundDate: Date, roundID: String,
        target: RunTarget,
        images: [Attachment.ImagePayload],
        contextSummary: String?,
        priorTurns: [PriorTurn],
        tools: [LLMTool],
        toolContext: ToolContext?,
        conversationTitle: String,
        conversationID: String,
        maxToolRounds: Int = 6,
        agentInstruction: String? = nil
    ) async -> (UUID, String, String?) {
        let state: ResponseState
        switch target {
        case .panel:
            guard let s = liveStates[config.id] else { return (config.id, "", "状态丢失") }
            state = s
        case .chair:
            guard let s = liveChairState else { return (config.id, "", "状态丢失") }
            state = s
        case .summary:
            guard let s = liveSummaryState else { return (config.id, "", "状态丢失") }
            state = s
        }
        var failure: String? = nil
        do {
            let key = config.kind.needsAPIKey ? (try KeychainStore.load(id: config.id)) : ""
            let client = ProviderRegistry.client(for: config.kind)
            var options = optionsFor(config: config, systemPromptOverride: systemPrompt)
            options.images = images
            options.contextSummary = contextSummary
            options.priorTurns = priorTurns
            options.tools = tools
            options.toolContext = toolContext
            options.maxToolRounds = maxToolRounds
            options.agentInstruction = agentInstruction
            // MARK: - [PII] 出站脱敏:云端 provider + 脱敏开关开时,把 prompt / system / 历史里的 PII
            // 替换成占位符发送;本地 provider(Ollama/localhost/CLI)跳过。返回的 restorer 在下方流式还原占位符。
            var outboundPrompt = prompt
            let restorer = self.applyPIIRedaction(config: config, prompt: &outboundPrompt, options: &options)
            // MARK: - [PII] end
            for try await chunk in client.stream(prompt: outboundPrompt, options: options, config: config, apiKey: key) {
                if Task.isCancelled { break }
                switch chunk {
                case .text(let t):       state.append(restorer?.push(t) ?? t)
                case .reasoning(let r):  state.appendReasoning(r)
                case .toolEvent(let e):  state.logEvent(e)
                case .toolStep(let s):
                    state.upsertToolStep(s)
                    // 深入模式(agentInstruction 非空)→ 同步推给 Live Activity(灵动岛)。
                    if agentInstruction != nil {
                        DeepTaskEvents.postToolStep(round: s.round + 1, displayName: s.displayName,
                                                    status: s.status.rawValue)
                    }
                case .sources(let refs):
                    // web_search 命中的来源:累积到本轮 liveSources(全轮合并,落盘进 Turn.sources),
                    // 同时按本卡 state 单独留一份(各 panel 小卡显示自己引用的地址),都按 url 去重。
                    let known = Set(self.liveSources.map(\.url))
                    self.liveSources.append(contentsOf: refs.filter { !known.contains($0.url) })
                    let stateKnown = Set(state.sources.map(\.url))
                    state.sources.append(contentsOf: refs.filter { !stateKnown.contains($0.url) })
                case .usage(let input, let output, let cached):
                    // 存进 state(回填进 Turn.tokenUsage 算成本)+ 记一笔到 UsageStore(按天分桶)
                    state.inputTokens = input
                    state.outputTokens = output
                    state.cachedInputTokens = cached
                    UsageStore.shared.record(
                        providerKind: config.kind,
                        model: config.model,
                        inputTokens: input,
                        outputTokens: output,
                        cachedTokens: cached
                    )
                }
            }
            if Task.isCancelled {
                state.fail("已取消")
                failure = "已取消"
            } else {
                // MARK: - [PII] 流末把还原器缓冲里残留的尾巴(可能是半截占位符)吐出,避免末尾占位符丢失。
                if let restorer, case let rest = restorer.flush(), !rest.isEmpty { state.append(rest) }
                // MARK: - [PII] end
                state.finish()
            }
        } catch is CancellationError {
            state.fail("已取消")
            failure = "已取消"
        } catch {
            state.fail(error.localizedDescription)
            failure = error.localizedDescription
        }

        // 自动容错:panel provider 真失败(非取消)且开关开 → 换另一家 enabled provider 重试一次(纯文本)。
        if target == .panel, let f = failure, f != "已取消", autoFailoverEnabled,
           let alt = providers.first(where: { $0.enabled && !$0.kind.isCLI && $0.id != config.id && KeychainStore.hasKey(id: $0.id) }) {
            do {
                let altKey = try KeychainStore.load(id: alt.id)
                let altClient = ProviderRegistry.client(for: alt.kind)
                var opts = optionsFor(config: alt, systemPromptOverride: systemPrompt)
                opts.contextSummary = contextSummary
                opts.priorTurns = priorTurns
                state.reset()
                state.append("(原「\(config.displayName)」失败,已自动切换到「\(alt.displayName)」)\n\n")
                // MARK: - [PII] 自动容错也走脱敏(按替补 provider 的本地/云端判断),并流式还原。
                var altPrompt = prompt
                let altRestorer = self.applyPIIRedaction(config: alt, prompt: &altPrompt, options: &opts)
                // MARK: - [PII] end
                for try await chunk in altClient.stream(prompt: altPrompt, options: opts, config: alt, apiKey: altKey) {
                    if Task.isCancelled { break }
                    if case .text(let t) = chunk { state.append(altRestorer?.push(t) ?? t) }
                    else if case .reasoning(let r) = chunk { state.appendReasoning(r) }
                    else if case .usage(let i, let o, let cached) = chunk {
                        state.inputTokens = i
                        state.outputTokens = o
                        state.cachedInputTokens = cached
                        UsageStore.shared.record(providerKind: alt.kind, model: alt.model, inputTokens: i, outputTokens: o, cachedTokens: cached)
                    }
                }
                // MARK: - [PII] 流末还原残留尾巴。
                if !Task.isCancelled, let altRestorer, case let rest = altRestorer.flush(), !rest.isEmpty { state.append(rest) }
                // MARK: - [PII] end
                if !Task.isCancelled { state.finish(); failure = nil }
            } catch {
                state.fail(f)  // 容错也失败 → 恢复展示原错误
            }
        }

        let entry = ResponseLogger.Entry(
            roundID: roundID,
            timestamp: roundDate,
            providerName: config.displayName,
            providerKind: config.kind.rawValue,
            baseURL: config.baseURL,
            model: config.model,
            prompt: prompt,
            systemPrompt: systemPrompt,
            response: state.text,
            elapsedSeconds: state.elapsedSeconds,
            error: failure,
            conversationTitle: conversationTitle,
            conversationID: conversationID
        )
        ResponseLogger.writeAsync(entry)

        return (config.id, state.text, failure)
    }

    // MARK: - [PII] 出站脱敏接线
    /// 隐私脱敏开关开 + provider 是云端时,把 `prompt` 与 `options`(system / contextSummary / priorTurns)里的
    /// PII 假名化(共用一份映射),返回用于流式还原占位符的 `StreamingRestorer`;
    /// 关闭 / 本地 provider / 无 PII 命中时原样返回 nil(调用点据此直通)。
    private func applyPIIRedaction(config: ProviderConfig,
                                   prompt: inout String,
                                   options: inout ChatOptions) -> PIIRedactor.StreamingRestorer? {
        let settings = PIIRedactor.currentSettings()
        guard settings.active else { return nil }
        guard !PIIRedactor.isLocalProvider(config) else { return nil }   // 本地不出本机,跳过

        var map = PIIRedactor.RedactionMap()
        // 顺序:prompt → systemPrompt → contextSummary → priorTurns,共用同一份 map(同一原文复用同一占位符)。
        let p = PIIRedactor.redact(prompt, settings: settings, map: map)
        prompt = p.text; map = p.map
        if let sys = options.systemPrompt {
            let r = PIIRedactor.redact(sys, settings: settings, map: map)
            options.systemPrompt = r.text; map = r.map
        }
        if let sum = options.contextSummary {
            let r = PIIRedactor.redact(sum, settings: settings, map: map)
            options.contextSummary = r.text; map = r.map
        }
        if !options.priorTurns.isEmpty {
            options.priorTurns = options.priorTurns.map { turn in
                let u = PIIRedactor.redact(turn.userText, settings: settings, map: map)
                map = u.map
                let a = PIIRedactor.redact(turn.assistantText, settings: settings, map: map)
                map = a.map
                return PriorTurn(userText: u.text, assistantText: a.text)
            }
        }
        // 一处 PII 都没命中 → 无需还原,直通(省掉流式还原开销)。
        guard !map.isEmpty else { return nil }
        return PIIRedactor.StreamingRestorer(map: map)
    }
    // MARK: - [PII] end

    private func optionsFor(config: ProviderConfig, systemPromptOverride: String) -> ChatOptions {
        let sys = systemPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        // 会话级生成参数覆盖优先(设置入口:会话参数面板);未设则回退 provider 配置。
        let conv = selectedConversation
        return ChatOptions(
            systemPrompt: sys.isEmpty ? nil : sys,
            temperature: conv?.conversationTemperature ?? config.temperature,
            topP: conv?.conversationTopP,
            maxTokens: conv?.conversationMaxTokens ?? config.maxTokens
        )
    }
}
