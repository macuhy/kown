import Foundation

/// Permission families exposed by a connector to projects and agent runs.
enum ConnectorHubPermission: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case read
    case write
    case action

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .read: return "Read"
        case .write: return "Write"
        case .action: return "Action"
        }
    }

    var agentVerb: String {
        switch self {
        case .read: return "read context"
        case .write: return "write or stage changes"
        case .action: return "perform actions"
        }
    }
}

enum ConnectorHubHealth: String, CaseIterable, Codable, Hashable, Sendable {
    case healthy
    case warning
    case needsSetup
    case unavailable

    var displayName: String {
        switch self {
        case .healthy: return "Healthy"
        case .warning: return "Attention"
        case .needsSetup: return "Needs setup"
        case .unavailable: return "Unavailable"
        }
    }

    var priority: Int {
        switch self {
        case .unavailable: return 0
        case .needsSetup: return 1
        case .warning: return 2
        case .healthy: return 3
        }
    }
}

enum ConnectorHubState: String, CaseIterable, Codable, Hashable, Sendable {
    case connected
    case configured
    case partial
    case disabled
    case needsSetup
    case unavailable

    var displayName: String {
        switch self {
        case .connected: return "Connected"
        case .configured: return "Configured"
        case .partial: return "Partial"
        case .disabled: return "Disabled"
        case .needsSetup: return "Needs setup"
        case .unavailable: return "Unavailable"
        }
    }
}

enum ConnectorHubConnectorKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case github
    case web
    case mcp
    case knowledgeBase
    case iCloud
    case calendarReminders
    case systemTools

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .web: return "Firecrawl / Web"
        case .mcp: return "MCP"
        case .knowledgeBase: return "本地知识库"
        case .iCloud: return "iCloud"
        case .calendarReminders: return "Calendar / Reminders"
        case .systemTools: return "System Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .web: return "globe"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .knowledgeBase: return "books.vertical.fill"
        case .iCloud: return "icloud.fill"
        case .calendarReminders: return "calendar.badge.checkmark"
        case .systemTools: return "wrench.and.screwdriver.fill"
        }
    }
}

struct ConnectorHubDetail: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var label: String
    var value: String

    init(id: String? = nil, label: String, value: String) {
        self.id = id ?? label
        self.label = label
        self.value = value
    }
}

struct ConnectorHubAction: Identifiable, Codable, Hashable, Sendable {
    enum Priority: String, Codable, Hashable, Sendable {
        case high
        case normal
        case low
    }

    var id: String
    var connector: ConnectorHubConnectorKind
    var title: String
    var detail: String
    var priority: Priority

    init(id: String? = nil,
         connector: ConnectorHubConnectorKind,
         title: String,
         detail: String,
         priority: Priority = .normal) {
        self.id = id ?? "\(connector.rawValue).\(title)"
        self.connector = connector
        self.title = title
        self.detail = detail
        self.priority = priority
    }
}

struct ConnectorHubItem: Identifiable, Codable, Hashable, Sendable {
    var id: ConnectorHubConnectorKind { kind }
    var kind: ConnectorHubConnectorKind
    var title: String
    var subtitle: String
    var state: ConnectorHubState
    var health: ConnectorHubHealth
    var permissions: [ConnectorHubPermission]
    /// Last known sync/update/check time. `nil` means the connector is event-driven or has no reliable timestamp yet.
    var lastSyncAt: Date?
    var details: [ConnectorHubDetail]
    var projectDescription: String
    var agentDescription: String
    var suggestedActions: [ConnectorHubAction]

    init(kind: ConnectorHubConnectorKind,
         title: String? = nil,
         subtitle: String,
         state: ConnectorHubState,
         health: ConnectorHubHealth,
         permissions: [ConnectorHubPermission],
         lastSyncAt: Date? = nil,
         details: [ConnectorHubDetail] = [],
         projectDescription: String,
         agentDescription: String,
         suggestedActions: [ConnectorHubAction] = []) {
        self.kind = kind
        self.title = title ?? kind.displayName
        self.subtitle = subtitle
        self.state = state
        self.health = health
        self.permissions = Self.normalized(permissions)
        self.lastSyncAt = lastSyncAt
        self.details = details
        self.projectDescription = projectDescription
        self.agentDescription = agentDescription
        self.suggestedActions = suggestedActions
    }

    var isReadyForAgent: Bool {
        health == .healthy || (health == .warning && state != .needsSetup && state != .unavailable)
    }

    var permissionSummary: String {
        permissions.map(\.displayName).joined(separator: " / ")
    }

    private static func normalized(_ permissions: [ConnectorHubPermission]) -> [ConnectorHubPermission] {
        ConnectorHubPermission.allCases.filter { permissions.contains($0) }
    }
}

struct ConnectorHubSnapshot: Identifiable, Codable, Hashable, Sendable {
    var id: Date { generatedAt }
    var generatedAt: Date
    var connectors: [ConnectorHubItem]

    var readyConnectors: [ConnectorHubItem] {
        connectors.filter(\.isReadyForAgent)
    }

    var suggestedActions: [ConnectorHubAction] {
        connectors.flatMap(\.suggestedActions).sorted { lhs, rhs in
            if lhs.priority.rank != rhs.priority.rank { return lhs.priority.rank < rhs.priority.rank }
            if lhs.connector.rawValue != rhs.connector.rawValue { return lhs.connector.rawValue < rhs.connector.rawValue }
            return lhs.title < rhs.title
        }
    }

    var healthSummary: String {
        let ready = readyConnectors.count
        return "\(ready)/\(connectors.count) ready"
    }

    var agentContextDescription: String {
        let lines = readyConnectors.map { connector in
            "- \(connector.title): \(connector.permissionSummary) - \(connector.agentDescription)"
        }
        guard !lines.isEmpty else {
            return "No connector is ready for agent use yet. Ask the user to configure Connector Hub first."
        }
        return (["Available connectors for this project/agent:"] + lines).joined(separator: "\n")
    }
}

private extension ConnectorHubAction.Priority {
    var rank: Int {
        switch self {
        case .high: return 0
        case .normal: return 1
        case .low: return 2
        }
    }
}
