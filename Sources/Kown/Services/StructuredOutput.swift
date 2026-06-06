import Foundation

/// Structured 模式的核心工具:JSON Schema 预设、prompt 构建、从回答里抽取 JSON、轻量校验。
/// 纯逻辑、可跨平台,无任何 UI / 平台依赖,SwiftPM / iOS / mac 三端共用。
enum StructuredOutput {

    // MARK: - Schema 预设

    /// 一个常用的 JSON Schema 模板(供 UI 里一键填入)。
    struct SchemaPreset: Identifiable, Hashable {
        var id: String { title }
        let title: String
        let schema: String
    }

    /// 内置预设:覆盖「优缺点评分」「实体抽取」「待办分解」「情感分析」几个高频场景。
    static let presets: [SchemaPreset] = [
        SchemaPreset(
            title: "优缺点 + 评分",
            schema: """
            {
              "name": "string — 方案/选项名称",
              "pros": ["string — 优点,逐条列出"],
              "cons": ["string — 缺点,逐条列出"],
              "score": "number — 0 到 10 的综合评分"
            }
            """
        ),
        SchemaPreset(
            title: "实体抽取",
            schema: """
            {
              "summary": "string — 一句话摘要",
              "entities": [
                {
                  "name": "string — 实体名",
                  "type": "string — 类型(人物/地点/组织/时间/其他)"
                }
              ]
            }
            """
        ),
        SchemaPreset(
            title: "任务分解",
            schema: """
            {
              "goal": "string — 目标概述",
              "steps": [
                {
                  "title": "string — 步骤标题",
                  "detail": "string — 该步骤说明",
                  "estimate": "string — 预计耗时"
                }
              ]
            }
            """
        ),
        SchemaPreset(
            title: "情感分析",
            schema: """
            {
              "sentiment": "string — positive / neutral / negative",
              "confidence": "number — 0 到 1 的置信度",
              "keywords": ["string — 影响判断的关键词"]
            }
            """
        )
    ]

    /// 默认填入新 structured 会话的 schema(取第一个预设)。
    static var defaultSchema: String { presets.first?.schema ?? "{}" }

    // MARK: - prompt 构建

    /// 给每个模型发送的 prompt:把用户问题 + schema 拼起来,强制只输出严格 JSON。
    /// 全 provider 通用(纯 prompt 指令 + 输出解析),不依赖各家的 response_format,避免 provider 差异炸裂。
    static func buildStructuredPrompt(userPrompt: String, schema: String) -> String {
        let trimmedSchema = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        let schemaBlock = trimmedSchema.isEmpty ? "{}" : trimmedSchema
        return """
        请根据下面的「任务」回答,并严格按「JSON Schema」返回结果。

        【任务】
        \(userPrompt)

        【JSON Schema】
        \(schemaBlock)

        【输出要求 — 必须严格遵守】
        - 只输出一个合法的 JSON 对象,不要输出任何解释文字。
        - 不要使用 markdown 代码块(不要写 ```json 或 ```)。
        - 不要在 JSON 前后添加任何额外字符。
        - schema 中字段值里的描述(如 "string — xxx")只是对该字段的说明,请用真实内容替换,不要原样照抄说明文字。
        - 保证 JSON 可被标准解析器直接解析。
        """
    }

    // MARK: - 抽取 + 校验

    /// 校验结果:解析成功时带格式化后的 JSON 文本 + 顶层键;失败时带错误信息(仍保留原始文本兜底)。
    struct ValidationResult: Equatable {
        var isValid: Bool
        /// 解析并美化(缩进)后的 JSON 文本;失败时为 nil。
        var prettyJSON: String?
        /// 解析出的顶层对象的键(用于「必须键是否齐全」提示)。
        var topLevelKeys: [String]
        /// schema 要求但回答里缺失的顶层键(轻量检查)。
        var missingKeys: [String]
        /// 人类可读的错误/警告信息(无问题时为 nil)。
        var error: String?
    }

    /// 从模型回答里抽出 JSON(剥掉 ```json 围栏 / 前后说明),解析,并对照 schema 的顶层必须键做轻量校验。
    static func validate(responseText: String, schema: String) -> ValidationResult {
        let extracted = extractJSON(from: responseText)
        guard let extracted, let data = extracted.data(using: .utf8) else {
            return ValidationResult(isValid: false, prettyJSON: nil, topLevelKeys: [],
                                    missingKeys: [], error: "未能从回答里找到 JSON 对象")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return ValidationResult(isValid: false, prettyJSON: nil, topLevelKeys: [],
                                    missingKeys: [], error: "JSON 解析失败:\(error.localizedDescription)")
        }
        // 美化输出(失败就退回 extracted 原文)
        let pretty: String = {
            guard JSONSerialization.isValidJSONObject(object),
                  let d = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                  let s = String(data: d, encoding: .utf8) else { return extracted }
            return s
        }()

        guard let dict = object as? [String: Any] else {
            // 不是对象(可能是数组/标量)— 解析成功但不符合「JSON 对象」约定。
            return ValidationResult(isValid: false, prettyJSON: pretty, topLevelKeys: [],
                                    missingKeys: [], error: "返回的不是 JSON 对象(顶层应为 { })")
        }

        let keys = Array(dict.keys).sorted()
        let required = requiredTopLevelKeys(from: schema)
        let missing = required.filter { dict[$0] == nil }
        if !missing.isEmpty {
            return ValidationResult(isValid: false, prettyJSON: pretty, topLevelKeys: keys,
                                    missingKeys: missing,
                                    error: "缺少必须字段:\(missing.joined(separator: "、"))")
        }
        return ValidationResult(isValid: true, prettyJSON: pretty, topLevelKeys: keys,
                                missingKeys: [], error: nil)
    }

    /// 从一段文本里抽出最可能是 JSON 对象的部分:
    /// 1) 先剥掉 ```json … ``` / ``` … ``` 围栏;
    /// 2) 再取第一个 `{` 到与之匹配的 `}`(按括号配平,忽略字符串内的括号)。
    static func extractJSON(from text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥围栏:```json\n...\n``` 或 ```\n...\n```
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let fenceRange = s.range(of: "```", options: .backwards) {
                s = String(s[..<fenceRange.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 直接就是对象
        if s.hasPrefix("{"), s.hasSuffix("}") { return s }
        // 否则从第一个 { 配平到匹配的 }
        return balancedObjectSlice(in: s)
    }

    /// 在文本里找到第一个 `{` 并按括号配平截取到对应 `}`(跳过字符串字面量内的括号与转义)。
    private static func balancedObjectSlice(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    /// 从 schema 文本里推断「顶层必须键」:把 schema 自身当 JSON 解析,取其顶层键。
    /// schema 本身可能带描述值(如 "string — xxx"),不影响取键。解析失败时返回空(只做存在性兜底)。
    static func requiredTopLevelKeys(from schema: String) -> [String] {
        guard let slice = extractJSON(from: schema),
              let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = obj as? [String: Any] else {
            return []
        }
        return Array(dict.keys).sorted()
    }

    /// 发送前校验用户输入的 schema 是否是合法 JSON(对象)。返回 nil = 合法;非 nil = 错误信息。
    static func schemaError(_ schema: String) -> String? {
        let trimmed = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "请先定义一个 JSON Schema" }
        guard let slice = extractJSON(from: trimmed),
              let data = slice.data(using: .utf8) else {
            return "Schema 不是合法的 JSON 对象"
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard obj is [String: Any] else { return "Schema 顶层必须是 JSON 对象({ })" }
            return nil
        } catch {
            return "Schema JSON 解析失败:\(error.localizedDescription)"
        }
    }
}
