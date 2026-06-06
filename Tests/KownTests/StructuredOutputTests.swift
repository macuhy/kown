import XCTest
@testable import Kown

/// 覆盖 Structured 模式的纯逻辑:从模型回答里抽 JSON、对照 schema 校验、schema 合法性检查。
@MainActor
final class StructuredOutputTests: XCTestCase {

    // MARK: extractJSON

    func testExtractPlainObject() {
        XCTAssertEqual(StructuredOutput.extractJSON(from: #"{"a":1}"#), #"{"a":1}"#)
    }

    func testExtractStripsJSONFence() {
        let text = "```json\n{\"a\":1}\n```"
        XCTAssertEqual(StructuredOutput.extractJSON(from: text), #"{"a":1}"#)
    }

    func testExtractStripsBareFence() {
        let text = "```\n{\"a\":1}\n```"
        XCTAssertEqual(StructuredOutput.extractJSON(from: text), #"{"a":1}"#)
    }

    func testExtractFromSurroundingProse() {
        let text = "这是结果:{\"name\":\"x\"} 以上。"
        XCTAssertEqual(StructuredOutput.extractJSON(from: text), #"{"name":"x"}"#)
    }

    func testExtractIgnoresBracesInsideStrings() {
        // 字符串字面量里的 } 不应提前结束配平。
        let text = #"{"a":"close } brace","b":2}"#
        XCTAssertEqual(StructuredOutput.extractJSON(from: text), text)
    }

    func testExtractNestedObject() {
        let text = #"prefix {"a":{"b":1}} suffix"#
        XCTAssertEqual(StructuredOutput.extractJSON(from: text), #"{"a":{"b":1}}"#)
    }

    func testExtractReturnsNilWhenNoObject() {
        XCTAssertNil(StructuredOutput.extractJSON(from: "没有任何 JSON 内容"))
    }

    // MARK: validate

    func testValidateAcceptsObjectWithRequiredKeys() {
        let schema = #"{"name":"string","score":"number"}"#
        let r = StructuredOutput.validate(responseText: #"{"name":"甲","score":7}"#, schema: schema)
        XCTAssertTrue(r.isValid)
        XCTAssertTrue(r.missingKeys.isEmpty)
        XCTAssertEqual(r.topLevelKeys, ["name", "score"])
        XCTAssertNotNil(r.prettyJSON)
    }

    func testValidateFlagsMissingKeys() {
        let schema = #"{"name":"string","score":"number"}"#
        let r = StructuredOutput.validate(responseText: #"{"name":"甲"}"#, schema: schema)
        XCTAssertFalse(r.isValid)
        XCTAssertEqual(r.missingKeys, ["score"])
    }

    func testValidateRejectsNonObject() {
        let r = StructuredOutput.validate(responseText: "[1,2,3]", schema: #"{"a":"x"}"#)
        XCTAssertFalse(r.isValid)
    }

    func testValidateRejectsGarbage() {
        let r = StructuredOutput.validate(responseText: "完全不是 JSON", schema: #"{"a":"x"}"#)
        XCTAssertFalse(r.isValid)
        XCTAssertNotNil(r.error)
    }

    // MARK: schemaError / requiredTopLevelKeys

    func testSchemaErrorEmpty() {
        XCTAssertNotNil(StructuredOutput.schemaError("   "))
    }

    func testSchemaErrorValidObject() {
        XCTAssertNil(StructuredOutput.schemaError(#"{"name":"string"}"#))
    }

    func testSchemaErrorNonObject() {
        XCTAssertNotNil(StructuredOutput.schemaError("[1,2]"))
        XCTAssertNotNil(StructuredOutput.schemaError("不是 JSON"))
    }

    func testRequiredTopLevelKeysSorted() {
        let schema = #"{"score":"number","name":"string","tags":["string"]}"#
        XCTAssertEqual(StructuredOutput.requiredTopLevelKeys(from: schema), ["name", "score", "tags"])
    }

    // MARK: presets / prompt

    func testPresetsNonEmptyAndValid() {
        XCTAssertFalse(StructuredOutput.presets.isEmpty)
        for preset in StructuredOutput.presets {
            XCTAssertNil(StructuredOutput.schemaError(preset.schema), "预设 \(preset.title) 的 schema 应是合法 JSON 对象")
        }
        XCTAssertNil(StructuredOutput.schemaError(StructuredOutput.defaultSchema))
    }

    func testBuildPromptEmbedsSchemaAndUserPrompt() {
        let p = StructuredOutput.buildStructuredPrompt(userPrompt: "分析这段文字", schema: #"{"k":"v"}"#)
        XCTAssertTrue(p.contains("分析这段文字"))
        XCTAssertTrue(p.contains(#"{"k":"v"}"#))
    }
}
