import Foundation
import TermLayout
import XCTest

final class GitStatusParserTests: XCTestCase {
    private func parse(_ entries: [String]) -> GitStatusSnapshot {
        GitStatusParser.parse(Data(entries.joined(separator: "\0").utf8 + [0]))
    }

    /// 실제 `git status --porcelain=v1 -z --untracked-files=normal --ignored=matching` 출력 모양
    func testParsesRealOutputIncludingRenameAndSpaces() {
        let snapshot = parse([
            " M src/app/main.swift",
            "A  src/app/ui/Added.swift",
            "R  src/new_name.txt", "src/old_name.txt",
            "?? docs/my file.md",
            "?? notes.txt",
            "?? scratch/",
            "!! build/",
            "!! debug.log",
        ])
        XCTAssertEqual(snapshot.status(of: "src/app/main.swift"), .modified)
        XCTAssertEqual(snapshot.status(of: "src/app/ui/Added.swift"), .added)
        XCTAssertEqual(snapshot.status(of: "src/new_name.txt"), .renamed)
        // 옛 경로는 다음 항목으로 읽지 않는다
        XCTAssertNil(snapshot.status(of: "src/old_name.txt"))
        XCTAssertEqual(snapshot.status(of: "docs/my file.md"), .untracked)
        XCTAssertEqual(snapshot.status(of: "notes.txt"), .untracked)
        XCTAssertEqual(snapshot.status(of: "debug.log"), .ignored)
        XCTAssertNil(snapshot.status(of: "README.md"))
        XCTAssertEqual(snapshot.changeCount, 6)
    }

    func testFolderEntriesApplyToDescendants() {
        let snapshot = parse(["?? scratch/", "!! build/", "!! .build/"])
        XCTAssertEqual(snapshot.status(of: "scratch"), .untracked)
        XCTAssertEqual(snapshot.status(of: "scratch/deep/z.txt"), .untracked)
        XCTAssertEqual(snapshot.status(of: "build/out.bin"), .ignored)
        XCTAssertEqual(snapshot.status(of: ".build/debug/x"), .ignored)
        XCTAssertNil(snapshot.status(of: "scratchpad.txt")) // 이름 앞부분만 같은 것은 아니다
    }

    func testRenameWithChangeInWorktreeAndCopy() {
        let snapshot = parse(["RM b.txt", "a.txt", "C  c2.txt", "c.txt", " M d.txt"])
        XCTAssertEqual(snapshot.status(of: "b.txt"), .renamed)
        XCTAssertEqual(snapshot.status(of: "c2.txt"), .added)
        XCTAssertEqual(snapshot.status(of: "d.txt"), .modified)
        XCTAssertNil(snapshot.status(of: "a.txt"))
        XCTAssertNil(snapshot.status(of: "c.txt"))
    }

    func testStatusCodes() {
        func s(_ code: String) -> GitFileStatus? {
            let b = Array(code.utf8)
            return GitStatusParser.status(x: b[0], y: b[1])
        }
        for code in ["UU", "AA", "DD", "AU", "UA", "DU", "UD"] { XCTAssertEqual(s(code), .conflicted, code) }
        XCTAssertEqual(s("M "), .modified)
        XCTAssertEqual(s("MM"), .modified)
        XCTAssertEqual(s(" T"), .modified)
        XCTAssertEqual(s("AM"), .added)
        XCTAssertEqual(s("D "), .deleted)
        XCTAssertEqual(s(" D"), .deleted)
        XCTAssertEqual(s("R "), .renamed)
        XCTAssertEqual(s("??"), .untracked)
        XCTAssertEqual(s("!!"), .ignored)
        XCTAssertNil(s("  "))
    }

    func testParentFoldersGetChangeMarkButNotForIgnored() {
        let snapshot = parse([" M src/app/ui/View.swift", "?? scratch/", "!! build/", "!! logs/a.log", " D gone/old.txt"])
        for folder in ["", "src", "src/app", "src/app/ui", "gone"] {
            XCTAssertTrue(snapshot.containsChanges(folder), folder)
        }
        XCTAssertFalse(snapshot.containsChanges("scratch")) // 폴더 자신은 untracked 색으로 보인다
        XCTAssertFalse(snapshot.containsChanges("build"))
        XCTAssertFalse(snapshot.containsChanges("logs"))
        XCTAssertFalse(snapshot.containsChanges("src/app/ui/View.swift"))
        XCTAssertEqual(snapshot.status(of: "gone/old.txt"), .deleted)
    }

    func testOnlyIgnoredDoesNotMarkRoot() {
        let snapshot = parse(["!! build/"])
        XCTAssertFalse(snapshot.containsChanges(""))
        XCTAssertEqual(snapshot.changeCount, 0)
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(GitStatusParser.parse(Data()).isEmpty)
        XCTAssertTrue(GitStatusParser.parse(Data("x\0??\0".utf8)).isEmpty)
        // 한글 이름
        XCTAssertEqual(parse(["?? 문서/메모.txt"]).status(of: "문서/메모.txt"), .untracked)
    }

    /// 실제 git 으로 만든 저장소에서 확인(git 이 없으면 건너뜀)
    func testAgainstRealGit() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git 없음") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitstatus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        @discardableResult
        func git(_ args: String...) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", dir.path, "-c", "user.email=t@t", "-c", "user.name=t"] + args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }
        func write(_ path: String, _ text: String) throws {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try git("init", "-q")
        try write("a/b/mod.txt", "1")
        try write("old.txt", "o")
        try write(".gitignore", "out/\n")
        try git("add", "-A")
        try git("commit", "-qm", "init")
        try write("a/b/mod.txt", "2")
        try git("mv", "old.txt", "new name.txt")
        try write("staged.txt", "s")
        try git("add", "staged.txt")
        try write("u/deep/x.txt", "u")
        try write("out/bin", "b")
        let snapshot = GitStatusParser.parse(try git("status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignored=matching"))
        XCTAssertEqual(snapshot.status(of: "a/b/mod.txt"), .modified)
        XCTAssertEqual(snapshot.status(of: "new name.txt"), .renamed)
        XCTAssertEqual(snapshot.status(of: "staged.txt"), .added)
        XCTAssertEqual(snapshot.status(of: "u/deep/x.txt"), .untracked)
        XCTAssertEqual(snapshot.status(of: "out/bin"), .ignored)
        XCTAssertTrue(snapshot.containsChanges("a"))
        XCTAssertTrue(snapshot.containsChanges("a/b"))
        XCTAssertNil(snapshot.status(of: ".gitignore"))
    }
}

final class ToolLayoutTests: XCTestCase {
    func testDefaultsBothLeftSpacesSelected() {
        let layout = ToolLayout()
        XCTAssertEqual(layout.tools(in: .left), [.spaces, .files])
        XCTAssertEqual(layout.tools(in: .right), [])
        XCTAssertEqual(layout.visibleTool(in: .left), .spaces)
        XCTAssertNil(layout.visibleTool(in: .right))
        XCTAssertTrue(layout.isVisible(.spaces))
        XCTAssertFalse(layout.isVisible(.files))
    }

    func testToggleCycle() {
        var layout = ToolLayout()
        // 보이지만 고르지 않음 → 고른다
        layout.toggle(.files)
        XCTAssertTrue(layout.isVisible(.files))
        XCTAssertFalse(layout.isVisible(.spaces))
        // 고른 상태 → 숨긴다, 같은 쪽 남은 도구가 보인다
        layout.toggle(.files)
        XCTAssertEqual(layout.side(of: .files), .hidden)
        XCTAssertEqual(layout.visibleTool(in: .left), .spaces)
        // 숨김 → 마지막 쪽에 보이고 고른다
        layout.toggle(.files)
        XCTAssertEqual(layout.side(of: .files), .left)
        XCTAssertTrue(layout.isVisible(.files))
    }

    func testMoveRememberSideAndHide() {
        var layout = ToolLayout()
        layout.move(.files, to: .right)
        XCTAssertEqual(layout.tools(in: .left), [.spaces])
        XCTAssertEqual(layout.visibleTool(in: .right), .files)
        XCTAssertEqual(layout.visibleTool(in: .left), .spaces)
        layout.toggle(.files) // 고른 상태라 숨김
        XCTAssertEqual(layout.side(of: .files), .hidden)
        XCTAssertNil(layout.visibleTool(in: .right))
        layout.toggle(.files) // 오른쪽으로 돌아온다
        XCTAssertEqual(layout.side(of: .files), .right)
        // spaces 숨기면 왼쪽은 빈다
        layout.move(.spaces, to: .hidden)
        XCTAssertNil(layout.visibleTool(in: .left))
        layout.toggle(.spaces)
        XCTAssertEqual(layout.side(of: .spaces), .left)
    }

    func testMovingSelectedToolSelectsNeighbourInOldDock() {
        var layout = ToolLayout()
        layout.toggle(.files) // 왼쪽에서 files 고름
        layout.move(.files, to: .right)
        XCTAssertEqual(layout.visibleTool(in: .left), .spaces)
        layout.move(.spaces, to: .right)
        XCTAssertEqual(layout.tools(in: .right), [.spaces, .files])
        XCTAssertEqual(layout.visibleTool(in: .right), .spaces)
        XCTAssertNil(layout.visibleTool(in: .left))
    }

    func testRoundTrip() throws {
        var layout = ToolLayout()
        layout.move(.files, to: .right)
        layout.widths[.right] = 333
        layout.move(.spaces, to: .hidden)
        let data = try XCTUnwrap(layout.data())
        let decoded = try JSONDecoder().decode(ToolLayout.self, from: data)
        XCTAssertEqual(decoded, layout)
        XCTAssertEqual(decoded.width(.right), 333)
        XCTAssertEqual(decoded.lastSides[.spaces], .left)
    }

    func testToleratesMissingOldAndBrokenFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ui.json")
        XCTAssertEqual(ToolLayout.load(from: url), ToolLayout()) // 없음
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(ToolLayout.load(from: url), ToolLayout()) // 망가짐
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(ToolLayout.load(from: url), ToolLayout()) // 빈 파일(예전)
        // 모르는 도구·쪽·이상한 폭은 버리고, 고른 도구가 그쪽에 없으면 바로잡는다
        try Data(#"{"tools":{"files":"right","terminal":"left","spaces":"top"},"selected":{"left":"files","right":"bogus"},"widths":{"left":5,"right":300}}"#.utf8)
            .write(to: url)
        let layout = ToolLayout.load(from: url)
        XCTAssertEqual(layout.side(of: .files), .right)
        XCTAssertEqual(layout.side(of: .spaces), .left)
        XCTAssertEqual(layout.visibleTool(in: .left), .spaces)
        XCTAssertEqual(layout.visibleTool(in: .right), .files)
        XCTAssertEqual(layout.width(.left), 260)
        XCTAssertEqual(layout.width(.right), 300)
    }
}

extension ToolLayoutTests {
    /// 브라우저 도구: 처음엔 숨김, 옆 도크로 꺼내면(작은 창이 기본이므로 move) 오른쪽 + 읽힐 만한 폭, 예전 ui.json(브라우저 없음)도 숨김으로
    func testBrowserToolHiddenByDefaultShowsOnTheRightWide() throws {
        var layout = ToolLayout()
        XCTAssertEqual(layout.side(of: .browser), .hidden)
        XCTAssertFalse(layout.isVisible(.browser))
        layout.move(.browser, to: .right)
        XCTAssertEqual(layout.side(of: .browser), .right)
        XCTAssertTrue(layout.isVisible(.browser))
        XCTAssertEqual(layout.width(.right), ToolLayout.browserWidth)
        // 사람이 정한 폭은 지킨다
        var custom = ToolLayout()
        custom.widths[.right] = 500
        custom.move(.browser, to: .right)
        XCTAssertEqual(custom.width(.right), 500)
        // 넓게 펼친 브라우저 도크 폭(2000pt 넘게)도 다시 켜면 그대로
        custom.widths[.right] = 2300
        let wide = try JSONDecoder().decode(ToolLayout.self, from: XCTUnwrap(custom.data()))
        XCTAssertEqual(wide.width(.right), 2300)
        let old = try JSONDecoder().decode(ToolLayout.self, from: Data(#"{"tools":{"spaces":"left","files":"right"}}"#.utf8))
        XCTAssertEqual(old.side(of: .browser), .hidden)
        XCTAssertEqual(old.visibleTool(in: .right), .files)
    }
}

final class DirectoryListingTests: XCTestCase {
    func testFoldersFirstCaseInsensitive() {
        let entries = [
            DirectoryEntry(name: "b.txt", isDirectory: false),
            DirectoryEntry(name: "Zeta", isDirectory: true),
            DirectoryEntry(name: "A.txt", isDirectory: false),
            DirectoryEntry(name: "alpha", isDirectory: true),
            DirectoryEntry(name: ".env", isDirectory: false),
            DirectoryEntry(name: "file10", isDirectory: false),
            DirectoryEntry(name: "file2", isDirectory: false),
        ]
        XCTAssertEqual(DirectoryListing.sorted(entries).map(\.name), ["alpha", "Zeta", ".env", "A.txt", "b.txt", "file2", "file10"])
        XCTAssertTrue(entries[4].isHidden)
    }

    func testReadSkipsGitAndDetectsFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("listing-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("README.md"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("src"))
        defer { try? fm.removeItem(at: dir) }
        let entries = DirectoryListing.read(dir.path)
        XCTAssertEqual(entries.map(\.name), ["link", "src", ".hidden", "README.md"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, true, false, false])
        XCTAssertEqual(DirectoryListing.read(dir.appendingPathComponent("nope").path), [])
    }

    func testWorktreeBranch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("branch-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("main/.git"), withIntermediateDirectories: true)
        try "ref: refs/heads/feature/x\n".write(to: dir.appendingPathComponent("main/.git/HEAD"), atomically: true, encoding: .utf8)
        // 작업 트리: .git 파일이 가리키는 곳의 HEAD
        try fm.createDirectory(at: dir.appendingPathComponent("main/.git/worktrees/wt"), withIntermediateDirectories: true)
        try "ref: refs/heads/side\n".write(to: dir.appendingPathComponent("main/.git/worktrees/wt/HEAD"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: dir.appendingPathComponent("wt"), withIntermediateDirectories: true)
        try "gitdir: ../main/.git/worktrees/wt\n".write(to: dir.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dir) }
        XCTAssertEqual(GitWorktrees.branch(worktreeRoot: dir.appendingPathComponent("main").path), "feature/x")
        XCTAssertEqual(GitWorktrees.branch(worktreeRoot: dir.appendingPathComponent("wt").path), "side")
        XCTAssertNil(GitWorktrees.branch(worktreeRoot: dir.path))
    }
}

final class ExpansionMemoryTests: XCTestCase {
    func testPerRootShallowFirstAndBounded() {
        var memory = ExpansionMemory(maxRoots: 2, maxPathsPerRoot: 3)
        memory.setExpanded("src/app", true, root: "/r1")
        memory.setExpanded("src", true, root: "/r1")
        memory.setExpanded("docs", true, root: "/r1")
        memory.setExpanded("more", true, root: "/r1") // 넘침 → 무시
        XCTAssertEqual(memory.paths(for: "/r1"), ["docs", "src", "src/app"])
        memory.setExpanded("x", true, root: "/r2")
        memory.setExpanded("y", true, root: "/r3") // 가장 오래된 r1 이 빠진다
        XCTAssertEqual(memory.rootCount, 2)
        XCTAssertEqual(memory.paths(for: "/r1"), [])
        XCTAssertEqual(memory.paths(for: "/r3"), ["y"])
    }

    func testCollapseAndForget() {
        var memory = ExpansionMemory()
        for path in ["a", "a/b", "a/b/c", "ab"] { memory.setExpanded(path, true, root: "/r") }
        memory.setExpanded("a/b/c", false, root: "/r")
        XCTAssertEqual(memory.paths(for: "/r"), ["a", "ab", "a/b"])
        memory.forget("a", root: "/r")
        XCTAssertEqual(memory.paths(for: "/r"), ["ab"])
        memory.collapseAll(root: "/r")
        XCTAssertEqual(memory.paths(for: "/r"), [])
    }
}

final class ToolLayoutFontSizeTests: XCTestCase {
    /// 글꼴 크기가 없는 예전 ui.json 도 읽힌다(nil = 기본)
    func testOldFileWithoutFontSizeDecodes() throws {
        let old = #"{"version":1,"tools":{"spaces":"left","files":"right"},"widths":{"left":300}}"#
        let layout = try JSONDecoder().decode(ToolLayout.self, from: Data(old.utf8))
        XCTAssertNil(layout.fontSize)
        XCTAssertEqual(layout.side(of: .files), .right)
    }

    func testFontSizeRoundTripsAndRejectsGarbage() throws {
        var layout = ToolLayout()
        layout.fontSize = 17
        let data = try XCTUnwrap(layout.data())
        XCTAssertEqual(try JSONDecoder().decode(ToolLayout.self, from: data).fontSize, 17)
        let bad = #"{"version":1,"fontSize":-5}"#
        XCTAssertNil(try JSONDecoder().decode(ToolLayout.self, from: Data(bad.utf8)).fontSize)
    }
}

final class BrowserFloatTests: XCTestCase {
    private let host = CGSize(width: 1000, height: 700)

    /// 처음 꺼내면 작은 창(옆 도크가 아니라), 숨기면 도크 쪽은 그대로 숨김
    func testFirstRevealIsFloat() {
        var layout = ToolLayout()
        layout.toggle(.browser)
        XCTAssertTrue(layout.browserFloat.shown)
        XCTAssertEqual(layout.side(of: .browser), .hidden)
        XCTAssertFalse(layout.isVisible(.browser))
        XCTAssertTrue(layout.isBrowserShown)
        layout.toggle(.browser)
        XCTAssertFalse(layout.isBrowserShown)
        layout.toggle(.browser)
        XCTAssertTrue(layout.browserFloat.shown)
    }

    /// 시험 명령으로 도크에 옮겼다가 숨겨도, 다시 꺼내면 작은 창(옆 도크로 가지 않는다)
    func testToggleAlwaysFloatsEvenAfterDebugDock() {
        var layout = ToolLayout()
        layout.move(.browser, to: .left)
        XCTAssertTrue(layout.isVisible(.browser))
        XCTAssertFalse(layout.browserFloat.shown)
        layout.toggle(.browser) // 보이지만 고르지 않았으면 고름 / 고른 상태면 숨김
        layout.move(.browser, to: .hidden)
        layout.toggle(.browser)
        XCTAssertEqual(layout.side(of: .browser), .hidden)
        XCTAssertTrue(layout.browserFloat.shown)
        layout.move(.browser, to: .right)
        XCTAssertFalse(layout.browserFloat.shown)
        layout.move(.browser, to: .hidden)
        XCTAssertFalse(layout.isBrowserShown)
    }

    func testRoundTripKeepsFloatState() throws {
        var layout = ToolLayout()
        layout.follow(session: "ad-aaaaaaaaaaaa")
        layout.showBrowserFloat()
        layout.browserFloat.frame = FloatFrame(right: 0.02, bottom: 0.1, width: 0.5, height: 0.6)
        var back = try JSONDecoder().decode(ToolLayout.self, from: XCTUnwrap(layout.data()))
        // 열림은 세션마다 파일에 남고, 지금 보임(shown)은 세션을 따라갈 때 정해진다
        XCTAssertFalse(back.browserFloat.shown)
        back.follow(session: "ad-aaaaaaaaaaaa")
        XCTAssertEqual(back.browserFloat, layout.browserFloat)
        XCTAssertEqual(back, layout)
    }

    /// 예전에 옆 도크에 붙여 쓰던 파일: 이제 작은 창으로 나온다(보이고 있었으면 작은 창을 띄움, 숨겨 뒀으면 숨김 유지)
    func testSavedSideDockMigratesToFloat() throws {
        func load(_ json: String) throws -> ToolLayout { try JSONDecoder().decode(ToolLayout.self, from: Data(json.utf8)) }
        let shown = try load(#"{"version":1,"tools":{"spaces":"left","files":"left","browser":"right"},"selected":{"left":"spaces","right":"browser"}}"#)
        XCTAssertEqual(shown.side(of: .browser), .hidden)
        XCTAssertFalse(shown.browserFloat.shown) // 열림은 세션마다 처음부터(예전 전역 값은 읽지 않는다)
        XCTAssertFalse(shown.isBrowserShown)
        XCTAssertNil(shown.visibleTool(in: .right))
        XCTAssertEqual(shown.visibleTool(in: .left), .spaces)
        // 도크에는 붙어 있었지만 다른 도구가 앞이라 안 보이던 브라우저는 숨김 그대로
        let behind = try load(#"{"version":1,"tools":{"spaces":"left","files":"left","browser":"left"},"selected":{"left":"files"}}"#)
        XCTAssertEqual(behind.side(of: .browser), .hidden)
        XCTAssertFalse(behind.browserFloat.shown)
        XCTAssertEqual(behind.visibleTool(in: .left), .files)
        // 저장된 작은 창 자리는 그대로, 다시 저장해 읽어도 도크로 돌아가지 않는다
        let framed = try load(#"{"version":1,"tools":{"browser":"left"},"selected":{"left":"browser"},"browserFloat":{"frame":{"right":0.02,"bottom":0.1,"width":0.5,"height":0.6}}}"#)
        XCTAssertFalse(framed.browserFloat.shown)
        XCTAssertEqual(framed.browserFloat.frame, FloatFrame(right: 0.02, bottom: 0.1, width: 0.5, height: 0.6))
        let again = try JSONDecoder().decode(ToolLayout.self, from: XCTUnwrap(framed.data()))
        XCTAssertEqual(again, framed)
    }

    /// 작은 창 정보가 없는 예전 파일·망가진 값
    func testOldAndBrokenFilesDecode() throws {
        let hidden = try JSONDecoder().decode(ToolLayout.self, from: Data(#"{"version":1,"tools":{"spaces":"left"}}"#.utf8))
        XCTAssertFalse(hidden.browserFloat.shown)
        XCTAssertNil(hidden.browserFloat.frame)
        let bad = #"{"version":1,"browserFloat":{"shown":true,"frame":{"right":-3,"bottom":0.1,"width":0.5,"height":0.5}}}"#
        let broken = try JSONDecoder().decode(ToolLayout.self, from: Data(bad.utf8))
        XCTAssertNil(broken.browserFloat.frame)
        XCTAssertFalse(broken.browserFloat.shown)
        // 도크에 붙어 있으면서 작은 창도 떠 있다고 적힌 파일: 한 곳(작은 창)만
        let both = #"{"version":1,"tools":{"browser":"left"},"browserFloat":{"shown":true}}"#
        let merged = try JSONDecoder().decode(ToolLayout.self, from: Data(both.utf8))
        XCTAssertEqual(merged.side(of: .browser), .hidden)
    }

    func testDefaultRectAnchorsAboveButton() {
        let rect = FloatSpec.browser.defaultRect(in: host, corner: .bottomRight, edgeInset: 56)
        XCTAssertEqual(rect.width, 450, accuracy: 0.01)
        XCTAssertEqual(rect.height, 455, accuracy: 0.01)
        XCTAssertEqual(rect.maxX, 1000 - 14, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 56, accuracy: 0.01)
    }

    func testRectIsClampedInsideHost() {
        // 최소 크기 이상, 호스트 안
        let small = FloatFrame(right: 0.1, bottom: 0.1, width: 0.1, height: 0.1).rect(in: host, spec: .browser)
        XCTAssertEqual(small.size, FloatSpec.browser.minSize)
        let out = FloatFrame(right: 0, bottom: 0.95, width: 0.5, height: 0.5).rect(in: host, spec: .browser)
        XCTAssertLessThanOrEqual(out.maxY, host.height)
        XCTAssertGreaterThanOrEqual(out.minY, 0)
        // 창이 줄어도 안에 남는다
        let narrow = CGSize(width: 500, height: 320)
        let moved = FloatFrame(right: 0.02, bottom: 0.1, width: 0.45, height: 0.65).rect(in: narrow, spec: .browser)
        XCTAssertTrue(CGRect(origin: .zero, size: narrow).contains(moved))
        // 최소 크기보다 작은 호스트는 호스트 크기까지만
        let tiny = FloatFrame(right: 0, bottom: 0, width: 0.5, height: 0.5).rect(in: CGSize(width: 300, height: 200), spec: .browser)
        XCTAssertEqual(tiny.size, CGSize(width: 300, height: 200))
    }

    func testFrameRatioRoundTrip() {
        let rect = CGRect(x: 120, y: 80, width: 500, height: 400)
        let frame = FloatFrame(rect: rect, in: host)
        XCTAssertEqual(frame.rect(in: host, spec: .browser).origin.x, rect.origin.x, accuracy: 0.01)
        XCTAssertEqual(frame.rect(in: host, spec: .browser).origin.y, rect.origin.y, accuracy: 0.01)
        XCTAssertEqual(frame.rect(in: host, spec: .browser).width, rect.width, accuracy: 0.01)
        // 호스트가 커지면 비율대로 커진다
        XCTAssertEqual(frame.rect(in: CGSize(width: 2000, height: 700), spec: .browser).width, 1000, accuracy: 0.01)
    }
}

/// 작은 창 열림·닫힘은 세션마다, 자리는 창 종류마다 하나
final class PerSessionFloatTests: XCTestCase {
    private let host = CGSize(width: 1000, height: 700)
    private func decode(_ json: String) throws -> ToolLayout { try JSONDecoder().decode(ToolLayout.self, from: Data(json.utf8)) }

    func testOpenStateFollowsSession() {
        var layout = ToolLayout()
        layout.follow(session: "ad-1")
        layout.showBrowserFloat()
        layout.toggleTerminalFloat()
        XCTAssertTrue(layout.browserFloat.shown)
        XCTAssertTrue(layout.terminalFloat.shown)
        layout.follow(session: "ad-2") // 두 번째 세션도 브라우저만 연다
        XCTAssertFalse(layout.browserFloat.shown)
        XCTAssertFalse(layout.terminalFloat.shown)
        layout.showBrowserFloat()
        layout.follow(session: "ad-3") // 새 세션: 둘 다 닫힘
        XCTAssertFalse(layout.isBrowserShown)
        XCTAssertFalse(layout.terminalFloat.shown)
        layout.follow(session: "ad-1")
        XCTAssertTrue(layout.browserFloat.shown)
        XCTAssertTrue(layout.terminalFloat.shown)
        layout.follow(session: "ad-2")
        XCTAssertTrue(layout.browserFloat.shown)
        XCTAssertFalse(layout.terminalFloat.shown)
    }

    func testClosingOnlyAffectsSelectedSession() {
        var layout = ToolLayout()
        for session in ["ad-1", "ad-2"] {
            layout.follow(session: session)
            layout.showBrowserFloat()
            layout.toggleTerminalFloat()
        }
        layout.toggle(.browser) // ⌘⇧B / ✕ : 지금(2번) 세션만 닫는다
        layout.toggleTerminalFloat()
        XCTAssertFalse(layout.isBrowserShown)
        XCTAssertFalse(layout.terminalFloat.shown)
        layout.follow(session: "ad-1")
        XCTAssertTrue(layout.browserFloat.shown)
        XCTAssertTrue(layout.terminalFloat.shown)
    }

    func testNoSessionStaysClosedAndKeepsNothing() {
        var layout = ToolLayout()
        layout.toggleTerminalFloat() // 세션이 없을 때 열어도 어느 세션 몫으로도 남지 않는다
        XCTAssertTrue(layout.terminalFloat.shown)
        layout.follow(session: "ad-1")
        XCTAssertFalse(layout.terminalFloat.shown)
        layout.follow(session: nil)
        XCTAssertFalse(layout.browserFloat.shown)
    }

    func testRoundTripAndPrune() throws {
        var layout = ToolLayout()
        for session in ["ad-1", "ad-2", "ad-3"] {
            layout.follow(session: session)
            layout.showBrowserFloat()
        }
        layout.follow(session: "ad-1")
        layout.toggleTerminalFloat()
        layout.terminalFloat.frame = FloatFrame(right: 0.4, bottom: 0.05, width: 0.55, height: 0.4)
        var back = try JSONDecoder().decode(ToolLayout.self, from: XCTUnwrap(layout.data()))
        XCTAssertEqual(back.browserFloat.openSessions, ["ad-1", "ad-2", "ad-3"])
        XCTAssertEqual(back.terminalFloat.openSessions, ["ad-1"])
        XCTAssertEqual(back.terminalFloat.frame, layout.terminalFloat.frame)
        back.prune(sessions: ["ad-1", "ad-3"]) // 없어진 세션(ad-2)의 기록은 지운다
        XCTAssertEqual(back.browserFloat.openSessions, ["ad-1", "ad-3"])
        back.follow(session: "ad-1")
        XCTAssertTrue(back.terminalFloat.shown)
    }

    /// 예전 파일(전역 shown·작은 터미널 정보 없음)과 망가진 값
    func testOldAndBrokenFilesDecode() throws {
        let old = try decode(#"{"version":1,"browserFloat":{"shown":true,"frame":{"right":0.02,"bottom":0.1,"width":0.45,"height":0.65}}}"#)
        XCTAssertFalse(old.browserFloat.shown)
        XCTAssertTrue(old.browserFloat.openSessions.isEmpty)
        XCTAssertNotNil(old.browserFloat.frame)
        XCTAssertNil(old.terminalFloat.frame)
        XCTAssertFalse(old.terminalFloat.shown)
        let broken = try decode(#"{"version":1,"terminalFloat":{"frame":{"right":-1,"bottom":0,"width":0.5,"height":0.5},"sessions":["","ad-1"]}}"#)
        XCTAssertNil(broken.terminalFloat.frame)
        XCTAssertEqual(broken.terminalFloat.openSessions, ["ad-1"])
    }

    func testTerminalDefaultIsBottomLeftAndMinSize() {
        let rect = FloatSpec.terminal.defaultRect(in: host, corner: .bottomRight, edgeInset: 14)
        XCTAssertEqual(rect.minX, 14, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 14, accuracy: 0.01)
        XCTAssertEqual(rect.width, 500, accuracy: 0.01)
        XCTAssertEqual(rect.height, 280, accuracy: 0.01)
        let browser = FloatSpec.browser.defaultRect(in: host, corner: .bottomRight, edgeInset: 70)
        XCTAssertLessThanOrEqual(rect.maxX, browser.minX) // 오른쪽 아래의 브라우저 처음 자리와 겹치지 않는다
        let small = FloatFrame(right: 0.5, bottom: 0.1, width: 0.1, height: 0.1).rect(in: host, spec: .terminal)
        XCTAssertEqual(small.size, CGSize(width: 360, height: 200))
        XCTAssertTrue(CGRect(origin: .zero, size: host).contains(FloatSpec.terminal.largeRect(in: host, corner: .bottomRight, edgeInset: 14)))
    }
}

final class FloatCornerTests: XCTestCase {
    /// 오른쪽 위: 탭 줄 28 + 버튼 줄(위 10 + 버튼 44) 아래 + 14 — 앱이 넘기는 값과 같은 식
    private let tabBar = 28.0, buttonTop = 10.0, button = 44.0
    private var inset: Double { tabBar + buttonTop + button + FloatSpec.margin }
    private func decode(_ json: String) throws -> ToolLayout { try JSONDecoder().decode(ToolLayout.self, from: Data(json.utf8)) }

    /// 버튼 줄(원점 왼쪽 아래 좌표): 호스트 위쪽에서 tabBar + 10 아래로 44pt, 오른쪽 22pt 안쪽에서 왼쪽으로 ⌨(44)·간격 8·🌐(알약이면 더 넓게)
    private func buttonRow(in host: CGSize, pillWidth: Double = 160) -> CGRect {
        let top = Double(host.height) - tabBar - buttonTop
        let width = pillWidth + 8 + button
        return CGRect(x: Double(host.width) - 22 - width, y: top - button, width: width, height: button)
    }

    func testTopRightDefaultsDoNotOverlapEachOtherOrButtons() {
        for host in [CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 900), CGSize(width: 800, height: 600)] {
            let bounds = CGRect(origin: .zero, size: host)
            let browser = FloatSpec.browser.defaultRect(in: host, corner: .topRight, edgeInset: inset)
            let terminal = FloatSpec.terminal.defaultRect(in: host, corner: .topRight, edgeInset: inset)
            XCTAssertTrue(bounds.contains(browser), "\(host)")
            XCTAssertTrue(bounds.contains(terminal), "\(host)")
            // 브라우저: 오른쪽 위(오른쪽 14, 버튼 줄 아래)
            XCTAssertEqual(browser.maxX, host.width - 14, accuracy: 0.01)
            XCTAssertEqual(browser.maxY, host.height - inset, accuracy: 0.01)
            XCTAssertEqual(browser.width, host.width * 0.45, accuracy: 0.01)
            // 작은 터미널: 같은 높이에서 브라우저 왼쪽, 겹치지 않는다
            XCTAssertEqual(terminal.maxY, host.height - inset, accuracy: 0.01)
            XCTAssertLessThanOrEqual(terminal.maxX, browser.minX - FloatSpec.gap + 0.01, "\(host)")
            XCTAssertFalse(terminal.intersects(browser), "\(host)")
            // 버튼 줄과 겹치지 않는다
            let row = buttonRow(in: host)
            XCTAssertFalse(browser.intersects(row), "\(host)")
            XCTAssertFalse(terminal.intersects(row), "\(host)")
            XCTAssertGreaterThanOrEqual(terminal.width, FloatSpec.terminal.minSize.width)
            XCTAssertGreaterThanOrEqual(browser.width, FloatSpec.browser.minSize.width)
        }
        // 1000×700: 터미널은 0.5 폭 그대로
        let terminal = FloatSpec.terminal.defaultRect(in: CGSize(width: 1000, height: 700), corner: .topRight, edgeInset: inset)
        XCTAssertEqual(terminal.width, 500, accuracy: 0.01) // 자리가 되면 0.5 폭 그대로(모자라면 줄어든다)
        XCTAssertEqual(terminal.height, 280, accuracy: 0.01)
    }

    func testTopRightLargeStaysInsideHostBelowButtons() {
        for host in [CGSize(width: 1000, height: 700), CGSize(width: 700, height: 500)] {
            let bounds = CGRect(origin: .zero, size: host)
            for spec in [FloatSpec.browser, .terminal] {
                let large = spec.largeRect(in: host, corner: .topRight, edgeInset: inset)
                XCTAssertTrue(bounds.contains(large), "\(host)")
                XCTAssertLessThanOrEqual(large.maxY, host.height - inset + 0.01)
                XCTAssertFalse(large.intersects(buttonRow(in: host)))
            }
        }
    }

    func testBottomRightIsUnchanged() {
        let host = CGSize(width: 1000, height: 700)
        let browser = FloatSpec.browser.defaultRect(in: host, corner: .bottomRight, edgeInset: 70)
        XCTAssertEqual(browser, CGRect(x: 1000 - 14 - 450, y: 70, width: 450, height: 455))
        let terminal = FloatSpec.terminal.defaultRect(in: host, corner: .bottomRight, edgeInset: 14)
        XCTAssertEqual(terminal, CGRect(x: 14, y: 14, width: 500, height: 280))
        XCTAssertEqual(FloatSpec.browser.largeRect(in: host, corner: .bottomRight, edgeInset: 70),
                       FloatSpec.browser.clamp(CGRect(x: 1000 - 14 - 800, y: 70, width: 800, height: 616), in: host))
    }

    func testSavedFrameRoundTripsAsHostFractions() {
        // 오른쪽 위 기본 자리를 비율로 저장했다가 같은 호스트에서 같은 자리로
        let host = CGSize(width: 1000, height: 700)
        let rect = FloatSpec.browser.defaultRect(in: host, corner: .topRight, edgeInset: inset)
        let frame = FloatFrame(rect: rect, in: host)
        let back = frame.rect(in: host, spec: .browser)
        XCTAssertEqual(back.minX, rect.minX, accuracy: 0.01)
        XCTAssertEqual(back.minY, rect.minY, accuracy: 0.01)
        // 작아진 호스트에서도 안에 남는다
        let small = CGSize(width: 500, height: 400)
        XCTAssertTrue(CGRect(origin: .zero, size: small).contains(frame.rect(in: small, spec: .browser)))
    }

    func testSettingDefaultsToTopRightAndToleratesBadValues() throws {
        XCTAssertEqual(ToolLayout().floatCorner, .topRight)
        XCTAssertEqual(try decode(#"{"version":1}"#).floatCorner, .topRight)
        XCTAssertEqual(try decode(#"{"version":1,"floatCorner":"nowhere"}"#).floatCorner, .topRight)
        XCTAssertEqual(try decode(#"{"version":1,"floatCorner":"bottomRight"}"#).floatCorner, .bottomRight)
        XCTAssertEqual(try decode(#"{"version":1,"floatCorner":"topRight"}"#).floatCorner, .topRight)
        // 저장 → 읽기
        var layout = ToolLayout()
        layout.setFloatCorner(.bottomRight)
        let data = try XCTUnwrap(layout.data())
        XCTAssertEqual(try JSONDecoder().decode(ToolLayout.self, from: data).floatCorner, .bottomRight)
    }

    func testChangingCornerClearsFramesButKeepsOpenSessions() throws {
        var layout = ToolLayout()
        layout.browserFloat.follow("ad-1")
        layout.browserFloat.setShown(true)
        layout.browserFloat.frame = FloatFrame(right: 0.02, bottom: 0.1, width: 0.45, height: 0.65)
        layout.terminalFloat.frame = FloatFrame(right: 0.5, bottom: 0.1, width: 0.5, height: 0.4)
        layout.setFloatCorner(.bottomRight)
        XCTAssertNil(layout.browserFloat.frame)
        XCTAssertNil(layout.terminalFloat.frame)
        XCTAssertTrue(layout.browserFloat.shown)
        XCTAssertEqual(layout.browserFloat.openSessions, ["ad-1"])
        // 같은 값으로 "바꿔도" 자리는 그대로
        layout.browserFloat.frame = FloatFrame(right: 0.02, bottom: 0.1, width: 0.45, height: 0.65)
        layout.setFloatCorner(.bottomRight)
        XCTAssertNotNil(layout.browserFloat.frame)
    }
}

final class ScratchPaneTests: XCTestCase {
    func testIdRoundTrip() {
        let id = ScratchPane.id(owner: "ABC-123")
        XCTAssertTrue(ScratchPane.isScratch(id))
        XCTAssertEqual(ScratchPane.owner(of: id), "ABC-123")
        XCTAssertFalse(ScratchPane.isScratch("ABC-123"))
        XCTAssertNil(ScratchPane.owner(of: "ABC-123"))
        XCTAssertNil(ScratchPane.owner(of: "scratch-"))
    }

    func testSplitKeepsOrderAndSeparates() {
        let ids = ["a", ScratchPane.id(owner: "a"), "b", ScratchPane.id(owner: "b")]
        let (regular, scratch) = ScratchPane.split(ids) { $0 }
        XCTAssertEqual(regular, ["a", "b"])
        XCTAssertEqual(scratch, ["scratch-a", "scratch-b"])
    }

    func testOrphansAreScratchWithoutLiveOwner() {
        let scratch = [ScratchPane.id(owner: "a"), ScratchPane.id(owner: "gone"), "scratch-"]
        XCTAssertEqual(ScratchPane.orphans(scratch, liveOwners: ["a", "b"]), ["scratch-gone", "scratch-"])
    }
}


final class ScratchShellTrackerTests: XCTestCase {
    private let id = ScratchPane.id(owner: "a")
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func tracker() -> ScratchShellTracker { ScratchShellTracker(timeout: 15) }

    func testPendingCreateCountsAsExistingUntilListedOrTimeout() {
        var t = tracker()
        XCTAssertFalse(t.exists(id, listed: false, now: t0))
        t.requestCreate(id, now: t0)
        XCTAssertTrue(t.exists(id, listed: false, now: t0 + 5))
        XCTAssertFalse(t.exists(id, listed: false, now: t0 + 16)) // 시간 초과
        t.reconcile(listed: [id], now: t0 + 2)
        XCTAssertTrue(t.exists(id, listed: true, now: t0 + 3)) // 목록에 나타남
        XCTAssertFalse(t.exists(id, listed: false, now: t0 + 3)) // 기록은 지워졌다
    }

    func testEndBeforeListedClearsPendingSoReopenCreatesFresh() {
        var t = tracker()
        t.requestCreate(id, now: t0)
        t.requestEnd(id, now: t0 + 1) // 목록에 나타나기 전에 끝내기
        XCTAssertFalse(t.exists(id, listed: false, now: t0 + 2))
        // 만들기가 큐에서 먼저 처리돼 목록에 옛 셸이 잠깐 보여도 "있는 셈"이 아니다 → 다시 열면 새로 만든다
        XCTAssertFalse(t.exists(id, listed: true, now: t0 + 2))
        // 목록에서 사라지면 끝난 것
        t.reconcile(listed: [], now: t0 + 3)
        XCTAssertFalse(t.exists(id, listed: false, now: t0 + 3))
        XCTAssertTrue(t.exists(id, listed: true, now: t0 + 3)) // 이제 목록의 항목은 새 셸
    }

    func testReopenWhileOldShellStillListedRecreatesAfterItExits() {
        var t = tracker()
        t.requestEnd(id, now: t0)
        t.requestCreate(id, now: t0 + 1) // 옛 셸이 아직 있을 때 다시 열어 만들기를 보냄(데몬이 무시)
        XCTAssertTrue(t.exists(id, listed: true, now: t0 + 1))
        t.reconcile(listed: [id], now: t0 + 2) // 아직 옛 셸이 목록에 있다
        XCTAssertTrue(t.exists(id, listed: true, now: t0 + 2))
        XCTAssertTrue(t.exited(id)) // 옛 셸이 죽음 → 다시 만들라고 보내야 한다
        XCTAssertFalse(t.exited(id))
    }

    func testExitWithoutRecreateClearsRecords() {
        var t = tracker()
        t.requestCreate(id, now: t0)
        XCTAssertFalse(t.exited(id))
        XCTAssertFalse(t.exists(id, listed: false, now: t0 + 1))
        t.requestEnd(id, now: t0)
        XCTAssertFalse(t.exited(id))
        XCTAssertTrue(t.exists(id, listed: true, now: t0 + 1)) // 끝내기 기록도 지워졌다
    }

    func testResetDropsEverythingAfterDisconnect() {
        var t = tracker()
        t.requestCreate(id, now: t0)
        t.requestEnd(ScratchPane.id(owner: "b"), now: t0)
        t.reset()
        XCTAssertFalse(t.exists(id, listed: false, now: t0 + 1))
        XCTAssertTrue(t.exists(ScratchPane.id(owner: "b"), listed: true, now: t0 + 1))
    }
}

/// 다시 켜도 세션마다 열림이 남는다: 파일 읽기 → 시작 직후의 정리(따라가기·목록 맞추기) → 다시 저장해도 그대로
final class FloatRelaunchTests: XCTestCase {
    private func decode(_ data: Data) throws -> ToolLayout { try JSONDecoder().decode(ToolLayout.self, from: data) }

    private func openedBoth(session: String) -> ToolLayout {
        var layout = ToolLayout()
        layout.follow(session: session)
        layout.showBrowserFloat()
        layout.toggleTerminalFloat()
        return layout
    }

    /// 실제 파일 모양(관측: browserFloat·terminalFloat 모두 sessions 만, tools.browser = hidden)
    func testRealFileShapeRestoresBothKindsOnFollow() throws {
        let json = #"""
        {"version":1,"floatCorner":"topRight","tools":{"browser":"hidden","files":"left","spaces":"left"},
         "lastSides":{"browser":"right","files":"left","spaces":"left"},"selected":{"left":"spaces"},
         "widths":{"left":260,"right":280},
         "browserFloat":{"sessions":["ad-1769d88f6da7"]},"terminalFloat":{"sessions":["ad-1769d88f6da7"]}}
        """#
        var layout = try decode(Data(json.utf8))
        XCTAssertEqual(layout.browserFloat.openSessions, ["ad-1769d88f6da7"])
        XCTAssertFalse(layout.browserFloat.shown) // 세션을 고르기 전에는 안 보인다
        layout.follow(session: "ad-1769d88f6da7")
        XCTAssertTrue(layout.browserFloat.shown)
        XCTAssertTrue(layout.terminalFloat.shown)
    }

    /// 시작 직후 일어나는 일들(세션 없음 → 세션 고르기 → 목록 맞추기 → 구조 정리 → 저장)이 열림 기록을 지우지 않는다
    func testStartupChurnKeepsOpenRecords() throws {
        var layout = try decode(XCTUnwrap(openedBoth(session: "ad-1").data()))
        layout.follow(session: nil)              // 도크가 세션을 놓았다 다시 따라감(연결 끊김·되살리기)
        layout.prune(sessions: [])               // 아직 목록을 못 받음 → 지우지 않는다
        layout.follow(session: "ad-1")
        layout.normalize()
        layout.move(.browser, to: .right)        // 도크로 옮겨 봤다가(시험 명령) 화면에서만 내려간다
        layout.move(.spaces, to: .left)          // 다른 도구의 구조 정리
        layout.prune(sessions: ["ad-1", "ad-2"])
        XCTAssertEqual(layout.browserFloat.openSessions, ["ad-1"])
        XCTAssertEqual(layout.terminalFloat.openSessions, ["ad-1"])
        let again = try decode(XCTUnwrap(layout.data()))
        XCTAssertEqual(again.browserFloat.openSessions, ["ad-1"])
        XCTAssertEqual(again.terminalFloat.openSessions, ["ad-1"])
    }

    /// 사람이 닫은 것만 기록에서 지운다: 숨기기(✕·🌐·⌘W)는 그 세션 몫만 지우고, 도크로 옮기기·정리는 지우지 않는다
    func testOnlyAnExplicitCloseForgetsASession() {
        var layout = openedBoth(session: "ad-1")
        layout.follow(session: "ad-2")
        layout.showBrowserFloat()
        layout.move(.browser, to: .left) // 도크로: 화면에서만 내림
        XCTAssertFalse(layout.browserFloat.shown)
        XCTAssertEqual(layout.browserFloat.openSessions, ["ad-1", "ad-2"])
        layout.move(.browser, to: .hidden) // 숨기기: 지금 세션(ad-2)의 기록만 지운다
        XCTAssertEqual(layout.browserFloat.openSessions, ["ad-1"])
        layout.follow(session: "ad-1")
        XCTAssertTrue(layout.browserFloat.shown)
    }

    func testPruneForgetsClosedSessionsButNeverWithoutAList() {
        var layout = openedBoth(session: "ad-1")
        layout.follow(session: "ad-2")
        layout.showBrowserFloat()
        layout.prune(sessions: [])
        XCTAssertEqual(layout.browserFloat.openSessions, ["ad-1", "ad-2"])
        layout.prune(sessions: ["ad-2"]) // ad-1 은 닫힌 세션
        XCTAssertEqual(layout.browserFloat.openSessions, ["ad-2"])
        XCTAssertTrue(layout.terminalFloat.openSessions.isEmpty)
    }

    /// 예전 파일의 shown·prefersFloat 는 읽지 않고, 같은 파일의 세션 기록은 그대로 읽는다
    func testOldFieldsDoNotWipeSessions() throws {
        let json = #"{"version":1,"browserFloat":{"shown":false,"prefersFloat":true,"sessions":["ad-9"]},"terminalFloat":{"shown":true,"sessions":["ad-9"]}}"#
        var layout = try decode(Data(json.utf8))
        layout.follow(session: "ad-9")
        XCTAssertTrue(layout.browserFloat.shown)
        XCTAssertTrue(layout.terminalFloat.shown)
    }
}

/// 작은 터미널의 기본 자리: 브라우저가 안 보이면 구석에 혼자, 보이면 브라우저 왼쪽, 저장된 자리는 그대로
final class TerminalDefaultPlacementTests: XCTestCase {
    private let tabBar = 28.0, buttonTop = 10.0, button = 44.0
    private var topInset: Double { tabBar + buttonTop + button + FloatSpec.margin }
    private let bottomBrowserInset = 12 + 44 + FloatSpec.margin

    func testAloneHugsTheCornerWithTheBrowsersInsets() {
        for host in [CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 900), CGSize(width: 800, height: 600)] {
            let top = FloatSpec.terminal.defaultRect(in: host, corner: .topRight, edgeInset: topInset, besideBrowser: false)
            XCTAssertEqual(top.maxX, host.width - FloatSpec.margin, accuracy: 0.01, "\(host)")
            XCTAssertEqual(top.maxY, host.height - topInset, accuracy: 0.01, "\(host)")
            XCTAssertEqual(top.width, max(host.width * 0.5, 360), accuracy: 0.01)
            XCTAssertTrue(CGRect(origin: .zero, size: host).contains(top))
            let bottom = FloatSpec.terminal.defaultRect(in: host, corner: .bottomRight, edgeInset: bottomBrowserInset, besideBrowser: false)
            XCTAssertEqual(bottom.maxX, host.width - FloatSpec.margin, accuracy: 0.01, "\(host)")
            XCTAssertEqual(bottom.minY, bottomBrowserInset, accuracy: 0.01, "\(host)")
            XCTAssertTrue(CGRect(origin: .zero, size: host).contains(bottom))
            // 브라우저 처음 자리와 같은 구석(오른쪽 가장자리·같은 세로 기준)
            let browserTop = FloatSpec.browser.defaultRect(in: host, corner: .topRight, edgeInset: topInset)
            XCTAssertEqual(top.maxX, browserTop.maxX, accuracy: 0.01)
            XCTAssertEqual(top.maxY, browserTop.maxY, accuracy: 0.01)
            let browserBottom = FloatSpec.browser.defaultRect(in: host, corner: .bottomRight, edgeInset: bottomBrowserInset)
            XCTAssertEqual(bottom.maxX, browserBottom.maxX, accuracy: 0.01)
            XCTAssertEqual(bottom.minY, browserBottom.minY, accuracy: 0.01)
        }
    }

    func testBesideBrowserIsLeftOfItWithoutOverlap() {
        for host in [CGSize(width: 1000, height: 700), CGSize(width: 1440, height: 900), CGSize(width: 800, height: 600)] {
            let topBrowser = FloatSpec.browser.defaultRect(in: host, corner: .topRight, edgeInset: topInset)
            let top = FloatSpec.terminal.defaultRect(in: host, corner: .topRight, edgeInset: topInset, besideBrowser: true)
            XCTAssertLessThanOrEqual(top.maxX, topBrowser.minX - FloatSpec.gap + 0.01, "\(host)")
            XCTAssertFalse(top.intersects(topBrowser))
            let bottomBrowser = FloatSpec.browser.defaultRect(in: host, corner: .bottomRight, edgeInset: bottomBrowserInset)
            let bottom = FloatSpec.terminal.defaultRect(in: host, corner: .bottomRight, edgeInset: FloatSpec.margin, besideBrowser: true)
            XCTAssertLessThanOrEqual(bottom.maxX, bottomBrowser.minX + 0.01, "\(host)")
            XCTAssertFalse(bottom.intersects(bottomBrowser))
        }
    }

    func testLargeModeIsIndependentOfTheBrowser() {
        let host = CGSize(width: 1000, height: 700)
        for corner in [FloatCorner.topRight, .bottomRight] {
            let large = FloatSpec.terminal.largeRect(in: host, corner: corner, edgeInset: topInset)
            XCTAssertEqual(large.minX, FloatSpec.margin, accuracy: 0.01) // 예전과 같다: 왼쪽 기준
        }
    }

    func testLayoutPicksAloneBesideOrSaved() {
        let host = CGSize(width: 1000, height: 700)
        var layout = ToolLayout()
        layout.follow(session: "ad-1")
        layout.toggleTerminalFloat()
        XCTAssertEqual(layout.terminalRectKind, .defaultAlone)
        let alone = layout.terminalRect(in: host, browserEdgeInset: topInset, terminalEdgeInset: topInset)
        XCTAssertEqual(alone.maxX, host.width - FloatSpec.margin, accuracy: 0.01)
        layout.showBrowserFloat() // 브라우저가 열림 → 나란히
        XCTAssertEqual(layout.terminalRectKind, .defaultBeside)
        let beside = layout.terminalRect(in: host, browserEdgeInset: topInset, terminalEdgeInset: topInset)
        let browser = FloatSpec.browser.defaultRect(in: host, corner: .topRight, edgeInset: topInset)
        XCTAssertFalse(beside.intersects(browser))
        XCTAssertLessThan(beside.maxX, alone.maxX)
        layout.follow(session: "ad-2") // 다른 세션: 브라우저가 닫혀 있다
        XCTAssertEqual(layout.terminalRectKind, .defaultAlone)
        layout.toggle(.browser)
        layout.toggle(.browser) // 열었다 닫음
        XCTAssertEqual(layout.terminalRectKind, .defaultAlone)
    }

    func testSavedFrameIsNeverMovedByTheBrowser() {
        let host = CGSize(width: 1000, height: 700)
        var layout = ToolLayout()
        layout.follow(session: "ad-1")
        layout.toggleTerminalFloat()
        let frame = FloatFrame(right: 0.3, bottom: 0.2, width: 0.4, height: 0.35)
        layout.terminalFloat.frame = frame
        let before = layout.terminalRect(in: host, browserEdgeInset: topInset, terminalEdgeInset: topInset)
        XCTAssertEqual(layout.terminalRectKind, .saved)
        layout.showBrowserFloat()
        XCTAssertEqual(layout.terminalRectKind, .saved)
        XCTAssertEqual(layout.terminalRect(in: host, browserEdgeInset: topInset, terminalEdgeInset: topInset), before)
        layout.toggle(.browser)
        XCTAssertEqual(layout.terminalRect(in: host, browserEdgeInset: topInset, terminalEdgeInset: topInset), before)
        XCTAssertEqual(before, frame.rect(in: host, spec: .terminal))
    }
}
