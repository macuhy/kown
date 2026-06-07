import XCTest
@testable import Kown

/// 覆盖 MCP 的纯逻辑:JSON Schema → ToolParameters 的浅层映射、server 命名空间 slug。
final class MCPSchemaMappingTests: XCTestCase {

    // MARK: - inputSchema 映射

    func testBasicTypesAndRequired() {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "搜索词"],
                "limit": ["type": "integer", "description": "条数"],
                "ratio": ["type": "number"],
                "flag": ["type": "boolean"]
            ],
            "required": ["query"]
        ]
        let params = MCPConnection.mapInputSchema(schema)
        XCTAssertEqual(params.properties["query"]?.type, "string")
        XCTAssertEqual(params.properties["query"]?.description, "搜索词")
        XCTAssertEqual(params.properties["limit"]?.type, "integer")
        XCTAssertEqual(params.properties["ratio"]?.type, "number")
        XCTAssertEqual(params.properties["flag"]?.type, "boolean")
        XCTAssertEqual(params.required, ["query"])
    }

    func testNestedAndArrayDowngradeToString() {
        let schema: [String: Any] = [
            "properties": [
                "obj": ["type": "object", "description": "嵌套对象"],
                "arr": ["type": "array", "description": "列表"]
            ],
            "required": ["obj"]
        ]
        let params = MCPConnection.mapInputSchema(schema)
        // object / array 都降级为 string 透传。
        XCTAssertEqual(params.properties["obj"]?.type, "string")
        XCTAssertEqual(params.properties["arr"]?.type, "string")
    }

    func testMissingTypeDefaultsToString() {
        let schema: [String: Any] = [
            "properties": ["x": ["description": "无 type"]]
        ]
        let params = MCPConnection.mapInputSchema(schema)
        XCTAssertEqual(params.properties["x"]?.type, "string")
    }

    func testDescriptionFallsBackToKey() {
        let schema: [String: Any] = [
            "properties": ["name": ["type": "string"]]
        ]
        let params = MCPConnection.mapInputSchema(schema)
        XCTAssertEqual(params.properties["name"]?.description, "name")
    }

    func testRequiredFiltersUnknownProperties() {
        // required 里出现了 properties 没声明的字段 → 过滤掉,避免给模型矛盾的 schema。
        let schema: [String: Any] = [
            "properties": ["a": ["type": "string"]],
            "required": ["a", "ghost"]
        ]
        let params = MCPConnection.mapInputSchema(schema)
        XCTAssertEqual(params.required, ["a"])
    }

    func testEmptySchema() {
        let params = MCPConnection.mapInputSchema([:])
        XCTAssertTrue(params.properties.isEmpty)
        XCTAssertTrue(params.required.isEmpty)
    }

    func testUnionTypeArrayTakesFirstUsable() {
        // type 是 ["string","null"] 这类联合 → 取第一个,可用则保留,否则 string。
        let schema: [String: Any] = [
            "properties": ["maybe": ["type": ["string", "null"], "description": "可空"]]
        ]
        let params = MCPConnection.mapInputSchema(schema)
        XCTAssertEqual(params.properties["maybe"]?.type, "string")
    }

    // MARK: - slug

    func testSlugLowercasesAndSanitizes() {
        XCTAssertEqual(MCPServerConfig.makeSlug("My API Server", fallback: "x"), "my_api_server")
        XCTAssertEqual(MCPServerConfig.makeSlug("Figma-MCP", fallback: "x"), "figma_mcp")
    }

    func testSlugCollapsesAndTrimsUnderscores() {
        XCTAssertEqual(MCPServerConfig.makeSlug("  weird __ name  ", fallback: "x"), "weird_name")
    }

    func testSlugFallbackWhenEmpty() {
        let slug = MCPServerConfig.makeSlug("！！！", fallback: "ABC123XYZ")
        XCTAssertTrue(slug.hasPrefix("srv"))
    }

    // MARK: - 工具命名空间识别

    func testIsMCPTool() {
        XCTAssertTrue(MCPSession.isMCPTool("mcp__fs__read_file"))
        XCTAssertFalse(MCPSession.isMCPTool("web_search"))
    }
}
