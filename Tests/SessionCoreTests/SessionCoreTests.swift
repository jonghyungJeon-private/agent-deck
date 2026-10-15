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
        setenv("CLAUDE_SESSIONS_HOME", dir.path, 1)
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
        let installer = HookInstaller(settingsURL: settings, executablePath: "/Applications/ClaudeSessions.app/Contents/MacOS/ClaudeSessions")
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
        try HookInstaller(settingsURL: settings, executablePath: "/Users/me/Downloads/ClaudeSessions.app/Contents/MacOS/ClaudeSessions").install()
        let moved = HookInstaller(settingsURL: settings, executablePath: "/Applications/ClaudeSessions.app/Contents/MacOS/ClaudeSessions")
        XCTAssertEqual(try moved.status(), .outdated)
        try moved.install()
        XCTAssertEqual(try moved.status(), .installed)
    }

    func testMissingSettingsFileIsCreated() throws {
        let installer = HookInstaller(settingsURL: settings, executablePath: "/A B/ClaudeSessions")
        XCTAssertNil(try installer.install())
        XCTAssertEqual(try installer.status(), .installed)
        XCTAssertEqual(installer.command, "\"/A B/ClaudeSessions\" hook")
    }

    func testInvalidSettingsIsNotOverwritten() throws {
        try Data("{ not json".utf8).write(to: settings)
        XCTAssertThrowsError(try HookInstaller(settingsURL: settings, executablePath: "/x/ClaudeSessions").install())
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

    func testCommandTemplateQuotes() {
        XCTAssertEqual(CommandTemplate.render("claude --resume {id}", sessionId: "abc-1", name: "x", cwd: "/"),
                       "claude --resume abc-1")
        XCTAssertEqual(CommandTemplate.render("claudec resume {id} {name}", sessionId: "abc", name: "it's a@b", cwd: "/"),
                       #"claudec resume abc 'it'\''s a@b'"#)
    }

    func testSkipPermissionsFlag() {
        XCTAssertEqual(CommandTemplate.render("claude --resume {id}", sessionId: "abc", name: "x", cwd: "/", skipPermissions: true),
                       "claude --resume abc --dangerously-skip-permissions")
        XCTAssertEqual(CommandTemplate.render("claude --dangerously-skip-permissions -r {id}", sessionId: "abc", name: "x", cwd: "/",
                                              skipPermissions: true),
                       "claude --dangerously-skip-permissions -r abc", "이미 있으면 중복으로 붙이지 않는다")
        XCTAssertEqual(CommandTemplate.render("claude --resume {id}", sessionId: "abc", name: "x", cwd: "/", skipPermissions: false),
                       "claude --resume abc")
    }

    func testScannerReadsSessionIdFromArgs() {
        let id = "9b191756-fd8b-4be8-a08b-d171a3e85f49"
        XCTAssertEqual(RunningSessionScanner.sessionId(fromArguments: ["claude", "-n", "x", "--session-id", id]), id)
        XCTAssertEqual(RunningSessionScanner.sessionId(fromArguments: ["claude", "-r", id]), id)
        XCTAssertEqual(RunningSessionScanner.sessionId(fromArguments: ["claude", "--resume=\(id)"]), id)
        XCTAssertNil(RunningSessionScanner.sessionId(fromArguments: ["claude", "-p", "--resume", id]))
        XCTAssertNil(RunningSessionScanner.sessionId(fromArguments: ["node", "--resume", id]))
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
        setenv("CLAUDE_SESSIONS_HOME", dir.path, 1)
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

    func testNameArgument() {
        XCTAssertEqual(RunningSessionScanner.nameArgument(["claude", "--dangerously-skip-permissions", "-n", "repo@main", "--session-id", "x"]), "repo@main")
        XCTAssertNil(RunningSessionScanner.nameArgument(["claude", "--resume", "x"]))
    }
}

final class ImportTests: XCTestCase {
    /// 실행 인자는 --session-id A 지만 그 뒤 /resume 으로 B 로 옮겨 hook 이 B 를 기록 중인 프로세스 → A 를 되살리지 않는다.
    func testImportSkipsProcessAlreadyTrackedByHook() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(dir: dir)
        let a = "67546642-52d0-468c-a4d5-a3b24aba8bf4", b = "5cd5ab17-cd37-4eaf-ac7d-16827eadf085"
        let c = "9f5faf78-f11b-4eca-bd74-240269048f9f"
        let tracked = ProcInfo(pid: 100, ppid: 1, startTime: 1000, hasTTY: true)
        let untracked = ProcInfo(pid: 200, ppid: 1, startTime: 2000, hasTTY: true)
        try store.save(SessionRecord(sessionId: b, cwd: "/tmp", transcriptPath: nil,
                                     pid: 100, pidStartedAt: 1000, startedAt: Date()))
        let imported = RunningSessionScanner.importRunning(into: store, processes: [
            .init(pid: 100, args: ["claude", "--session-id", a], info: tracked, cwd: "/tmp"),
            .init(pid: 200, args: ["claude", "--resume", c], info: untracked, cwd: "/work"),
        ])
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(Set(store.all().map(\.sessionId)), [b, c])
    }
}

final class LayoutTests: XCTestCase {
    let a = "5cd5ab17-cd37-4eaf-ac7d-16827eadf085", b = "2184159e-a9ef-4055-ad38-7753a8260d04"
    let c = "d1d1c893-d5b3-42d2-a7dd-79ee0034935e", d = "71713d11-4b12-492d-908b-0ce41409e5ce"

    /// 지금 사용자 배치: 탭 3개, 3번 탭은 분할 2개
    var live: LiveLayout {
        [[
            [LiveTerminal(id: "t1", title: "✳ 주문 요약 캐시 및 성능 최적화")],
            [LiveTerminal(id: "t2", title: "◐ demo_Project-1238")],
            [LiveTerminal(id: "t3", title: "✳ jato-admin@feature/x"),
             LiveTerminal(id: "t4", title: "⠂ Demo Platform 1차 개발 오케스트레이션")],
        ], [
            [LiveTerminal(id: "t5", title: "me@host:~/tmp")],  // Claude 없는 창 → 기록에서 빠짐
        ]]
    }

    var candidates: [LayoutMatcher.Candidate] {
        [.init(sessionId: a, titles: ["주문 요약 캐시 및 성능 최적화", "shop-api@ABC-3850"]),
         .init(sessionId: b, titles: ["demo_Project-1238"]),
         .init(sessionId: c, titles: ["jato-admin@feature/x"]),
         .init(sessionId: d, titles: ["Demo Platform 1차 개발 오케스트레이션"])]
    }

    func testTitleParsing() {
        XCTAssertEqual(TerminalTitle.claudeTitle("✳ 캐시 개선"), "캐시 개선")
        XCTAssertEqual(TerminalTitle.claudeTitle("⠐ repo@main"), "repo@main")
        XCTAssertNil(TerminalTitle.claudeTitle("me@host:~/tmp"))
        XCTAssertTrue(TerminalTitle.isIdle("me@host:/tmp"))
    }

    func testSnapshotMatchesPanesToSessions() {
        let snapshot = LayoutMatcher.snapshot(of: live, candidates: candidates)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].shape, [1, 1, 2])
        XCTAssertEqual(snapshot.windows[0].tabs[2].terminals.map(\.sessionId), [c, d])
    }

    func testPlanFillsRestoredIdleWindow() {
        let snapshot = LayoutMatcher.snapshot(of: live, candidates: candidates)
        // 재부팅 후: 모두 꺼짐, Ghostty 가 같은 모양의 빈 셸 창을 되살림
        let plan = RestorePlan.make(snapshot: snapshot, stopped: [a, b, c, d, "e-leftover"])
        XCTAssertEqual(plan.leftovers, ["e-leftover"])
        XCTAssertEqual(plan.windows[0].tabs.map { $0.terminals.compactMap(\.sessionId) }, [[a], [b], [c, d]])
        let restored: LiveLayout = [[
            [LiveTerminal(id: "n1", title: "me@host:~")], [LiveTerminal(id: "n2", title: "me@host:~")],
            [LiveTerminal(id: "n3", title: "me@host:~"), LiveTerminal(id: "n4", title: "me@host:~")],
        ]]
        XCTAssertEqual(RestorePlan.fillTarget(for: plan.windows[0], in: restored, excluding: []), 0)
        // 모양이 다르거나 이미 Claude 가 돌고 있으면 채우지 않고 새 창을 만든다
        XCTAssertNil(RestorePlan.fillTarget(for: plan.windows[0], in: live, excluding: []))
        XCTAssertNil(RestorePlan.fillTarget(for: plan.windows[0], in: [restored[0].dropLast().map { $0 }], excluding: []))
    }

    func testPlanSkipsSessionsAlreadyRunning() {
        let snapshot = LayoutMatcher.snapshot(of: live, candidates: candidates)
        let plan = RestorePlan.make(snapshot: snapshot, stopped: [d])
        XCTAssertEqual(plan.windows.count, 1)
        XCTAssertEqual(plan.windows[0].tabs.count, 1, "꺼진 세션이 있는 탭만")
        XCTAssertEqual(plan.windows[0].tabs[0].index, 2)
        XCTAssertEqual(plan.windows[0].tabs[0].terminals, [RestorePlan.Terminal(index: 1, sessionId: d)])
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

final class TTYMatchingTests: XCTestCase {
    func testTTYBeatsTitleAndIdleUsesTTY() {
        let a = "aaaaaaaa-0000-0000-0000-000000000001", b = "aaaaaaaa-0000-0000-0000-000000000002"
        // iTerm2: 제목은 둘 다 "claude" 라 제목으로는 구분 불가 → tty 로 짝짓는다
        let live: LiveLayout = [[[LiveTerminal(id: "s1", title: "✳ claude", tty: "/dev/ttys010"),
                                  LiveTerminal(id: "s2", title: "✳ claude", tty: "/dev/ttys011")]]]
        let snapshot = LayoutMatcher.snapshot(of: live, candidates: [
            .init(sessionId: b, titles: ["claude"], tty: "/dev/ttys011"),
            .init(sessionId: a, titles: ["claude"], tty: "/dev/ttys010"),
        ])
        XCTAssertEqual(snapshot.windows[0].tabs[0].terminals.map(\.sessionId), [a, b])

        let plan = RestorePlan.make(snapshot: snapshot, stopped: [a, b])
        let restored: LiveLayout = [[[LiveTerminal(id: "n1", title: "zsh", tty: "/dev/ttys020"),
                                      LiveTerminal(id: "n2", title: "zsh", tty: "/dev/ttys021")]]]
        XCTAssertEqual(RestorePlan.fillTarget(for: plan.windows[0], in: restored, excluding: []), 0)
        XCTAssertNil(RestorePlan.fillTarget(for: plan.windows[0], in: restored, excluding: [],
                                            busyTTYs: ["/dev/ttys021"]), "claude 가 도는 화면은 채우지 않는다")
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
        let installed = dir.appendingPathComponent("A/ClaudeSessions")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: installed.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        try HookInstaller(settingsURL: settings, executablePath: installed.path).install()

        let other = HookInstaller(settingsURL: settings, executablePath: dir.appendingPathComponent("B/ClaudeSessions").path)
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

final class ArrangementTests: XCTestCase {
    func testTitleChangesDoNotCountAsLayoutChange() {
        let a = LayoutSnapshot(capturedAt: Date(), windows: [LayoutWindow(tabs: [LayoutTab(terminals: [LayoutTerminal(sessionId: "x", title: "✳ 작업")])])])
        var b = a
        b.windows[0].tabs[0].terminals[0].title = "◐ 작업"
        XCTAssertTrue(a.hasSameArrangement(as: b))
        b.windows[0].tabs[0].terminals.append(LayoutTerminal(sessionId: "y", title: "zsh"))
        XCTAssertFalse(a.hasSameArrangement(as: b))
    }
}

/// 중복 실행 방지: 실행 직전 재확인 + 여는 중 예약
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
        setenv("CLAUDE_SESSIONS_HOME", dir.path, 1)
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

final class LayoutMergeTests: XCTestCase {
    let a = "aaaaaaaa-0000-0000-0000-00000000000a", b = "bbbbbbbb-0000-0000-0000-00000000000b"
    let c = "cccccccc-0000-0000-0000-00000000000c"

    func window(_ ids: [[String?]]) -> LayoutWindow {
        LayoutWindow(tabs: ids.map { LayoutTab(terminals: $0.map { LayoutTerminal(sessionId: $0, title: "") }) })
    }

    /// iTerm2 창 W1(A), W2(B) 중 W1 을 닫은 뒤 기록해도 W1 의 자리(A)는 남는다.
    func testClosedWindowIsKept() {
        let previous = LayoutSnapshot(capturedAt: Date(), windows: [window([[a]]), window([[b]])])
        let now = LayoutSnapshot(capturedAt: Date(), windows: [window([[b]])])
        let merged = now.merging(previous: previous, keep: [a])
        XCTAssertEqual(merged.windows, [window([[b]]), window([[a]])])
    }

    /// 아직 열려 있는 창의 옛 기록, 다시 열 수 없는(기록이 지워진) 세션만 있던 창은 버린다.
    func testStaleWindowsAreDropped() {
        let previous = LayoutSnapshot(capturedAt: Date(), windows: [window([[a, b]]), window([[c]])])
        let now = LayoutSnapshot(capturedAt: Date(), windows: [window([[b]])])
        XCTAssertEqual(now.merging(previous: previous, keep: [a]).windows, [window([[b]])])
    }

    /// iTerm2(tty 를 아는 터미널)에서 tty 로 못 찾은 화면은 제목이 같아도 짝짓지 않는다.
    func testNoTitleFallbackWhenTTYKnown() {
        let live: LiveLayout = [[[LiveTerminal(id: "s1", title: "✳ 작업", tty: "/dev/ttys050")]]]
        let snapshot = LayoutMatcher.snapshot(of: live, candidates: [.init(sessionId: a, titles: ["작업"], tty: "/dev/ttys051")])
        XCTAssertTrue(snapshot.sessionIds.isEmpty)
    }

    /// 제목만 아는 터미널(Ghostty)에서 같은 제목이 둘이면 어느 쪽인지 확정하지 않는다.
    func testAmbiguousTitlesAreNotMatched() {
        let live: LiveLayout = [[[LiveTerminal(id: "g1", title: "✳ repo@main"), LiveTerminal(id: "g2", title: "✳ repo@main")]]]
        let snapshot = LayoutMatcher.snapshot(of: live, candidates: [.init(sessionId: a, titles: ["repo@main"]),
                                                                     .init(sessionId: b, titles: ["repo@main"])])
        XCTAssertTrue(snapshot.sessionIds.isEmpty)
        let single: LiveLayout = [[[LiveTerminal(id: "g1", title: "✳ repo@main")]]]
        XCTAssertEqual(LayoutMatcher.snapshot(of: single, candidates: [.init(sessionId: a, titles: ["repo@main"])]).sessionIds, [a])
    }

    func testLayoutsArePerTerminal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = LayoutStore(url: dir.appendingPathComponent("layout.json"))
        try legacy.save(LayoutSnapshot(capturedAt: Date(), windows: [window([[a]])]))
        LayoutStore.migrateLegacy(toTerminal: "iterm2", dir: dir)
        XCTAssertEqual(LayoutStore(terminal: "iterm2", dir: dir).load()?.sessionIds, [a])
        XCTAssertNil(LayoutStore(terminal: "ghostty", dir: dir).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.url.path))
    }
}

final class TemplateTests: XCTestCase {
    /// 넣은 값 안의 "{cwd}" 가 다시 바뀌지 않는다.
    func testSinglePassSubstitution() {
        XCTAssertEqual(CommandTemplate.render("echo {name}", sessionId: "x", name: "{cwd}", cwd: "/tmp/a b"), "echo '{cwd}'")
    }

    /// "{name}" 처럼 따옴표로 감싼 자리표시자도 안전하게 한 인자로 들어간다.
    func testQuotedPlaceholderIsUnwrapped() {
        XCTAssertEqual(CommandTemplate.render(#"claude -n "{name}" --resume {id}"#, sessionId: "abc", name: "$(rm -rf ~)", cwd: "/"),
                       "claude -n '$(rm -rf ~)' --resume abc")
    }
}

final class AttachPlanTests: XCTestCase {
    /// 분할 A|B 중 A 만 꺼짐 → 계획에 "B 가 아직 열려 있음"을 남겨 새 창 대신 B 옆에 붙일 수 있게 한다.
    func testPlanRecordsOpenSiblings() {
        let a = "aaaaaaaa-0000-0000-0000-00000000000a", b = "bbbbbbbb-0000-0000-0000-00000000000b"
        let c = "cccccccc-0000-0000-0000-00000000000c"
        let snapshot = LayoutSnapshot(capturedAt: Date(), windows: [LayoutWindow(tabs: [
            LayoutTab(terminals: [LayoutTerminal(sessionId: a, title: ""), LayoutTerminal(sessionId: b, title: "")]),
            LayoutTab(terminals: [LayoutTerminal(sessionId: c, title: "")]),
        ])])
        let plan = RestorePlan.make(snapshot: snapshot, stopped: [a, c], open: [b])
        XCTAssertEqual(plan.windows.count, 1)
        XCTAssertEqual(plan.windows[0].openSiblings, [b])
        XCTAssertEqual(plan.windows[0].tabs.map(\.openSiblings), [[b], []])
        XCTAssertEqual(plan.windows[0].tabs.map { $0.terminals.compactMap(\.sessionId) }, [[a], [c]])
    }
}
