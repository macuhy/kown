import XCTest
@testable import Kown

/// 覆盖 `ConversationStore.dedupeByID` —— iCloud 冲突副本(`<id> 2.json`)会让同一个 id
/// 被读到多份,不去重会让 `SidebarView` 的 `ForEach` 拿到重复 Identifiable id、布局错乱。
final class ConversationDedupTests: XCTestCase {

    private func conv(_ id: UUID, updated: TimeInterval, title: String) -> Conversation {
        Conversation(id: id,
                     title: title,
                     createdAt: Date(timeIntervalSince1970: 0),
                     updatedAt: Date(timeIntervalSince1970: updated))
    }

    func testKeepsNewestForDuplicateID() {
        let id = UUID()
        let older = conv(id, updated: 100, title: "旧")
        let newer = conv(id, updated: 200, title: "新")
        // 不论输入顺序,都保留 updatedAt 最新的那份
        for input in [[older, newer], [newer, older]] {
            let result = ConversationStore.dedupeByID(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.title, "新")
        }
    }

    func testDistinctIDsAllKeptSortedDescending() {
        let a = conv(UUID(), updated: 100, title: "a")
        let b = conv(UUID(), updated: 300, title: "b")
        let c = conv(UUID(), updated: 200, title: "c")
        let result = ConversationStore.dedupeByID([a, b, c])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.title), ["b", "c", "a"], "应按 updatedAt 倒序")
    }

    func testEmptyInput() {
        XCTAssertTrue(ConversationStore.dedupeByID([]).isEmpty)
    }
}
