import XCTest
@testable import Kown

final class ConnectorHubTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    func testSnapshotContainsAllConnectorsInStableOrder() {
        let snapshot = ConnectorHubService.makeSnapshot(from: .empty, now: fixedNow)

        XCTAssertEqual(snapshot.generatedAt, fixedNow)
        XCTAssertEqual(snapshot.connectors.map(\.kind), ConnectorHubConnectorKind.allCases)
    }

    func testWebConnectorRequiresEnabledSwitchAndApiKey() {
        var state = ConnectorHubRuntimeState.empty
        state.webSearchEnabled = true
        state.webSearchHasKey = false

        let web = ConnectorHubService.makeSnapshot(from: state, now: fixedNow).connector(.web)

        XCTAssertEqual(web?.state, .needsSetup)
        XCTAssertEqual(web?.health, .needsSetup)
        XCTAssertTrue(web?.suggestedActions.contains { $0.title.contains("API Key") } == true)
    }

    func testKnowledgeConnectorUsesLatestFolderOrDocumentTime() {
        var state = ConnectorHubRuntimeState.empty
        let folderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let docDate = Date(timeIntervalSince1970: 1_710_000_000)
        state.knowledge = ConnectorHubKnowledgeSnapshot(
            folderCount: 1,
            documentCount: 2,
            characterCount: 12_300,
            lastUpdatedAt: max(folderDate, docDate)
        )

        let knowledge = ConnectorHubService.makeSnapshot(from: state, now: fixedNow).connector(.knowledgeBase)

        XCTAssertEqual(knowledge?.state, .connected)
        XCTAssertEqual(knowledge?.health, .healthy)
        XCTAssertEqual(knowledge?.lastSyncAt, docDate)
        XCTAssertEqual(knowledge?.permissions, [.read, .write])
    }

    func testMCPConnectorSummarizesEnabledServersForAgents() {
        var state = ConnectorHubRuntimeState.empty
        let createdAt = Date(timeIntervalSince1970: 1_720_000_000)
        state.mcpServers = [
            ConnectorHubMCPServerSnapshot(
                name: "Design MCP",
                enabled: true,
                transportKind: .http,
                transportSummary: "https://mcp.example.com",
                createdAt: createdAt,
                slug: "design_mcp"
            )
        ]

        let snapshot = ConnectorHubService.makeSnapshot(from: state, now: fixedNow)
        let mcp = snapshot.connector(.mcp)

        XCTAssertEqual(mcp?.state, .configured)
        XCTAssertEqual(mcp?.health, .healthy)
        XCTAssertEqual(mcp?.lastSyncAt, createdAt)
        XCTAssertEqual(mcp?.permissions, [.read, .write, .action])
        XCTAssertTrue(snapshot.agentContextDescription.contains("mcp__server__tool"))
    }

    func testCalendarRemindersPartialWhenOnlyCalendarWriteIsAvailable() {
        var state = ConnectorHubRuntimeState.empty
        state.remindersSupported = true
        state.calendarSupported = true
        state.calendarAccess = .writeOnly

        let connector = ConnectorHubService.makeSnapshot(from: state, now: fixedNow).connector(.calendarReminders)

        XCTAssertEqual(connector?.state, .partial)
        XCTAssertEqual(connector?.health, .warning)
        XCTAssertTrue(connector?.suggestedActions.contains { $0.title.contains("提醒事项") } == true)
        XCTAssertTrue(connector?.suggestedActions.contains { $0.title.contains("完整日历") } == true)
    }
}

private extension ConnectorHubSnapshot {
    func connector(_ kind: ConnectorHubConnectorKind) -> ConnectorHubItem? {
        connectors.first { $0.kind == kind }
    }
}
