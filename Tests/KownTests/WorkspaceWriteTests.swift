import XCTest
@testable import Kown

/// 覆盖 Workspace 的 `kown:write` 解析与**路径安全校验**(防 `../` 越权写到 workspace 之外、
/// 防写非文本后缀)。这是会被 LLM 输出直接驱动落盘的路径,必须守住。
@MainActor
final class WorkspaceWriteTests: XCTestCase {

    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kown-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - 解析

    func testParseBasicWriteBlock() {
        let text = """
        前面随便聊点什么。
        ```kown:write notes/todo.md
        - [ ] 写测试
        ```
        后面继续。
        """
        let writes = WorkspaceManager.parseProposedWrites(text)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.relativePath, "notes/todo.md")
        XCTAssertEqual(writes.first?.content, "- [ ] 写测试")
    }

    func testParseCaseInsensitiveAndQuotedPath() {
        // 大小写不敏感(KOWN:WRITE)+ 引号包裹的路径(去引号)
        let text = "```KOWN:WRITE \"src/main.swift\"\nlet x = 1\n```"
        let writes = WorkspaceManager.parseProposedWrites(text)
        XCTAssertEqual(writes.first?.relativePath, "src/main.swift")
        XCTAssertEqual(writes.first?.content, "let x = 1")
    }

    // MARK: - 路径安全

    func testRejectsParentTraversal() {
        let result = WorkspaceManager.apply(
            PendingWrite(relativePath: "../escape.md", content: "x"),
            workspaceURL: workspace
        )
        XCTAssertEqual(result.action, .skipped)
        XCTAssertFalse(result.success)
        // 文件不应被写到 workspace 之外
        let escaped = workspace.deletingLastPathComponent().appendingPathComponent("escape.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }

    func testRejectsNonTextExtension() {
        // .png 是二进制,不在文本白名单 → 拒绝写入(脚本类如 .sh 是文本,允许)
        let result = WorkspaceManager.apply(
            PendingWrite(relativePath: "image.png", content: "not really an image"),
            workspaceURL: workspace
        )
        XCTAssertEqual(result.action, .skipped)
        XCTAssertFalse(result.success)
    }

    func testAllowsValidWrite() {
        let result = WorkspaceManager.apply(
            PendingWrite(relativePath: "notes.md", content: "hello"),
            workspaceURL: workspace
        )
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.action, .create)
        let written = try? String(contentsOf: workspace.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertEqual(written, "hello")
    }
}
