import Foundation
import XCTest
@testable import SessionCore

/// 앱을 지우거나 옮겨도 hook 이 오류를 내지 않게 하는 가드 형태와 그 갱신·제거
final class GuardedHookTests: XCTestCase {
    var dir: URL!
    var settings: URL { dir.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func json() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    }

    func commands(_ event: String) throws -> [String] {
        let groups = (try json()["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testGuardedCommandFormat() {
        let installer = HookInstaller.claude(daemonPath: "/Applications/AgentDeck.app/Contents/MacOS/ClaudeTermDaemon",
                                             settingsURL: settings)
        XCTAssertEqual(installer.command,
                       #"[ -x "/Applications/AgentDeck.app/Contents/MacOS/ClaudeTermDaemon" ] || exit 0; "#
                       + #"exec "/Applications/AgentDeck.app/Contents/MacOS/ClaudeTermDaemon" hook"#)
        let codex = HookInstaller.codex(daemonPath: "/a b/ClaudeTermDaemon", hooksURL: settings)
        XCTAssertEqual(codex.command, #"[ -x "/a b/ClaudeTermDaemon" ] || exit 0; exec "/a b/ClaudeTermDaemon" codex-hook"#)
    }

    func testEscapingAppliesToBothOccurrences() {
        let path = #"/x/we"ird $HOME `id` \b/ClaudeTermDaemon"#
        let command = HookInstaller.claude(daemonPath: path, settingsURL: settings).command
        let quoted = #""/x/we\"ird \$HOME \`id\` \\b/ClaudeTermDaemon""#
        XCTAssertEqual(command, "[ -x \(quoted) ] || exit 0; exec \(quoted) hook")
        XCTAssertEqual(HookInstaller.executablePath(in: command), path)
        XCTAssertEqual(HookInstaller.executablePath(in: HookInstaller.unguardedCommand(path, "hook")), path)
    }

    func testIsOursForNewOldAndLegacy() {
        let term = HookInstaller.claude(daemonPath: "/A/ClaudeTermDaemon", settingsURL: settings)
        XCTAssertTrue(term.isOurs(term.command))
        XCTAssertTrue(term.isOurs(HookInstaller.unguardedCommand("/old place/ClaudeTerm.app/Contents/MacOS/ClaudeTermDaemon", "hook")))
        XCTAssertTrue(term.isOurs(HookInstaller.guardedCommand("/elsewhere/ClaudeTermDaemon", "hook")))
        XCTAssertFalse(term.isOurs(HookInstaller.guardedCommand("/A/ClaudeTermDaemon", "codex-hook")), "Codex 것은 다른 하위 명령")
        XCTAssertFalse(term.isOurs(#""/Applications/ClaudeSessions.app/Contents/MacOS/ClaudeSessions" hook"#))
        XCTAssertFalse(term.isOurs("rtk hook claude"))
        let legacy = HookInstaller(settingsURL: settings, executablePath: "/Applications/ClaudeSessions.app/Contents/MacOS/ClaudeSessions")
        XCTAssertTrue(legacy.isOurs(#""/Applications/ClaudeSessions.app/Contents/MacOS/ClaudeSessions" hook"#))
        XCTAssertTrue(legacy.isOurs(legacy.command))
    }

    /// 0.1 이 넣은 가드 없는 hook → outdated(갱신하기) → 갱신하면 가드 형태로 바뀌고 다른 hook 은 그대로
    func testUpgradeReplacesUnguardedWithoutTouchingOthers() throws {
        let daemon = "/Applications/ClaudeTerm.app/Contents/MacOS/ClaudeTermDaemon"
        var hooks: [String: Any] = [:]
        for event in HookInstaller.events {
            hooks[event] = [["hooks": [["type": "command", "command": HookInstaller.unguardedCommand(daemon, "hook"), "timeout": 10]]]]
        }
        hooks["Stop"] = (hooks["Stop"] as! [Any]) + [["hooks": [["type": "command", "command": "say done"]]]]
        hooks["PreToolUse"] = [["matcher": "Bash", "hooks": [["type": "command", "command": "rtk hook claude"]]]]
        try JSONSerialization.data(withJSONObject: ["model": "opus", "hooks": hooks]).write(to: settings)

        let moved = HookInstaller.claude(daemonPath: "/Applications/AgentDeck.app/Contents/MacOS/ClaudeTermDaemon", settingsURL: settings)
        XCTAssertEqual(try moved.status(), .outdated, "가드 없는 예전 형태·다른 경로는 갱신 대상")
        let same = HookInstaller.claude(daemonPath: daemon, settingsURL: settings)
        XCTAssertEqual(try same.status(), .outdated, "같은 경로라도 가드가 없으면 갱신 대상")
        XCTAssertEqual(try moved.installedExecutablePaths(), Array(repeating: daemon, count: HookInstaller.events.count))
        XCTAssertTrue(try moved.needsRepair(), "예전 경로 파일이 없으면 고칠 대상")

        let backup = try moved.install()
        XCTAssertNotNil(backup)
        XCTAssertTrue(backup!.lastPathComponent.hasPrefix("settings.json.claudeterm-backup-"))
        XCTAssertEqual(try moved.status(), .installed)
        for event in HookInstaller.events {
            XCTAssertEqual(try commands(event).filter(moved.isOurs), [moved.command], event)
        }
        XCTAssertEqual(try commands("Stop").filter { !moved.isOurs($0) }, ["say done"])
        XCTAssertEqual(try commands("PreToolUse"), ["rtk hook claude"])
        XCTAssertEqual(try json()["model"] as? String, "opus")
    }

    func testUninstallRemovesOnlyOursAndLeavesFileWhenNothingToDo() throws {
        let original = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],"#
            + #""PostToolUse":[{"hooks":[{"type":"command","command":"\"/old/ClaudeTermDaemon\" hook"}]}]},"model":"opus"}"#
        try Data(original.utf8).write(to: settings)
        let installer = HookInstaller.claude(daemonPath: "/new/ClaudeTermDaemon", settingsURL: settings)
        XCTAssertEqual(try installer.uninstall().removed, 1, "지금 목록에 없는 이벤트(PostToolUse)의 예전 hook 도 뺀다")
        XCTAssertNil((try json()["hooks"] as? [String: Any])?["PostToolUse"])
        try installer.install()
        let removal = try installer.uninstall()
        XCTAssertEqual(removal.removed, HookInstaller.events.count)
        XCTAssertNotNil(removal.backup)
        XCTAssertEqual(try commands("Stop"), ["say done"])
        XCTAssertEqual(try json()["model"] as? String, "opus")
        let before = try Data(contentsOf: settings)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).count
        XCTAssertEqual(try installer.uninstall(), HookInstaller.Removal(removed: 0, backup: nil))
        XCTAssertEqual(try Data(contentsOf: settings), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, backups, "할 일이 없으면 백업도 만들지 않는다")
    }

    func testUnhookCommandCleansBothFiles() throws {
        let codexURL = dir.appendingPathComponent("hooks.json")
        try HookInstaller.claude(daemonPath: "/x/ClaudeTermDaemon", settingsURL: settings).install()
        try HookInstaller.codex(daemonPath: "/x/ClaudeTermDaemon", hooksURL: codexURL).install()
        var lines: [String] = []
        XCTAssertEqual(Unhook.run(["--claude-settings", settings.path, "--codex-hooks", codexURL.path]) { lines.append($0) }, 0)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try HookInstaller.claude(daemonPath: "/x/ClaudeTermDaemon", settingsURL: settings).status(), .notInstalled)
        XCTAssertEqual(try HookInstaller.codex(daemonPath: "/x/ClaudeTermDaemon", hooksURL: codexURL).status(), .notInstalled)

        try Data("{ broken".utf8).write(to: settings)
        XCTAssertEqual(Unhook.run(["--claude-settings", settings.path, "--codex-hooks", codexURL.path]) { _ in }, 1)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ broken")
        XCTAssertEqual(Unhook.run(["--bogus"]) { _ in }, 2)
    }

    // MARK: - 실제 셸로

    func run(_ command: String, stdin: String) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let input = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = input
        process.standardOutput = out
        process.standardError = err
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    func testMissingBinaryIsSilentNoOp() throws {
        let command = HookInstaller.guardedCommand(dir.appendingPathComponent("gone/ClaudeTermDaemon").path, "hook")
        let result = try run(command, stdin: #"{"session_id":"x"}"#)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.out, "")
        XCTAssertEqual(result.err, "")
        // 예전 형태는 같은 상황에서 오류를 낸다(바꾼 이유)
        XCTAssertNotEqual(try run(HookInstaller.unguardedCommand(dir.appendingPathComponent("gone/ClaudeTermDaemon").path, "hook"),
                                  stdin: "").status, 0)
    }

    func testExistingBinaryGetsStdinArgumentsAndExitCode() throws {
        let script = dir.appendingPathComponent("we\"ird $dir/ClaudeTermDaemon")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s:' \"$1\"; cat; exit 7\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let result = try run(HookInstaller.guardedCommand(script.path, "hook"), stdin: #"{"session_id":"x"}"#)
        XCTAssertEqual(result.out, #"hook:{"session_id":"x"}"#)
        XCTAssertEqual(result.status, 7, "종료 코드를 그대로 넘긴다")
        XCTAssertEqual(result.err, "")
    }
}

final class UpdateCheckTests: XCTestCase {
    func testSemverCompare() {
        XCTAssertTrue(UpdateCheck.isNewer("v0.3.0", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("v0.2.1", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("v1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.0"), "자리별 숫자 비교(문자열 비교 아님)")
        XCTAssertFalse(UpdateCheck.isNewer("v0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("v0.2", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("v0.1.9", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("v0.3.0", than: "0.3.0-beta.1"), "정식판이 pre-release 보다 새것")
        XCTAssertFalse(UpdateCheck.isNewer("v0.3.0-beta.1", than: "0.3.0"))
        XCTAssertTrue(UpdateCheck.isNewer("v0.3.0-beta.10", than: "0.3.0-beta.2"))
        XCTAssertFalse(UpdateCheck.isNewer("latest", than: "0.2.0"), "못 읽는 태그는 알리지 않는다")
        XCTAssertFalse(UpdateCheck.isNewer("v0.3.0", than: "개발"))
    }

    func testDecodeGhOutput() {
        let data = Data(#"{"tagName":"v0.3.0","url":"https://github.com/o/r/releases/tag/v0.3.0"}"#.utf8)
        XCTAssertEqual(UpdateCheck.decode(data), UpdateCheck.Release(tag: "v0.3.0", url: "https://github.com/o/r/releases/tag/v0.3.0"))
        XCTAssertNil(UpdateCheck.decode(Data("release not found".utf8)))
    }

    func testStampRoundTripAndDue() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uc-\(UUID().uuidString)/update-check.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        UpdateCheck.Stamp(checkedAt: now, latest: .init(tag: "v0.3.0", url: "u")).save(to: url)
        let loaded = try XCTUnwrap(UpdateCheck.Stamp.load(from: url))
        XCTAssertEqual(loaded.latest?.tag, "v0.3.0")
        XCTAssertFalse(loaded.isDue(now: now.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(loaded.isDue(now: now.addingTimeInterval(24 * 3600)))
        XCTAssertTrue(loaded.isDue(now: now.addingTimeInterval(-60)), "시계가 뒤로 가면 다시 확인")
    }

    func testMissingGhIsReportedNotThrown() {
        XCTAssertEqual(UpdateCheck.latestRelease(gh: nil), .failure(.noGh))
        XCTAssertNil(UpdateCheck.ghPath(environment: ["PATH": "/nonexistent"]).flatMap { $0.hasPrefix("/nonexistent") ? $0 : nil })
    }
}
