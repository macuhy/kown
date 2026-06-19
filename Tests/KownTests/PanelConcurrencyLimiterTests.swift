import XCTest
@testable import Kown

final class PanelConcurrencyLimiterTests: XCTestCase {
    func testDefaultLimitStartsAtMostFourTasks() {
        var limiter = PanelConcurrencyLimiter(totalCount: 7)

        XCTAssertEqual(limiter.limit, 4)
        XCTAssertEqual(limiter.reserveInitialIndices(), [0, 1, 2, 3])
        XCTAssertEqual(limiter.reserveNextIndex(), 4)
        XCTAssertEqual(limiter.reserveNextIndex(), 5)
        XCTAssertEqual(limiter.reserveNextIndex(), 6)
        XCTAssertNil(limiter.reserveNextIndex())
    }

    func testLimitClampsToPanelSizeAndOneMinimum() {
        XCTAssertEqual(PanelConcurrencyLimiter.effectiveLimit(totalCount: 0), 0)
        XCTAssertEqual(PanelConcurrencyLimiter.effectiveLimit(totalCount: 2), 2)
        XCTAssertEqual(PanelConcurrencyLimiter.effectiveLimit(totalCount: 7, requestedLimit: 0), 1)
        XCTAssertEqual(PanelConcurrencyLimiter.effectiveLimit(totalCount: 7, requestedLimit: 10), 7)
    }
}
