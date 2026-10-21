import XCTest
@testable import TermLayout

final class SessionNavigationTests: XCTestCase {
    func target(_ id: String, _ state: String, _ at: Double = 0, name: String = "", folder: String = "") -> SessionTarget {
        SessionTarget(id: id, name: name, folder: folder, state: state, stateAt: Date(timeIntervalSince1970: at))
    }
    func testPriorityAndCycleIncludingRemovedDone() {
        let items = [target("work", "working"), target("done", "done"), target("error", "error"),
                     target("wait-old", "waiting", 1), target("wait-new", "waiting", 2), target("bg", "orchestrating")]
        XCTAssertEqual(SessionNavigation.attention(items).map(\.id), ["wait-new", "wait-old", "error", "done", "bg"])
        var cycle = AttentionCycle()
        XCTAssertEqual((0..<4).compactMap { _ in cycle.next(items) }, ["wait-new", "wait-old", "error", "done"])
        let remaining = items.filter { $0.id != "done" }
        XCTAssertEqual(cycle.next(remaining), "bg")
        XCTAssertEqual(cycle.next(remaining), "wait-new")
        XCTAssertNil(cycle.next([]))
        XCTAssertEqual(cycle.next([target("only", "error")]), "only")
        XCTAssertEqual(cycle.next([target("only", "error")]), "only")
    }
    func testCycleSkipsFocusedFirstTarget() {
        let items = [target("waiting", "waiting"), target("error", "error")]
        var cycle = AttentionCycle()
        XCTAssertEqual(cycle.next(items, focused: "waiting"), "error")
        XCTAssertEqual(cycle.next(items, focused: "error"), "waiting")
        XCTAssertEqual(cycle.next([items[0]], focused: "waiting"), "waiting")
    }
    func testKoreanSubstringAndNameRanking() {
        let items = [target("a", "", name: "한글 검색", folder: "/tmp/작업트리"),
                     target("b", "waiting", name: "다른 이름", folder: "/tmp/한글")]
        XCTAssertEqual(SessionNavigation.ranked(items, query: "한글").map(\.id), ["a", "b"])
        XCTAssertEqual(SessionNavigation.ranked(items, query: "검색 작업트리").map(\.id), ["a"])
        XCTAssertEqual(SessionNavigation.ranked(items, query: "없는 글"), [])
        XCTAssertEqual(SessionNavigation.ranked(items, query: "").map(\.id), ["b", "a"])
    }
    func testRecentAndDeterministicTies() {
        var older = target("a", "")
        var newer = target("b", "")
        older.recentAt = Date(timeIntervalSince1970: 1)
        newer.recentAt = Date(timeIntervalSince1970: 2)
        XCTAssertEqual(SessionNavigation.ranked([older, newer], query: "").map(\.id), ["b", "a"])
    }
    func testWideAndWrappedBufferSearch() {
        let matches = BufferLineSearch.find("한글", rows: ["ab한글 한글", "한", "글!"], wrapped: [2])
        XCTAssertEqual(matches.map(\.start), [.init(row: 0, column: 2), .init(row: 0, column: 7), .init(row: 1, column: 0)])
        XCTAssertEqual(matches.map(\.end), [.init(row: 0, column: 6), .init(row: 0, column: 11), .init(row: 2, column: 2)])
        XCTAssertEqual(BufferLineSearch.find("한글", rows: ["한", "글"]).count, 0)
        XCTAssertEqual(BufferLineSearch.find("test", rows: ["Test test TEST"]).count, 3)
        XCTAssertEqual(BufferLineSearch.find("test", rows: ["Test test TEST"], caseSensitive: true).count, 1)
        XCTAssertTrue(BufferLineSearch.find("", rows: ["abc"]).isEmpty)
        XCTAssertEqual(BufferLineSearch.find("X", rows: ["😀e\u{301}X"]).first?.start.column, 3)
    }
}
