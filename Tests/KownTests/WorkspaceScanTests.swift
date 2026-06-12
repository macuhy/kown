import XCTest
@testable import Kown

/// 覆盖 workspace 上下文扫描(`WorkspaceManager.buildContext`)与知识库文件夹入库
/// (`DocumentIngestor.ingestFolder`)的**排除目录 / 上限**逻辑 —— 这两条「批量读」路径
/// 曾因无界扫描 / 主线程重 I/O 卡死 UI,必须用临时目录树守住硬限制。
final class WorkspaceScanTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kown-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ rel: String, _ content: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: url)
    }

    // MARK: - buildContext 排除目录

    func testBuildContextSkipsDependencyDirectories() throws {
        try write("src/main.swift", "let a = 1")
        try write("node_modules/pkg/index.js", "console.log(1)")
        try write("build/out.js", "x")
        try write("dist/bundle.js", "x")
        try write("__pycache__/mod.py", "x")

        let ctx = try XCTUnwrap(WorkspaceManager.buildContext(workspaceURL: root))
        XCTAssertTrue(ctx.contains("src/main.swift"), "正常源码文件应进文件树")
        XCTAssertTrue(ctx.contains("let a = 1"), "小目录的文件内容应照常注入")
        XCTAssertFalse(ctx.contains("node_modules"), "node_modules 应整棵跳过")
        XCTAssertFalse(ctx.contains("build/out.js"), "build 产物目录应整棵跳过")
        XCTAssertFalse(ctx.contains("dist/bundle.js"), "dist 产物目录应整棵跳过")
        XCTAssertFalse(ctx.contains("__pycache__"), "__pycache__ 应整棵跳过")
    }

    // MARK: - buildContext 单文件大小上限

    func testBuildContextSkipsOversizedFile() throws {
        try write("small.md", "hello")
        // 超过 perFileMaxSize(1MB)的文件不进树也不读内容
        let big = String(repeating: "a", count: WorkspaceManager.perFileMaxSize + 1)
        try write("big.md", big)

        let ctx = try XCTUnwrap(WorkspaceManager.buildContext(workspaceURL: root))
        XCTAssertTrue(ctx.contains("small.md"))
        XCTAssertFalse(ctx.contains("big.md"), "超过单文件上限的文件应被跳过")
    }

    // MARK: - buildContext 总文件数上限

    func testBuildContextTruncatesAtMaxFiles() throws {
        for i in 0..<10 {
            try write("f\(i).md", "content \(i)")
        }
        let ctx = try XCTUnwrap(WorkspaceManager.buildContext(workspaceURL: root, maxFiles: 3))
        // 只收 3 个文件 + 截断标注
        let treeCount = (0..<10).filter { ctx.contains("f\($0).md") }.count
        XCTAssertEqual(treeCount, 3, "达到文件数上限后应停止收集")
        XCTAssertTrue(ctx.contains("文件树已按上限截断"), "截断时应在树里标注")
    }

    func testBuildContextNoTruncationNoteForSmallDir() throws {
        try write("a.md", "x")
        try write("b.md", "y")
        let ctx = try XCTUnwrap(WorkspaceManager.buildContext(workspaceURL: root))
        XCTAssertFalse(ctx.contains("文件树已按上限截断"), "小目录不应出现截断标注(行为兼容)")
        XCTAssertTrue(ctx.contains("a.md") && ctx.contains("b.md"))
    }

    // MARK: - ingestFolder 排除目录 / 文件数上限

    func testIngestFolderSkipsDependencyDirectories() throws {
        try write("docs/readme.md", "# 文档")
        try write("node_modules/pkg/readme.md", "# 不该入库")
        try write("Pods/Lib/readme.md", "# 不该入库")

        let result = DocumentIngestor.ingestFolder(at: root)
        XCTAssertEqual(result.docs.count, 1)
        // 注:临时目录有 /var → /private/var 符号链接,展示名可能是绝对路径,这里只断言路径归属。
        XCTAssertTrue(result.docs.first?.name.hasSuffix("docs/readme.md") == true)
    }

    func testIngestFolderRespectsMaxFileCap() throws {
        // maxFilesPerFolder = 500,造 510 个文件应只收 500 个。
        // 文件极小,枚举 + 抽取在 CI 上秒级完成。
        for i in 0..<(DocumentIngestor.maxFilesPerFolder + 10) {
            try write("t\(i).txt", "doc \(i)")
        }
        let result = DocumentIngestor.ingestFolder(at: root)
        XCTAssertEqual(result.docs.count + result.failures.count,
                       DocumentIngestor.maxFilesPerFolder,
                       "超过上限的文件不应被枚举入库")
    }
}
