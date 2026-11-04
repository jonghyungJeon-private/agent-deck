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
        layout.showBrowserFloat()
        layout.browserFloat.frame = BrowserFloatFrame(right: 0.02, bottom: 0.1, width: 0.5, height: 0.6)
        let back = try JSONDecoder().decode(ToolLayout.self, from: XCTUnwrap(layout.data()))
        XCTAssertEqual(back.browserFloat, layout.browserFloat)
        XCTAssertEqual(back, layout)
    }

    /// 예전에 옆 도크에 붙여 쓰던 파일: 이제 작은 창으로 나온다(보이고 있었으면 작은 창을 띄움, 숨겨 뒀으면 숨김 유지)
    func testSavedSideDockMigratesToFloat() throws {
        func load(_ json: String) throws -> ToolLayout { try JSONDecoder().decode(ToolLayout.self, from: Data(json.utf8)) }
        let shown = try load(#"{"version":1,"tools":{"spaces":"left","files":"left","browser":"right"},"selected":{"left":"spaces","right":"browser"}}"#)
        XCTAssertEqual(shown.side(of: .browser), .hidden)
        XCTAssertTrue(shown.browserFloat.shown)
        XCTAssertTrue(shown.isBrowserShown)
        XCTAssertNil(shown.visibleTool(in: .right))
        XCTAssertEqual(shown.visibleTool(in: .left), .spaces)
        // 도크에는 붙어 있었지만 다른 도구가 앞이라 안 보이던 브라우저는 숨김 그대로
        let behind = try load(#"{"version":1,"tools":{"spaces":"left","files":"left","browser":"left"},"selected":{"left":"files"}}"#)
        XCTAssertEqual(behind.side(of: .browser), .hidden)
        XCTAssertFalse(behind.browserFloat.shown)
        XCTAssertEqual(behind.visibleTool(in: .left), .files)
        // 저장된 작은 창 자리는 그대로, 다시 저장해 읽어도 도크로 돌아가지 않는다
        let framed = try load(#"{"version":1,"tools":{"browser":"left"},"selected":{"left":"browser"},"browserFloat":{"frame":{"right":0.02,"bottom":0.1,"width":0.5,"height":0.6}}}"#)
        XCTAssertTrue(framed.browserFloat.shown)
        XCTAssertEqual(framed.browserFloat.frame, BrowserFloatFrame(right: 0.02, bottom: 0.1, width: 0.5, height: 0.6))
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
        XCTAssertTrue(broken.browserFloat.shown)
        // 도크에 붙어 있으면서 작은 창도 떠 있다고 적힌 파일: 한 곳(작은 창)만
        let both = #"{"version":1,"tools":{"browser":"left"},"browserFloat":{"shown":true}}"#
        let merged = try JSONDecoder().decode(ToolLayout.self, from: Data(both.utf8))
        XCTAssertTrue(merged.browserFloat.shown)
        XCTAssertEqual(merged.side(of: .browser), .hidden)
    }

    func testDefaultRectAnchorsAboveButton() {
        let rect = BrowserFloatFrame.defaultRect(in: host, bottomInset: 56)
        XCTAssertEqual(rect.width, 450, accuracy: 0.01)
        XCTAssertEqual(rect.height, 455, accuracy: 0.01)
        XCTAssertEqual(rect.maxX, 1000 - 14, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 56, accuracy: 0.01)
    }

    func testRectIsClampedInsideHost() {
        // 최소 크기 이상, 호스트 안
        let small = BrowserFloatFrame(right: 0.1, bottom: 0.1, width: 0.1, height: 0.1).rect(in: host)
        XCTAssertEqual(small.size, BrowserFloatFrame.minSize)
        let out = BrowserFloatFrame(right: 0, bottom: 0.95, width: 0.5, height: 0.5).rect(in: host)
        XCTAssertLessThanOrEqual(out.maxY, host.height)
        XCTAssertGreaterThanOrEqual(out.minY, 0)
        // 창이 줄어도 안에 남는다
        let narrow = CGSize(width: 500, height: 320)
        let moved = BrowserFloatFrame(right: 0.02, bottom: 0.1, width: 0.45, height: 0.65).rect(in: narrow)
        XCTAssertTrue(CGRect(origin: .zero, size: narrow).contains(moved))
        // 최소 크기보다 작은 호스트는 호스트 크기까지만
        let tiny = BrowserFloatFrame(right: 0, bottom: 0, width: 0.5, height: 0.5).rect(in: CGSize(width: 300, height: 200))
        XCTAssertEqual(tiny.size, CGSize(width: 300, height: 200))
    }

    func testFrameRatioRoundTrip() {
        let rect = CGRect(x: 120, y: 80, width: 500, height: 400)
        let frame = BrowserFloatFrame(rect: rect, in: host)
        XCTAssertEqual(frame.rect(in: host).origin.x, rect.origin.x, accuracy: 0.01)
        XCTAssertEqual(frame.rect(in: host).origin.y, rect.origin.y, accuracy: 0.01)
        XCTAssertEqual(frame.rect(in: host).width, rect.width, accuracy: 0.01)
        // 호스트가 커지면 비율대로 커진다
        XCTAssertEqual(frame.rect(in: CGSize(width: 2000, height: 700)).width, 1000, accuracy: 0.01)
    }
}
