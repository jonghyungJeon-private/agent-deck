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

    func testChromeForTestingPicksTheNewestInstalledVersion() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for version in ["99.0.1.2", "156.0.8078.73"] {
            let dir = home.appendingPathComponent(".abx/browsers/\(version)/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bin = dir.appendingPathComponent("Google Chrome for Testing")
            FileManager.default.createFile(atPath: bin.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        XCTAssertTrue(BrowserBinding.chromeForTesting(environment: [:], home: home)?.contains("/156.0.8078.73/") ?? false)
        XCTAssertNil(BrowserBinding.chromeForTesting(environment: [:], home: home.appendingPathComponent("none")))
    }
}
