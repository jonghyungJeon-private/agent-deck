import Foundation
import TermLayout
import XCTest

final class AgentViewTests: XCTestCase {
    let recipe = AgentViewRecipe(transcript: "/p/subagents/agent-1.jsonl", owner: "A", description: "조사", agentType: "Explore")

    func base() -> Workspace {
        Workspace(tabs: [TabState(id: "t1", root: .pane("A"), focused: "A"),
                         TabState(id: "t2", root: .pane("B"), focused: "B")], selected: "t2")
    }

    func testIdPrefix() {
        let id = AgentViewPane.newId()
        XCTAssertTrue(AgentViewPane.isAgentView(id))
        XCTAssertTrue(LocalPane.isLocal(id))
        XCTAssertFalse(AgentViewPane.isAgentView("editor:1"))
    }

    func testOpensToTheRightOfOwnerInOwnersTab() {
        var ws = base()
        let id = ws.openAgentView(recipe, newId: { "agentview:1" })
        XCTAssertEqual(id, "agentview:1")
        XCTAssertEqual(ws.selected, "t1")
        XCTAssertEqual(ws.tabs[0].root, .split(axis: .horizontal, ratio: 0.5, first: .pane("A"), second: .pane("agentview:1")))
        XCTAssertEqual(ws.tabs[0].focused, "agentview:1")
        XCTAssertEqual(ws.agentViewPane(transcript: recipe.transcript), "agentview:1")
    }

    func testFocusesExistingViewAnywhere() {
        var ws = base()
        ws.openAgentView(recipe, newId: { "agentview:1" })
        ws.selected = "t2"
        ws.tabs[0].focused = "A"
        let again = ws.openAgentView(recipe, newId: { "agentview:2" })
        XCTAssertEqual(again, "agentview:1")
        XCTAssertEqual(ws.selected, "t1")
        XCTAssertEqual(ws.tabs[0].focused, "agentview:1")
        XCTAssertEqual(ws.agentViews.count, 1)
    }

    func testOwnerNotInAnyTabOpensNewTabAfterCurrent() {
        var ws = base()
        ws.selected = "t1"
        var lost = recipe
        lost.owner = "gone"
        ws.openAgentView(lost, newId: { "agentview:1" })
        XCTAssertEqual(ws.tabs.map { $0.root.panes }, [["A"], ["agentview:1"], ["B"]])
        XCTAssertEqual(ws.selectedTab?.focused, "agentview:1")
    }

    func testForgetRemovesRecipe() {
        var ws = base()
        let id = ws.openAgentView(recipe)
        ws.forget(pane: id)
        XCTAssertNil(ws.agentViews[id])
        XCTAssertNil(ws.agentViewPane(transcript: recipe.transcript))
        XCTAssertEqual(ws.tabs[0].root, .pane("A"))
    }

    func testRoundTripAndOldLayout() throws {
        var ws = base()
        let id = ws.openAgentView(recipe)
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        XCTAssertEqual(decoded, ws)
        XCTAssertEqual(decoded.agentViews[id], recipe)
        let old = #"{"tabs":[{"id":"t","root":{"pane":{"_0":"A"}},"focused":"A","zoomed":false}],"selected":"t"}"#
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(old.utf8)).agentViews, [:])
        // 정보 없는 잎은 읽을 때 뺀다
        ws.agentViews[id] = nil
        let repaired = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        XCTAssertFalse(repaired.allPanes.contains(id))
    }

    func testReconcileKeepsAgentViewsAndDoesNotReviveThem() {
        var ws = base()
        let id = ws.openAgentView(recipe)
        ws.reconcile(live: ["A", "B"], daemonPid: 1)
        ws.reconcile(live: ["A", "B"], daemonPid: 2)
        XCTAssertTrue(ws.allPanes.contains(id))
        XCTAssertNotNil(ws.agentViews[id])
        XCTAssertFalse(ws.dormant.contains(id))
    }
}
