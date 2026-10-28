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
        XCTAssertEqual(PaneRecipe.keptArgs(["claude", "--resume=abc", "-c", "x y"]), [])
        // 값 없는 --resume 뒤의 옵션을 먹지 않는다
        XCTAssertEqual(PaneRecipe.keptArgs(["claude", "--resume", "--model", "opus"]), ["--model", "opus"])
        // 처음 질문·--worktree 는 버린다(되살릴 때 질문이 다시 전송되거나 작업 트리가 새로 생기지 않게)
        XCTAssertEqual(PaneRecipe.keptArgs(["claude", "로그인 버그 고쳐줘", "--dangerously-skip-permissions", "-w", "feat"]),
                       ["--dangerously-skip-permissions"])
        XCTAssertEqual(PaneRecipe.keptArgs(["claude", "--add-dir", "a", "b", "--effort", "high", "질문"]),
                       ["--add-dir", "a", "b", "--effort", "high"])
        XCTAssertEqual(PaneRecipe.keptArgs(["claude", "--model=opus", "--name=x", "--model"]), ["--model=opus"])
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

final class CodexRecipeTests: XCTestCase {
    func testOldLayoutStillDecodes() throws {
        let recipe = try JSONDecoder().decode(PaneRecipe.self, from: Data(#"{"cwd":"/old","sessionId":"claude-id","claudeArgs":["--model","opus"]}"#.utf8))
        XCTAssertEqual(recipe.resumeCommand, "claude --resume claude-id --model opus")
        XCTAssertNil(recipe.codexSessionId)
    }
    func testCodexResumesExactSessionWithOriginalOptionsAndHome() throws {
        let recipe = PaneRecipe(cwd: "/work", codexSessionId: "codex-id", codexArgs: ["--model", "model x"], codexHome: "/custom home")
        XCTAssertEqual(recipe.resumeCommand, "CODEX_HOME='/custom home' codex resume codex-id --model 'model x'")
        XCTAssertEqual(try JSONDecoder().decode(PaneRecipe.self, from: JSONEncoder().encode(recipe)), recipe)
    }
}

final class EditorPaneWorkspaceTests: XCTestCase {
    private func workspaceWithEditor() -> (Workspace, String) {
        let editor = EditorPane.newId()
        var workspace = Workspace(tabs: [
            TabState(id: "t1", root: SplitNode.pane("A").splitting("A", with: editor, axis: .horizontal), focused: editor),
            TabState(id: "t2", root: .pane("B"), focused: "B"),
        ], selected: "t1")
        workspace.editors[editor] = EditorRecipe(path: "/tmp/x.swift", cursor: 12)
        return (workspace, editor)
    }

    func testReconcileNeverDropsOrRevivesEditors() {
        var (workspace, editor) = workspaceWithEditor()
        // 데몬 목록에 편집기는 없다 — 같은 데몬이어도, 데몬이 바뀌어도 그대로
        workspace.reconcile(live: ["A", "B"], daemonPid: 1)
        XCTAssertTrue(workspace.allPanes.contains(editor))
        workspace.reconcile(live: ["B"], daemonPid: 1)
        XCTAssertEqual(workspace.allPanes, [editor, "B"])
        workspace.reconcile(live: [], daemonPid: 2) // 데몬 재시작
        XCTAssertTrue(workspace.allPanes.contains(editor))
        XCTAssertFalse(workspace.dormant.contains(editor))
        XCTAssertNil(workspace.recipes[editor])
        XCTAssertEqual(workspace.editors[editor]?.path, "/tmp/x.swift")
        // 데몬이 편집기 ID 를 알려 와도(그럴 일은 없지만) 새 탭으로 붙지 않는다
        let tabs = workspace.tabs.count
        workspace.reconcile(live: ["editor:ghost"], daemonPid: 2)
        XCTAssertEqual(workspace.tabs.count, tabs)
    }

    func testForgetRemovesEditorRecipe() {
        var (workspace, editor) = workspaceWithEditor()
        XCTAssertEqual(workspace.editorPane(path: "/tmp/x.swift"), editor)
        workspace.forget(pane: editor)
        XCTAssertNil(workspace.editors[editor])
        XCTAssertNil(workspace.editorPane(path: "/tmp/x.swift"))
        XCTAssertEqual(workspace.tabs[0].root, .pane("A"))
    }

    func testPersistenceRoundTrip() throws {
        let (workspace, editor) = workspaceWithEditor()
        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded, workspace)
        XCTAssertEqual(decoded.editors[editor], EditorRecipe(path: "/tmp/x.swift", cursor: 12))
        XCTAssertEqual(decoded.editorPanes, [editor])
    }

    func testOldLayoutWithoutEditorsAndBrokenEditorLeaves() throws {
        // 예전 파일(editors 없음)
        let old = #"{"tabs":[{"id":"t","root":{"pane":{"_0":"A"}},"focused":"A","zoomed":false}],"selected":"t"}"#
        let decoded = try JSONDecoder().decode(Workspace.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.editors, [:])
        XCTAssertEqual(decoded.allPanes, ["A"])
        // 파일 정보가 빠진 편집기 잎은 읽을 때 뺀다
        var (workspace, editor) = workspaceWithEditor()
        workspace.editors[editor] = nil
        let repaired = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertFalse(repaired.allPanes.contains(editor))
        XCTAssertEqual(repaired.tabs[0].focused, "A")
    }
}

final class TabMoveTests: XCTestCase {
    let editor = EditorPane.prefix + "E1"

    /// t1 = A | B(위) C(아래), t2 = D, t3 = 편집기 하나
    func workspace() -> Workspace {
        let tree = SplitNode.pane("A").splitting("A", with: "B", axis: .horizontal).splitting("B", with: "C", axis: .vertical)
        var workspace = Workspace(tabs: [TabState(id: "t1", root: tree, focused: "A"),
                                         TabState(id: "t2", root: .pane("D"), focused: "D"),
                                         TabState(id: "t3", root: .pane(editor), focused: editor)], selected: "t1")
        workspace.editors[editor] = EditorRecipe(path: "/tmp/a.swift")
        return workspace
    }

    func testInsertingPutsNodeOnThatSide() {
        let x = SplitNode.pane("X")
        XCTAssertEqual(SplitNode.pane("A").inserting(x, at: "A", toward: .left),
                       .split(axis: .horizontal, ratio: 0.5, first: x, second: .pane("A")))
        XCTAssertEqual(SplitNode.pane("A").inserting(x, at: "A", toward: .down),
                       .split(axis: .vertical, ratio: 0.5, first: .pane("A"), second: x))
        // 안쪽 화면만 나뉘고 나머지 비율은 그대로
        let tree = SplitNode.split(axis: .horizontal, ratio: 0.3, first: .pane("A"), second: .pane("B"))
        XCTAssertEqual(tree.inserting(x, at: "B", toward: .up),
                       .split(axis: .horizontal, ratio: 0.3, first: .pane("A"),
                              second: .split(axis: .vertical, ratio: 0.5, first: x, second: .pane("B"))))
        XCTAssertEqual(tree.inserting(x, at: "Z", toward: .up), tree)
    }

    func testReorderTabs() {
        var w = workspace()
        XCTAssertTrue(w.moveTab(from: 0, to: 2))
        XCTAssertEqual(w.tabs.map(\.id), ["t2", "t3", "t1"])
        XCTAssertFalse(w.moveTab(from: 2, to: 9)) // 이미 맨 끝
        XCTAssertTrue(w.moveTab(from: 2, to: -1))
        XCTAssertEqual(w.tabs.map(\.id), ["t1", "t2", "t3"])
        XCTAssertFalse(w.moveTab(from: 5, to: 0))
        // 틈 기준: t3 를 맨 앞 틈으로, t1 을 맨 뒤 틈으로. 옮긴 탭이 골라진다.
        XCTAssertTrue(w.move(tab: "t3", to: .tab(gap: 0)))
        XCTAssertEqual(w.tabs.map(\.id), ["t3", "t1", "t2"])
        XCTAssertEqual(w.selected, "t3")
        XCTAssertTrue(w.move(tab: "t1", to: .tab(gap: 3)))
        XCTAssertEqual(w.tabs.map(\.id), ["t3", "t2", "t1"])
        // 제자리 틈(앞뒤)은 순서가 그대로
        XCTAssertFalse(w.move(tab: "t1", to: .tab(gap: 2)))
        XCTAssertEqual(w.tabs.map(\.id), ["t3", "t2", "t1"])
    }

    func testMoveTabIntoAnotherTabsPane() {
        var w = workspace()
        // 분할된 탭 t1 을 D 의 왼쪽에: 나무째 들어가고 t1 은 닫힌다, 포커스는 t1 이 보던 화면
        XCTAssertTrue(w.move(tab: "t1", to: .split(target: "D", toward: .left)))
        XCTAssertEqual(w.tabs.map(\.id), ["t2", "t3"])
        XCTAssertEqual(w.tabs[0].root.panes, ["A", "B", "C", "D"])
        guard case .split(.horizontal, 0.5, let first, .pane("D")) = w.tabs[0].root else { return XCTFail() }
        XCTAssertEqual(first.panes, ["A", "B", "C"])
        XCTAssertEqual(w.tabs[0].focused, "A")
        XCTAssertEqual(w.selected, "t2")
        // 자기 화면 위로는 못 놓는다
        XCTAssertFalse(w.move(tab: "t2", to: .split(target: "B", toward: .up)))
        // 편집기 탭도 같다
        XCTAssertTrue(w.move(tab: "t3", to: .split(target: "B", toward: .down)))
        XCTAssertEqual(w.tabs.map(\.id), ["t2"])
        XCTAssertEqual(w.tabs[0].root.panes, ["A", "B", editor, "C", "D"])
        XCTAssertEqual(w.tabs[0].focused, editor)
        XCTAssertEqual(w.editors[editor]?.path, "/tmp/a.swift") // 편집기 정보는 그대로
    }

    func testMovePaneWithinTab() {
        var w = workspace()
        w.tabs[0].zoomed = true
        // C 를 A 위로: A|B 에서 (C/A)|B
        XCTAssertTrue(w.move(pane: "C", to: .split(target: "A", toward: .up)))
        XCTAssertEqual(w.tabs.count, 3)
        XCTAssertEqual(w.tabs[0].root, .split(axis: .horizontal, ratio: 0.5,
                                              first: .split(axis: .vertical, ratio: 0.5, first: .pane("C"), second: .pane("A")),
                                              second: .pane("B")))
        XCTAssertEqual(w.tabs[0].focused, "C")
        XCTAssertFalse(w.tabs[0].zoomed)
        XCTAssertFalse(w.move(pane: "C", to: .split(target: "C", toward: .left)))
        XCTAssertFalse(w.move(pane: "C", to: .split(target: "nope", toward: .left)))
        XCTAssertEqual(w.tabs[0].root.panes, ["C", "A", "B"])
    }

    func testMovePaneToAnotherTabAndEmptiedTabCloses() {
        var w = workspace()
        // B 를 D 오른쪽으로: t1 은 A|C 로 남고 포커스는 그대로
        XCTAssertTrue(w.move(pane: "B", to: .split(target: "D", toward: .right)))
        XCTAssertEqual(w.tabs[0].root.panes, ["A", "C"])
        XCTAssertEqual(w.tabs[0].focused, "A")
        XCTAssertEqual(w.tabs[1].root, .split(axis: .horizontal, ratio: 0.5, first: .pane("D"), second: .pane("B")))
        XCTAssertEqual(w.tabs[1].focused, "B")
        XCTAssertEqual(w.selected, "t2")
        // 혼자 있던 편집기를 A 아래로: 편집기 탭은 닫힌다
        XCTAssertTrue(w.move(pane: editor, to: .split(target: "A", toward: .down)))
        XCTAssertEqual(w.tabs.map(\.id), ["t1", "t2"])
        XCTAssertEqual(w.tabs[0].root.panes, ["A", editor, "C"])
        XCTAssertEqual(w.selected, "t1")
        XCTAssertEqual(w.tabs[0].focused, editor)
    }

    func testExtractPaneToNewTab() throws {
        var w = workspace()
        w.tabs[0].focused = "B"
        XCTAssertTrue(w.move(pane: "B", to: .tab(gap: 1)))
        XCTAssertEqual(w.tabs.count, 4)
        XCTAssertEqual(w.tabs[0].root.panes, ["A", "C"])
        XCTAssertEqual(w.tabs[0].focused, "A") // 뺀 화면 앞 화면
        XCTAssertEqual(w.tabs[1].root, .pane("B"))
        XCTAssertEqual(w.selected, w.tabs[1].id)
        // 맨 끝 틈(범위를 넘어도 끝으로)
        XCTAssertTrue(w.move(pane: "C", to: .tab(gap: 99)))
        XCTAssertEqual(w.tabs.last?.root, .pane("C"))
        // 혼자 있는 화면을 틈으로 = 탭 순서만(탭 ID 그대로)
        let id = w.tabs.last!.id
        XCTAssertTrue(w.move(pane: "C", to: .tab(gap: 0)))
        XCTAssertEqual(w.tabs.first?.id, id)
        XCTAssertEqual(w.tabs.count, 5)
        // 순서는 배치 파일에 남는다
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w))
        XCTAssertEqual(decoded.tabs.map(\.id), w.tabs.map(\.id))
        XCTAssertEqual(decoded.selected, id)
    }
}

final class BrowserPaneWorkspaceTests: XCTestCase {
    /// 탭 하나: A(에이전트) | 브라우저(주인 A), 다른 탭: B
    private func workspaceWithBrowser() -> (Workspace, String) {
        let browser = BrowserPane.newId()
        var workspace = Workspace(tabs: [
            TabState(id: "t1", root: SplitNode.pane("A").splitting("A", with: browser, axis: .horizontal), focused: browser),
            TabState(id: "t2", root: .pane("B"), focused: "B"),
        ], selected: "t1")
        workspace.browsers[browser] = BrowserRecipe(owner: "A")
        return (workspace, browser)
    }

    func testReconcileKeepsBrowserWhileOwnerLivesOrSleeps() {
        var (workspace, browser) = workspaceWithBrowser()
        workspace.recipes["A"] = PaneRecipe(cwd: "/tmp")
        workspace.reconcile(live: ["A", "B"], daemonPid: 1)
        XCTAssertTrue(workspace.allPanes.contains(browser))
        XCTAssertNil(workspace.recipes[browser])
        // 데몬이 바뀌어 주인이 꺼진 화면이 되어도 브라우저 화면은 남는다(되살리면 같은 브라우저)
        workspace.reconcile(live: ["B"], daemonPid: 2)
        XCTAssertTrue(workspace.dormant.contains("A"))
        XCTAssertTrue(workspace.allPanes.contains(browser))
        XCTAssertFalse(workspace.dormant.contains(browser))
        XCTAssertEqual(workspace.browserPane(owner: "A"), browser)
    }

    func testBrowserGoesWithItsOwner() {
        var (workspace, browser) = workspaceWithBrowser()
        workspace.reconcile(live: ["A", "B"], daemonPid: 1)
        workspace.reconcile(live: ["B"], daemonPid: 1) // 같은 데몬에서 A 가 끝남
        XCTAssertFalse(workspace.allPanes.contains("A"))
        XCTAssertFalse(workspace.allPanes.contains(browser))
        XCTAssertNil(workspace.browsers[browser])
        XCTAssertEqual(workspace.allPanes, ["B"])
        // 데몬이 브라우저 ID 를 알려 와도 새 탭으로 붙지 않는다
        workspace.reconcile(live: ["B", "browser:ghost"], daemonPid: 1)
        XCTAssertEqual(workspace.tabs.count, 1)
    }

    func testPersistenceAndBrokenBrowserLeaves() throws {
        let (workspace, browser) = workspaceWithBrowser()
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(decoded, workspace)
        XCTAssertEqual(decoded.browsers[browser], BrowserRecipe(owner: "A"))
        var broken = workspace
        broken.browsers[browser] = nil
        let repaired = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(broken))
        XCTAssertFalse(repaired.allPanes.contains(browser))
        XCTAssertEqual(repaired.tabs[0].focused, "A")
        // browsers 가 없는 예전 파일
        let old = #"{"tabs":[{"id":"t","root":{"pane":{"_0":"A"}},"focused":"A","zoomed":false}],"selected":"t"}"#
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(old.utf8)).browsers, [:])
    }
}
