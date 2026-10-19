import XCTest
@testable import SessionCore

final class HookHandlerTests: XCTestCase {
    var dir: URL!
    var store: SessionStore!
    let sid = "a20c2ad9-e7fb-48a3-aac3-f3b9c03b3a92"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SessionStore(dir: dir)
        // 테스트가 실제 앱 데이터(launching.json 등)를 건드리지 않게
        setenv("AGENTDECK_HOME", dir.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func context(args: [String] = ["claude"], tty: Bool = true) -> HookHandler.Context {
        let me = ProcessUtil.info(getpid())!
        return .init(
            claudePid: me.pid,
            claudeProcess: ProcInfo(pid: me.pid, ppid: me.ppid, startTime: me.startTime, hasTTY: tty),
            claudeArgs: args,
            environment: ["TERM_PROGRAM": "ghostty"],
            liveProcesses: []
        )
    }

    var transcript: URL { dir.appendingPathComponent("t.jsonl") }

    func event(_ name: String, extra: String) -> Data {
        Data("""
        {"session_id":"\(sid)","cwd":"/tmp/work","transcript_path":"\(transcript.path)","hook_event_name":"\(name)",\(extra)}
        """.utf8)
    }

    func testStartRecordsRunningSession() throws {
        try HookHandler.handle(input: event("SessionStart", extra: #""source":"startup""#), context: context(), store: store)
        let record = try XCTUnwrap(store.load(sid))
        XCTAssertEqual(record.cwd, "/tmp/work")
        XCTAssertEqual(record.termProgram, "ghostty")
        XCTAssertTrue(record.isRunning, "기록한 PID(테스트 프로세스 자신)가 살아 있으니 실행 중")
    }

    func testHeadlessAndNoTTYAreIgnored() throws {
        try HookHandler.handle(input: event("SessionStart", extra: #""source":"startup""#),
                               context: context(args: ["claude", "-p", "hi"]), store: store)
        try HookHandler.handle(input: event("SessionStart", extra: #""source":"startup""#),
                               context: context(tty: false), store: store)
        XCTAssertNil(store.load(sid))
    }

    func testClosingSessionWithoutConversationRemovesIt() throws {
        // 대화를 한 번도 안 하면 대화 파일이 없어 이어 열 수 없다 → 창을 닫아도 꺼짐으로 남기지 않는다
        try HookHandler.handle(input: event("SessionStart", extra: #""source":"startup""#), context: context(), store: store)
        try HookHandler.handle(input: event("SessionEnd", extra: #""reason":"other""#), context: context(), store: store)
        XCTAssertNil(store.load(sid))
    }

    func testExplicitExitRemovesButWindowCloseKeeps() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: transcript)
        let start = event("SessionStart", extra: #""source":"startup""#)
        try HookHandler.handle(input: start, context: context(), store: store)
        try HookHandler.handle(input: event("SessionEnd", extra: #""reason":"other""#), context: context(), store: store)
        let kept = try XCTUnwrap(store.load(sid))
        XCTAssertEqual(kept.endReason, "other")
        XCTAssertFalse(kept.isRunning)

        // 다시 이어 열면 실행 중으로 돌아온다
        try HookHandler.handle(input: event("SessionStart", extra: #""source":"resume""#), context: context(), store: store)
        XCTAssertTrue(try XCTUnwrap(store.load(sid)).isRunning)

        try HookHandler.handle(input: event("SessionEnd", extra: #""reason":"prompt_input_exit""#), context: context(), store: store)
        XCTAssertNil(store.load(sid))
    }

    func testDeadProcessIsNotRunning() {
        let record = SessionRecord(sessionId: sid, cwd: "/tmp", transcriptPath: nil, pid: getpid(),
                                   pidStartedAt: 1, startedAt: Date())
        XCTAssertFalse(record.isRunning, "시작 시각이 다르면 PID 재사용으로 본다")
    }

    func testRejectsPathLikeIds() {
        XCTAssertFalse(SessionStore.isValidId("../../etc/passwd"))
        XCTAssertTrue(SessionStore.isValidId(sid))
    }
}

final class HookInstallerTests: XCTestCase {
    var dir: URL!
    var settings: URL { dir.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func json() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    }

    func testInstallKeepsExistingHooksAndUninstallRestores() throws {
        let original = """
        {"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}],
         "SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}
        """
        try Data(original.utf8).write(to: settings)
        let installer = HookInstaller(settingsURL: settings, executablePath: "/Applications/AgentDeck.app/Contents/MacOS/AgentDeckDaemon")
        XCTAssertEqual(try installer.status(), .notInstalled)

        let backup = try installer.install()
        XCTAssertNotNil(backup)
        XCTAssertEqual(try installer.status(), .installed)
        var hooks = try json()["hooks"] as! [String: Any]
        XCTAssertEqual((hooks["SessionStart"] as! [Any]).count, 2, "사용자 hook 유지 + 앱 hook 추가")
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertEqual(try json()["model"] as? String, "opus")

        // 두 번 설치해도 중복되지 않는다
        try installer.install()
        hooks = try json()["hooks"] as! [String: Any]
        XCTAssertEqual((hooks["SessionStart"] as! [Any]).count, 2)

        try installer.uninstall()
        hooks = try json()["hooks"] as! [String: Any]
        XCTAssertEqual((hooks["SessionStart"] as! [Any]).count, 1)
        XCTAssertNil(hooks["SessionEnd"])
        XCTAssertEqual(try installer.status(), .notInstalled)
    }

    func testMovedAppIsOutdatedAndReinstallFixesPath() throws {
        try HookInstaller(settingsURL: settings, executablePath: "/Users/me/Downloads/AgentDeck.app/Contents/MacOS/AgentDeckDaemon").install()
        let moved = HookInstaller(settingsURL: settings, executablePath: "/Applications/AgentDeck.app/Contents/MacOS/AgentDeckDaemon")
        XCTAssertEqual(try moved.status(), .outdated)
        try moved.install()
        XCTAssertEqual(try moved.status(), .installed)
    }

    func testMissingSettingsFileIsCreated() throws {
        let installer = HookInstaller(settingsURL: settings, executablePath: "/A B/AgentDeckDaemon")
        XCTAssertNil(try installer.install())
        XCTAssertEqual(try installer.status(), .installed)
        XCTAssertEqual(installer.command, "[ -x \"/A B/AgentDeckDaemon\" ] || exit 0; exec \"/A B/AgentDeckDaemon\" hook")
    }

    func testInvalidSettingsIsNotOverwritten() throws {
        try Data("{ not json".utf8).write(to: settings)
        XCTAssertThrowsError(try HookInstaller(settingsURL: settings, executablePath: "/x/AgentDeckDaemon").install())
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ not json")
    }
}

final class TranscriptAndCommandTests: XCTestCase {
    func testReadsLatestTitlesAndPrompt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"user","message":{"content":"\"type\":\"ai-title\" 본문에 나와도 무시"}}"#,
            #"{"type":"custom-title","customTitle":"repo@main"}"#,
            #"{"type":"ai-title","aiTitle":"옛 제목"}"#,
            #"{"type":"last-prompt","lastPrompt":"첫 요청"}"#,
            #"{"type":"ai-title","aiTitle":"캐시 성능 개선"}"#,
            #"{"type":"last-prompt","lastPrompt":"테스트 돌려줘\n둘째 줄"}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        let summary = TranscriptReader.read(path: url.path)
        XCTAssertEqual(summary.aiTitle, "캐시 성능 개선")
        XCTAssertEqual(summary.customTitle, "repo@main")
        XCTAssertEqual(summary.lastPrompt, "테스트 돌려줘\n둘째 줄")
    }

    func testScannerReadsSessionIdFromArgs() {
        let id = "9b191756-fd8b-4be8-a08b-d171a3e85f49"
        XCTAssertEqual(ClaudeArguments.sessionId(["claude", "-n", "x", "--session-id", id]), id)
        XCTAssertEqual(ClaudeArguments.sessionId(["claude", "-r", id]), id)
        XCTAssertEqual(ClaudeArguments.sessionId(["claude", "--resume=\(id)"]), id)
        XCTAssertNil(ClaudeArguments.sessionId(["claude", "-p", "--resume", id]))
        XCTAssertNil(ClaudeArguments.sessionId(["node", "--resume", id]))
    }
}

final class SessionSwitchTests: XCTestCase {
    var dir: URL!
    var store: SessionStore!
    let empty = "67546642-52d0-468c-a4d5-a3b24aba8bf4"
    let resumed = "5cd5ab17-cd37-4eaf-ac7d-16827eadf085"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SessionStore(dir: dir)
        setenv("AGENTDECK_HOME", dir.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func context(now: Date = Date()) -> HookHandler.Context {
        let me = ProcessUtil.info(getpid())!
        return .init(claudePid: me.pid, claudeProcess: ProcInfo(pid: me.pid, ppid: me.ppid, startTime: me.startTime, hasTTY: true),
                     claudeArgs: ["claude"], environment: [:], now: now, liveProcesses: [])
    }

    func event(_ id: String, _ name: String, _ extra: String) -> Data {
        Data(#"{"session_id":"\#(id)","cwd":"/tmp","hook_event_name":"\#(name)",\#(extra)}"#.utf8)
    }

    /// 빈 새 세션에서 /resume 으로 다른 세션으로 바꾸면(SessionEnd 없음) 빈 세션 기록이 사라진다.
    func testResumeInsideSessionReplacesEmptySession() throws {
        try HookHandler.handle(input: event(empty, "SessionStart", #""source":"startup""#), context: context(), store: store)
        try HookHandler.handle(input: event(resumed, "SessionStart", #""source":"resume""#), context: context(), store: store)
        XCTAssertEqual(store.all().map(\.sessionId), [resumed])
    }

    /// 대화가 있던 세션을 /resume 으로 떠나면 SessionEnd(reason: resume) → 지운다.
    func testLeavingByResumeRemovesRecord() throws {
        try HookHandler.handle(input: event(resumed, "SessionStart", #""source":"startup""#), context: context(), store: store)
        try HookHandler.handle(input: event(resumed, "SessionEnd", #""reason":"resume""#), context: context(), store: store)
        XCTAssertNil(store.load(resumed))
    }

    /// 이미 쌓인 중복(같은 프로세스에 열림 기록 2개)은 최근 것만 남긴다.
    func testRemoveSupersededKeepsLatest() throws {
        let me = ProcessUtil.info(getpid())!
        var old = SessionRecord(sessionId: empty, cwd: "/tmp", transcriptPath: nil, pid: me.pid, pidStartedAt: me.startTime, startedAt: Date())
        old.activeSince = Date(timeIntervalSinceNow: -60)
        var new = old
        new.sessionId = resumed
        new.activeSince = Date()
        try store.save(old)
        try store.save(new)
        XCTAssertEqual(store.removeSupersededSessions(), [empty])
        XCTAssertEqual(store.all().map(\.sessionId), [resumed])
    }

}

final class DuplicateTabTests: XCTestCase {
    /// 같은 세션을 두 탭에서 열고 먼저 연 쪽을 닫아도, 아직 도는 쪽 기록은 "실행 중" 그대로여야 한다.
    func testEndFromOtherProcessDoesNotStopLiveRecord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(dir: dir)
        let sid = "2184159e-a9ef-4055-ad38-7753a8260d04"
        let me = ProcessUtil.info(getpid())!
        try store.save(SessionRecord(sessionId: sid, cwd: "/tmp", transcriptPath: nil,
                                     pid: me.pid, pidStartedAt: me.startTime, startedAt: Date()))
        let other = HookHandler.Context(claudePid: 99999, claudeProcess: ProcInfo(pid: 99999, ppid: 1, startTime: 5, hasTTY: true),
                                        claudeArgs: ["claude"], environment: [:], liveProcesses: [])
        for reason in ["other", "prompt_input_exit"] {
            try HookHandler.handle(input: Data(#"{"session_id":"\#(sid)","hook_event_name":"SessionEnd","reason":"\#(reason)"}"#.utf8),
                                   context: other, store: store)
            XCTAssertTrue(try XCTUnwrap(store.load(sid)).isRunning, reason)
        }
    }
}

final class GitInfoTests: XCTestCase {
    func testRepoRootFindsTopLevelFromSubfolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        XCTAssertEqual(GitInfo.repoRoot(at: sub.path), root.standardizedFileURL.path)
        XCTAssertEqual(GitInfo.branch(at: sub.path), "main")
    }
}

final class RepairTests: XCTestCase {
    /// 다른 위치의 앱(개발용 빌드 등)이 실행돼도, 기존 hook 의 실행 파일이 살아 있으면 고쳐 쓰지 않는다.
    func testRepairOnlyWhenInstalledExecutableIsGone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json")
        let installed = dir.appendingPathComponent("A/AgentDeckDaemon")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: installed.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        try HookInstaller(settingsURL: settings, executablePath: installed.path).install()

        let other = HookInstaller(settingsURL: settings, executablePath: dir.appendingPathComponent("B/AgentDeckDaemon").path)
        XCTAssertEqual(try other.status(), .outdated)
        XCTAssertFalse(try other.needsRepair(), "기존 앱이 아직 있으면 건드리지 않는다")
        try FileManager.default.removeItem(at: installed)
        XCTAssertTrue(try other.needsRepair(), "기존 앱을 옮겨서 없어졌으면 고친다")
    }
}

final class InheritedEnvironmentTests: XCTestCase {
    func testScrubsClaudeSessionMarkersOnly() {
        setenv("CLAUDE_CODE_CHILD_SESSION", "1", 1)
        setenv("CLAUDECODE", "1", 1)
        setenv("CLAUDE_CONFIG_DIR", "/x", 1)
        let removed = InheritedEnvironment.scrub()
        XCTAssertTrue(removed.contains("CLAUDE_CODE_CHILD_SESSION"))
        XCTAssertTrue(removed.contains("CLAUDECODE"))
        XCTAssertNil(getenv("CLAUDE_CODE_CHILD_SESSION"))
        XCTAssertEqual(String(cString: getenv("CLAUDE_CONFIG_DIR")), "/x", "세션 표시가 아닌 설정 변수는 남긴다")
        unsetenv("CLAUDE_CONFIG_DIR")
    }
}

final class IncrementalTranscriptTests: XCTestCase {
    func testReadsOnlyAppendedCompleteLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((#"{"type":"ai-title","aiTitle":"처음 제목"}"# + "\n").utf8).write(to: url)
        var cursor = TranscriptReader.update(path: url.path, cursor: nil)
        XCTAssertEqual(cursor.summary.aiTitle, "처음 제목")

        // 쓰는 중이라 잘린 줄은 반영하지 않고, 다음 번에 다시 읽는다
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"type":"last-prompt","lastPr"#.utf8))
        cursor = TranscriptReader.update(path: url.path, cursor: cursor)
        XCTAssertNil(cursor.summary.lastPrompt)

        handle.write(Data((#"ompt":"두번째 요청"}"# + "\n" + #"{"type":"ai-title","aiTitle":"바뀐 제목"}"# + "\n").utf8))
        try handle.close()
        cursor = TranscriptReader.update(path: url.path, cursor: cursor)
        XCTAssertEqual(cursor.summary.lastPrompt, "두번째 요청")
        XCTAssertEqual(cursor.summary.aiTitle, "바뀐 제목")
        XCTAssertEqual(cursor.offset, UInt64(try Data(contentsOf: url).count))
    }
}

final class LaunchGateTests: XCTestCase {
    var dir: URL!
    var store: SessionStore!
    var reservations: LaunchReservations!
    let a = "aaaaaaaa-1111-0000-0000-000000000001", b = "bbbbbbbb-2222-0000-0000-000000000002"
    var me: ProcInfo { ProcessUtil.info(getpid())! }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SessionStore(dir: dir.appendingPathComponent("sessions"))
        reservations = LaunchReservations(url: dir.appendingPathComponent("launching.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func stoppedRecord(_ id: String) -> SessionRecord {
        SessionRecord(sessionId: id, cwd: "/tmp", transcriptPath: nil, pid: 99999, pidStartedAt: 1, startedAt: Date(),
                      endedAt: Date(), endReason: "other")
    }

    func runningRecord(_ id: String) -> SessionRecord {
        SessionRecord(sessionId: id, cwd: "/tmp", transcriptPath: nil, pid: me.pid, pidStartedAt: me.startTime, startedAt: Date())
    }

    /// 사용자 보고: 한 창의 A|B 중 A 만 닫고 "모두 열기" → 목록이 늦어 B 까지 후보로 와도 B 는 열지 않는다.
    func testRunningSessionIsNeverRelaunched() throws {
        try store.save(stoppedRecord(a))
        try store.save(runningRecord(b))
        XCTAssertEqual(LaunchGate.claim([a, b], store: store, reservations: reservations, processes: []), [a])
    }

    /// 기록은 "꺼짐"이어도 그 세션을 실행 인자로 연 claude 가 떠 있으면 열지 않는다.
    func testSessionWithLiveClaudeProcessIsNotRelaunched() throws {
        try store.save(stoppedRecord(a))
        let live = LiveSessions.Process(pid: 4242, startTime: 7, tty: "/dev/ttys009", argumentSessionId: a)
        XCTAssertEqual(LaunchGate.claim([a], store: store, reservations: reservations, processes: [live]), [])
    }

    /// 방금 열라고 보낸 세션은 claude 가 뜨기 전(기록이 아직 꺼짐)이라도 다시 열지 않는다(연속 클릭·모두 열기 두 번).
    func testSecondClaimWhileOpeningIsRefused() throws {
        try store.save(stoppedRecord(a))
        XCTAssertEqual(LaunchGate.claim([a], store: store, reservations: reservations, processes: []), [a])
        XCTAssertEqual(LaunchGate.claim([a], store: store, reservations: reservations, processes: []), [])
        // claude 가 떠서 SessionStart 가 예약을 풀고, 다시 닫히면 그때는 열 수 있다
        reservations.release([a])
        XCTAssertEqual(LaunchGate.claim([a], store: store, reservations: reservations, processes: []), [a])
    }

    func testReservationExpires() {
        let past = Date(timeIntervalSinceNow: -LaunchReservations.ttl - 1)
        XCTAssertEqual(reservations.reserve([a], open: [], now: past), [a])
        XCTAssertEqual(reservations.reserve([a], open: [], now: Date()), [a], "오래된 예약은 무시")
    }

    /// 기록이 지워진(/exit 로 끝낸) 세션은 열지 않는다.
    func testMissingRecordIsNotClaimed() {
        XCTAssertEqual(LaunchGate.claim([a], store: store, reservations: reservations, processes: []), [])
    }

    /// 실행 인자는 --resume A 였지만 그 뒤 /resume 으로 B 로 옮겨 B 기록이 맡은 프로세스 → A 는 열려 있지 않다.
    func testStaleArgumentOfOwnedProcessIsIgnored() throws {
        try store.save(stoppedRecord(a))
        try store.save(runningRecord(b))
        let owner = LiveSessions.Process(pid: me.pid, startTime: me.startTime, tty: nil, argumentSessionId: a)
        XCTAssertEqual(LiveSessions.openIds(records: store.all(), processes: [owner]), [b])
    }

    /// 같은 세션을 두 화면에서 열고 기록을 맡은 쪽을 닫은 뒤 → 남은 claude 로 기록을 옮겨 "실행 중"으로 되돌린다.
    func testAdoptMovesRecordToSurvivingProcess() throws {
        try store.save(stoppedRecord(a))
        let survivor = LiveSessions.Process(pid: me.pid, startTime: me.startTime, tty: "/dev/ttys004",
                                            argumentSessionId: a, termProgram: "iTerm.app")
        XCTAssertEqual(LiveSessions.adopt(into: store, processes: [survivor]), [a])
        let record = try XCTUnwrap(store.load(a))
        XCTAssertTrue(record.isRunning)
        XCTAssertEqual(record.tty, "/dev/ttys004")
        XCTAssertEqual(record.termProgram, "iTerm.app")
    }

    func testLockIsReentrant() {
        let value = store.withLock { store.withLock { 42 } }
        XCTAssertEqual(value, 42)
    }
}

final class SessionEndOwnershipTests: XCTestCase {
    var dir: URL!
    var store: SessionStore!
    let sid = "cccccccc-3333-0000-0000-000000000003"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SessionStore(dir: dir)
        setenv("AGENTDECK_HOME", dir.path, 1)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("t.jsonl").path, contents: Data("{}\n".utf8))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func end(_ reason: String, from proc: ProcInfo?, live: [LiveSessions.Process]) throws {
        let input = #"{"session_id":"\#(sid)","hook_event_name":"SessionEnd","reason":"\#(reason)","transcript_path":"\#(dir.appendingPathComponent("t.jsonl").path)"}"#
        try HookHandler.handle(input: Data(input.utf8),
                               context: .init(claudePid: proc?.pid ?? 0, claudeProcess: proc, claudeArgs: ["claude"],
                                              environment: [:], liveProcesses: live), store: store)
    }

    func ownedRecord(pid: pid_t, start: Double) throws {
        try store.save(SessionRecord(sessionId: sid, cwd: "/tmp", transcriptPath: dir.appendingPathComponent("t.jsonl").path,
                                     pid: pid, pidStartedAt: start, startedAt: Date()))
    }

    /// 기록을 맡은(나중에 연) 쪽을 닫아도 먼저 연 쪽이 남아 있으면 꺼짐이 아니라 그쪽으로 넘어간다. /exit 도 같다.
    func testOwnerEndHandsOverToSurvivor() throws {
        let me = ProcessUtil.info(getpid())!
        for reason in ["other", "prompt_input_exit"] {
            try ownedRecord(pid: 88888, start: 3)
            let survivor = LiveSessions.Process(pid: me.pid, startTime: me.startTime, tty: "/dev/ttys002", argumentSessionId: sid)
            try end(reason, from: ProcInfo(pid: 88888, ppid: 1, startTime: 3, hasTTY: true), live: [survivor])
            let record = try XCTUnwrap(store.load(sid), reason)
            XCTAssertEqual(record.pid, me.pid, reason)
            XCTAssertNil(record.endedAt, reason)
        }
    }

    /// 끝나는 프로세스를 알 수 없으면 기록을 건드리지 않는다.
    func testUnknownEndingProcessLeavesRecord() throws {
        try ownedRecord(pid: 88888, start: 3)
        try end("other", from: nil, live: [])
        XCTAssertNil(try XCTUnwrap(store.load(sid)).endedAt)
    }

    func testOwnerEndWithoutSurvivorStops() throws {
        try ownedRecord(pid: 88888, start: 3)
        try end("other", from: ProcInfo(pid: 88888, ppid: 1, startTime: 3, hasTTY: true), live: [])
        XCTAssertNotNil(try XCTUnwrap(store.load(sid)).endedAt)
    }
}
