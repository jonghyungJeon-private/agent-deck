import Foundation
@testable import SessionCore
import XCTest

final class SessionNamingTests: XCTestCase {
    func testAutomaticNames() {
        XCTAssertTrue(SessionNaming.isAutomatic("demo_Project-1238", cwd: "/Users/a/demo_Project"))
        XCTAssertTrue(SessionNaming.isAutomatic("shop-api@feature/ABC-123", cwd: "/x/shop-api"))
        XCTAssertTrue(SessionNaming.isAutomatic("app", cwd: "/x/app"))
        XCTAssertFalse(SessionNaming.isAutomatic("결제 버그 수정", cwd: "/x/app"))
        XCTAssertFalse(SessionNaming.isAutomatic("app-login-fix", cwd: "/x/app"))
        XCTAssertFalse(SessionNaming.isAutomatic("app@ 회의 메모", cwd: "/x/app"))
    }

    func testPreview() {
        XCTAssertEqual(SessionNaming.preview(of: "  로그인   버그\n둘째 줄"), "로그인 버그")
        XCTAssertEqual(SessionNaming.preview(of: String(repeating: "가", count: 40), limit: 10), String(repeating: "가", count: 9) + "…")
    }

    func testFirstPromptSkipsMetaAndCommands() throws {
        let lines: [[String: Any]] = [
            ["type": "custom-title", "customTitle": "app-1200"],
            ["type": "user", "isMeta": true, "message": ["role": "user", "content": "Caveat: meta"]],
            ["type": "user", "message": ["role": "user", "content": "<command-name>/clear</command-name>"]],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "x"]]]],
            ["type": "user", "message": ["role": "user", "content": [["type": "image"], ["type": "text", "text": "이 화면 버그 고쳐줘"]]]],
            ["type": "user", "message": ["role": "user", "content": "두 번째 질문"]],
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try lines.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptReader.firstPrompt(path: url.path), "이 화면 버그 고쳐줘")
    }
}

final class HookInstallerMarkerTests: XCTestCase {
    /// 그 전 앱(ClaudeSessions)의 hook 만 있으면 "갱신하기"(outdated) → 갱신하면 AgentDeckDaemon 으로 바뀌고 다른 hook 은 그대로
    func testAgentDeckReplacesLegacyHooks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let legacy = HookInstaller(settingsURL: settings, executablePath: "/Applications/ClaudeSessions.app/Contents/MacOS/ClaudeSessions",
                                   markers: ["ClaudeSessions"])
        try legacy.install()
        // 사용자의 다른 hook 은 그대로 남아야 한다
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        var hooks = object["hooks"] as! [String: Any]
        hooks["Stop"] = [["hooks": [["type": "command", "command": "say done"]]]]
        object["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: object).write(to: settings)

        let deck = HookInstaller.claude(daemonPath: "/x/AgentDeck.app/Contents/MacOS/AgentDeckDaemon", settingsURL: settings)
        XCTAssertEqual(try deck.status(), .outdated)
        try deck.install()
        XCTAssertEqual(try deck.status(), .installed)
        XCTAssertEqual(try legacy.status(), .notInstalled)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertNotNil((after["hooks"] as! [String: Any])["Stop"])
    }
}

final class HookStatusTests: XCTestCase {
    func testStatusEventsUpdateRecord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(dir: dir)
        let me = try XCTUnwrap(ProcessUtil.info(getpid()))
        let proc = ProcInfo(pid: me.pid, ppid: me.ppid, startTime: me.startTime, hasTTY: true, tty: "/dev/ttys099",
                            command: "claude", isZombie: false)
        let context = HookHandler.Context(claudePid: proc.pid, claudeProcess: proc, claudeArgs: ["claude"],
                                          environment: ["AGENTDECK_PANE": "PANE-1", "TERM_PROGRAM": "AgentDeck"])
        let id = "11111111-2222-3333-4444-555555555555"
        func send(_ json: [String: Any]) throws {
            var body = json
            body["session_id"] = id
            try HookHandler.handle(input: JSONSerialization.data(withJSONObject: body), context: context, store: store)
        }
        // 세션 기록이 없어도 상태 이벤트가 오면 기록을 만들고 화면 ID 를 남긴다
        try send(["hook_event_name": "UserPromptSubmit", "cwd": "/tmp"])
        XCTAssertEqual(store.load(id)?.state, "working")
        XCTAssertEqual(store.load(id)?.pane, "PANE-1")
        try send(["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Bash 실행 허용?"])
        XCTAssertEqual(store.load(id)?.state, "waiting")
        XCTAssertEqual(store.load(id)?.stateMessage, "Bash 실행 허용?")
        // 기다리는 중에는 오래 기다림 알림이 덮지 않는다
        try send(["hook_event_name": "Notification", "notification_type": "idle_prompt"])
        XCTAssertEqual(store.load(id)?.state, "waiting")
        try send(["hook_event_name": "Stop"])
        XCTAssertEqual(store.load(id)?.state, "done")
        try send(["hook_event_name": "Notification", "notification_type": "auth_success"])
        XCTAssertEqual(store.load(id)?.state, "done") // 상관없는 알림은 무시
        try send(["hook_event_name": "UserPromptSubmit"])
        try send(["hook_event_name": "Notification", "notification_type": "idle_prompt"])
        XCTAssertEqual(store.load(id)?.state, "idle") // Esc 로 멈춘 작업 중은 쉬는 중으로 바로잡는다
        try send(["hook_event_name": "StopFailure", "error": "rate_limit"])
        XCTAssertEqual(store.load(id)?.state, "error")
        XCTAssertEqual(store.load(id)?.stateMessage, "rate_limit")
    }
}

final class WorkStateRulesTests: XCTestCase {
    var dir: URL!
    var store: SessionStore!
    let sid = "aaaaaaaa-0000-4000-8000-000000000001"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wsr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = SessionStore(dir: dir)
        setenv("AGENTDECK_HOME", dir.path, 1) // 실제 앱 데이터(launching.json 등)를 건드리지 않게
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 모든 hook 을 같은 시각(같은 초)에 보낸다
    func send(_ json: [String: Any], now: Date) throws {
        let me = try XCTUnwrap(ProcessUtil.info(getpid()))
        let proc = ProcInfo(pid: me.pid, ppid: me.ppid, startTime: me.startTime, hasTTY: true, tty: "/dev/ttys099",
                            command: "claude", isZombie: false)
        let context = HookHandler.Context(claudePid: proc.pid, claudeProcess: proc, claudeArgs: ["claude"],
                                          environment: ["CLAUDE_SESSIONS_PANE": "PANE-1"], now: now) // 예전 데몬의 셸(예전 이름)
        var body = json
        body["session_id"] = sid
        body["cwd"] = "/tmp"
        try HookHandler.handle(input: JSONSerialization.data(withJSONObject: body), context: context, store: store)
    }

    func key(_ record: SessionRecord) throws -> String {
        WorkStateRules.notificationKey(sessionId: record.sessionId, seq: record.stateSeq,
                                       state: try XCTUnwrap(record.state), at: try XCTUnwrap(record.stateAt))
    }

    /// 같은 초에 입력 대기 → 완료 → (다시) 입력 대기 → 완료가 와도 번호가 달라 모두 따로 알린다
    func testStateSeqSeparatesSameSecondChanges() throws {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        try send(["hook_event_name": "SessionStart", "source": "startup"], now: now)
        XCTAssertEqual(store.load(sid)?.stateSeq, 1) // 시작(쉬는 중)도 올린다
        var keys: [String] = []
        for event: [String: Any] in [
            ["hook_event_name": "PermissionRequest"], ["hook_event_name": "Stop"],
            ["hook_event_name": "PermissionRequest"], ["hook_event_name": "Stop"],
        ] {
            try send(event, now: now)
            let record = try XCTUnwrap(store.load(sid))
            XCTAssertEqual(record.stateAt, now)
            keys.append(try key(record))
        }
        XCTAssertEqual(store.load(sid)?.stateSeq, 5)
        XCTAssertEqual(Set(keys).count, 4, "\(keys)")
        // 쓰지 않고 넘어간 이벤트(입력 대기 중 오래 기다림 알림)는 번호를 올리지 않는다
        try send(["hook_event_name": "PermissionRequest"], now: now)
        try send(["hook_event_name": "Notification", "notification_type": "idle_prompt"], now: now)
        XCTAssertEqual(store.load(sid)?.state, "waiting")
        XCTAssertEqual(store.load(sid)?.stateSeq, 6)
        // 저장 형식은 예전 빌드와 같다: 소수 초 없는 ISO8601 이라 예전 디코더(.iso8601)로도 읽힌다
        let data = try Data(contentsOf: dir.appendingPathComponent("\(sid).json"))
        let old = JSONDecoder()
        old.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(try old.decode(SessionRecord.self, from: data))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(".000Z"))
    }

    /// 예전 형식 기록(stateSeq 없음)도 읽히고, 알림 열쇠는 "상태@시각" 으로 돌아간다
    func testOldRecordWithoutStateSeq() throws {
        let json = #"{"sessionId":"aaaaaaaa-0000-4000-8000-000000000001","cwd":"/tmp","pid":1,"pidStartedAt":0,"startedAt":"2026-10-15T06:56:09Z","stateAt":"2026-10-15T06:56:09Z","state":"waiting","stateMessage":"권한 요청"}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(sid).json"))
        let record = try XCTUnwrap(store.load(sid))
        XCTAssertNil(record.stateSeq)
        XCTAssertEqual(record.state, "waiting")
        let waitingKey = try key(record)
        XCTAssertFalse(waitingKey.contains("#"))
        var done = record
        done.state = "done" // 같은 초에 완료 — 상태가 달라 다른 알림
        XCTAssertNotEqual(waitingKey, try key(done))
        // 번호가 없던 기록에 hook 이 상태를 쓰면 1부터 붙는다
        try send(["hook_event_name": "Stop"], now: Date())
        XCTAssertEqual(store.load(sid)?.stateSeq, 1)
    }

    /// 확인한 완료만 쉬는 중으로. 번호가 있으면 같은 초에 새로 온 완료는 다시 완료로 보인다.
    func testSeenDone() {
        let at = Date(timeIntervalSince1970: 1_792_000_000)
        let seen = WorkStateRules.Seen(seq: 3, at: at)
        XCTAssertEqual(WorkStateRules.effective(state: "done", at: at, seq: 3, transcriptModifiedAt: nil, seen: seen), "idle")
        XCTAssertEqual(WorkStateRules.effective(state: "done", at: at, seq: 5, transcriptModifiedAt: nil, seen: seen), "done")
        XCTAssertEqual(WorkStateRules.effective(state: "done", at: at, seq: 5, transcriptModifiedAt: nil, seen: nil), "done")
        // 번호가 없으면(예전 기록) 시각으로
        let oldSeen = WorkStateRules.Seen(seq: nil, at: at)
        XCTAssertEqual(WorkStateRules.effective(state: "done", at: at, transcriptModifiedAt: nil, seen: oldSeen), "idle")
        XCTAssertEqual(WorkStateRules.effective(state: "done", at: at.addingTimeInterval(1), transcriptModifiedAt: nil,
                                                seen: oldSeen), "done")
        XCTAssertFalse(WorkStateRules.isSeen(nil, seq: 1, at: at))
        XCTAssertNil(WorkStateRules.effective(state: nil, at: at, transcriptModifiedAt: nil, seen: nil))
    }

    /// 입력 대기 → 작업 중 판단은 대화 파일 수정 시각(stat)만 본다(이름 정하기와 상관없이)
    func testWaitingTurnsWorkingWhenTranscriptGrows() throws {
        let at = Date(timeIntervalSince1970: 1_792_000_000)
        let transcript = dir.appendingPathComponent("t.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        try FileManager.default.setAttributes([.modificationDate: at.addingTimeInterval(5)], ofItemAtPath: transcript.path)
        let modified = try XCTUnwrap(WorkStateRules.transcriptModifiedAt(transcript.path))
        XCTAssertEqual(modified.timeIntervalSince(at), 5, accuracy: 0.01)
        XCTAssertEqual(WorkStateRules.effective(state: "waiting", at: at, transcriptModifiedAt: modified, seen: nil), "working")
        // 입력 대기 직후(2초 안)의 쓰기는 대기 그대로
        try FileManager.default.setAttributes([.modificationDate: at.addingTimeInterval(1)], ofItemAtPath: transcript.path)
        XCTAssertEqual(WorkStateRules.effective(state: "waiting", at: at,
                                                transcriptModifiedAt: WorkStateRules.transcriptModifiedAt(transcript.path),
                                                seen: nil), "waiting")
        // 파일이 없거나 경로를 모르면 대기 그대로
        XCTAssertNil(WorkStateRules.transcriptModifiedAt(dir.appendingPathComponent("none.jsonl").path))
        XCTAssertNil(WorkStateRules.transcriptModifiedAt(nil))
        XCTAssertEqual(WorkStateRules.effective(state: "waiting", at: at, transcriptModifiedAt: nil, seen: nil), "waiting")
        // 다른 상태에는 대화 파일이 영향을 주지 않는다
        XCTAssertEqual(WorkStateRules.effective(state: "done", at: at, transcriptModifiedAt: modified, seen: nil), "done")
    }
}
