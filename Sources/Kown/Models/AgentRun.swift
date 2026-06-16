import Foundation

/// A unified record for long-running agent work: deep research, scheduled jobs,
/// standalone tool calls, meeting follow-ups, and other background tasks.
struct AgentRun: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case longTask
        case deepResearch
        case scheduledTask
        case toolCall
        case meetingTask

        var displayName: String {
            switch self {
            case .longTask: return "长任务"
            case .deepResearch: return "深度研究"
            case .scheduledTask: return "定时任务"
            case .toolCall: return "工具调用"
            case .meetingTask: return "会议任务"
            }
        }

        var symbolName: String {
            switch self {
            case .longTask: return "checklist.checked"
            case .deepResearch: return "doc.text.magnifyingglass"
            case .scheduledTask: return "calendar.badge.clock"
            case .toolCall: return "wrench.and.screwdriver"
            case .meetingTask: return "person.2.wave.2"
            }
        }
    }

    enum Status: String, Codable, CaseIterable, Sendable {
        case queued
        case running
        case waitingForApproval
        case paused
        case succeeded
        case failed
        case cancelled

        var displayName: String {
            switch self {
            case .queued: return "排队中"
            case .running: return "运行中"
            case .waitingForApproval: return "待审批"
            case .paused: return "已暂停"
            case .succeeded: return "已完成"
            case .failed: return "失败"
            case .cancelled: return "已取消"
            }
        }

        var isActive: Bool {
            switch self {
            case .queued, .running, .waitingForApproval, .paused: return true
            case .succeeded, .failed, .cancelled: return false
            }
        }

        var isTerminal: Bool { !isActive }

        var canPause: Bool {
            switch self {
            case .queued, .running, .waitingForApproval: return true
            case .paused, .succeeded, .failed, .cancelled: return false
            }
        }

        var canResume: Bool { self == .paused }

        var canCancel: Bool {
            switch self {
            case .queued, .running, .waitingForApproval, .paused: return true
            case .succeeded, .failed, .cancelled: return false
            }
        }

        func canTransition(to next: Status) -> Bool {
            guard self != next else { return true }
            switch (self, next) {
            case (.queued, .running),
                 (.queued, .waitingForApproval),
                 (.queued, .paused),
                 (.queued, .failed),
                 (.queued, .cancelled):
                return true
            case (.running, .waitingForApproval),
                 (.running, .paused),
                 (.running, .succeeded),
                 (.running, .failed),
                 (.running, .cancelled):
                return true
            case (.waitingForApproval, .running),
                 (.waitingForApproval, .paused),
                 (.waitingForApproval, .failed),
                 (.waitingForApproval, .cancelled):
                return true
            case (.paused, .queued),
                 (.paused, .running),
                 (.paused, .failed),
                 (.paused, .cancelled):
                return true
            default:
                return false
            }
        }
    }

    enum ApprovalStatus: String, Codable, CaseIterable, Sendable {
        case notRequired
        case pending
        case approved
        case rejected
        case expired

        var displayName: String {
            switch self {
            case .notRequired: return "无需审批"
            case .pending: return "待审批"
            case .approved: return "已批准"
            case .rejected: return "已拒绝"
            case .expired: return "已过期"
            }
        }
    }

    enum StepStatus: String, Codable, CaseIterable, Sendable {
        case queued
        case running
        case waitingForApproval
        case done
        case error
        case cancelled
        case skipped

        var displayName: String {
            switch self {
            case .queued: return "排队"
            case .running: return "运行"
            case .waitingForApproval: return "待批"
            case .done: return "完成"
            case .error: return "错误"
            case .cancelled: return "取消"
            case .skipped: return "跳过"
            }
        }

        var isTerminal: Bool {
            switch self {
            case .done, .error, .cancelled, .skipped: return true
            case .queued, .running, .waitingForApproval: return false
            }
        }
    }

    struct Step: Identifiable, Codable, Hashable, Sendable {
        let id: UUID
        var title: String
        var detail: String
        var status: StepStatus
        var startedAt: Date?
        var finishedAt: Date?
        var resultSummary: String?
        var errorMessage: String?
        var toolCallID: UUID?
        var approvalStatus: ApprovalStatus
        var metadata: [String: String]

        init(
            id: UUID = UUID(),
            title: String,
            detail: String = "",
            status: StepStatus = .queued,
            startedAt: Date? = nil,
            finishedAt: Date? = nil,
            resultSummary: String? = nil,
            errorMessage: String? = nil,
            toolCallID: UUID? = nil,
            approvalStatus: ApprovalStatus = .notRequired,
            metadata: [String: String] = [:]
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.status = status
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.resultSummary = resultSummary
            self.errorMessage = errorMessage
            self.toolCallID = toolCallID
            self.approvalStatus = approvalStatus
            self.metadata = metadata
        }

        var durationSeconds: TimeInterval? {
            guard let startedAt else { return nil }
            return (finishedAt ?? Date()).timeIntervalSince(startedAt)
        }
    }

    struct ToolCall: Identifiable, Codable, Hashable, Sendable {
        let id: UUID
        /// Provider-specific call id, if the upstream model exposed one.
        var externalID: String?
        var name: String
        var displayName: String
        var argumentsSummary: String
        var status: StepStatus
        var startedAt: Date?
        var finishedAt: Date?
        var resultSummary: String?
        var errorMessage: String?
        var approvalStatus: ApprovalStatus
        var cost: Cost
        var metadata: [String: String]

        init(
            id: UUID = UUID(),
            externalID: String? = nil,
            name: String,
            displayName: String? = nil,
            argumentsSummary: String = "",
            status: StepStatus = .queued,
            startedAt: Date? = nil,
            finishedAt: Date? = nil,
            resultSummary: String? = nil,
            errorMessage: String? = nil,
            approvalStatus: ApprovalStatus = .notRequired,
            cost: Cost = Cost(),
            metadata: [String: String] = [:]
        ) {
            self.id = id
            self.externalID = externalID
            self.name = name
            self.displayName = displayName ?? name
            self.argumentsSummary = argumentsSummary
            self.status = status
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.resultSummary = resultSummary
            self.errorMessage = errorMessage
            self.approvalStatus = approvalStatus
            self.cost = cost
            self.metadata = metadata
        }

        var durationSeconds: TimeInterval? {
            guard let startedAt else { return nil }
            return (finishedAt ?? Date()).timeIntervalSince(startedAt)
        }
    }

    struct Cost: Codable, Hashable, Sendable {
        var inputTokens: Int
        var outputTokens: Int
        var cachedInputTokens: Int
        var estimatedUSD: Double
        var currency: String

        init(
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            cachedInputTokens: Int = 0,
            estimatedUSD: Double = 0,
            currency: String = "USD"
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cachedInputTokens = cachedInputTokens
            self.estimatedUSD = estimatedUSD
            self.currency = currency
        }

        var totalTokens: Int { inputTokens + outputTokens }
        var isEmpty: Bool { totalTokens == 0 && estimatedUSD == 0 }

        mutating func add(_ other: Cost) {
            inputTokens += other.inputTokens
            outputTokens += other.outputTokens
            cachedInputTokens += other.cachedInputTokens
            estimatedUSD += other.estimatedUSD
            if currency.isEmpty { currency = other.currency }
        }

        mutating func subtract(_ other: Cost) {
            inputTokens -= other.inputTokens
            outputTokens -= other.outputTokens
            cachedInputTokens -= other.cachedInputTokens
            estimatedUSD -= other.estimatedUSD
        }
    }

    let id: UUID
    var kind: Kind
    var title: String
    var prompt: String
    var summary: String?
    var status: Status
    var approvalStatus: ApprovalStatus
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var steps: [Step]
    var toolCalls: [ToolCall]
    var cost: Cost
    var errorMessage: String?
    /// Optional foreign key, e.g. scheduled task id, conversation id, calendar event id.
    var sourceID: String?
    var retryOf: UUID?
    var tags: [String]
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        prompt: String = "",
        summary: String? = nil,
        status: Status = .queued,
        approvalStatus: ApprovalStatus = .notRequired,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        steps: [Step] = [],
        toolCalls: [ToolCall] = [],
        cost: Cost = Cost(),
        errorMessage: String? = nil,
        sourceID: String? = nil,
        retryOf: UUID? = nil,
        tags: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.prompt = prompt
        self.summary = summary
        self.status = status
        self.approvalStatus = approvalStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.steps = steps
        self.toolCalls = toolCalls
        self.cost = cost
        self.errorMessage = errorMessage
        self.sourceID = sourceID
        self.retryOf = retryOf
        self.tags = tags
        self.metadata = metadata
    }

    var durationSeconds: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var completedStepCount: Int {
        steps.filter { $0.status.isTerminal }.count
    }

    var progressFraction: Double? {
        guard !steps.isEmpty else { return nil }
        return Double(completedStepCount) / Double(steps.count)
    }

    var canPause: Bool { status.canPause }
    var canResume: Bool { status.canResume }
    var canCancel: Bool { status.canCancel }
    var canRerun: Bool { status.isTerminal || status == .paused }
    var needsApproval: Bool {
        status == .waitingForApproval ||
        approvalStatus == .pending ||
        steps.contains { $0.approvalStatus == .pending || $0.status == .waitingForApproval } ||
        toolCalls.contains { $0.approvalStatus == .pending || $0.status == .waitingForApproval }
    }

    mutating func applyStatus(_ newStatus: Status, at date: Date = Date(), reason: String? = nil) {
        status = newStatus
        updatedAt = date
        if startedAt == nil, newStatus == .running || newStatus == .waitingForApproval {
            startedAt = date
        }
        if newStatus.isTerminal {
            finishedAt = date
        } else if newStatus == .running {
            finishedAt = nil
        }
        if let reason, !reason.isEmpty {
            switch newStatus {
            case .failed, .cancelled:
                errorMessage = reason
            default:
                summary = reason
            }
        }
    }
}

struct AgentRunNotification: Identifiable, Equatable, Sendable {
    enum Level: String, Equatable, Sendable {
        case approval
        case running
        case success
        case failure
    }

    var id: String { "\(runID.uuidString)-\(level.rawValue)" }
    let runID: UUID
    let level: Level
    let title: String
    let message: String
    let actionTitle: String?
    let createdAt: Date
}
