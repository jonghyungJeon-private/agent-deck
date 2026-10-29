import XCTest
@testable import TermWire

final class BrowserBindingTests: XCTestCase {
    func testNamesComeFromThePaneIdAndStayShort() {
        let pane = "3F2A9C1B-0000-4000-8000-ABCDEFABCDEF"
        XCTAssertEqual(BrowserBinding.sessionName(pane: pane), "ad-3f2a9c1b0000")
        let term = URL(fileURLWithPath: "/Users/someone/Library/Application Support/AgentDeck/term")
        let env = BrowserBinding.environment(pane: pane, termDir: term, browser: nil)
        XCTAssertEqual(env["ABX_SESSION"], "ad-3f2a9c1b0000")
        XCTAssertEqual(env["ABX_PROFILE_DIR"], term.path + "/abx-profiles/ad-3f2a9c1b0000")
        XCTAssertEqual(env["ABX_STATE_DIR"], term.path + "/abx/state")
        XCTAssertEqual(env["ABX_HEADLESS"], "1")
        XCTAssertNil(env["ABX_BROWSER"])
        // 엔진 소켓(<socketDir>/<session>.sock)과 잠금 소켓이 유닉스 소켓 길이 한도(104) 안
        XCTAssertLessThan((env["ABX_SOCKET_DIR"]! + "/ad-3f2a9c1b0000.lock.sock").utf8.count, 104)
    }

    func testLongTermPathFallsBackToAShortSocketDir() {
        let long = URL(fileURLWithPath: "/Users/" + String(repeating: "x", count: 60) + "/Library/Application Support/AgentDeck/term")
        let dir = BrowserBinding.socketDir(termDir: long, temporary: "/var/folders/ab/cd/T/")
        XCTAssertTrue(dir.path.hasPrefix("/var/folders/ab/cd/T/agentdeck-abx-"))
        XCTAssertLessThan((dir.path + "/" + BrowserBinding.longestSocketName).utf8.count, 104)
        // 같은 term 폴더면 늘 같은 곳(앱과 데몬이 따로 계산해도 맞는다)
        XCTAssertEqual(dir, BrowserBinding.socketDir(termDir: long, temporary: "/var/folders/ab/cd/T/"))
        // 상태 파일은 길이 한도가 없으니 term 아래 그대로
        XCTAssertEqual(BrowserBinding.environment(pane: "A", termDir: long, browser: nil)["ABX_STATE_DIR"], long.path + "/abx/state")
    }

    func testBrowserChoiceIsLeftToAbxUnlessPinned() throws {
        let env = BrowserBinding.environment(pane: "A", termDir: URL(fileURLWithPath: "/t"), browser: nil,
                                             browsersDir: URL(fileURLWithPath: "/h/.abx/browsers"))
        XCTAssertEqual(env["ABX_BROWSERS_DIR"], "/h/.abx/browsers")
        XCTAssertNil(env["ABX_BROWSER"])
        XCTAssertEqual(BrowserBinding.environment(pane: "A", browser: "/bin/sh")["ABX_BROWSER"], "/bin/sh")
        XCTAssertEqual(BrowserBinding.explicitBrowser(environment: ["AGENTDECK_BROWSER": "/bin/sh"]), "/bin/sh")
        XCTAssertNil(BrowserBinding.explicitBrowser(environment: ["AGENTDECK_BROWSER": "/nope"]))
        XCTAssertNil(BrowserBinding.explicitBrowser(environment: [:]))
    }

    func testShimRunsTheAppsAbx() throws {
        let term = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: term) }
        // 따옴표가 든 경로도 그대로 실행한다
        let target = term.appendingPathComponent("it's/abx")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"abx:$*\"\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let dir = try XCTUnwrap(BrowserBinding.installShim(abx: target, termDir: term))
        let process = Process()
        process.executableURL = dir.appendingPathComponent("abx")
        process.arguments = ["open", "a b"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "abx:open a b\n")
        XCTAssertNil(BrowserBinding.installShim(abx: nil, termDir: term))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("abx").path))
    }

    func testBundledAbxAndPath() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/X.app/Contents")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let helper = app.appendingPathComponent("Helpers/abx")
        FileManager.default.createFile(atPath: helper.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let daemon = app.appendingPathComponent("MacOS/AgentDeckDaemon")
        XCTAssertEqual(BrowserBinding.bundledAbx(environment: [:], executable: daemon)?.resolvingSymlinksInPath().path,
                       helper.resolvingSymlinksInPath().path)
        XCTAssertEqual(BrowserBinding.bundledAbx(environment: ["AGENTDECK_ABX": "/bin/sh"], executable: daemon)?.path, "/bin/sh")
        XCTAssertNil(BrowserBinding.bundledAbx(environment: [:], executable: URL(fileURLWithPath: "/usr/bin/true")))
        let bin = URL(fileURLWithPath: "/t/bin")
        XCTAssertEqual(BrowserBinding.prependPath(bin, to: "/usr/bin:/t/bin:/bin"), "/t/bin:/usr/bin:/bin")
        XCTAssertEqual(BrowserBinding.prependPath(bin, to: nil), "/t/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
