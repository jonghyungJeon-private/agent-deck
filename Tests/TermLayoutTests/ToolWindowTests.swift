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
