import Foundation
import TermLayout
import XCTest

/// `agentdeck new` 가 만든 칸의 배치(Workspace.place)
final class PanePlacementTests: XCTestCase {
    func base() -> Workspace {
        Workspace(tabs: [
            TabState(id: "t1", root: .pane("A"), focused: "A"),
            TabState(id: "t2", root: .pane("Z"), focused: "Z"),
        ], selected: "t2")
    }

    func testDefaultGoesRightOfAnchorWithoutStealingFocus() {
        var w = base()
        XCTAssertTrue(w.place(newPane: "N1", beside: "A", .stack))
        XCTAssertEqual(w.tabs[0].root, .split(axis: .horizontal, ratio: 0.5, first: .pane("A"), second: .pane("N1")))
        XCTAssertEqual(w.tabs[0].focused, "A", "지휘하는 칸의 입력 포커스를 뺏지 않는다")
        XCTAssertEqual(w.selected, "t2", "보고 있던 탭도 그대로")
    }

    func testSecondAndThirdStackDownInRightColumn() {
        var w = base()
        _ = w.place(newPane: "N1", beside: "A", .stack)
        _ = w.place(newPane: "N2", beside: "A", .stack)
        _ = w.place(newPane: "N3", beside: "A", .stack)
        let root = w.tabs[0].root
        XCTAssertEqual(Set(root.panes), ["A", "N1", "N2", "N3"])
        // A 의 오른쪽에는 N1·N2·N3 가 위에서 아래로 쌓인다
        XCTAssertEqual(root.neighbor(of: "N1", toward: .left), "A")
        XCTAssertNil(root.neighbor(of: "N1", toward: .up))
        XCTAssertEqual(root.neighbor(of: "N1", toward: .down), "N2")
        XCTAssertEqual(root.neighbor(of: "N2", toward: .down), "N3")
        XCTAssertNil(root.neighbor(of: "N3", toward: .down))
        // 같은 높이(1/3 씩): 위 가르는 선 1/3, 그다음 1/2
        guard case .split(_, _, _, let column) = root, case .split(let axis, let ratio, _, let rest) = column else { return XCTFail() }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(ratio, 1.0 / 3, accuracy: 0.001)
        guard case .split(_, let ratio2, _, _) = rest else { return XCTFail() }
        XCTAssertEqual(ratio2, 0.5, accuracy: 0.001)
    }

    /// 시험 결과: `new --right --of X` 를 두 번 하면 둘째가 X 와 첫째 사이에 끼었다((X | 둘째) | 첫째)
    func testRepeatedExplicitRightStacksBelowFirstNotBetween() {
        var w = base()
        _ = w.place(newPane: "N1", beside: "A", .right)
        _ = w.place(newPane: "N2", beside: "A", .right)
        let root = w.tabs[0].root
        XCTAssertEqual(root.neighbor(of: "A", toward: .right), "N1", "첫째가 X 바로 옆에 그대로")
        XCTAssertEqual(root.neighbor(of: "N1", toward: .down), "N2")
        XCTAssertEqual(root.neighbor(of: "N2", toward: .left), "A")
        // 같은 높이
        XCTAssertEqual(root, .split(axis: .horizontal, ratio: 0.5, first: .pane("A"),
                                    second: .split(axis: .vertical, ratio: 0.5, first: .pane("N1"), second: .pane("N2"))))
        _ = w.place(newPane: "N3", beside: "A", .right)
        guard case .split(_, _, _, let column) = w.tabs[0].root, case .split(_, let ratio, _, _) = column else { return XCTFail() }
        XCTAssertEqual(ratio, 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(w.tabs[0].root.neighbor(of: "N2", toward: .down), "N3")
    }

    /// --down 도 같은 원리: 아래 줄이 있으면 그 줄 맨 오른쪽으로(A / (N1 | N2 | N3)), 같은 너비로
    func testRepeatedExplicitDownStacksRightOfFirstInRow() {
        var w = base()
        _ = w.place(newPane: "N1", beside: "A", .down)
        _ = w.place(newPane: "N2", beside: "A", .down)
        XCTAssertEqual(w.tabs[0].root, .split(axis: .vertical, ratio: 0.5, first: .pane("A"),
                                              second: .split(axis: .horizontal, ratio: 0.5, first: .pane("N1"), second: .pane("N2"))))
        _ = w.place(newPane: "N3", beside: "A", .down)
        let root = w.tabs[0].root
        XCTAssertEqual(root.neighbor(of: "N1", toward: .up), "A", "첫째가 A 바로 아래 줄의 맨 왼쪽")
        XCTAssertNil(root.neighbor(of: "N1", toward: .left))
        XCTAssertEqual(root.neighbor(of: "N1", toward: .right), "N2")
        XCTAssertEqual(root.neighbor(of: "N2", toward: .right), "N3")
        guard case .split(_, _, _, let row) = root, case .split(_, let ratio, _, _) = row else { return XCTFail() }
        XCTAssertEqual(ratio, 1.0 / 3, accuracy: 0.001)
    }

    /// 기준 칸 옆이 아닌 다른 줄의 칸은 끌어들이지 않는다: Y / (X | Z) 에서 X 의 오른쪽 줄은 Z 하나
    func testLineOnlyContainsPanesTouchingAnchor() {
        let tree = SplitNode.split(axis: .vertical, ratio: 0.5, first: .pane("Y"),
                                   second: .split(axis: .horizontal, ratio: 0.5, first: .pane("X"), second: .pane("Z")))
        var w = Workspace(tabs: [TabState(id: "t", root: tree, focused: "X")], selected: "t")
        _ = w.place(newPane: "N", beside: "X", .right)
        let root = w.tabs[0].root
        XCTAssertEqual(root.neighbor(of: "Z", toward: .down), "N")
        XCTAssertNil(root.neighbor(of: "Y", toward: .down).flatMap { $0 == "N" ? $0 : nil }, "Y 아래에 N 이 끼지 않는다")
        XCTAssertEqual(root.neighbor(of: "X", toward: .right), "Z")
    }

    func testExplicitRightAndDown() {
        var w = base()
        _ = w.place(newPane: "N1", beside: "A", .down)
        XCTAssertEqual(w.tabs[0].root, .split(axis: .vertical, ratio: 0.5, first: .pane("A"), second: .pane("N1")))
        _ = w.place(newPane: "N2", beside: "A", .right)
        XCTAssertEqual(w.tabs[0].root.neighbor(of: "A", toward: .right), "N2")
        XCTAssertEqual(w.tabs[0].root.neighbor(of: "A", toward: .down), "N1")
    }

    func testMovesPaneThatWasAlreadyAttachedAsOwnTab() {
        var w = base()
        w.tabs.append(TabState(id: "t3", root: .pane("N1"), focused: "N1")) // 앱이 먼저 새 탭으로 붙였다
        XCTAssertTrue(w.place(newPane: "N1", beside: "A", .stack))
        XCTAssertEqual(w.tabs.map(\.id), ["t1", "t2"], "빈 탭은 사라진다")
        XCTAssertEqual(Set(w.tabs[0].root.panes), ["A", "N1"])
        XCTAssertEqual(w.allPanes.filter { $0 == "N1" }.count, 1)
    }

    func testMissingAnchorChangesNothing() {
        var w = base()
        let before = w
        XCTAssertFalse(w.place(newPane: "N1", beside: "nope", .stack))
        XCTAssertFalse(w.place(newPane: "A", beside: "A", .stack))
        XCTAssertEqual(w, before)
    }

    func testStackBesideSplitWithOtherPanesUsesRightNeighborColumn() {
        // A | B(오른쪽에 이미 칸이 있다) → 새 칸은 B 아래로
        var w = Workspace(tabs: [TabState(id: "t", root: .split(axis: .horizontal, ratio: 0.5, first: .pane("A"), second: .pane("B")),
                                          focused: "A")], selected: "t")
        _ = w.place(newPane: "N", beside: "A", .stack)
        XCTAssertEqual(w.tabs[0].root.neighbor(of: "B", toward: .down), "N")
        XCTAssertEqual(w.tabs[0].root.neighbor(of: "A", toward: .right), "B")
    }
}
