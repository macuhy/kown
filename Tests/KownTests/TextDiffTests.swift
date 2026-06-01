import XCTest
@testable import Kown

/// 覆盖行级 diff(workspace 改动「查看 diff」用)。
final class TextDiffTests: XCTestCase {

    func testIdenticalAllEqual() {
        let lines = TextDiff.diff(old: "a\nb\nc", new: "a\nb\nc")
        XCTAssertEqual(lines.map(\.kind), [.equal, .equal, .equal])
        let s = TextDiff.stats(lines)
        XCTAssertEqual(s.added, 0)
        XCTAssertEqual(s.removed, 0)
    }

    func testInsertMiddleLine() {
        let lines = TextDiff.diff(old: "a\nc", new: "a\nb\nc")
        let s = TextDiff.stats(lines)
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(s.removed, 0)
        XCTAssertTrue(lines.contains { $0.kind == .insert && $0.text == "b" })
    }

    func testReplaceLineCountsBothSides() {
        let lines = TextDiff.diff(old: "x\nold\nz", new: "x\nnew\nz")
        let s = TextDiff.stats(lines)
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(s.removed, 1)
        XCTAssertTrue(lines.contains { $0.kind == .delete && $0.text == "old" })
        XCTAssertTrue(lines.contains { $0.kind == .insert && $0.text == "new" })
    }

    func testFromEmptyIsAllInsert() {
        let lines = TextDiff.diff(old: "", new: "a\nb")
        XCTAssertEqual(TextDiff.stats(lines).added, 2)
        XCTAssertEqual(TextDiff.stats(lines).removed, 0)
    }

    func testToEmptyIsAllDelete() {
        let lines = TextDiff.diff(old: "a\nb", new: "")
        XCTAssertEqual(TextDiff.stats(lines).removed, 2)
        XCTAssertEqual(TextDiff.stats(lines).added, 0)
    }
}
