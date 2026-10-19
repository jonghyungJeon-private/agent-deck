import Foundation
import TermWire
import XCTest

/// 데몬을 launchd 작업으로 띄울 때의 순수 부분: 작업 이름, plist 내용, 앱 환경 넘기기, launchctl print 읽기
final class DaemonLaunchAgentTests: XCTestCase {
    // MARK: 이름

    func testLabelIsStableShortAndPrefixed() {
        let term = URL(fileURLWithPath: "/Users/someone/Library/Application Support/AgentDeck/term", isDirectory: true)
        let label = DaemonLaunchAgent.label(termDir: term)
        XCTAssertTrue(label.hasPrefix("dev.agentdeck.daemon."))
        let suffix = label.dropFirst(DaemonLaunchAgent.labelPrefix.count)
        XCTAssertEqual(suffix.count, 12)
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // 같은 경로면 늘 같은 이름(다음에 켤 때 같은 작업을 찾는다). 끝의 / 나 `.` 이 있어도 같다.
        XCTAssertEqual(label, DaemonLaunchAgent.label(termDir: term))
        XCTAssertEqual(label, DaemonLaunchAgent.label(termDir: URL(fileURLWithPath: term.path + "/./")))
        XCTAssertEqual(label, DaemonLaunchAgent.label(forPath: term.path))
    }

    /// 폴더가 있든 없든 같은 이름(/private/tmp 는 standardizedFileURL 이 폴더가 있을 때만 /tmp 로 바꾼다)
    func testLabelDoesNotDependOnFileSystem() throws {
        let base = URL(fileURLWithPath: "/private" + NSTemporaryDirectory().replacingOccurrences(of: "/private", with: ""))
            .appendingPathComponent("agentdeck-label-\(UUID().uuidString)", isDirectory: true)
        let term = base.appendingPathComponent("term", isDirectory: true)
        let before = DaemonLaunchAgent.label(termDir: term)
        try FileManager.default.createDirectory(at: term, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(DaemonLaunchAgent.label(termDir: term), before)
        XCTAssertEqual(DaemonLaunchAgent.label(forPath: "/private/tmp/x/term"), DaemonLaunchAgent.label(forPath: "/private/tmp//x/./term/"))
        XCTAssertNotEqual(DaemonLaunchAgent.label(forPath: "/private/tmp/x/term"), DaemonLaunchAgent.label(forPath: "/tmp/x/term"))
    }

    func testLabelDiffersPerTermDir() {
        let a = DaemonLaunchAgent.label(forPath: "/tmp/qa-a/term")
        let b = DaemonLaunchAgent.label(forPath: "/tmp/qa-b/term")
        XCTAssertNotEqual(a, b)
    }

    /// 알려진 값(FNV-1a 64): 해시 방식이 바뀌면 이미 올라간 작업을 못 찾으니 고정해 둔다
    func testLabelKnownValue() {
        // FNV-1a 64("") = cbf29ce484222325, ("a") = af63dc4c8601ec8c
        XCTAssertEqual(DaemonLaunchAgent.label(forPath: ""), "dev.agentdeck.daemon.cbf29ce48422")
        XCTAssertEqual(DaemonLaunchAgent.label(forPath: "a"), "dev.agentdeck.daemon.af63dc4c8601")
    }

    // MARK: plist

    func testPlistContent() throws {
        let plist = DaemonLaunchAgent.plist(label: "dev.agentdeck.daemon.abc", program: "/A.app/Contents/MacOS/AgentDeckDaemon",
                                            root: "/data root", logPath: "/data root/term/daemon-stderr.log",
                                            environment: ["PATH": "/usr/bin", "LANG": "ko_KR.UTF-8"])
        XCTAssertEqual(plist["Label"] as? String, "dev.agentdeck.daemon.abc")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/A.app/Contents/MacOS/AgentDeckDaemon", "--root", "/data root"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        // KeepAlive 가 켜지면 쉬다 끝난 데몬을 launchd 가 다시 띄운다(쉬면 끝나기와 싸움)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, false)
        XCTAssertEqual(plist["AbandonProcessGroup"] as? Bool, true)
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(plist["StandardOutPath"] as? String, "/data root/term/daemon-stderr.log")
        XCTAssertEqual(plist["StandardErrorPath"] as? String, "/data root/term/daemon-stderr.log")
        XCTAssertEqual(plist["EnvironmentVariables"] as? [String: String], ["PATH": "/usr/bin", "LANG": "ko_KR.UTF-8"])

        // 올린 뒤 남기는 파일에는 환경이 없다
        let bare = DaemonLaunchAgent.plist(label: "x", program: "/p", root: "/r", logPath: "/l", environment: nil)
        XCTAssertNil(bare["EnvironmentVariables"])

        // XML plist 로 쓰고 다시 읽으면 같다(특수 문자 포함)
        let tricky = ["TOKEN": "a<b>&\"c'\n", "한글": "값"]
        let data = try DaemonLaunchAgent.plistData(
            DaemonLaunchAgent.plist(label: "x", program: "/p", root: "/r", logPath: "/l", environment: tricky))
        let back = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(back?["EnvironmentVariables"] as? [String: String], tricky)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("<?xml"))
    }

    // MARK: 환경

    func testEnvironmentSnapshotKeepsUserEnvironment() {
        let env = [
            "PATH": "/opt/homebrew/bin:/usr/bin", "LANG": "ko_KR.UTF-8", "LC_ALL": "ko_KR.UTF-8", "SHELL": "/bin/zsh",
            "HOME": "/fake/home", "USER": "me", "LOGNAME": "me", "TMPDIR": "/var/folders/x/", "SSH_AUTH_SOCK": "/s",
            "AGENTDECK_HOME": "/qa/root", "AGENTDECK_TERM_HOME": "/qa/term", "CLAUDE_TERM_HOME": "/old",
            "AGENTDECK_DEBUG": "1", "NVM_DIR": "/nvm", "CODEX_HOME": "/codex", "CLAUDE_CONFIG_DIR": "/claude",
            "SHLVL": "2", "__CF_USER_TEXT_ENCODING": "0x1F5:0x3:0x33",
        ]
        XCTAssertEqual(DaemonLaunchAgent.environmentSnapshot(env), env)
    }

    func testEnvironmentSnapshotDropsLaunchdAndSessionMarkers() {
        let env = [
            "PATH": "/usr/bin",
            "XPC_SERVICE_NAME": "application.dev.agentdeck.app.1.2", "XPC_FLAGS": "0x0", "__CFBundleIdentifier": "dev.agentdeck.app",
            "_": "/usr/bin/open", "PWD": "/x", "OLDPWD": "/y",
            "AGENTDECK_PANE": "pane-1", "CLAUDE_SESSIONS_PANE": "pane-0", "CODEX_THREAD_ID": "t",
            "CLAUDECODE": "1", "CLAUDE_PID": "9", "CLAUDE_EFFORT": "high", "CLAUDE_CODE_ENTRYPOINT": "cli",
            "BAD=KEY": "v", "NUL": "a\0b",
        ]
        XCTAssertEqual(DaemonLaunchAgent.environmentSnapshot(env), ["PATH": "/usr/bin"])
    }

    /// 데몬이 자기 작업 이름을 아는 법: launchd 가 넣는 XPC_SERVICE_NAME 이 이 앱의 접두어일 때만(예전 방식 데몬은 앱의 값을 물려받는다)
    func testOwnLabel() {
        XCTAssertEqual(DaemonLaunchAgent.ownLabel(["XPC_SERVICE_NAME": "dev.agentdeck.daemon.0123456789ab"]), "dev.agentdeck.daemon.0123456789ab")
        XCTAssertNil(DaemonLaunchAgent.ownLabel(["XPC_SERVICE_NAME": "application.dev.agentdeck.app.1.2"]))
        XCTAssertNil(DaemonLaunchAgent.ownLabel(["XPC_SERVICE_NAME": "0"]))
        XCTAssertNil(DaemonLaunchAgent.ownLabel([:]))
    }

    // MARK: launchctl print

    func testParsePrintRunning() {
        let output = """
            gui/501/dev.agentdeck.daemon.abc = {
            \tactive count = 1
            \tpath = /x/term/dev.agentdeck.daemon.plist
            \ttype = LaunchAgent
            \tstate = running

            \tprogram = /A.app/Contents/MacOS/AgentDeckDaemon
            \tjob state = running
            \tendpoints = {
            \t\tstate = active
            \t}
            \truns = 1
            \tpid = 4242
            }
            """
        XCTAssertEqual(DaemonLaunchAgent.parsePrint(output, exitStatus: 0),
                       DaemonLaunchAgent.ServiceStatus(loaded: true, running: true, pid: 4242))
    }

    func testParsePrintLoadedNotRunning() {
        let output = """
            gui/501/dev.agentdeck.daemon.abc = {
            \tactive count = 0
            \tstate = not running
            \truns = 1
            \tlast exit code = 0
            \tspawn type = interactive (4)
            \tproperties = {
            \t\tstate = running
            \t}
            }
            """
        XCTAssertEqual(DaemonLaunchAgent.parsePrint(output, exitStatus: 0),
                       DaemonLaunchAgent.ServiceStatus(loaded: true, running: false, pid: nil))
    }

    func testParsePrintNotLoaded() {
        let output = "Bad request.\nCould not find service \"dev.agentdeck.daemon.abc\" in domain for user gui: 501\n"
        XCTAssertEqual(DaemonLaunchAgent.parsePrint(output, exitStatus: 113), DaemonLaunchAgent.ServiceStatus())
    }
}
