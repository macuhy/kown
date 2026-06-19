import XCTest
@testable import Kown

@MainActor
final class WorkspaceWriteConflictTests: XCTestCase {
    func testPrepareProposedWritesKeepsConflictingVariantsPending() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let prepared = WorkspaceManager.prepareProposedWrites([
            PendingWrite(relativePath: "notes.md", content: "from A"),
            PendingWrite(relativePath: "notes.md", content: "from B")
        ], workspaceURL: workspace)

        XCTAssertEqual(prepared.count, 2)
        XCTAssertEqual(prepared.map(\.relativePath), ["notes.md", "notes.md"])
        XCTAssertEqual(prepared.map(\.newContent), ["from A", "from B"])
        XCTAssertTrue(prepared.allSatisfy { $0.pendingConfirmation == true })
        XCTAssertTrue(prepared.allSatisfy { $0.warning?.contains("2 个不同版本") == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("notes.md").path))
    }

    func testPrepareProposedWritesDeduplicatesSamePathSameContent() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let prepared = WorkspaceManager.prepareProposedWrites([
            PendingWrite(relativePath: "notes.md", content: "same"),
            PendingWrite(relativePath: "notes.md", content: "same")
        ], workspaceURL: workspace)

        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared.first?.newContent, "same")
        XCTAssertNil(prepared.first?.warning)
    }

    func testPrepareProposedWritesKeepsStablePathAndVariantOrder() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let prepared = WorkspaceManager.prepareProposedWrites([
            PendingWrite(relativePath: "b.md", content: "b1"),
            PendingWrite(relativePath: "a.md", content: "a1"),
            PendingWrite(relativePath: "b.md", content: "b2"),
            PendingWrite(relativePath: "c.md", content: "c1")
        ], workspaceURL: workspace)

        XCTAssertEqual(prepared.map { "\($0.relativePath):\($0.newContent)" }, [
            "b.md:b1",
            "b.md:b2",
            "a.md:a1",
            "c.md:c1"
        ])
    }

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kown-ws-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }
}
