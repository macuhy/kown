import Foundation

/// 「AI 现做交互小工具」(Generative UI)的核心服务。两件事:
/// 1) **产出工具规格** —— 用 `StructuredOutput` 约束模型输出「自包含 HTML + 它会发起哪些回调」(JSON),
///    解析成 `GenerativeToolSpec`。
/// 2) **处理工具发来的回调** —— 校验回调已声明 → 按 kind 走 LLM(再调一次模型)或 compute(本机 `CodeSandboxService`)
///    → 把结果折叠成 `GenerativeToolResult` 回填工具。
///
/// 纯逻辑、跨平台,无 UI 依赖;所有模型/代码调用都在调用点的后台 Task 里 await,绝不阻塞主线程
/// (对齐 CPU 卡死不变量:重活走后台 / actor)。
enum GenerativeToolService {

    // MARK: - 生成工具规格的 prompt(StructuredOutput 约束)

    /// 工具规格的 JSON Schema(喂给 `StructuredOutput.buildStructuredPrompt`,逼模型出合法 JSON)。
    static let specSchema = """
    {
      "title": "string — 工具标题(中文,简短,如『房贷月供计算器』)",
      "summary": "string — 一句话说明这个工具能做什么",
      "html": "string — 一个自包含的完整 HTML 文档(含 <!doctype html>),所有 CSS / JS 必须内联,绝对不要引用任何 CDN、外链脚本或外部图片。这是一个可交互的 mini-app。",
      "callbacks": [
        {
          "name": "string — 回调名(英文小写下划线,在本工具内唯一,如 ask_model / compute_stats)",
          "kind": "string — 必须是 \\"llm\\" 或 \\"compute\\" 之一",
          "purpose": "string — 这个回调做什么、期望什么入参、回填什么结果"
        }
      ]
    }
    """

    /// 系统指令:讲清楚「生成式 UI」范式 + 桥接 API 契约 + 安全边界。
    static func specSystemPrompt(codeExecAvailable: Bool) -> String {
        let computeNote = codeExecAvailable
            ? "- kind=\"compute\":宿主会用本机解释器执行你回填的代码。入参里放 { \"code\": \"...\", \"language\": \"python\" 或 \"javascript\" },宿主返回 { stdout, stderr, exitCode }。"
            : "- kind=\"compute\":当前设备未开启代码执行,**不要**声明 compute 回调;需要计算就在工具自己的 JS 里算,或用 llm 回调。"
        return """
        你是一个「生成式 UI」工具构造器。用户有一个问题或需求,你要为它现做一个**能用的交互式 mini-app**
        (例如:贷款月供计算器、可筛选排序的数据表、可调参数的图表、单位换算器、决策打分器…)。

        这个工具最强的地方是它能**回调你(模型)**:用户在工具里操作时,工具的 JS 可以把请求发回宿主,
        宿主再调用你或本机能力,把结果回填到工具里。请充分利用这一点,让工具不只是静态展示。

        【宿主提供的桥接 API —— 在你的 HTML 内联 JS 里直接用】
        - 调用回调(返回 Promise):
            const res = await window.kown.call("<回调名>", { ...入参 });
            // 成功:res.ok === true,结果在 res.value;失败:res.ok === false,原因在 res.error
        - 你**只能**调用你在 callbacks 里声明过的回调名,否则宿主会拒绝。
        - kind="llm":宿主把入参拼成 prompt 调模型,res.value 是模型的文本回答(你可以约定让它回 JSON 字符串再自己 parse)。
        \(computeNote)
        - 不需要回调的纯前端逻辑(简单算术、筛选、排序、画 SVG/canvas)就直接在 JS 里写,不要为它声明回调。

        【硬性要求】
        1. html 必须是**单个自包含文档**:内联所有 CSS 和 JS,绝不引用 CDN、外部脚本、外部样式或外链图片(会被宿主拦截,加载失败)。
        2. 界面要适配深浅色(可用 prefers-color-scheme),宽度自适应(手机和桌面都能用)。
        3. JS 要健壮:对 window.kown 不存在的情况要降级(纯静态也能看),对回调失败要在界面上给出可读提示,绝不白屏。
        4. 回调要有清晰边界:每个声明的回调都要有明确用途,入参精简。
        5. 不要在 JS 里尝试访问网络(fetch/XHR)、本地存储以外的系统资源 —— 需要外部数据就通过 llm 回调让模型给。
        """
    }

    /// 「让 AI 改这个工具」的系统指令:在现有工具基础上改,仍返回同一份规格 JSON。
    static func revisionSystemPrompt(codeExecAvailable: Bool) -> String {
        specSystemPrompt(codeExecAvailable: codeExecAvailable) + """


        【本次是修改任务】
        用户会给你**当前工具的规格**和修改要求。在保留原有可用功能与回调契约的前提下按要求修改,
        仍然返回**完整的**新规格(html 要是改完后的完整文档,不是 diff;callbacks 要是改完后的完整列表)。
        """
    }

    /// 生成工具的 user prompt:用户原始需求(+ 可选的「来自某条回答」上下文)。
    static func generationPrompt(userNeed: String, sourceAnswer: String?) -> String {
        var lines: [String] = []
        lines.append("【用户需求 —— 为它造一个交互工具】")
        lines.append(userNeed.trimmingCharacters(in: .whitespacesAndNewlines))
        if let src = sourceAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !src.isEmpty {
            lines.append("")
            lines.append("【可参考的已有回答 —— 工具可基于这里的数据/逻辑构建】")
            lines.append(String(src.prefix(4000)))
        }
        return lines.joined(separator: "\n")
    }

    /// 修改工具的 user prompt:当前规格全文 + 修改要求。
    static func revisionPrompt(currentSpec: GenerativeToolSpec, instruction: String) -> String {
        var lines: [String] = []
        lines.append("【当前工具规格】")
        lines.append("标题:\(currentSpec.title)")
        lines.append("说明:\(currentSpec.summary)")
        if !currentSpec.callbacks.isEmpty {
            lines.append("已声明回调:")
            for cb in currentSpec.callbacks {
                lines.append("- \(cb.name) (\(cb.kind.rawValue)): \(cb.purpose)")
            }
        }
        lines.append("当前 HTML:")
        lines.append("```html")
        lines.append(currentSpec.html)
        lines.append("```")
        lines.append("")
        lines.append("【修改要求】")
        lines.append(instruction.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }

    // MARK: - 解析模型回答 → GenerativeToolSpec

    /// 从模型回答里抽出工具规格 JSON 并解析成 `GenerativeToolSpec`。
    /// 复用 `StructuredOutput.extractJSON` 剥围栏/配平括号;html 字段可能很长,JSONSerialization 全程吃得下。
    /// 解析失败时尽量给出可诊断原因。
    static func parseSpec(from reply: String) throws -> GenerativeToolSpec {
        guard let jsonText = StructuredOutput.extractJSON(from: reply),
              let data = jsonText.data(using: .utf8) else {
            throw GenerativeToolError.parseFailed("未在回答里找到 JSON 对象")
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw GenerativeToolError.parseFailed(error.localizedDescription)
        }
        guard let dict = obj as? [String: Any] else {
            throw GenerativeToolError.parseFailed("顶层不是 JSON 对象")
        }
        let html = (dict["html"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !html.isEmpty else {
            throw GenerativeToolError.parseFailed("缺少 html 字段或为空")
        }
        let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "交互工具"
        let summary = (dict["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var callbacks: [GenerativeCallback] = []
        if let rawCBs = dict["callbacks"] as? [[String: Any]] {
            for raw in rawCBs {
                guard let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty,
                      let kindRaw = (raw["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      let kind = GenerativeCallback.Kind(rawValue: kindRaw) else { continue }
                let purpose = (raw["purpose"] as? String) ?? ""
                // 去重:同名回调只留第一个。
                if callbacks.contains(where: { $0.name == name }) { continue }
                callbacks.append(GenerativeCallback(name: name, kind: kind, purpose: purpose))
            }
        }
        return GenerativeToolSpec(title: title, summary: summary, html: html, callbacks: callbacks)
    }

    // MARK: - 处理一次工具回调

    /// 处理工具发来的一次回调:校验已声明 + kind 分发,把结果折叠成 `GenerativeToolResult`。
    /// 永不抛错 —— 所有失败都进 result.error,JS 侧据此 reject 并在工具里提示。
    ///
    /// - llm:用 `runLLM` 把入参拼 prompt 调模型,回文本。
    /// - compute:用 `CodeSandboxService` 跑入参里的代码,回 { stdout, stderr, exitCode }。
    ///
    /// 入参:
    /// - request:JS 发来的请求(已解析)。
    /// - spec:当前工具规格(用于校验回调声明)。
    /// - runLLM:调模型的闭包(由 ViewModel 注入,带当前会话的 provider/key);入参 prompt → 文本回答。
    /// - codeExecEnabled:代码执行总开关快照(关闭时拒绝 compute 回调)。
    static func handle(
        request: GenerativeToolRequest,
        spec: GenerativeToolSpec,
        codeExecEnabled: Bool,
        runLLM: @Sendable (_ prompt: String, _ system: String) async throws -> String
    ) async -> GenerativeToolResult {
        // 安全边界:只处理工具声明过的回调。
        guard let cb = spec.callback(named: request.callback) else {
            return .failure(requestID: request.requestID,
                            error: GenerativeToolError.unknownCallback(request.callback).localizedDescription)
        }
        switch cb.kind {
        case .llm:
            return await handleLLM(request: request, callback: cb, runLLM: runLLM)
        case .compute:
            guard codeExecEnabled else {
                return .failure(requestID: request.requestID,
                                error: GenerativeToolError.callbackDisabled(cb.name).localizedDescription)
            }
            return await handleCompute(request: request)
        }
    }

    /// llm 回调:把回调用途 + 入参拼成 prompt,调模型,回文本。
    /// 入参里若有 `prompt` 字段直接当主指令;否则把整个 args JSON 交给模型,让它按 callback.purpose 处理。
    private static func handleLLM(
        request: GenerativeToolRequest,
        callback: GenerativeCallback,
        runLLM: @Sendable (_ prompt: String, _ system: String) async throws -> String
    ) async -> GenerativeToolResult {
        let args = request.args
        let directPrompt = (args["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // 入参序列化成紧凑 JSON 给模型当上下文(已在 init 里校验过合法性)。
        let argsBlock = request.argsJSON
        let system = """
        你是一个交互工具的后端处理器。工具会把用户操作作为一次请求发给你,你只返回结果本身,
        不要寒暄、不要解释过程、不要用 markdown 代码块包裹(除非结果本身就是代码)。
        这个回调的用途是:\(callback.purpose)
        """
        let userPrompt: String
        if let p = directPrompt, !p.isEmpty {
            userPrompt = p
        } else {
            userPrompt = """
            回调名:\(callback.name)
            入参(JSON):
            \(argsBlock)

            请按上面「用途」处理这些入参,直接给出结果。
            """
        }
        do {
            let reply = try await runLLM(userPrompt, system)
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure(requestID: request.requestID, error: "模型返回为空")
            }
            return .successText(requestID: request.requestID, trimmed)
        } catch {
            return .failure(requestID: request.requestID, error: error.localizedDescription)
        }
    }

    /// compute 回调:跑入参里的代码,回 { stdout, stderr, exitCode, timedOut }。
    private static func handleCompute(request: GenerativeToolRequest) async -> GenerativeToolResult {
        let args = request.args
        let code = (args["code"] as? String) ?? ""
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(requestID: request.requestID, error: "compute 回调缺少 code 入参")
        }
        // 语言:入参指定优先,否则按平台默认(iOS 只有 JS,macOS 默认 python)。
        let lang = (args["language"] as? String) ?? Self.defaultComputeLanguage
        let r = await CodeSandboxService.run(language: lang, code: code)
        if let failure = r.failureReason {
            return .failure(requestID: request.requestID, error: failure)
        }
        let value: [String: Any] = [
            "stdout": r.stdout,
            "stderr": r.stderr,
            "exitCode": Int(r.exitCode),
            "timedOut": r.timedOut,
            "durationMs": r.durationMS
        ]
        return .success(requestID: request.requestID, value: value)
    }

    /// compute 默认语言:iOS 只有 JavaScriptCore;macOS 默认 python(也支持 js)。
    private static var defaultComputeLanguage: String {
        #if os(iOS)
        return "javascript"
        #else
        return "python"
        #endif
    }
}
