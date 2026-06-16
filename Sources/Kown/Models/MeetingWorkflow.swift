import Foundation

/// Meeting close-loop 2.0: a structured, cross-platform model that connects
/// pre-meeting preparation, in-meeting capture, and post-meeting follow-up.
struct MeetingWorkflow: Identifiable, Sendable, Equatable, Codable {
    var id: UUID
    var title: String
    var attendees: [Participant]
    var createdAt: Date
    var source: Source
    var preMeeting: PreMeeting
    var inMeeting: InMeeting
    var postMeeting: PostMeeting

    init(
        id: UUID = UUID(),
        title: String,
        attendees: [Participant] = [],
        createdAt: Date = Date(),
        source: Source = .manual,
        preMeeting: PreMeeting = PreMeeting(),
        inMeeting: InMeeting = InMeeting(),
        postMeeting: PostMeeting = PostMeeting()
    ) {
        self.id = id
        self.title = title
        self.attendees = attendees
        self.createdAt = createdAt
        self.source = source
        self.preMeeting = preMeeting
        self.inMeeting = inMeeting
        self.postMeeting = postMeeting
    }
}

extension MeetingWorkflow {
    enum Source: String, Sendable, Equatable, Codable {
        case manual
        case transcript
        case meetingNotes
        case transcriptAndNotes
    }

    struct Participant: Identifiable, Sendable, Equatable, Codable {
        var id: UUID
        var name: String
        var role: Role

        init(id: UUID = UUID(), name: String, role: Role = .participant) {
            self.id = id
            self.name = name
            self.role = role
        }
    }

    enum Role: String, Sendable, Equatable, Codable, CaseIterable {
        case host
        case decisionMaker
        case participant
        case owner
        case observer

        var label: String {
            switch self {
            case .host: return "主持人"
            case .decisionMaker: return "决策人"
            case .participant: return "参会人"
            case .owner: return "负责人"
            case .observer: return "观察者"
            }
        }
    }

    struct PreMeeting: Sendable, Equatable, Codable {
        var objective: String
        var agenda: [AgendaItem]
        var preparationItems: [PreparationItem]
        var questionsToResolve: [String]

        init(
            objective: String = "",
            agenda: [AgendaItem] = [],
            preparationItems: [PreparationItem] = [],
            questionsToResolve: [String] = []
        ) {
            self.objective = objective
            self.agenda = agenda
            self.preparationItems = preparationItems
            self.questionsToResolve = questionsToResolve
        }
    }

    struct AgendaItem: Identifiable, Sendable, Equatable, Codable {
        var id: UUID
        var title: String
        var detail: String?
        /// Lightweight timebox in minutes. Nil means no fixed timebox yet.
        var minutes: Int?
        var owner: String?

        init(id: UUID = UUID(), title: String, detail: String? = nil, minutes: Int? = nil, owner: String? = nil) {
            self.id = id
            self.title = title
            self.detail = detail
            self.minutes = minutes
            self.owner = owner
        }
    }

    struct PreparationItem: Identifiable, Sendable, Equatable, Codable {
        var id: UUID
        var title: String
        var owner: String?
        var isRequired: Bool

        init(id: UUID = UUID(), title: String, owner: String? = nil, isRequired: Bool = true) {
            self.id = id
            self.title = title
            self.owner = owner
            self.isRequired = isRequired
        }
    }

    struct InMeeting: Sendable, Equatable, Codable {
        var summary: String
        var captureHints: [CaptureHint]
        var decisions: [Decision]
        var risks: [Risk]
        var actionItems: [ActionItem]

        init(
            summary: String = "",
            captureHints: [CaptureHint] = [],
            decisions: [Decision] = [],
            risks: [Risk] = [],
            actionItems: [ActionItem] = []
        ) {
            self.summary = summary
            self.captureHints = captureHints
            self.decisions = decisions
            self.risks = risks
            self.actionItems = actionItems
        }
    }

    struct CaptureHint: Identifiable, Sendable, Equatable, Codable {
        var id: UUID
        var title: String
        var detail: String

        init(id: UUID = UUID(), title: String, detail: String) {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    struct Decision: Identifiable, Sendable, Equatable, Codable {
        var id: UUID
        var text: String
        var owner: String?
        var evidence: String?

        init(id: UUID = UUID(), text: String, owner: String? = nil, evidence: String? = nil) {
            self.id = id
            self.text = text
            self.owner = owner
            self.evidence = evidence
        }
    }

    struct Risk: Identifiable, Sendable, Equatable, Codable {
        var id: UUID
        var text: String
        var level: RiskLevel
        var mitigation: String?
        var owner: String?

        init(
            id: UUID = UUID(),
            text: String,
            level: RiskLevel = .medium,
            mitigation: String? = nil,
            owner: String? = nil
        ) {
            self.id = id
            self.text = text
            self.level = level
            self.mitigation = mitigation
            self.owner = owner
        }
    }

    enum RiskLevel: String, Sendable, Equatable, Codable, CaseIterable {
        case low
        case medium
        case high

        var label: String {
            switch self {
            case .low: return "低"
            case .medium: return "中"
            case .high: return "高"
            }
        }
    }

    struct ActionItem: Identifiable, Sendable, Equatable, Codable {
        var id: UUID
        var title: String
        var owner: String?
        var dueText: String?
        var dueDate: Date?
        var status: ActionStatus
        var source: String?

        init(
            id: UUID = UUID(),
            title: String,
            owner: String? = nil,
            dueText: String? = nil,
            dueDate: Date? = nil,
            status: ActionStatus = .open,
            source: String? = nil
        ) {
            self.id = id
            self.title = title
            self.owner = owner
            self.dueText = dueText
            self.dueDate = dueDate
            self.status = status
            self.source = source
        }

        init(from notesItem: MeetingNotes.ActionItem) {
            self.init(
                title: notesItem.task,
                owner: notesItem.owner,
                dueText: notesItem.dueText,
                dueDate: notesItem.dueDate,
                status: .open,
                source: "MeetingNotes"
            )
        }

        var reminderTitle: String {
            var parts = [title.trimmingCharacters(in: .whitespacesAndNewlines)]
            if let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
                parts.append("(\(owner))")
            }
            return parts.joined(separator: " ")
        }
    }

    enum ActionStatus: String, Sendable, Equatable, Codable, CaseIterable {
        case open
        case waiting
        case done

        var label: String {
            switch self {
            case .open: return "待推进"
            case .waiting: return "等待中"
            case .done: return "已完成"
            }
        }
    }

    struct PostMeeting: Sendable, Equatable, Codable {
        var followUpDrafts: [FollowUpDraft]
        var reminderSuggestions: [ReminderSuggestion]
        var trackingSummary: String

        init(
            followUpDrafts: [FollowUpDraft] = [],
            reminderSuggestions: [ReminderSuggestion] = [],
            trackingSummary: String = ""
        ) {
            self.followUpDrafts = followUpDrafts
            self.reminderSuggestions = reminderSuggestions
            self.trackingSummary = trackingSummary
        }
    }

    struct FollowUpDraft: Identifiable, Sendable, Equatable, Codable {
        var id: UUID
        var channel: FollowUpChannel
        var audience: String
        var subject: String
        var body: String

        init(
            id: UUID = UUID(),
            channel: FollowUpChannel = .message,
            audience: String,
            subject: String,
            body: String
        ) {
            self.id = id
            self.channel = channel
            self.audience = audience
            self.subject = subject
            self.body = body
        }
    }

    enum FollowUpChannel: String, Sendable, Equatable, Codable, CaseIterable {
        case message
        case email

        var label: String {
            switch self {
            case .message: return "消息"
            case .email: return "邮件"
            }
        }
    }

    struct ReminderSuggestion: Identifiable, Sendable, Equatable, Codable {
        var id: UUID
        var title: String
        var suggestedAt: Date?
        var reason: String
        var relatedActionID: UUID?

        init(
            id: UUID = UUID(),
            title: String,
            suggestedAt: Date? = nil,
            reason: String,
            relatedActionID: UUID? = nil
        ) {
            self.id = id
            self.title = title
            self.suggestedAt = suggestedAt
            self.reason = reason
            self.relatedActionID = relatedActionID
        }
    }
}
