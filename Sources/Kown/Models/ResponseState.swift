import Foundation
import Observation

enum ResponsePhase: Sendable {
    case idle
    case streaming
    case finished
    case failed(String)
}

@Observable
@MainActor
final class ResponseState: Identifiable {
    let id: UUID
    var text: String = ""
    var phase: ResponsePhase = .idle
    var startedAt: Date?
    var finishedAt: Date?

    init(id: UUID) {
        self.id = id
    }

    func reset() {
        text = ""
        phase = .streaming
        startedAt = Date()
        finishedAt = nil
    }

    func append(_ chunk: String) {
        text += chunk
    }

    func finish() {
        phase = .finished
        finishedAt = Date()
    }

    func fail(_ message: String) {
        phase = .failed(message)
        finishedAt = Date()
    }

    var elapsedSeconds: Double? {
        guard let startedAt else { return nil }
        let end = finishedAt ?? Date()
        return end.timeIntervalSince(startedAt)
    }
}
