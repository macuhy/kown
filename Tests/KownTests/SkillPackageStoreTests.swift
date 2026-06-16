import XCTest
@testable import Kown

@MainActor
final class SkillPackageStoreTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let package = samplePackage()
        let data = try SkillPackageStore.encode(package)
        let decoded = try SkillPackageStore.decodePackage(from: data)

        XCTAssertEqual(decoded.id, package.id)
        XCTAssertEqual(decoded.displayName, "研究包")
        XCTAssertEqual(decoded.variableNames, ["主题"])
        XCTAssertEqual(decoded.requiredToolNames, ["web_search"])
    }

    func testInstallExportAndReload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kown-skill-")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("skill-packages.json")
        let store = SkillPackageStore(storeURL: url, loadFromDisk: false)
        let package = samplePackage()

        store.install(package)
        let data = try store.exportData(for: package)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("研究包") == true)

        let reloaded = SkillPackageStore(storeURL: url, loadFromDisk: true)
        XCTAssertEqual(reloaded.installedPackages.count, 1)
        XCTAssertEqual(reloaded.installedPackages.first?.id, package.id)
    }

    func testRejectsEmptyPackage() throws {
        let package = SkillPackage(metadata: .init(name: "空包"), prompts: [])
        XCTAssertThrowsError(try SkillPackageStore.encode(package)) { error in
            XCTAssertEqual(error as? SkillPackageStore.StoreError, .emptyPackage)
        }
    }

    func testMakeSkillBridgeKeepsToolsAndPrompt() {
        let skill = samplePackage().makeSkill()

        XCTAssertEqual(skill.name, "研究包")
        XCTAssertEqual(skill.allowedTools, ["web_search"])
        XCTAssertTrue(skill.instructions.contains("{{主题}}"))
    }

    func testRecommendedPackagesAreAvailableInMarket() {
        let store = SkillPackageStore(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), loadFromDisk: false)

        XCTAssertGreaterThanOrEqual(store.recommendedPackages.count, 3)
        XCTAssertEqual(store.marketPackages.count, store.recommendedPackages.count)
    }

    private func samplePackage() -> SkillPackage {
        SkillPackage(
            id: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
            metadata: .init(name: "研究包", summary: "生成研究简报", tags: ["研究"]),
            prompts: [.init(title: "系统", template: "研究 {{主题}}")],
            variables: [.init(name: "主题")],
            examples: [.init(title: "例子", input: "主题=端侧 AI")],
            requiredToolPermissions: [.init(toolName: "web_search", displayName: "联网搜索", category: .network)],
            personaReferences: [.init(name: "研究员")],
            promptChainReferences: [.init(name: "检索链", stepTitles: ["检索", "总结"])]
        )
    }
}
