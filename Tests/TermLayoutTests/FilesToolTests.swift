import CoreGraphics
import Foundation
import TermLayout
import XCTest

final class FilesRootTests: XCTestCase {
    let repo = GitLocation(repoRoot: "/p/repo", worktreeRoot: "/p/repo", commonDir: "/p/repo/.git")
    let worktree = GitLocation(repoRoot: "/p/repo", worktreeRoot: "/w/side", commonDir: "/p/repo/.git")

    func locate(_ dir: String) -> GitLocation? {
        if dir.hasPrefix("/p/repo") { return repo }
        if dir.hasPrefix("/w/side") { return worktree }
        return nil
    }

    func testTerminalUsesWorktreeTopOrFolder() {
        XCTAssertEqual(FilesRoot.folder("/p/repo/src/a", git: repo), FilesRoot(path: "/p/repo", isGit: true))
        XCTAssertEqual(FilesRoot.folder("/w/side/x", git: worktree), FilesRoot(path: "/w/side", isGit: true))
        XCTAssertEqual(FilesRoot.folder("/p/notes/", git: nil), FilesRoot(path: "/p/notes", isGit: false))
    }

    /// 보고: 상위 폴더(저장소 아님)를 둘러보다 하위 저장소 파일을 열면 루트가 그 저장소로 바뀌어 보던 자리를 잃었다
    func testEditorInsideCurrentRootKeepsRoot() {
        let parent = FilesRoot(path: "/p", isGit: false)
        XCTAssertEqual(FilesRoot.editor(file: "/p/repo/src/deep/A.swift", current: parent, locate: locate), parent)
    }

    /// 같은 저장소·작업 트리의 터미널 화면과 같은 루트
    func testEditorMatchesTerminalRootOutsideCurrent() {
        let other = FilesRoot(path: "/elsewhere", isGit: false)
        XCTAssertEqual(FilesRoot.editor(file: "/p/repo/src/A.swift", current: other, locate: locate),
                       FilesRoot.folder("/p/repo/src", git: locate("/p/repo/src")))
        XCTAssertEqual(FilesRoot.editor(file: "/w/side/Sources/B.swift", current: nil, locate: locate),
                       FilesRoot(path: "/w/side", isGit: true))
        XCTAssertEqual(FilesRoot.editor(file: "/tmp/x/note.md", current: other, locate: locate),
                       FilesRoot(path: "/tmp/x", isGit: false))
    }

    func testContainsIsByPathComponent() {
        let root = FilesRoot(path: "/p/repo", isGit: true)
        XCTAssertTrue(root.contains("/p/repo/a"))
        XCTAssertTrue(root.contains("/p/repo"))
        XCTAssertFalse(root.contains("/p/repo2/a"))
        XCTAssertEqual(root.relative("/p/repo/a/b.swift"), "a/b.swift")
        XCTAssertEqual(root.relative("/p/repo"), "")
        XCTAssertNil(root.relative("/p/other"))
        XCTAssertEqual(FilesRoot(path: "/", isGit: false).relative("/etc/hosts"), "etc/hosts")
    }
}

final class TreePlaceMemoryTests: XCTestCase {
    func testPlacesArePerRootAndEvictedWithRoot() {
        var memory = ExpansionMemory(maxRoots: 2)
        memory.setExpanded("src", true, root: "/a")
        memory.setPlace(TreePlace(topRow: "src/x", selected: "src/x/y.swift"), root: "/a")
        memory.setPlace(TreePlace(topRow: "docs"), root: "/b")
        XCTAssertEqual(memory.place(for: "/a")?.selected, "src/x/y.swift")
        XCTAssertEqual(memory.place(for: "/b")?.topRow, "docs")
        XCTAssertEqual(memory.paths(for: "/a"), ["src"])
        memory.setPlace(TreePlace(), root: "/c") // /b 가 가장 오래됨
        XCTAssertNil(memory.place(for: "/b"))
        XCTAssertNotNil(memory.place(for: "/a"))
        XCTAssertEqual(memory.rootCount, 2)
    }

    func testAncestors() {
        XCTAssertEqual(ExpansionMemory.ancestors(of: "a/b/c.swift"), ["a", "a/b"])
        XCTAssertEqual(ExpansionMemory.ancestors(of: "top.swift"), [])
    }
}

final class UIScaleTests: XCTestCase {
    func testFactorFollowsFontSizeWithinRange() {
        XCTAssertEqual(UIScale(fontSize: 13, defaultSize: 13).factor, 1)
        XCTAssertEqual(UIScale(fontSize: 26, defaultSize: 13).factor, 1.6) // 위로 묶음
        XCTAssertEqual(UIScale(fontSize: 8, defaultSize: 13).factor, 0.8) // 아래로 묶음
        XCTAssertEqual(UIScale(fontSize: 18, defaultSize: 13).factor, 18.0 / 13, accuracy: 1e-9)
    }

    func testScaledValuesRoundToHalfPoint() {
        let scale = UIScale(fontSize: 18, defaultSize: 13)
        XCTAssertEqual(scale(12), 16.5) // 16.61
        XCTAssertEqual(scale(22), 30.5) // 30.46
        XCTAssertEqual(UIScale.identity(11), 11)
        XCTAssertEqual(UIScale(fontSize: 10, defaultSize: 13)(12), 9.5) // 9.23
    }
}

final class FileOpeningTests: XCTestCase {
    private var counter = 0
    private func newId() -> String {
        counter += 1
        return "editor:\(counter)"
    }

    /// 터미널 T 하나인 탭
    private func workspace() -> Workspace {
        Workspace(tabs: [TabState(id: "tab", root: .pane("T"), focused: "T")], selected: "tab")
    }

    func testFirstOpenSplitsRightAsPreviewThenReplaces() {
        var ws = workspace()
        let first = ws.openPreview(path: "/r/a.swift", newId: newId)
        XCTAssertEqual(first.focused, "editor:1")
        XCTAssertEqual(ws.tabs[0].root, .split(axis: .horizontal, ratio: 0.5, first: .pane("T"), second: .pane("editor:1")))
        XCTAssertEqual(ws.editors["editor:1"]?.isPreview, true)

        // 다음 파일은 미리보기 자리를 바꾼다(나누지 않음)
        let second = ws.openPreview(path: "/r/b.swift", newId: newId)
        XCTAssertEqual(second.closed, ["editor:1"])
        XCTAssertEqual(ws.tabs[0].root, .split(axis: .horizontal, ratio: 0.5, first: .pane("T"), second: .pane("editor:2")))
        XCTAssertNil(ws.editors["editor:1"])
        XCTAssertEqual(ws.editors["editor:2"]?.path, "/r/b.swift")
        XCTAssertEqual(ws.tabs[0].focused, "editor:2")

        // 터미널로 포커스를 옮겨도 미리보기 자리를 쓴다
        ws.tabs[0].focused = "T"
        _ = ws.openPreview(path: "/r/c.swift", newId: newId)
        XCTAssertEqual(ws.tabs[0].root.panes, ["T", "editor:3"])
    }

    func testPinnedPreviewMakesNextOpenSplitBesideFocused() {
        var ws = workspace()
        _ = ws.openPreview(path: "/r/a.swift", newId: newId)
        XCTAssertTrue(ws.pin(editor: "editor:1"))
        XCTAssertFalse(ws.pin(editor: "editor:1"))
        _ = ws.openPreview(path: "/r/b.swift", newId: newId)
        // 지금 화면(고정된 a) 오른쪽에 새 미리보기
        XCTAssertEqual(ws.tabs[0].root.panes, ["T", "editor:1", "editor:2"])
        XCTAssertEqual(ws.editors["editor:1"]?.isPreview, false)
        XCTAssertEqual(ws.previewPane(inTab: 0), "editor:2")
    }

    func testAlreadyOpenFocusesInsteadOfDuplicating() {
        var ws = workspace()
        ws.tabs.append(TabState(id: "other", root: .pane("editor:x"), focused: "editor:x"))
        ws.editors["editor:x"] = EditorRecipe(path: "/r/open.swift")
        let result = ws.openPreview(path: "/r/open.swift", newId: newId)
        XCTAssertEqual(result, FileOpenResult(focused: "editor:x"))
        XCTAssertEqual(ws.selected, "other")
        XCTAssertEqual(ws.editors.count, 1)
    }

    func testNoTabOpensNewTab() {
        var ws = Workspace()
        let result = ws.openPreview(path: "/r/a.swift", newId: newId)
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.tabs[0].root, .pane("editor:1"))
        XCTAssertEqual(result.focused, "editor:1")
    }

    func testStackedOpenUsesPreviewSlotAsColumn() {
        var ws = workspace()
        _ = ws.openPreview(path: "/r/p.swift", newId: newId)
        let result = ws.openStacked(paths: ["/r/a", "/r/b", "/r/c"], newId: newId)
        XCTAssertEqual(result.closed, ["editor:1"])
        XCTAssertEqual(result.created, ["editor:2", "editor:3", "editor:4"])
        let column = SplitNode.split(axis: .vertical, ratio: 1.0 / 3, first: .pane("editor:2"),
                                     second: .split(axis: .vertical, ratio: 0.5, first: .pane("editor:3"), second: .pane("editor:4")))
        XCTAssertEqual(ws.tabs[0].root, .split(axis: .horizontal, ratio: 0.5, first: .pane("T"), second: column))
        XCTAssertTrue(result.created.allSatisfy { ws.editors[$0]?.isPreview == false }) // 여러 개는 고정
        XCTAssertEqual(ws.tabs[0].focused, "editor:2")
    }

    func testStackedOpenWithoutPreviewGoesRightOfFocusedAndSkipsOpenFiles() {
        var ws = workspace()
        ws.tabs[0].root = SplitNode.pane("T").splitting("T", with: "editor:x", axis: .horizontal)
        ws.editors["editor:x"] = EditorRecipe(path: "/r/a")
        let result = ws.openStacked(paths: ["/r/a", "/r/b", "/r/b", "/r/c"], newId: newId)
        XCTAssertEqual(result.created.map { ws.editors[$0]?.path }, ["/r/b", "/r/c"])
        XCTAssertEqual(ws.tabs[0].root.panes, ["T", "editor:1", "editor:2", "editor:x"])
    }

    func testGridOpensNewTabCapped() {
        var ws = workspace()
        let paths = (1...14).map { "/r/f\($0)" }
        let result = ws.openGrid(paths: paths, newId: newId)
        XCTAssertEqual(result.created.count, Workspace.maxGridFiles)
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertEqual(ws.selected, ws.tabs[1].id)
        XCTAssertEqual(ws.tabs[1].root.panes.count, 12)
        XCTAssertEqual(ws.tabs[0].root, .pane("T"))
    }

    func testGridShape() {
        // 6개 → 3열 2줄
        let grid = SplitNode.grid(["1", "2", "3", "4", "5", "6"])
        let frames = grid!.layout(in: CGRect(x: 0, y: 0, width: 300, height: 200), divider: 0).panes
        XCTAssertEqual(frames["1"], CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(frames["6"], CGRect(x: 200, y: 100, width: 100, height: 100))
        XCTAssertEqual(SplitNode.grid(["a"]), .pane("a"))
        XCTAssertNil(SplitNode.grid([]))
    }

    func testOldEditorRecipeDecodesAsPinned() throws {
        let data = Data(#"{"path":"/r/a.swift","cursor":3}"#.utf8)
        let recipe = try JSONDecoder().decode(EditorRecipe.self, from: data)
        XCTAssertFalse(recipe.isPreview)
        let encoded = String(data: try JSONEncoder().encode(EditorRecipe(path: "/x")), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("preview"))
    }
}
