import Foundation
import Observation

/// In-memory + JSON-backed store for the Agent Run Center MVP.
@MainActor
@Observable
final class AgentRunStore {
    static let shared = AgentRunStore()

    private(set) var runs: [AgentRun]
    private(set) var lastPersistenceError: String?

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let fileManager: FileManager

    convenience init() {
        self.init(fileURL: Self.defaultFileURL())
    }

    init(fileURL: URL?, initialRuns: [AgentRun]? = nil, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        if let initialRuns {
            self.runs = Self.sorted(initialRuns)
        } else if let fileURL {
            self.runs = Self.load(from: fileURL)
        } else {
            self.runs = []
        }
    }

    static func inMemory(sampleRuns: [AgentRun] = []) -> AgentRunStore {
        AgentRunStore(fileURL: nil, initialRuns: sampleRuns)
    }

    private static func defaultFileURL() -> URL {
        Platform.syncedDataDir.appendingPathComponent("agent_runs.json")
    }

    nonisolated static func load(from url: URL) -> [AgentRun] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([AgentRun].self, from: data) else { return [] }
        return sorted(decoded)
    }

    func reload() {
        guard let fileURL else { return }
        runs = Self.load(from: fileURL)
    }

    func run(id: UUID) -> AgentRun? {
        runs.first { $0.id == id }
    }

    func filteredRuns(
        status: AgentRun.Status? = nil,
        kind: AgentRun.Kind? = nil,
        query: String = ""
    ) -> [AgentRun] {
        var candidates = runs
        if let status {
            candidates = candidates.filter { $0.status == status }
        }
        if let kind {
            candidates = candidates.filter { $0.kind == kind }
        }

        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return candidates }

        return candidates.filter { run in
            let text = Self.searchableText(for: run).lowercased()
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    @discardableResult
    func create(
        kind: AgentRun.Kind,
        title: String,
        prompt: String = "",
        status: AgentRun.Status = .queued,
        approvalStatus: AgentRun.ApprovalStatus = .notRequired,
        sourceID: String? = nil,
        tags: [String] = [],
        metadata: [String: String] = [:],
        at date: Date = Date()
    ) -> AgentRun {
        var run = AgentRun(
            kind: kind,
            title: title,
            prompt: prompt,
            status: status,
            approvalStatus: approvalStatus,
            createdAt: date,
            updatedAt: date,
            sourceID: sourceID,
            tags: tags,
            metadata: metadata
        )
        if status == .running || status == .waitingForApproval {
            run.startedAt = date
        }
        upsert(run)
        return run
    }

    func upsert(_ run: AgentRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.insert(run, at: 0)
        }
        sortRuns()
        persist()
    }

    func remove(_ id: UUID) {
        runs.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        runs.removeAll()
        persist()
    }

    @discardableResult
    func transition(_ id: UUID, to newStatus: AgentRun.Status, reason: String? = nil, at date: Date = Date()) -> Bool {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return false }
        let current = runs[index].status
        guard current.canTransition(to: newStatus) else { return false }
        runs[index].applyStatus(newStatus, at: date, reason: reason)
        sortRuns()
        persist()
        return true
    }

    @discardableResult
    func pause(_ id: UUID, reason: String? = nil) -> Bool {
        transition(id, to: .paused, reason: reason)
    }

    @discardableResult
    func resume(_ id: UUID) -> Bool {
        transition(id, to: .running)
    }

    @discardableResult
    func cancel(_ id: UUID, reason: String? = "用户取消") -> Bool {
        transition(id, to: .cancelled, reason: reason)
    }

    func setApprovalStatus(_ id: UUID, _ approvalStatus: AgentRun.ApprovalStatus, at date: Date = Date()) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].approvalStatus = approvalStatus
        runs[index].updatedAt = date
        sortRuns()
        persist()
    }

    @discardableResult
    func approve(_ id: UUID, at date: Date = Date()) -> Bool {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return false }
        runs[index].approvalStatus = .approved
        runs[index].updatedAt = date
        for stepIndex in runs[index].steps.indices
        where runs[index].steps[stepIndex].approvalStatus == .pending || runs[index].steps[stepIndex].status == .waitingForApproval {
            runs[index].steps[stepIndex].approvalStatus = .approved
            if runs[index].steps[stepIndex].status == .waitingForApproval {
                runs[index].steps[stepIndex].status = .running
                if runs[index].steps[stepIndex].startedAt == nil { runs[index].steps[stepIndex].startedAt = date }
            }
        }
        for callIndex in runs[index].toolCalls.indices
        where runs[index].toolCalls[callIndex].approvalStatus == .pending || runs[index].toolCalls[callIndex].status == .waitingForApproval {
            runs[index].toolCalls[callIndex].approvalStatus = .approved
            if runs[index].toolCalls[callIndex].status == .waitingForApproval {
                runs[index].toolCalls[callIndex].status = .running
                if runs[index].toolCalls[callIndex].startedAt == nil { runs[index].toolCalls[callIndex].startedAt = date }
            }
        }
        if runs[index].status == .waitingForApproval || runs[index].status == .queued {
            runs[index].applyStatus(.running, at: date, reason: "审批已通过,继续运行。")
        }
        sortRuns()
        persist()
        return true
    }

    @discardableResult
    func reject(_ id: UUID, reason: String = "用户拒绝审批", at date: Date = Date()) -> Bool {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return false }
        runs[index].approvalStatus = .rejected
        runs[index].updatedAt = date
        for stepIndex in runs[index].steps.indices
        where runs[index].steps[stepIndex].approvalStatus == .pending || runs[index].steps[stepIndex].status == .waitingForApproval {
            runs[index].steps[stepIndex].approvalStatus = .rejected
            runs[index].steps[stepIndex].status = .skipped
            runs[index].steps[stepIndex].finishedAt = date
            runs[index].steps[stepIndex].errorMessage = reason
        }
        for callIndex in runs[index].toolCalls.indices
        where runs[index].toolCalls[callIndex].approvalStatus == .pending || runs[index].toolCalls[callIndex].status == .waitingForApproval {
            runs[index].toolCalls[callIndex].approvalStatus = .rejected
            runs[index].toolCalls[callIndex].status = .skipped
            runs[index].toolCalls[callIndex].finishedAt = date
            runs[index].toolCalls[callIndex].errorMessage = reason
        }
        if runs[index].status.canTransition(to: .cancelled) {
            runs[index].applyStatus(.cancelled, at: date, reason: reason)
        } else {
            runs[index].errorMessage = reason
        }
        sortRuns()
        persist()
        return true
    }

    @discardableResult
    func appendStep(to runID: UUID, _ step: AgentRun.Step, at date: Date = Date()) -> AgentRun.Step? {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return nil }
        var nextStep = step
        if nextStep.startedAt == nil, nextStep.status == .running || nextStep.status == .waitingForApproval {
            nextStep.startedAt = date
        }
        if nextStep.finishedAt == nil, nextStep.status.isTerminal {
            nextStep.finishedAt = date
        }
        runs[index].steps.append(nextStep)
        runs[index].updatedAt = date
        if runs[index].status == .queued, nextStep.status == .running {
            runs[index].applyStatus(.running, at: date)
        }
        sortRuns()
        persist()
        return nextStep
    }

    @discardableResult
    func appendStep(
        to runID: UUID,
        title: String,
        detail: String = "",
        status: AgentRun.StepStatus = .running,
        approvalStatus: AgentRun.ApprovalStatus = .notRequired,
        metadata: [String: String] = [:],
        at date: Date = Date()
    ) -> AgentRun.Step? {
        let step = AgentRun.Step(
            title: title,
            detail: detail,
            status: status,
            approvalStatus: approvalStatus,
            metadata: metadata
        )
        return appendStep(to: runID, step, at: date)
    }

    @discardableResult
    func updateStep(
        runID: UUID,
        stepID: UUID,
        status: AgentRun.StepStatus? = nil,
        detail: String? = nil,
        resultSummary: String? = nil,
        errorMessage: String? = nil,
        approvalStatus: AgentRun.ApprovalStatus? = nil,
        at date: Date = Date()
    ) -> Bool {
        guard let runIndex = runs.firstIndex(where: { $0.id == runID }),
              let stepIndex = runs[runIndex].steps.firstIndex(where: { $0.id == stepID }) else { return false }
        if let status {
            runs[runIndex].steps[stepIndex].status = status
            if runs[runIndex].steps[stepIndex].startedAt == nil, status == .running || status == .waitingForApproval {
                runs[runIndex].steps[stepIndex].startedAt = date
            }
            if status.isTerminal {
                runs[runIndex].steps[stepIndex].finishedAt = date
            }
        }
        if let detail { runs[runIndex].steps[stepIndex].detail = detail }
        if let resultSummary { runs[runIndex].steps[stepIndex].resultSummary = resultSummary }
        if let errorMessage { runs[runIndex].steps[stepIndex].errorMessage = errorMessage }
        if let approvalStatus { runs[runIndex].steps[stepIndex].approvalStatus = approvalStatus }
        runs[runIndex].updatedAt = date
        sortRuns()
        persist()
        return true
    }

    @discardableResult
    func appendToolCall(to runID: UUID, _ call: AgentRun.ToolCall, at date: Date = Date()) -> AgentRun.ToolCall? {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return nil }
        var nextCall = call
        if nextCall.startedAt == nil, nextCall.status == .running || nextCall.status == .waitingForApproval {
            nextCall.startedAt = date
        }
        if nextCall.finishedAt == nil, nextCall.status.isTerminal {
            nextCall.finishedAt = date
        }
        runs[index].toolCalls.append(nextCall)
        runs[index].cost.add(nextCall.cost)
        runs[index].updatedAt = date
        sortRuns()
        persist()
        return nextCall
    }

    @discardableResult
    func appendToolCall(
        to runID: UUID,
        name: String,
        displayName: String? = nil,
        argumentsSummary: String = "",
        status: AgentRun.StepStatus = .running,
        approvalStatus: AgentRun.ApprovalStatus = .notRequired,
        metadata: [String: String] = [:],
        at date: Date = Date()
    ) -> AgentRun.ToolCall? {
        let call = AgentRun.ToolCall(
            name: name,
            displayName: displayName,
            argumentsSummary: argumentsSummary,
            status: status,
            approvalStatus: approvalStatus,
            metadata: metadata
        )
        return appendToolCall(to: runID, call, at: date)
    }

    @discardableResult
    func updateToolCall(
        runID: UUID,
        callID: UUID,
        status: AgentRun.StepStatus? = nil,
        resultSummary: String? = nil,
        errorMessage: String? = nil,
        approvalStatus: AgentRun.ApprovalStatus? = nil,
        cost: AgentRun.Cost? = nil,
        at date: Date = Date()
    ) -> Bool {
        guard let runIndex = runs.firstIndex(where: { $0.id == runID }),
              let callIndex = runs[runIndex].toolCalls.firstIndex(where: { $0.id == callID }) else { return false }
        if let status {
            runs[runIndex].toolCalls[callIndex].status = status
            if runs[runIndex].toolCalls[callIndex].startedAt == nil, status == .running || status == .waitingForApproval {
                runs[runIndex].toolCalls[callIndex].startedAt = date
            }
            if status.isTerminal {
                runs[runIndex].toolCalls[callIndex].finishedAt = date
            }
        }
        if let resultSummary { runs[runIndex].toolCalls[callIndex].resultSummary = resultSummary }
        if let errorMessage { runs[runIndex].toolCalls[callIndex].errorMessage = errorMessage }
        if let approvalStatus { runs[runIndex].toolCalls[callIndex].approvalStatus = approvalStatus }
        if let cost {
            let previous = runs[runIndex].toolCalls[callIndex].cost
            runs[runIndex].toolCalls[callIndex].cost = cost
            runs[runIndex].cost.subtract(previous)
            runs[runIndex].cost.add(cost)
        }
        runs[runIndex].updatedAt = date
        sortRuns()
        persist()
        return true
    }

    func setCost(runID: UUID, cost: AgentRun.Cost, at date: Date = Date()) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].cost = cost
        runs[index].updatedAt = date
        sortRuns()
        persist()
    }

    func attentionNotifications(now: Date = Date()) -> [AgentRunNotification] {
        runs.flatMap { run -> [AgentRunNotification] in
            if run.needsApproval {
                return [AgentRunNotification(
                    runID: run.id,
                    level: .approval,
                    title: "待审批",
                    message: run.title.isEmpty ? run.kind.displayName : run.title,
                    actionTitle: "处理",
                    createdAt: run.updatedAt
                )]
            }
            if run.status == .running || run.status == .queued || run.status == .paused {
                return [AgentRunNotification(
                    runID: run.id,
                    level: .running,
                    title: run.status.displayName,
                    message: run.title.isEmpty ? run.kind.displayName : run.title,
                    actionTitle: "查看",
                    createdAt: run.updatedAt
                )]
            }
            guard now.timeIntervalSince(run.updatedAt) <= 86_400 else { return [] }
            switch run.status {
            case .succeeded:
                return [AgentRunNotification(
                    runID: run.id,
                    level: .success,
                    title: "任务已完成",
                    message: run.summary ?? run.title,
                    actionTitle: "查看结果",
                    createdAt: run.updatedAt
                )]
            case .failed, .cancelled:
                return [AgentRunNotification(
                    runID: run.id,
                    level: .failure,
                    title: run.status == .failed ? "任务失败" : "任务已取消",
                    message: run.errorMessage ?? run.title,
                    actionTitle: run.canRerun ? "重跑" : "查看",
                    createdAt: run.updatedAt
                )]
            default:
                return []
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
        .prefix(8)
        .map { $0 }
    }

    @discardableResult
    func rerun(_ id: UUID, at date: Date = Date()) -> AgentRun? {
        guard let original = run(id: id) else { return nil }
        var rerun = AgentRun(
            kind: original.kind,
            title: original.title.isEmpty ? original.kind.displayName : "\(original.title) · 重跑",
            prompt: original.prompt,
            summary: nil,
            status: .queued,
            approvalStatus: original.approvalStatus == .pending ? .pending : .notRequired,
            createdAt: date,
            updatedAt: date,
            sourceID: original.sourceID,
            retryOf: original.id,
            tags: original.tags,
            metadata: original.metadata.merging([
                "retryOf": original.id.uuidString,
                "retryCreatedAt": ISO8601DateFormatter().string(from: date)
            ]) { current, _ in current }
        )
        rerun.steps.append(
            AgentRun.Step(
                title: "重跑已排队",
                detail: "来自 \(original.title.isEmpty ? original.kind.displayName : original.title)",
                status: .queued,
                resultSummary: original.errorMessage ?? original.summary,
                metadata: ["retryOf": original.id.uuidString]
            )
        )
        upsert(rerun)
        return rerun
    }

    private func sortRuns() {
        runs = Self.sorted(runs)
    }

    nonisolated private static func searchableText(for run: AgentRun) -> String {
        var parts: [String] = [
            run.kind.displayName,
            run.status.displayName,
            run.approvalStatus.displayName,
            run.title,
            run.prompt,
            run.summary ?? "",
            run.errorMessage ?? "",
            run.sourceID ?? "",
            run.retryOf?.uuidString ?? ""
        ]
        parts.append(contentsOf: run.tags)
        parts.append(contentsOf: run.metadata.flatMap { [$0.key, $0.value] })
        for step in run.steps {
            parts.append(contentsOf: [
                step.title,
                step.detail,
                step.status.displayName,
                step.resultSummary ?? "",
                step.errorMessage ?? "",
                step.approvalStatus.displayName
            ])
            parts.append(contentsOf: step.metadata.flatMap { [$0.key, $0.value] })
        }
        for call in run.toolCalls {
            parts.append(contentsOf: [
                call.name,
                call.displayName,
                call.argumentsSummary,
                call.status.displayName,
                call.resultSummary ?? "",
                call.errorMessage ?? "",
                call.approvalStatus.displayName,
                call.externalID ?? ""
            ])
            parts.append(contentsOf: call.metadata.flatMap { [$0.key, $0.value] })
        }
        return parts.joined(separator: "\n")
    }

    nonisolated private static func sorted(_ runs: [AgentRun]) -> [AgentRun] {
        runs.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700 as NSNumber]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(runs)
            try data.write(to: fileURL, options: .atomic)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }
}
