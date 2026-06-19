import Foundation

struct PanelConcurrencyLimiter {
    static let defaultLimit = 4

    let totalCount: Int
    let limit: Int
    private var nextIndex = 0

    init(totalCount: Int, requestedLimit: Int = Self.defaultLimit) {
        self.totalCount = max(0, totalCount)
        self.limit = Self.effectiveLimit(totalCount: totalCount, requestedLimit: requestedLimit)
    }

    static func effectiveLimit(totalCount: Int, requestedLimit: Int = Self.defaultLimit) -> Int {
        let total = max(0, totalCount)
        guard total > 0 else { return 0 }
        return min(max(1, requestedLimit), total)
    }

    mutating func reserveInitialIndices() -> [Int] {
        guard limit > 0 else { return [] }
        return reserve(upTo: limit)
    }

    mutating func reserveNextIndex() -> Int? {
        guard nextIndex < totalCount else { return nil }
        defer { nextIndex += 1 }
        return nextIndex
    }

    private mutating func reserve(upTo count: Int) -> [Int] {
        var indices: [Int] = []
        indices.reserveCapacity(count)
        while indices.count < count, let index = reserveNextIndex() {
            indices.append(index)
        }
        return indices
    }
}
