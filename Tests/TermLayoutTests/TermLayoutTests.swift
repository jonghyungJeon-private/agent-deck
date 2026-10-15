import Foundation
import TermLayout
import XCTest

final class SplitTreeTests: XCTestCase {
    // A | B 위아래로 C
    //   +---+---+
    //   | A | B |
    //   |   +---+
    //   |   | C |
    //   +---+---+
    let tree = SplitNode.pane("A")
        .splitting("A", with: "B", axis: .horizontal)
        .splitting("B", with: "C", axis: .vertical)

    func testSplitAndRemove() {
        XCTAssertEqual(tree.panes, ["A", "B", "C"])
        XCTAssertEqual(tree.removing("B")?.panes, ["A", "C"])
        XCTAssertEqual(tree.removing("A"), .split(axis: .vertical, ratio: 0.5, first: .pane("B"), second: .pane("C")))
        XCTAssertNil(SplitNode.pane("A").removing("A"))
    }

    func testLayoutLeavesRoomForDividers() {
        let (panes, dividers) = tree.layout(in: CGRect(x: 0, y: 0, width: 201, height: 101), divider: 1)
        XCTAssertEqual(panes["A"], CGRect(x: 0, y: 0, width: 100, height: 101))
        XCTAssertEqual(panes["B"], CGRect(x: 101, y: 0, width: 100, height: 50))
        XCTAssertEqual(panes["C"], CGRect(x: 101, y: 51, width: 100, height: 50))
        XCTAssertEqual(dividers.map(\.path), [[], [true]])
    }

    func testNeighbors() {
        XCTAssertEqual(tree.neighbor(of: "A", toward: .right), "B") // 둘 다 맞닿으면 위쪽(먼저 나온 것)
        XCTAssertEqual(tree.neighbor(of: "C", toward: .left), "A")
        XCTAssertEqual(tree.neighbor(of: "B", toward: .down), "C")
        XCTAssertEqual(tree.neighbor(of: "C", toward: .up), "B")
        XCTAssertNil(tree.neighbor(of: "A", toward: .left))
        XCTAssertNil(tree.neighbor(of: "C", toward: .down))
    }

    func testResizeMovesNearestMatchingDivider() {
        let wider = tree.resizing("C", toward: .left, by: 0.1)
        guard case .split(_, let ratio, _, _) = wider else { return XCTFail() }
        XCTAssertEqual(ratio, 0.4, accuracy: 0.0001)
        let taller = tree.resizing("B", toward: .down, by: 0.2)
        guard case .split(_, let outer, _, .split(_, let inner, _, _)) = taller else { return XCTFail() }
        XCTAssertEqual(outer, 0.5)
        XCTAssertEqual(inner, 0.7, accuracy: 0.0001)
    }

    func testEqualizeWeighsSameAxisPanes() {
        let three = SplitNode.pane("A").splitting("A", with: "B", axis: .horizontal).splitting("B", with: "C", axis: .horizontal)
        guard case .split(_, let ratio, _, .split(_, let inner, _, _)) = three.equalized() else { return XCTFail() }
        XCTAssertEqual(ratio, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(inner, 0.5)
    }

    func testSettingRatioClamps() {
        guard case .split(_, _, _, .split(_, let inner, _, _)) = tree.settingRatio(at: [true], to: 0.99) else { return XCTFail() }
        XCTAssertEqual(inner, 0.9, accuracy: 0.0001)
    }

    func testWorkspaceReconcile() throws {
        var workspace = Workspace(tabs: [TabState(id: "t1", root: tree, focused: "B"),
                                         TabState(id: "t2", root: .pane("D"), focused: "D")], selected: "t2")
        // B 가 사라지고, E 는 새로 나타났고, F 는 만드는 중(아직 목록에 없음)
        workspace.tabs[1].root = .pane("D").splitting("D", with: "F", axis: .vertical)
        XCTAssertTrue(workspace.reconcile(live: ["A", "C", "D", "E"], keep: ["F"]))
        XCTAssertEqual(workspace.tabs.map { $0.root.panes }, [["A", "C"], ["D", "F"], ["E"]])
        XCTAssertEqual(workspace.tabs[0].focused, "A") // 사라진 B 대신 앞 화면
        // D 탭이 통째로 사라지면 그 자리 탭이 선택된다
        workspace.reconcile(live: ["A", "C", "E"])
        XCTAssertEqual(workspace.tabs.map(\.id).count, 2)
        XCTAssertEqual(workspace.selectedTab?.root.panes, ["E"])
        // 저장했다 읽어도 같다
        let data = try JSONEncoder().encode(workspace)
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: data), workspace)
    }

    func testDaemonRestartKeepsPanesAsDormant() throws {
        var workspace = Workspace(tabs: [TabState(id: "t1", root: tree, focused: "B")])
        workspace.recipes = ["A": PaneRecipe(cwd: "/a", sessionId: "s-a"), "B": PaneRecipe(cwd: "/b")]
        workspace.reconcile(live: ["A", "B", "C"], daemonPid: 100)
        // 같은 데몬에서 C 가 끝나면 뺀다
        workspace.reconcile(live: ["A", "B"], daemonPid: 100)
        XCTAssertEqual(workspace.allPanes, ["A", "B"])
        XCTAssertTrue(workspace.dormant.isEmpty)
        // 데몬이 바뀌면(강제 종료 뒤 새로 뜸) 되살리기 정보가 있는 화면은 꺼진 화면으로 남는다
        workspace.reconcile(live: [], daemonPid: 200)
        XCTAssertEqual(workspace.allPanes, ["A", "B"])
        XCTAssertEqual(workspace.dormant, ["A", "B"])
        // 되살아나면 꺼진 표시가 빠진다
        workspace.reconcile(live: ["A"], keep: [], daemonPid: 200)
        XCTAssertEqual(workspace.dormant, ["B"])
        // 저장했다 읽어도 같고, 예전 형식(되살리기 정보 없음)도 읽힌다
        let data = try JSONEncoder().encode(workspace)
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: data), workspace)
        let old = try JSONDecoder().decode(Workspace.self, from: Data(#"{"tabs":[],"selected":null}"#.utf8))
        XCTAssertTrue(old.recipes.isEmpty)
    }

    func testResumeCommandKeepsOtherFlags() {
        let argv = ["claude", "--dangerously-skip-permissions", "-n", "demo-1350", "--session-id", "old", "--model", "opus"]
        XCTAssertEqual(PaneRecipe.keptArgs(argv), ["--dangerously-skip-permissions", "--model", "opus"])
        XCTAssertEqual(PaneRecipe.keptArgs(["claude", "--resume=abc", "-c", "x y"]), ["x y"])
        let recipe = PaneRecipe(cwd: "/x", sessionId: "71713d11", claudeArgs: ["--dangerously-skip-permissions", "it's"])
        XCTAssertEqual(recipe.resumeCommand, "claude --resume 71713d11 --dangerously-skip-permissions 'it'\\''s'")
        XCTAssertNil(PaneRecipe(cwd: "/x").resumeCommand)
    }

    func testZoomShowsOnlyFocused() {
        var tab = TabState(root: tree, focused: "C", zoomed: true)
        XCTAssertEqual(tab.visibleRoot, .pane("C"))
        tab.zoomed = false
        XCTAssertEqual(tab.visibleRoot, tree)
    }
}

final class GitWorktreesTests: XCTestCase {
    func testReadsWorktreesWithoutGit() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gwt-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }
        let repo = root + "/repo", common = repo + "/.git"
        let wt = repo + "/.claude/worktrees/fix-bug"
        try fm.createDirectory(atPath: common + "/worktrees/fix-bug", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: wt + "/src", withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(toFile: common + "/HEAD", atomically: true, encoding: .utf8)
        try "gitdir: \(common)/worktrees/fix-bug\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        try "../..\n".write(toFile: common + "/worktrees/fix-bug/commondir", atomically: true, encoding: .utf8)
        try "\(wt)/.git\n".write(toFile: common + "/worktrees/fix-bug/gitdir", atomically: true, encoding: .utf8)
        try "ref: refs/heads/worktree-fix-bug\n".write(toFile: common + "/worktrees/fix-bug/HEAD", atomically: true, encoding: .utf8)
        // 사라진 작업 트리는 목록에서 빠진다
        try fm.createDirectory(atPath: common + "/worktrees/gone", withIntermediateDirectories: true)
        try "\(root)/nowhere/.git\n".write(toFile: common + "/worktrees/gone/gitdir", atomically: true, encoding: .utf8)

        let std = { (p: String) in (p as NSString).standardizingPath }
        let inside = try XCTUnwrap(GitWorktrees.locate(wt + "/src"))
        XCTAssertEqual(inside.repoRoot, std(repo))
        XCTAssertEqual(inside.worktreeRoot, std(wt))
        XCTAssertEqual(GitWorktrees.locate(repo)?.worktreeRoot, std(repo))

        let list = GitWorktrees.list(inside)
        XCTAssertEqual(list.map(\.path), [std(repo), std(wt)])
        XCTAssertEqual(list.map(\.branch), ["main", "worktree-fix-bug"])
        XCTAssertEqual(list.map(\.isClaude), [false, true])
        XCTAssertNil(GitWorktrees.locate(root))
    }
}
