import Foundation

/// 「AI 现做交互小工具」(Generative UI)的 ViewModel 入口:
/// 从某条回答 / 当前输入一键生成交互工具、迭代修改、以及处理工具发来的回调(分发给 `GenerativeToolService`)。
///
/// 所有模型调用都走独立的轻量流式收集(不进主对话流、不动 liveStates / isRunning),
/// 与 `runArtifactRevision` 同款;重活在后台 Task await,主线程只更新 @Observable 状态。
@MainActor
extension AppViewModel {

    // MARK: - 能力探测

    /// 当前是否可生成交互工具:至少一个 enabled 非 CLI provider(CLI 输出不可控,JSON 规格不可靠)。
    var canGenerateTool: Bool {
        providersForCurrentSend().panel.contains(where: { !$0.kind.isCLI })
            || providers.contains(where: { $0.enabled && !$0.kind.isCLI })
    }

    /// 选当前会话将用的非 CLI provider(优先 panel 首个,否则第一个 enabled 非 CLI)。
    private var toolProvider: ProviderConfig? {
        providersForCurrentSend().panel.first(where: { !$0.kind.isCLI })
            ?? providers.first(where: { $0.enabled && !$0.kind.isCLI })
    }

    // MARK: - 单次 LLM 调用(独立,不进主对话)

    /// 用当前会话将用的模型做一次独立调用,收集纯文本回复(生成规格 / 处理 llm 回调共用)。
    /// CLI provider 跳过。`temperature` 默认 0.4(规格生成要点创造力,但别太发散)。
    func runToolLLM(prompt: String, systemPrompt: String, temperature: Double = 0.4) async throws -> String {
        guard let provider = toolProvider else { throw GenerativeToolError.noProvider }
        let key = try KeychainStore.load(id: provider.id)
        let client = ProviderRegistry.client(for: provider.kind)
        let options = ChatOptions(systemPrompt: systemPrompt, temperature: temperature, maxTokens: 8000)
        var collected = ""
        for try await chunk in client.stream(
            prompt: prompt, options: options, config: provider, apiKey: key
        ) {
            if case .text(let t) = chunk { collected += t }
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GenerativeToolError.emptyReply }
        return trimmed
    }

    /// 构造一个 `@Sendable` 的 LLM 回调闭包,供 `GenerativeToolService.handle` 在后台处理工具回调时调用。
    /// 闭包内捕获 provider/key 的不可变快照,流式收集在调用点(后台)完成,不回主线程。
    private func makeToolLLMRunner() -> (@Sendable (_ prompt: String, _ system: String) async throws -> String)? {
        guard let provider = toolProvider,
              let key = try? KeychainStore.load(id: provider.id) else { return nil }
        let client = ProviderRegistry.client(for: provider.kind)
        return { prompt, system in
            let options = ChatOptions(systemPrompt: system, temperature: 0.3, maxTokens: 4000)
            var collected = ""
            for try await chunk in client.stream(
                prompt: prompt, options: options, config: provider, apiKey: key
            ) {
                if case .text(let t) = chunk { collected += t }
            }
            return collected.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - 生成 / 修改

    /// 代码执行是否可用(compute 回调要它;决定生成 prompt 里要不要鼓励 compute)。
    private var codeExecAvailable: Bool { CodeExecToolState.shared.isEnabled }

    /// 从某条回答一键「生成交互工具」:取该轮问题 + 回答作为上下文,让模型造一个工具。
    func generateTool(fromTurnID turnID: UUID) {
        guard let conv = selectedConversation,
              let turn = conv.turns.first(where: { $0.id == turnID }) else { return }
        let answer = turn.chairSummary ?? turn.summaryText
            ?? turn.responses.values.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let need = turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        startGeneration(userNeed: need.isEmpty ? "为这次回答做一个相关的交互工具" : need,
                        sourceAnswer: answer.isEmpty ? nil : answer,
                        sourceTurnID: turnID)
    }

    /// 从当前输入框文本生成交互工具(输入框非空时可用;不消费输入框,只读取)。
    func generateToolFromInput() {
        let need = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !need.isEmpty else {
            generativeToolError = "先在输入框写下你想要的工具(如『做个房贷计算器』)。"
            showGenerativeToolPanel = true
            return
        }
        startGeneration(userNeed: need, sourceAnswer: nil, sourceTurnID: nil)
    }

    /// 共用的生成流程:打开面板 → 调模型出规格 → 解析 → 落盘 → 展示。
    private func startGeneration(userNeed: String, sourceAnswer: String?, sourceTurnID: UUID?) {
        guard !generatingTool else { return }
        guard canGenerateTool else {
            generativeToolError = "没有可用的 API provider:生成交互工具需要带 API key 的 provider(CLI 不支持)。"
            showGenerativeToolPanel = true
            return
        }
        // 确保有承载会话(从输入框直接造时可能还没会话)。
        if selectedConversationID == nil { newConversation(mode: currentMode) }
        guard let convID = selectedConversationID else { return }

        generatingTool = true
        generativeToolError = nil
        showGenerativeToolPanel = true
        let execAvailable = codeExecAvailable
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.generatingTool = false }
            do {
                let reply = try await self.runToolLLM(
                    prompt: GenerativeToolService.generationPrompt(userNeed: userNeed, sourceAnswer: sourceAnswer),
                    systemPrompt: GenerativeToolService.specSystemPrompt(codeExecAvailable: execAvailable)
                )
                let spec = try GenerativeToolService.parseSpec(from: reply)
                let stored = GenerativeToolStore.append(
                    StoredGenerativeTool(sourceTurnID: sourceTurnID, spec: spec),
                    conversationID: convID
                )
                self.activeGenerativeTool = stored
            } catch {
                self.generativeToolError = error.localizedDescription
            }
        }
    }

    /// 「让 AI 改这个工具」:在当前 active 工具的规格上按要求修改,产出新规格(version +1)。
    func runToolRevision(instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !generatingTool,
              let tool = activeGenerativeTool,
              let convID = selectedConversationID else { return }
        generatingTool = true
        generativeToolError = nil
        let currentSpec = tool.spec
        let toolID = tool.id
        let execAvailable = codeExecAvailable
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.generatingTool = false }
            do {
                let reply = try await self.runToolLLM(
                    prompt: GenerativeToolService.revisionPrompt(currentSpec: currentSpec, instruction: trimmed),
                    systemPrompt: GenerativeToolService.revisionSystemPrompt(codeExecAvailable: execAvailable)
                )
                let newSpec = try GenerativeToolService.parseSpec(from: reply)
                GenerativeToolStore.update(toolID: toolID, conversationID: convID, newSpec: newSpec)
                // 刷新 active(取回 bump 后的 version / updatedAt)。
                self.activeGenerativeTool = GenerativeToolStore.tools(conversationID: convID)
                    .first(where: { $0.id == toolID })
            } catch {
                self.generativeToolError = error.localizedDescription
            }
        }
    }

    /// 打开历史里某条已生成的工具到面板。
    func openGenerativeTool(_ tool: StoredGenerativeTool) {
        activeGenerativeTool = tool
        generativeToolError = nil
        showGenerativeToolPanel = true
    }

    /// 删除某条工具;若删的是当前 active,顺手清空 active。
    func deleteGenerativeTool(_ toolID: UUID) {
        guard let convID = selectedConversationID else { return }
        GenerativeToolStore.remove(toolID: toolID, conversationID: convID)
        if activeGenerativeTool?.id == toolID {
            activeGenerativeTool = GenerativeToolStore.tools(conversationID: convID).last
        }
    }

    /// 当前会话已生成的全部工具(面板里切换 / 历史菜单用)。
    var generativeToolsForCurrentConversation: [StoredGenerativeTool] {
        guard let convID = selectedConversationID else { return [] }
        return GenerativeToolStore.tools(conversationID: convID)
    }

    // MARK: - 处理工具回调(JS → Swift 桥的落点)

    /// 处理工具(WebView)发来的一次回调请求,返回结果(由 View 的 `WKScriptMessageHandler` 调用后回填 JS)。
    /// 永不抛错;所有失败折叠进 `GenerativeToolResult.error`。
    /// 校验:回调必须属于当前 active 工具且已声明(`GenerativeToolService.handle` 内再校验一次,双保险)。
    func handleToolCallback(_ request: GenerativeToolRequest) async -> GenerativeToolResult {
        guard let spec = activeGenerativeTool?.spec else {
            return .failure(requestID: request.requestID, error: "工具已关闭,无法处理回调")
        }
        guard let runner = makeToolLLMRunner() else {
            return .failure(requestID: request.requestID,
                            error: GenerativeToolError.noProvider.localizedDescription)
        }
        let execEnabled = CodeExecToolState.shared.isEnabled
        return await GenerativeToolService.handle(
            request: request,
            spec: spec,
            codeExecEnabled: execEnabled,
            runLLM: runner
        )
    }
}
