import TermLayout
import XCTest

final class TabNumberShortcutTests: XCTestCase {
    private func workspace() -> Workspace {
        let root = SplitNode.pane("A")
            .splitting("A", with: "B", axis: .horizontal)
            .splitting("B", with: "C", axis: .vertical)
        return Workspace(tabs: [
            TabState(id: "t1", root: root, focused: "B"),
            TabState(id: "t2", root: .pane("D"), focused: "D"),
        ], selected: "t2")
    }

    func testSwitchSelectsFirstPaneInsteadOfRememberedFocus() {
        var workspace = workspace()
        XCTAssertTrue(workspace.numberShortcut(1))
        XCTAssertEqual(workspace.selected, "t1")
        XCTAssertEqual(workspace.selectedTab?.focused, "A")
        XCTAssertFalse(workspace.tabs[0].zoomed)
        XCTAssertEqual(workspace.tabs[1].focused, "D")
    }

    func testRepeatAdvancesFromCurrentFocus() {
        var workspace = workspace()
        workspace.selected = "t1"
        XCTAssertTrue(workspace.numberShortcut(1))
        XCTAssertEqual(workspace.selectedTab?.focused, "C")
    }

    func testRepeatedShortcutWrapsInLeafOrder() {
        var workspace = workspace()
        for pane in ["A", "B", "C", "A"] {
            XCTAssertTrue(workspace.numberShortcut(1))
            XCTAssertEqual(workspace.selectedTab?.focused, pane)
        }
    }

    func testSwitchingTabsResetsCycle() {
        var workspace = workspace()
        workspace.numberShortcut(1)
        workspace.numberShortcut(1)
        XCTAssertEqual(workspace.selectedTab?.focused, "B")
        workspace.numberShortcut(2)
        XCTAssertEqual(workspace.selected, "t2")
        workspace.numberShortcut(1)
        XCTAssertEqual(workspace.selectedTab?.focused, "A")
        // 클릭·이전/다음 탭으로 다른 탭을 골랐어도 번호로 돌아오면 처음부터.
        workspace.numberShortcut(1)
        workspace.selected = "t2"
        workspace.numberShortcut(1)
        XCTAssertEqual(workspace.selectedTab?.focused, "A")
    }

    func testSinglePaneRepeatKeepsWorkspace() {
        var workspace = workspace()
        let before = workspace
        XCTAssertFalse(workspace.numberShortcut(2))
        XCTAssertEqual(workspace, before)
        workspace = Workspace(tabs: [TabState(id: "only", root: .pane("A"), focused: "A")], selected: "only")
        let only = workspace
        XCTAssertFalse(workspace.numberShortcut(9))
        XCTAssertEqual(workspace, only)
    }

    func testZoomFollowsFirstAndNextPaneWithoutUnzooming() {
        var workspace = workspace()
        workspace.tabs[0].zoomed = true
        let root = workspace.tabs[0].root
        for pane in ["A", "B", "C", "A"] {
            workspace.numberShortcut(1)
            XCTAssertEqual(workspace.selectedTab?.focused, pane)
            XCTAssertEqual(workspace.selectedTab?.visibleRoot, .pane(pane))
            XCTAssertTrue(workspace.tabs[0].zoomed)
            XCTAssertEqual(workspace.tabs[0].root, root)
        }
    }

    func testNineSelectsAndCyclesLastTabEvenWithMoreThanNineTabs() {
        var workspace = Workspace(tabs: (1...11).map { number in
            let pane = "pane\(number)"
            return TabState(id: "t\(number)", root: .pane(pane).splitting(pane, with: "extra\(number)", axis: .horizontal),
                            focused: "extra\(number)")
        }, selected: "t1")
        workspace.numberShortcut(9)
        XCTAssertEqual(workspace.selected, "t11")
        XCTAssertEqual(workspace.selectedTab?.focused, "pane11")
        workspace.numberShortcut(9)
        XCTAssertEqual(workspace.selectedTab?.focused, "extra11")
        workspace.numberShortcut(9)
        XCTAssertEqual(workspace.selectedTab?.focused, "pane11")
        workspace.numberShortcut(8)
        XCTAssertEqual(workspace.selected, "t8")
        XCTAssertEqual(workspace.selectedTab?.focused, "pane8")
    }

    func testNestedHorizontalAndVerticalSplitsUseLeafOrder() {
        for (outer, inner) in [(SplitAxis.horizontal, SplitAxis.vertical), (.vertical, .horizontal)] {
            let root = SplitNode.pane("A")
                .splitting("A", with: "B", axis: outer)
                .splitting("A", with: "C", axis: inner)
                .splitting("B", with: "D", axis: inner)
            XCTAssertEqual(root.panes, ["A", "C", "B", "D"])
            var workspace = Workspace(tabs: [TabState(id: "t1", root: root, focused: "D")])
            for pane in ["A", "C", "B", "D", "A"] {
                workspace.numberShortcut(1)
                XCTAssertEqual(workspace.selectedTab?.focused, pane)
            }
        }
    }

    func testEditorAndTerminalPanesShareCycle() {
        let first = EditorPane.newId(), last = EditorPane.newId()
        let root = SplitNode.pane(first)
            .splitting(first, with: "terminal", axis: .horizontal)
            .splitting("terminal", with: last, axis: .vertical)
        var workspace = Workspace(tabs: [
            TabState(id: "editors", root: root, focused: last, zoomed: true),
            TabState(id: "other", root: .pane("other"), focused: "other"),
        ], selected: "other")
        workspace.editors = [first: EditorRecipe(path: "/tmp/first.swift"), last: EditorRecipe(path: "/tmp/last.swift")]
        for pane in [first, "terminal", last, first] {
            workspace.numberShortcut(1)
            XCTAssertEqual(workspace.selectedTab?.focused, pane)
            XCTAssertEqual(workspace.selectedTab?.visibleRoot, .pane(pane))
            XCTAssertTrue(workspace.tabs[0].zoomed)
        }
    }

    func testMissingFocusFallsBackToFirstPane() {
        var workspace = workspace()
        workspace.selected = "t1"
        workspace.tabs[0].focused = "missing"
        workspace.numberShortcut(1)
        XCTAssertEqual(workspace.selectedTab?.focused, "A")
    }

    func testInvalidOrUnavailableNumberDoesNothing() {
        var workspace = workspace()
        let before = workspace
        for number in [-1, 0, 3, 8, 10] {
            XCTAssertFalse(workspace.numberShortcut(number))
            XCTAssertEqual(workspace, before)
        }
        workspace = Workspace()
        XCTAssertFalse(workspace.numberShortcut(1))
        XCTAssertFalse(workspace.numberShortcut(9))
        XCTAssertEqual(workspace, Workspace())
    }
}
