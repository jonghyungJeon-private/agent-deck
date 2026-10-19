import XCTest
@testable import SessionCore

/// 오케스트레이션 중: Stop 의 background_tasks 기록, 파일로 끝남 확인, 상태 규칙
final class OrchestrationTests: XCTestCase {
    var dir: URL!
    let sid = "0b0b0b0b-1111-4222-8333-444444444444"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("orch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 실제 앱 데이터(launching.json 등)를 건드리지 않게
        setenv("AGENTDECK_HOME", dir.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - hook

    func send(_ store: SessionStore, _ json: String) throws {
        let me = try XCTUnwrap(ProcessUtil.info(getpid()))
        let proc = ProcInfo(pid: me.pid, ppid: me.ppid, startTime: me.startTime, hasTTY: true, tty: "/dev/ttys099",
                            command: "claude", isZombie: false)
        let context = HookHandler.Context(claudePid: proc.pid, claudeProcess: proc, claudeArgs: ["claude"],
                                          environment: ["AGENTDECK_PANE": "PANE-1"], liveProcesses: [])
        let body = #"{"session_id":"\#(sid)","cwd":"/tmp","# + json.dropFirst()
        try HookHandler.handle(input: Data(body.utf8), context: context, store: store)
    }

    func testStopRecordsInFlightBackgroundTasks() throws {
        let store = SessionStore(dir: dir.appendingPathComponent("sessions"))
        try send(store, #"{"hook_event_name":"UserPromptSubmit"}"#)
        XCTAssertNil(store.load(sid)?.background)
        try send(store, #"{"hook_event_name":"Stop","background_tasks":[{"id":"a1","type":"subagent","status":"running","agent_type":"general-purpose"},{"id":"b1","type":"shell","status":"running","command":"sleep 9"},{"id":"d1","type":"dream","status":"running"},{"id":"x","type":"shell","status":"completed"}],"session_crons":[]}"#)
        XCTAssertEqual(store.load(sid)?.state, "done")
        // 내부 정리 일(dream)·끝난 것은 세지 않는다
        XCTAssertEqual(store.load(sid)?.background, [BackgroundTask(id: "a1", type: "subagent"), BackgroundTask(id: "b1", type: "shell")])
        // 입력 대기·작업 중 동안은 목록을 그대로 둔다(하위 에이전트의 권한 요청 뒤 오케스트레이션으로 돌아오게)
        try send(store, #"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#)
        XCTAssertEqual(store.load(sid)?.state, "waiting")
        XCTAssertEqual(store.load(sid)?.background?.count, 2)
        // 다음 Stop 이 새 목록으로 바꾼다
        try send(store, #"{"hook_event_name":"Stop","background_tasks":[]}"#)
        XCTAssertEqual(store.load(sid)?.background, [])
        // 필드가 없으면(예전 Claude Code) 모름
        try send(store, #"{"hook_event_name":"Stop"}"#)
        XCTAssertNil(store.load(sid)?.background)
        // 모양이 이상해도 상태 기록은 한다
        try send(store, #"{"hook_event_name":"Stop","background_tasks":"weird"}"#)
        XCTAssertEqual(store.load(sid)?.state, "done")
        XCTAssertNil(store.load(sid)?.background)
        try send(store, #"{"hook_event_name":"Stop","background_tasks":[7,{"type":"shell"},{"id":"c1","type":"monitor"}]}"#)
        XCTAssertEqual(store.load(sid)?.background, [BackgroundTask(id: "c1", type: "monitor")])
        // 새로 시작하면 지운다
        try send(store, #"{"hook_event_name":"SessionStart","source":"resume"}"#)
        XCTAssertNil(store.load(sid)?.background)
    }

    // MARK: - 파일로 끝남 확인

    func testShellOutputEndMarkers() {
        XCTAssertTrue(BackgroundWork.outputEnded(Data("Build complete\n\n[exited with code 0]\n".utf8)))
        XCTAssertTrue(BackgroundWork.outputEnded(Data("…\n[exited with code 144]\n".utf8)))
        XCTAssertTrue(BackgroundWork.outputEnded(Data("abc\n\n[killed]\n".utf8)))
        XCTAssertFalse(BackgroundWork.outputEnded(Data()))
        XCTAssertFalse(BackgroundWork.outputEnded(Data("still running\n".utf8)))
        XCTAssertFalse(BackgroundWork.outputEnded(Data("[exited with code 0]\nmore output\n".utf8)))
    }

    /// 기록은 압축 JSON 한 줄씩(읽는 쪽이 바이트 표식으로 찾는다)
    static let toolUse = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#
    static let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#
    static let apiRequest = #"{"type":"api-request","params":{}}"#
    static let endTurn = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"끝"}]}}"#
    static let followUp = #"{"type":"user","message":{"role":"user","content":"하나 더"}}"#

    func lines(_ items: String...) -> Data { Data((items.joined(separator: "\n") + "\n").utf8) }

    func testAgentEndDetection() {
        // meta 의 finished 가 가장 확실하다
        XCTAssertTrue(BackgroundWork.agentEnded(meta: Data(#"{"agentType":"x","finished":true}"#.utf8), tail: Data()))
        XCTAssertFalse(BackgroundWork.agentEnded(meta: Data(#"{"agentType":"x"}"#.utf8), tail: lines(Self.toolUse, Self.toolResult, Self.apiRequest)))
        // finished 가 없는 예전 판: 마지막 assistant 가 end_turn 이면 끝
        XCTAssertTrue(BackgroundWork.agentEnded(meta: nil, tail: lines(Self.toolUse, Self.toolResult, Self.apiRequest, Self.endTurn)))
        // 도구 결과를 기다리는 중·API 요청 중
        XCTAssertFalse(BackgroundWork.agentEnded(meta: nil, tail: lines(Self.toolResult, Self.toolUse)))
        XCTAssertFalse(BackgroundWork.agentEnded(meta: nil, tail: lines(Self.toolUse, Self.toolResult, Self.apiRequest)))
        // 끝난 뒤 다시 이어 시켰다(SendMessage)
        XCTAssertFalse(BackgroundWork.agentEnded(meta: nil, tail: lines(Self.endTurn, Self.followUp, Self.apiRequest)))
    }

    func testInspectChecksSubagentsAndShellOutputs() throws {
        let fm = FileManager.default
        // <projects>/<폴더>/<세션>.jsonl, <세션>/subagents/agent-<id>.jsonl, <tmp>/<폴더>/<세션>/tasks/<id>.output
        let project = dir.appendingPathComponent("projects/-tmp-work")
        let subagents = project.appendingPathComponent("\(sid)/subagents")
        try fm.createDirectory(at: subagents, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("\(sid).jsonl")
        try Data().write(to: transcript)
        let tmp = dir.appendingPathComponent("tmp")
        let tasks = tmp.appendingPathComponent("-tmp-work/\(sid)/tasks")
        try fm.createDirectory(at: tasks, withIntermediateDirectories: true)

        try lines(Self.toolUse, Self.toolResult).write(to: subagents.appendingPathComponent("agent-arun.jsonl"))
        try Data(#"{"agentType":"general-purpose"}"#.utf8).write(to: subagents.appendingPathComponent("agent-arun.meta.json"))
        try lines(Self.toolUse, Self.endTurn).write(to: subagents.appendingPathComponent("agent-adone.jsonl"))
        try Data(#"{"agentType":"general-purpose","finished":true}"#.utf8).write(to: subagents.appendingPathComponent("agent-adone.meta.json"))
        try Data("compiling…\n".utf8).write(to: tasks.appendingPathComponent("bshrun.output"))
        try Data("ok\n\n[exited with code 0]\n".utf8).write(to: tasks.appendingPathComponent("bshdone.output"))

        let stoppedAt = Date(timeIntervalSinceNow: -30)
        let all = [BackgroundTask(id: "arun", type: "subagent"), BackgroundTask(id: "adone", type: "subagent"),
                   BackgroundTask(id: "bshrun", type: "shell"), BackgroundTask(id: "bshdone", type: "shell"),
                   BackgroundTask(id: "bgone", type: "shell"), BackgroundTask(id: "w1", type: "workflow")]
        let result = BackgroundWork.inspect(all, transcriptPath: transcript.path, sessionId: sid, stoppedAt: stoppedAt, tmpRoot: tmp)
        // 에이전트: arun + 확인할 파일이 없는 워크플로(hook 을 믿음), 셸: bshrun. bgone 은 출력이 정리됨(끝남)
        XCTAssertEqual(result.agents, 2)
        XCTAssertEqual(result.shells, 1)
        XCTAssertNotNil(result.lastEndedAt)
        XCTAssertNotNil(result.lastActiveAt)

        // 출력 폴더를 못 찾으면 셸은 확인할 수 없어 도는 것으로(hook 을 믿음)
        let unknown = BackgroundWork.inspect([BackgroundTask(id: "bshdone", type: "shell")], transcriptPath: transcript.path,
                                             sessionId: sid, stoppedAt: stoppedAt, tmpRoot: dir.appendingPathComponent("nowhere"))
        XCTAssertEqual(unknown.shells, 1)
        // 경로처럼 생긴 ID 는 파일로 찾지 않는다
        let odd = BackgroundWork.inspect([BackgroundTask(id: "../x", type: "shell")], transcriptPath: transcript.path,
                                         sessionId: sid, stoppedAt: stoppedAt, tmpRoot: tmp)
        XCTAssertEqual(odd.shells, 1)
    }

    // MARK: - 상태 규칙

    func testOrchestratingRules() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        let running = WorkStateRules.Background(agents: 2, shells: 1)
        func effective(_ state: String, _ background: WorkStateRules.Background?, now: Date = at.addingTimeInterval(5),
                       modified: Date? = nil, seen: WorkStateRules.Seen? = nil) -> String? {
            WorkStateRules.effective(state: state, at: at, seq: 3, transcriptModifiedAt: modified, seen: seen,
                                     background: background, now: now)
        }
        // 응답을 마쳤지만 맡긴 일이 돈다 → 완료가 아니다
        XCTAssertEqual(effective("done", running), "orchestrating")
        XCTAssertEqual(effective("idle", running), "orchestrating") // 오래 기다림 알림이 와도
        // 확인한 완료여도 일이 돌면 오케스트레이션
        XCTAssertEqual(effective("done", running, seen: .init(seq: 3, at: at)), "orchestrating")
        // 다 끝난 직후: 메인이 결과를 받아 다시 일할 때까지 잠깐 그대로(완료 알림이 두 번 나지 않게)
        let ended = WorkStateRules.Background(lastEndedAt: at.addingTimeInterval(100))
        XCTAssertEqual(effective("done", ended, now: at.addingTimeInterval(110)), "orchestrating")
        // 그 사이 hook 이 안 오면 완료로(이때 알린다)
        XCTAssertEqual(effective("done", ended, now: at.addingTimeInterval(100 + WorkStateRules.reportGrace + 1)), "done")
        // Stop 전에 끝난 것은 상관없다
        XCTAssertEqual(effective("done", WorkStateRules.Background(lastEndedAt: at.addingTimeInterval(-5))), "done")
        // 남은 일이 없거나 모르면(예전 Claude Code) 예전 그대로
        XCTAssertEqual(effective("done", WorkStateRules.Background()), "done")
        XCTAssertEqual(effective("done", nil), "done")
        XCTAssertEqual(effective("done", nil, seen: .init(seq: 3, at: at)), "idle")
        // 작업 중·오류는 그대로
        XCTAssertEqual(effective("working", running), "working")
        XCTAssertEqual(effective("error", running), "error")
        // 하위 에이전트의 권한 요청: 입력 대기를 그대로 보이고(알림), 허락해 그 에이전트가 다시 일하면 오케스트레이션으로
        XCTAssertEqual(effective("waiting", running), "waiting")
        XCTAssertEqual(effective("waiting", WorkStateRules.Background(agents: 1, lastActiveAt: at.addingTimeInterval(10))), "orchestrating")
        // 메인 대화가 늘었으면 메인이 일한다
        XCTAssertEqual(effective("waiting", running, modified: at.addingTimeInterval(10)), "working")
    }
}
