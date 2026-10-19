import XCTest
import SQLite3
@testable import SessionCore

final class CodexTests: XCTestCase {
    let sid = "01a13e6f-d93c-78d1-99ca-4e2a62355053"
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }
    func database(_ name: String, sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent(name).path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
    func testLegacyTranscriptAndCacheRefresh() throws {
        let sessions = dir.appendingPathComponent("sessions/2026/10/15")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let transcript = sessions.appendingPathComponent("rollout-2026-10-15-\(sid).jsonl")
        var lines = """
        {"type":"session_meta","payload":{"id":"\(sid)","cwd":"/project"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"Fix login"}]}}
        {"timestamp":"2026-10-15T07:00:00.001Z","type":"event_msg","payload":{"type":"task_started"}}
        """ + "\n"
        try lines.write(to: transcript, atomically: true, encoding: .utf8)
        let modified = Date(timeIntervalSince1970: 1792050000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: transcript.path)
        let reader = CodexSessions(home: dir)
        let first = try XCTUnwrap(reader.session(sid))
        XCTAssertEqual(first.title, "Fix login")
        XCTAssertEqual(first.cwd, "/project")
        XCTAssertEqual(first.state, "working")
        XCTAssertEqual(first.lastActivityAt, modified)
        XCTAssertEqual(reader.session(sid), first)
        lines += "{\"timestamp\":\"2026-10-15T07:00:00.002Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n"
        try lines.write(to: transcript, atomically: true, encoding: .utf8)
        XCTAssertEqual(reader.session(sid)?.state, "done")
        XCTAssertNotEqual(reader.session(sid)?.stateAt, first.stateAt)
        XCTAssertGreaterThan(try XCTUnwrap(reader.session(sid)?.lastActivityAt), modified)
        XCTAssertNil(reader.session("../../private"))
    }
    func testPaginatedHistoryAndOlderDatabaseSchema() throws {
        try database("state_5.sqlite", sql: """
        CREATE TABLE threads(id TEXT,cwd TEXT,rollout_path TEXT,title TEXT);
        INSERT INTO threads VALUES('\(sid)','/work','/missing','Named session');
        CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT,status TEXT);
        """)
        try database("thread_history_1.sqlite", sql: """
        CREATE TABLE thread_turns(thread_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER);
        INSERT INTO thread_turns VALUES('\(sid)','inProgress',1792050000,NULL,1);
        """)
        let reader = CodexSessions(home: dir)
        XCTAssertEqual(reader.session(sid)?.title, "Named session")
        XCTAssertEqual(reader.session(sid)?.state, "working")
        try database("thread_history_1.sqlite", sql: "UPDATE thread_turns SET status='completed',completed_at=1792050010;")
        XCTAssertEqual(reader.session(sid)?.state, "done")
        XCTAssertEqual(reader.session(sid)?.stateAt, Date(timeIntervalSince1970: 1792050010))
        XCTAssertEqual(reader.session(sid)?.lastActivityAt,
                       WorkStateRules.transcriptModifiedAt(dir.appendingPathComponent("thread_history_1.sqlite").path))
        XCTAssertEqual(reader.children(of: sid).count, 0)
    }

    func testSQLiteWALActivityKeepsOldWorkingTurnWithoutRollout() throws {
        try database("state_5.sqlite", sql: """
        CREATE TABLE threads(id TEXT,cwd TEXT,rollout_path TEXT,title TEXT);
        INSERT INTO threads VALUES('\(sid)','/work',NULL,'SQLite only');
        """)
        let history = dir.appendingPathComponent("thread_history_1.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(history.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
        PRAGMA journal_mode=WAL;
        CREATE TABLE thread_turns(thread_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER);
        INSERT INTO thread_turns VALUES('\(sid)','inProgress',1000,NULL,1);
        """, nil, nil, nil), SQLITE_OK)
        let now = Date()
        let old = now.addingTimeInterval(-2 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: history.path)
        let reader = CodexSessions(home: dir)
        let session = try XCTUnwrap(reader.session(sid))
        XCTAssertEqual(session.lastActivityAt, WorkStateRules.transcriptModifiedAt(history.path + "-wal"))
        XCTAssertEqual(CodexChildRules.activity(state: session.state, stateAt: session.stateAt,
            edgeStatus: "open", lastActivityAt: session.lastActivityAt, now: now), .running)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: history.path + "-wal")
        let stale = try XCTUnwrap(reader.session(sid))
        XCTAssertNil(CodexChildRules.activity(state: stale.state, stateAt: stale.stateAt,
            edgeStatus: "open", lastActivityAt: stale.lastActivityAt, now: now))
    }
    func testHooksObserveWithoutMixingClaudeRecordsOrSubagents() throws {
        let store = SessionStore(dir: dir.appendingPathComponent("records"))
        let env = ["AGENTDECK_PANE": "pane-1"]
        func event(_ name: String, extra: String = "") -> Data {
            Data("{\"session_id\":\"\(sid)\",\"cwd\":\"/work\",\"hook_event_name\":\"\(name)\"\(extra)}".utf8)
        }
        try CodexHook.handle(event("UserPromptSubmit"), environment: env, store: store)
        XCTAssertEqual(store.load(sid)?.state, "working")
        try CodexHook.handle(event("PermissionRequest"), environment: env, store: store)
        XCTAssertEqual(store.load(sid)?.state, "waiting")
        try CodexHook.handle(event("PostToolUse"), environment: env, store: store)
        XCTAssertEqual(store.load(sid)?.state, "working")
        try CodexHook.handle(event("Stop", extra: ",\"agent_id\":\"child\""), environment: env, store: store)
        XCTAssertEqual(store.load(sid)?.state, "working")
        try CodexHook.handle(event("Stop"), environment: env, store: store)
        XCTAssertEqual(store.load(sid)?.state, "done")
        XCTAssertEqual(store.load(sid)?.stateSeq, 4)
        try CodexHook.handle(event("SessionEnd"), environment: env, store: store)
        XCTAssertNotNil(store.load(sid)?.endedAt)
        try CodexHook.handle(event("SessionStart"), environment: env, store: store)
        XCTAssertNil(store.load(sid)?.endedAt)
        // 예전 데몬이 띄운 셸(예전 이름 CLAUDE_SESSIONS_PANE)도 화면 ID 로 읽는다
        try CodexHook.handle(event("UserPromptSubmit"), environment: ["CLAUDE_SESSIONS_PANE": "pane-old"], store: store)
        XCTAssertEqual(store.load(sid)?.pane, "pane-old")
        // 화면 ID 가 없으면(이 앱 밖의 codex) 적지 않는다
        try CodexHook.handle(event("Stop"), environment: [:], store: store)
        XCTAssertEqual(store.load(sid)?.state, "working")
    }
    func testCodexInstallerPreservesOtherHooksAndBacksUp() throws {
        let url = dir.appendingPathComponent("hooks.json")
        let original = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]},"other":true}"#.utf8)
        try original.write(to: url)
        let installer = HookInstaller.codex(daemonPath: "/a b/AgentDeckDaemon", hooksURL: url)
        let backup = try XCTUnwrap(installer.install())
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try installer.status(), .installed)
        _ = try installer.install()
        XCTAssertEqual(try installer.status(), .installed)
        let settings = try String(contentsOf: url)
        XCTAssertTrue(settings.contains("echo mine"))
        XCTAssertTrue(settings.contains("codex-hook"))
        _ = try installer.uninstall()
        XCTAssertEqual(try installer.status(), .notInstalled)
        XCTAssertTrue(try String(contentsOf: url).contains("echo mine"))
    }
    func testArgumentsExcludeBackgroundCommandsAndPrompts() {
        XCTAssertTrue(CodexArguments.isInteractive(["/bin/codex", "--yolo"]))
        XCTAssertFalse(CodexArguments.isInteractive(["codex", "app-server", "--listen", "unix://"]))
        XCTAssertFalse(CodexArguments.isInteractive(["node", "/bin/codex"]))
        XCTAssertFalse(CodexArguments.isInteractive(["codex", "-m", "x", "exec", "hello"]))
        XCTAssertEqual(CodexArguments.sessionId(["codex", "resume", sid]), sid)
        XCTAssertNil(CodexArguments.sessionId(["codex", "resume", "--last"]))
        XCTAssertEqual(CodexArguments.keptArgs(["codex", "--yolo", "resume", sid, "do this", "--model=x", "-s", "workspace-write", "--worktree"]), ["--yolo", "--model=x", "-s", "workspace-write"])
    }
    /// 설정 창의 기본 옵션(TermLayout CodexLaunch 가 만드는 긴 이름)과 짧은 이름이 모두 되살리기에 남는다
    func testKeptArgsCoverLaunchOptionFlags() {
        let launched = ["codex", "--ask-for-approval", "never", "--sandbox", "danger-full-access", "--model", "gpt-5", "첫 질문"]
        XCTAssertEqual(CodexArguments.keptArgs(launched), ["--ask-for-approval", "never", "--sandbox", "danger-full-access", "--model", "gpt-5"])
        XCTAssertEqual(CodexArguments.keptArgs(["codex", "-a", "on-request", "-s", "read-only", "-m", "o3"]),
                       ["-a", "on-request", "-s", "read-only", "-m", "o3"])
        XCTAssertEqual(CodexArguments.keptArgs(["codex", "--ask-for-approval=never", "--sandbox=read-only"]),
                       ["--ask-for-approval=never", "--sandbox=read-only"])
        XCTAssertEqual(CodexArguments.keptArgs(["codex", "--dangerously-bypass-approvals-and-sandbox", "--oss", "--local-provider", "ollama", "--strict-config"]),
                       ["--dangerously-bypass-approvals-and-sandbox", "--oss", "--local-provider", "ollama", "--strict-config"])
        XCTAssertTrue(CodexArguments.isInteractive(["codex", "--ask-for-approval", "never", "--sandbox", "read-only", "--model", "m"]))
    }
}
