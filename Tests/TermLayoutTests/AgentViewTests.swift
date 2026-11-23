import Foundation
import TermLayout
import XCTest

/// 예전(0.11) 하위 에이전트 보기 분할 잎("agentview:")은 이제 만들지 않는다 — 예전 layout.json 을 읽을 때 뺀다.
final class AgentViewTests: XCTestCase {
    /// 예전 배치 파일: t1 = A | agentview:1, t2 = agentview:2 만, t3 = B, "agentViews" 키 포함
    func legacyJSON(selected: String = "t1") throws -> Data {
        let ws = Workspace(tabs: [
            TabState(id: "t1", root: .split(axis: .horizontal, ratio: 0.5, first: .pane("A"), second: .pane("agentview:1")), focused: "agentview:1"),
            TabState(id: "t2", root: .pane("agentview:2"), focused: "agentview:2"),
            TabState(id: "t3", root: .pane("B"), focused: "B"),
        ], selected: selected)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ws)) as? [String: Any])
        let recipe: [String: Any] = ["transcript": "/p/subagents/agent-1.jsonl", "owner": "A", "description": "조사", "agentType": "Explore"]
        object["agentViews"] = ["agentview:1": recipe, "agentview:2": recipe]
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testLegacyLeavesAreDroppedOnLoadAndEmptyTabsCollapse() throws {
        let ws = try JSONDecoder().decode(Workspace.self, from: legacyJSON())
        XCTAssertEqual(ws.tabs.map(\.id), ["t1", "t3"]) // 잎만 있던 t2 는 사라진다
        XCTAssertEqual(ws.tabs[0].root, .pane("A")) // 나눈 탭은 옆 화면이 채운다
        XCTAssertEqual(ws.tabs[0].focused, "A")
        XCTAssertFalse(ws.allPanes.contains { LegacyAgentViewPane.isLegacy($0) })
        XCTAssertEqual(ws.selected, "t1")
    }

    func testSelectedLegacyOnlyTabFallsBackToNeighbour() throws {
        let ws = try JSONDecoder().decode(Workspace.self, from: legacyJSON(selected: "t2"))
        XCTAssertEqual(ws.tabs.map(\.id), ["t1", "t3"])
        XCTAssertNotNil(ws.selectedTab)
        XCTAssertEqual(ws.allPanes, ["A", "B"])
    }

    func testReencodedLayoutNoLongerHasAgentViewsKey() throws {
        let ws = try JSONDecoder().decode(Workspace.self, from: legacyJSON())
        let text = String(decoding: try JSONEncoder().encode(ws), as: UTF8.self)
        XCTAssertFalse(text.contains("agentview"))
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws)), ws)
    }

    func testOldLayoutWithoutAnyAgentViewsStillLoads() throws {
        let old = #"{"tabs":[{"id":"t","root":{"pane":{"_0":"A"}},"focused":"A","zoomed":false}],"selected":"t"}"#
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(old.utf8))
        XCTAssertEqual(ws.allPanes, ["A"])
    }

    /// 읽기를 거치지 않은 예전 ids 도 데몬 화면으로 보지 않는다(꺼진 화면으로 두거나 지우거나 되살리지 않는다)
    func testReconcileNeverTreatsLegacyIdsAsDaemonPanes() {
        XCTAssertTrue(LocalPane.isLocal("agentview:1"))
        var ws = Workspace(tabs: [TabState(id: "t1", root: .split(axis: .horizontal, ratio: 0.5, first: .pane("A"), second: .pane("agentview:1")), focused: "A")],
                           selected: "t1")
        ws.reconcile(live: ["A"], daemonPid: 1)
        ws.reconcile(live: ["A"], daemonPid: 2)
        XCTAssertFalse(ws.dormant.contains("agentview:1"))
        XCTAssertTrue(ws.recipes["agentview:1"] == nil)
        // 로드 뒤 reconcile 은 아무것도 되살리지 않는다
        var loaded = (try? JSONDecoder().decode(Workspace.self, from: legacyJSON())) ?? Workspace()
        loaded.reconcile(live: ["A", "B"], daemonPid: 1)
        XCTAssertEqual(loaded.allPanes, ["A", "B"])
        XCTAssertTrue(loaded.dormant.isEmpty)
    }
}
