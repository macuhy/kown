import Foundation

/// 本次发送中 Persona 的「展开结果」:把激活 Persona 的 系统提示 + 绑定技能 + 工具开关 +
/// 知识库 + 模型覆盖 预先解析成 send() 可直接消费的快照,让 AppViewModel+Send 的改动保持最小。
/// 无激活 Persona 时为全空默认值,send() 各注入点等价于原行为。
struct PersonaSendEffects: Sendable {
    /// 激活的 Persona(nil = 本会话未选 Persona)。
    var persona: Persona? = nil
    /// 注入到 system prompt 前段的文本:Persona 系统提示 + 绑定技能的 instructions(按绑定顺序)。
    var systemPromptPrefix: String = ""
    /// 绑定技能点名的工具白名单(并入本次发送的 extraToolNames)。
    var extraToolNames: Set<String> = []
    /// Persona 默认点亮的工具开关(与输入栏开关取「或」,只增不减)。
    var webSearch = false
    var deviceTools = false
    var mcp = false
    /// Persona 绑定的知识库资料夹(会话自己绑了时以会话为准,见调用点)。
    var knowledgeFolder: KnowledgeFolder? = nil
    /// 模型覆盖:Persona 指定 provider(+ 可选 model)时解析出的配置。
    var modelOverride: ProviderConfig? = nil

    /// 把模型覆盖应用到 panel:仅单模型路径(Direct / Translate)生效,
    /// 多列模式(Council/Compare/…)由用户面板决定,Persona 不插手。
    func applyingModelOverride(to panel: [ProviderConfig], mode: ConversationMode) -> [ProviderConfig] {
        guard let override = modelOverride,
              mode == .direct || mode == .translate,
              !panel.isEmpty else { return panel }
        var result = panel
        result[0] = override
        return result
    }
}

extension AppViewModel {
    // MARK: - Persona(会话绑定)

    /// 当前会话激活的 Persona(如有)。
    var currentPersona: Persona? {
        personaStore.persona(id: selectedConversation?.personaID)
    }

    /// 给当前会话绑定 / 解绑 Persona(nil = 解绑)。没有会话时先开一个(沿用 setDirectChoice 的习惯)。
    func setSelectedPersona(_ id: UUID?) {
        if selectedConversationID == nil {
            guard id != nil else { return }
            newConversation(mode: activeMode)
        }
        guard let convID = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        conversations[idx].personaID = id
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }

    /// 解析当前会话激活 Persona 的发送期效果(系统提示 / 技能 / 工具开关 / 知识库 / 模型覆盖)。
    /// 在 send() 主线程快照阶段调用一次,后续注入点只读返回值。
    func personaEffectsForSend() -> PersonaSendEffects {
        guard let persona = currentPersona else { return PersonaSendEffects() }
        var fx = PersonaSendEffects()
        fx.persona = persona
        fx.webSearch = persona.enableWebSearch
        fx.deviceTools = persona.enableDeviceTools
        fx.mcp = persona.enableMCP

        // 系统提示:Persona 提示词 + 绑定技能 instructions(渲染 {{变量}} 用空值,与手动技能一致)。
        var parts: [String] = []
        let prompt = persona.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { parts.append(prompt) }
        for skillID in persona.skillIDs {
            guard let skill = skillsStore.skill(id: skillID), skill.enabled else { continue }
            let body = skillsStore.render(skill, values: [:])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { parts.append(body) }
            fx.extraToolNames.formUnion(skill.allowedTools)
        }
        fx.systemPromptPrefix = parts.joined(separator: "\n\n")

        // 知识库:Persona 绑定的资料夹(可能已被删除 → nil 静默降级)。
        if let fid = persona.knowledgeFolderID {
            fx.knowledgeFolder = knowledgeFolders.first { $0.id == fid }
        }

        // 模型覆盖:provider 必须仍存在;model 覆盖为空时用该 provider 配置的默认 model。
        if let pid = persona.providerID,
           var cfg = providers.first(where: { $0.id == pid }) {
            if let m = persona.modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                cfg.model = m
            }
            fx.modelOverride = cfg
        }
        return fx
    }
}
