import Foundation
import TermLayout
import XCTest

/// 하위 에이전트 칸("agentpane:"): 배치 규칙, 부모 칸과 함께 닫힘, layout.json 왕복
final class AgentPaneTests: XCTestCase {
    func recipe(_ n: Int, owner: String = "A", type: String? = nil) -> AgentPaneRecipe {
        AgentPaneRecipe(transcriptPath: "/p/subagents/agent-\(n).jsonl", description: "조사 \(n)", agentType: type, ownerPaneID: owner)
    }

    /// t1 = A | B, t2 = C
    func base() -> Workspace {
        Workspace(tabs: [
            TabState(id: "t1", root: .split(axis: .horizontal, ratio: 0.5, first: .pane("A"), second: .pane("B")), focused: "B"),
            TabState(id: "t2", root: .pane("C"), focused: "C"),
        ], selected: "t2")
    }

    func ids() -> () -> String {
        var n = 0
        return { n += 1; return "agentpane:\(n)" }
    }

    // MARK: 레시피·파일

    func testRecipeCodableRoundTrip() throws {
        let r = recipe(1, owner: "A", type: "Explore")
        let back = try JSONDecoder().decode(AgentPaneRecipe.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        var ws = base()
        let next = ids()
        ws.openAgentPane(r, newId: next)
        ws.openAgentPane(recipe(2), newId: next)
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        XCTAssertEqual(decoded, ws)
        XCTAssertEqual(decoded.agentPanes.count, 2)
        XCTAssertEqual(decoded.agentPanes["agentpane:1"], r)
    }

    func testOldLayoutWithoutAgentPanesKeyDecodes() throws {
        let old = #"{"tabs":[{"id":"t","root":{"pane":{"_0":"A"}},"focused":"A","zoomed":false}],"selected":"t"}"#
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(old.utf8))
        XCTAssertEqual(ws.allPanes, ["A"])
        XCTAssertTrue(ws.agentPanes.isEmpty)
    }

    func testLoadDropsAgentPanesWithoutRecipeOrOwner() throws {
        var ws = Workspace(tabs: [TabState(id: "t1", root: .split(axis: .horizontal, ratio: 0.5, first: .pane("A"),
                                                                  second: .pane("agentpane:x")), focused: "A")], selected: "t1")
        ws.agentPanes["agentpane:x"] = recipe(1, owner: "GONE") // 부모 칸이 배치에 없다
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws)).allPanes, ["A"])
        ws.agentPanes["agentpane:x"] = nil // 레시피가 없다
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws)).allPanes, ["A"])
    }

    // MARK: 배치

    func testFirstPaneSplitsParentToTheRightAndFocuses() {
        var ws = base()
        let id = ws.openAgentPane(recipe(1), newId: ids())
        XCTAssertEqual(id, "agentpane:1")
        XCTAssertEqual(ws.selected, "t1") // 부모 칸이 있는 탭으로
        XCTAssertEqual(ws.tabs[0].focused, id)
        XCTAssertEqual(ws.tabs[0].root.panes, ["A", id, "B"])
        guard case .split(_, _, let first, _) = ws.tabs[0].root, case .split(let axis, _, let a, let b) = first else { return XCTFail() }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(a, .pane("A"))
        XCTAssertEqual(b, .pane(id))
        XCTAssertEqual(ws.tabs[1].root, .pane("C")) // 다른 탭은 그대로
    }

    func testSecondAndLaterPanesStackBelowTheLastOne() {
        var ws = base()
        let next = ids()
        let first = ws.openAgentPane(recipe(1), newId: next)
        let second = ws.openAgentPane(recipe(2), newId: next)
        let third = ws.openAgentPane(recipe(3), newId: next)
        XCTAssertEqual(ws.agentPanes(in: ws.tabs[0], owner: "A"), [first, second, third])
        // A | (first / (second / third)) : 오른쪽 한 줄에 위아래로
        guard case .split(_, _, let left, _) = ws.tabs[0].root, case .split(_, _, let a, let column) = left else { return XCTFail() }
        XCTAssertEqual(a, .pane("A"))
        guard case .split(let axis1, let r1, let top, let rest) = column, case .split(let axis2, let r2, let mid, let bottom) = rest else { return XCTFail() }
        XCTAssertEqual(axis1, .vertical)
        XCTAssertEqual(axis2, .vertical)
        // 같은 높이로(1/3씩): 위 칸 1/3, 나머지 둘은 반씩
        XCTAssertEqual(r1, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(r2, 0.5, accuracy: 1e-9)
        // 부모 칸과 하위 칸 줄 사이 비율은 건드리지 않는다
        guard case .split(_, let outer, _, _) = left else { return XCTFail() }
        XCTAssertEqual(outer, 0.5, accuracy: 1e-9)
        XCTAssertEqual([top, mid, bottom], [.pane(first), .pane(second), .pane(third)])
        XCTAssertEqual(ws.tabs[0].focused, third)
    }

    func testSameTranscriptReopenCreatesNoNewPaneAndFocusesIt() {
        var ws = base()
        let next = ids()
        let first = ws.openAgentPane(recipe(1), newId: next)
        ws.openAgentPane(recipe(2), newId: next)
        ws.selected = "t2"
        let again = ws.openAgentPane(recipe(1), newId: next)
        XCTAssertEqual(again, first)
        XCTAssertEqual(ws.agentPanes.count, 2)
        XCTAssertEqual(ws.allPanes.count, 5)
        XCTAssertEqual(ws.selected, "t1")
        XCTAssertEqual(ws.tabs[0].focused, first)
    }

    func testDifferentParentsGetTheirOwnFirstSplit() {
        var ws = base()
        let next = ids()
        let a1 = ws.openAgentPane(recipe(1, owner: "A"), newId: next)
        let b1 = ws.openAgentPane(recipe(2, owner: "B"), newId: next) // 같은 탭이어도 부모가 다르면 그 부모의 오른쪽
        XCTAssertEqual(ws.tabs[0].root.panes, ["A", a1, "B", b1])
        let c1 = ws.openAgentPane(recipe(3, owner: "C"), newId: next) // 다른 탭의 부모
        XCTAssertEqual(ws.selected, "t2")
        XCTAssertEqual(ws.tabs[1].root.panes, ["C", c1])
    }

    func testParentNotOnScreenAttachesToCurrentTabFocusKeepingOwner() {
        var ws = base()
        ws.selected = "t2"
        let id = ws.openAgentPane(recipe(1, owner: "GONE"), newId: ids())
        XCTAssertEqual(ws.tabs[1].root.panes, ["C", id]) // 지금 탭의 포커스 칸 오른쪽
        XCTAssertEqual(ws.agentPanes[id]?.ownerPaneID, "GONE") // 기록은 부모 세션 칸 그대로
        XCTAssertEqual(ws.selected, "t2")
        // 탭이 하나도 없으면 새 탭
        var empty = Workspace()
        let only = empty.openAgentPane(recipe(2, owner: "GONE"), newId: ids())
        XCTAssertEqual(empty.tabs.count, 1)
        XCTAssertEqual(empty.tabs[0].root, .pane(only))
    }

    // MARK: 닫기

    func testClosingParentClosesItsAgentPanesAndRecipes() {
        var ws = base()
        let next = ids()
        ws.openAgentPane(recipe(1, owner: "A"), newId: next)
        ws.openAgentPane(recipe(2, owner: "A"), newId: next)
        let other = ws.openAgentPane(recipe(3, owner: "B"), newId: next)
        ws.forget(pane: "A")
        XCTAssertEqual(ws.tabs[0].root.panes, ["B", other])
        XCTAssertEqual(Array(ws.agentPanes.keys), [other]) // 다른 부모의 칸과 레시피는 남는다
        ws.forget(pane: "B")
        XCTAssertTrue(ws.agentPanes.isEmpty)
        XCTAssertEqual(ws.allPanes, ["C"]) // 칸만 남은 탭은 사라진다
    }

    func testClosingAnAgentPaneForgetsOnlyItsRecipe() {
        var ws = base()
        let next = ids()
        let first = ws.openAgentPane(recipe(1), newId: next)
        let second = ws.openAgentPane(recipe(2), newId: next)
        ws.forget(pane: first)
        XCTAssertEqual(Array(ws.agentPanes.keys), [second])
        XCTAssertTrue(ws.allPanes.contains("A"))
    }

    func testReconcileClosesAgentPanesWhenSessionEnds() {
        var ws = base()
        let id = ws.openAgentPane(recipe(1, owner: "A"), newId: ids())
        // 데몬이 A 를 더는 안 줌(세션 종료) → 칸도 함께
        XCTAssertTrue(ws.reconcile(live: ["B", "C"], daemonPid: 1))
        XCTAssertFalse(ws.allPanes.contains(id))
        XCTAssertTrue(ws.agentPanes.isEmpty)
    }

    func testReconcileKeepsAgentPanesAndNeverTreatsThemAsDaemonPanes() {
        XCTAssertTrue(LocalPane.isLocal("agentpane:1"))
        var ws = base()
        let id = ws.openAgentPane(recipe(1, owner: "A"), newId: ids())
        ws.reconcile(live: ["A", "B", "C"], daemonPid: 1)
        ws.reconcile(live: ["A", "B", "C"], daemonPid: 2) // 데몬이 바뀌어도
        XCTAssertTrue(ws.allPanes.contains(id))
        XCTAssertFalse(ws.dormant.contains(id))
        XCTAssertNotNil(ws.agentPanes[id])
        // 부모가 꺼진 화면(dormant)으로 남으면 칸도 남는다
        ws.recipes["A"] = PaneRecipe(cwd: "/x")
        ws.reconcile(live: ["B", "C"], daemonPid: 3)
        XCTAssertTrue(ws.dormant.contains("A"))
        XCTAssertNotNil(ws.agentPanes[id])
    }

    // MARK: 세션처럼 보이지 않게

    func testSessionPaneMapsToParentAndNumberShortcutSkipsAgentPanes() {
        var ws = base()
        let next = ids()
        let a1 = ws.openAgentPane(recipe(1, owner: "A"), newId: next)
        XCTAssertEqual(ws.sessionPane(of: a1), "A")
        XCTAssertEqual(ws.sessionPane(of: "B"), "B")
        // t1 = A | a1 | B. 다른 탭에서 ⌘1: 첫 화면(A), 같은 탭에서 다시: 다음 세션(B) — 하위 칸은 건너뛴다
        ws.selected = "t2"
        XCTAssertTrue(ws.numberShortcut(1))
        XCTAssertEqual(ws.tabs[0].focused, "A")
        XCTAssertTrue(ws.numberShortcut(1))
        XCTAssertEqual(ws.tabs[0].focused, "B")
        // 하위 칸에 포커스가 있으면 그 부모의 다음 세션으로
        ws.tabs[0].focused = a1
        XCTAssertTrue(ws.numberShortcut(1))
        XCTAssertEqual(ws.tabs[0].focused, "B")
    }

    func testAgentPaneChoicePrefersRunningThenMostRecent() {
        let now = Date()
        XCTAssertNil(AgentPaneChoice.pick([]))
        XCTAssertEqual(AgentPaneChoice.pick([(false, now), (false, now.addingTimeInterval(60)), (false, now.addingTimeInterval(-60))]), 1)
        XCTAssertEqual(AgentPaneChoice.pick([(false, now.addingTimeInterval(600)), (true, now), (true, now.addingTimeInterval(-10))]), 1)
        XCTAssertEqual(AgentPaneChoice.pick([(true, now), (true, now)]), 0)
    }

    func testToggleOpensAllRunningAgentsUpToTheCapElseTheMostRecentOne() {
        let t = Date(timeIntervalSince1970: 1000)
        // 작업 중 둘 → 둘 다(최근 순)
        XCTAssertEqual(AgentPaneChoice.pickAll([(running: true, lastActive: t), (running: false, lastActive: t + 50), (running: true, lastActive: t + 10)]), [2, 0])
        // 작업 중이 없으면 가장 최근 것 하나
        XCTAssertEqual(AgentPaneChoice.pickAll([(running: false, lastActive: t), (running: false, lastActive: t + 5)]), [1])
        XCTAssertEqual(AgentPaneChoice.pickAll([]), [])
        // 상한
        let many = (0..<7).map { (running: true, lastActive: t + Double($0)) }
        XCTAssertEqual(AgentPaneChoice.pickAll(many), [6, 5, 4, 3])
        // 둘을 연이어 열면 같은 줄에 같은 높이로
        var ws = Workspace(tabs: [TabState(id: "t", root: .pane("A"), focused: "A")], selected: "t")
        var n = 0
        let next: () -> String = { n += 1; return "agentpane:\(n)" }
        for i in [1, 2] {
            ws.openAgentPane(AgentPaneRecipe(transcriptPath: "/p/agent-\(i).jsonl", description: "\(i)", ownerPaneID: "A"), newId: next)
        }
        XCTAssertEqual(ws.tabs[0].root.panes, ["A", "agentpane:1", "agentpane:2"])
    }
}
