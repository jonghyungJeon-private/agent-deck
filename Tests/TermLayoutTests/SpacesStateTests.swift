import Foundation
import TermLayout
import XCTest

final class SpacesOrderTests: XCTestCase {
    func testApplyKeepsUnknownAtEndInOriginalOrder() {
        let items = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(SpacesOrder.apply(items, order: ["d", "b"], id: { $0 }), ["d", "b", "a", "c", "e"])
        // 사라진 ID 는 무시, 빈 순서는 그대로
        XCTAssertEqual(SpacesOrder.apply(items, order: ["gone", "e"], id: { $0 }), ["e", "a", "b", "c", "d"])
        XCTAssertEqual(SpacesOrder.apply(items, order: [], id: { $0 }), items)
        // 같은 ID 가 두 번 있으면 앞의 것
        XCTAssertEqual(SpacesOrder.apply(["a", "b"], order: ["b", "a", "b"], id: { $0 }), ["b", "a"])
    }

    func testMoveDownGoesAfterTargetAndUpGoesBefore() {
        let ids = ["A", "B", "C", "D"]
        XCTAssertEqual(SpacesOrder.move(ids, "A", onto: "C"), ["B", "C", "A", "D"])
        XCTAssertEqual(SpacesOrder.move(ids, "D", onto: "B"), ["A", "D", "B", "C"])
        // 맨 끝·맨 앞으로도 갈 수 있다
        XCTAssertEqual(SpacesOrder.move(ids, "A", onto: "D"), ["B", "C", "D", "A"])
        XCTAssertEqual(SpacesOrder.move(ids, "D", onto: "A"), ["D", "A", "B", "C"])
        XCTAssertNil(SpacesOrder.move(ids, "A", onto: "A"))
        XCTAssertNil(SpacesOrder.move(ids, "A", onto: "Z"))
        XCTAssertTrue(SpacesOrder.insertsAfter(ids, "A", onto: "C"))
        XCTAssertFalse(SpacesOrder.insertsAfter(ids, "D", onto: "B"))
    }

    func testMergeReplacesSiblingsAndDropsDeadIds() {
        let merged = SpacesOrder.merge(["y", "x"], into: ["x", "dead", "other", "y"], keep: ["x", "y", "other"])
        XCTAssertEqual(merged, ["other", "y", "x"])
    }
}

final class SpacesStateTests: XCTestCase {
    func testMoveSessionOnlyReordersWithinSiblings() {
        var state = SpacesState()
        // 칸 1: p1 p2 p3, 칸 2: q1 q2
        XCTAssertTrue(state.moveSession("p3", onto: "p1", siblings: ["p1", "p2", "p3"], live: ["p1", "p2", "p3", "q1", "q2"]))
        XCTAssertEqual(SpacesOrder.apply(["p1", "p2", "p3"], order: state.sessionOrder, id: { $0 }), ["p3", "p1", "p2"])
        // 다른 칸의 순서는 그대로, 새 화면은 뒤에
        XCTAssertTrue(state.moveSession("q2", onto: "q1", siblings: ["q1", "q2"], live: ["p1", "p2", "p3", "q1", "q2"]))
        XCTAssertEqual(SpacesOrder.apply(["p1", "p2", "p3", "p4"], order: state.sessionOrder, id: { $0 }), ["p3", "p1", "p2", "p4"])
        XCTAssertEqual(SpacesOrder.apply(["q1", "q2"], order: state.sessionOrder, id: { $0 }), ["q2", "q1"])
        // 다른 칸으로는 옮기지 않는다(같은 칸에 없는 대상)
        XCTAssertFalse(state.moveSession("p1", onto: "q1", siblings: ["p3", "p1", "p2"], live: ["p1", "q1"]))
        // 닫힌 화면은 다음 옮기기 때 버린다
        state.moveSession("p1", onto: "p3", siblings: ["p3", "p1", "p2"], live: ["p1", "p2", "p3"])
        XCTAssertEqual(state.sessionOrder, ["p1", "p3", "p2"])
    }

    func testMoveGroupUsesDisplayedOrder() {
        var state = SpacesState()
        XCTAssertTrue(state.moveGroup("/c", onto: "/a", displayed: ["/a", "/b", "/c"]))
        XCTAssertEqual(state.groupOrder, ["/c", "/a", "/b"])
        let groups = SpacesOrder.apply(["/a", "/b", "/c", "/new"], order: state.groupOrder, id: { $0 })
        XCTAssertEqual(groups, ["/c", "/a", "/b", "/new"])
        XCTAssertFalse(state.moveGroup("/a", onto: "/a", displayed: groups))
    }

    func testCollapseToggleAndAll() {
        var state = SpacesState()
        let group = SpacesState.groupKey("/repo"), tree = SpacesState.worktreeKey("/repo-wt")
        state.toggle(group)
        XCTAssertTrue(state.isCollapsed(group))
        state.toggle(group)
        XCTAssertFalse(state.isCollapsed(group))
        state.setCollapsed("g:/gone", true)
        state.collapseAll([group, tree])
        XCTAssertEqual(state.collapsed, [group, tree])
        state.expandAll()
        XCTAssertTrue(state.collapsed.isEmpty)
    }

    func testCodecRoundTripAndTolerantDecoding() throws {
        var state = SpacesState()
        state.collapsed = ["g:/a", "w:/a/wt"]
        state.groupOrder = ["/b", "/a"]
        state.sessionOrder = ["p2", "p1"]
        let data = try XCTUnwrap(state.data())
        XCTAssertEqual(try JSONDecoder().decode(SpacesState.self, from: data), state)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"version\" : 1"))

        // 빈 파일·모르는 열쇠·잘못된 값: 기본값으로, 중복·빈 글·모르는 접힘 열쇠는 버린다
        XCTAssertEqual(try JSONDecoder().decode(SpacesState.self, from: Data("{}".utf8)), SpacesState())
        let messy = Data(#"{"version":9,"future":true,"collapsed":["g:/a","bogus",""],"groupOrder":["/a","/a",""],"sessionOrder":null}"#.utf8)
        let decoded = try JSONDecoder().decode(SpacesState.self, from: messy)
        XCTAssertEqual(decoded.collapsed, ["g:/a"])
        XCTAssertEqual(decoded.groupOrder, ["/a"])
        XCTAssertEqual(decoded.sessionOrder, [])
        // 깨진 파일은 기본값
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(SpacesState.load(from: url), SpacesState())
    }
}

final class SpacesSummaryTests: XCTestCase {
    func testCountsSessionsByKindInAttentionOrder() {
        var summary = SpacesSummary()
        summary.add(session: .working)
        summary.add(session: .done)
        summary.add(session: .waiting)
        summary.add(session: nil) // 셸
        summary.add(session: .working)
        summary.add(agentRunning: true)
        summary.add(agentRunning: false)
        XCTAssertEqual(summary.sessions, 5)
        XCTAssertEqual(summary.runningAgents, 1)
        XCTAssertEqual(summary.entries.map(\.kind), [.waiting, .done, .working])
        XCTAssertEqual(summary.entries.map(\.count), [1, 1, 2])
        XCTAssertTrue(summary.needsAttention)
    }

    func testMergeNestedAndAttention() {
        var tree = SpacesSummary()
        tree.add(session: .error)
        tree.add(agentRunning: true)
        var group = SpacesSummary()
        group.add(session: .idle)
        XCTAssertFalse(group.needsAttention)
        group.merge(tree)
        XCTAssertEqual(group.sessions, 2)
        XCTAssertEqual(group.runningAgents, 1)
        XCTAssertEqual(group.entries.map(\.kind), [.error, .idle])
        XCTAssertTrue(group.needsAttention)
        XCTAssertTrue(SpacesSummary().isEmpty)
    }
}
