import XCTest
@testable import SessionCore
import TermLayout
import TermWire

/// `agentdeck` 명령의 순수 로직: 칸 지정, 대기 상태 기계, 붙여넣기 인코딩, 마지막 답 글, 표·JSON, 화면 글 읽기, 앱 요청
final class AgentCliTests: XCTestCase {
    // MARK: - 칸 지정

    let panes = [
        PaneCandidate(id: "AB12CD34-0000-4000-8000-000000000001", name: "리뷰어"),
        PaneCandidate(id: "AB12EF56-0000-4000-8000-000000000002", name: "작업"),
        PaneCandidate(id: "FF000000-0000-4000-8000-000000000003", name: "작업"),
    ]

    func testSelectorFullIdPrefixNameAndSelf() {
        let selfId = panes[0].id
        XCTAssertEqual(PaneSelector.resolve(panes[1].id, among: panes, selfId: nil), .found(panes[1].id))
        XCTAssertEqual(PaneSelector.resolve(panes[1].id.lowercased(), among: panes, selfId: nil), .found(panes[1].id))
        XCTAssertEqual(PaneSelector.resolve("ab12cd", among: panes, selfId: nil), .found(panes[0].id))
        XCTAssertEqual(PaneSelector.resolve("ab12cd34000040008000", among: panes, selfId: nil), .found(panes[0].id), "대시 없이도")
        XCTAssertEqual(PaneSelector.resolve("리뷰어", among: panes, selfId: nil), .found(panes[0].id))
        XCTAssertEqual(PaneSelector.resolve(".", among: panes, selfId: selfId), .found(panes[0].id))
        XCTAssertEqual(PaneSelector.resolve(".", among: panes, selfId: nil), .noSelf)
        XCTAssertEqual(PaneSelector.resolve(".", among: panes, selfId: "없는-칸"), .noSelf)
        XCTAssertEqual(PaneSelector.resolve("zz", among: panes, selfId: nil), .notFound)
        XCTAssertEqual(PaneSelector.resolve("", among: panes, selfId: nil), .notFound)
    }

    func testSelectorAmbiguousShowsCandidates() {
        XCTAssertEqual(PaneSelector.resolve("ab12", among: panes, selfId: nil), .ambiguous([panes[0].id, panes[1].id]))
        XCTAssertEqual(PaneSelector.resolve("작업", among: panes, selfId: nil), .ambiguous([panes[1].id, panes[2].id]), "같은 이름이 둘")
        // 이름은 정확히 일치만(앞부분은 안 됨)
        XCTAssertEqual(PaneSelector.resolve("리뷰", among: panes, selfId: nil), .notFound)
    }

    func testNameBeatsPrefixButExactIdBeatsName() {
        let list = [PaneCandidate(id: "abcdef00-0", name: "x"), PaneCandidate(id: "11111111-1", name: "abcdef")]
        XCTAssertEqual(PaneSelector.resolve("abcdef", among: list, selfId: nil), .found("11111111-1"), "이름이 ID 앞부분보다 먼저")
        let same = [PaneCandidate(id: "abc", name: "y"), PaneCandidate(id: "def", name: "abc")]
        XCTAssertEqual(PaneSelector.resolve("abc", among: same, selfId: nil), .found("abc"), "전체 ID 가 이름보다 먼저")
    }

    func testShortIdsGrowOnCollision() {
        let ids = ["AB12CD34-1111", "AB12CD34-2222", "FF000000-3333"]
        let short = PaneSelector.shortIds(ids)
        XCTAssertEqual(short["FF000000-3333"], "ff000000")
        XCTAssertNotEqual(short[ids[0]], short[ids[1]])
        XCTAssertTrue(short[ids[0]]!.count > 8 && ids[0].lowercased().hasPrefix(short[ids[0]]!))
        // 줄인 ID 로 다시 지정된다
        let candidates = ids.map { PaneCandidate(id: $0, name: $0) }
        XCTAssertEqual(PaneSelector.resolve(short[ids[1]]!, among: candidates, selfId: nil), .found(ids[1]))
    }

    // MARK: - 대기 상태 기계

    typealias Obs = WaitMachine.Observation
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func machine(_ base: Obs, config: WaitMachine.Config = .init()) -> WaitMachine {
        WaitMachine(baseline: ["p": base], order: ["p"], config: config, now: t0)
    }

    func result(_ decision: WaitMachine.Decision) -> (WaitMachine.PaneResult, Int32)? {
        if case .finished(let results, _, let code) = decision { return (results[0], code) }
        return nil
    }

    func testWaitAlreadyWorkingThenDone() {
        var m = machine(Obs(state: .working, seq: 5))
        XCTAssertEqual(m.update(["p": Obs(state: .working, seq: 5)], now: t0 + 1), .waiting)
        let (r, code) = result(m.update(["p": Obs(state: .done, seq: 6)], now: t0 + 2))!
        XCTAssertEqual(r.reason, .finished)
        XCTAssertEqual(r.state, .done)
        XCTAssertEqual(code, 0)
    }

    /// 함정: 지시 직후의 idle·done 을 끝으로 착각하지 않는다 — working 을 본 뒤에만 끝
    func testWaitDoesNotMistakeBaselineIdleForFinished() {
        var m = machine(Obs(state: .idle, seq: 5))
        XCTAssertEqual(m.update(["p": Obs(state: .idle, seq: 5)], now: t0 + 0.5), .waiting)
        XCTAssertEqual(m.update(["p": Obs(state: .idle, seq: 5)], now: t0 + 2), .waiting)
        XCTAssertEqual(m.update(["p": Obs(state: .working, seq: 6)], now: t0 + 2.5), .waiting, "시작을 봤다")
        XCTAssertEqual(m.update(["p": Obs(state: .working, seq: 6)], now: t0 + 20), .waiting, "유예는 시작 전에만")
        let (r, code) = result(m.update(["p": Obs(state: .idle, seq: 7)], now: t0 + 21))!
        XCTAssertEqual(r.reason, .finished)
        XCTAssertEqual(code, 0)
    }

    /// 함정: 사용자가 안 본 done 은 idle 로 안 바뀐다 — done 도 끝이다
    func testWaitTreatsUnseenDoneAsFinished() {
        var m = machine(Obs(state: .idle, seq: 1))
        _ = m.update(["p": Obs(state: .working, seq: 2)], now: t0 + 0.4)
        let (r, _) = result(m.update(["p": Obs(state: .done, seq: 3)], now: t0 + 5))!
        XCTAssertEqual(r.state, .done)
        XCTAssertEqual(r.reason, .finished)
    }

    func testWaitFastTurnBetweenPollsIsFinished() {
        // working 을 못 보고 새 기록(번호가 오름)의 done 만 봤다 → 시작과 끝이 사이에 지나감
        var m = machine(Obs(state: .done, seq: 4))
        let (r, code) = result(m.update(["p": Obs(state: .done, seq: 6)], now: t0 + 0.5))!
        XCTAssertEqual(r.reason, .finished)
        XCTAssertTrue(r.started)
        XCTAssertEqual(code, 0)
    }

    func testWaitSeenChangeIsNotANewEvent() {
        // 같은 기록(번호 그대로)에서 done → idle(사용자가 봄)은 새 일이 아니다
        var m = machine(Obs(state: .done, seq: 4))
        XCTAssertEqual(m.update(["p": Obs(state: .idle, seq: 4)], now: t0 + 0.5), .waiting)
    }

    func testWaitNoStartAfterGraceReturnsCurrentState() {
        var m = machine(Obs(state: .done, seq: 4), config: .init(grace: 3))
        XCTAssertEqual(m.update(["p": Obs(state: .done, seq: 4)], now: t0 + 2.9), .waiting)
        let (r, code) = result(m.update(["p": Obs(state: .done, seq: 4)], now: t0 + 3))!
        XCTAssertEqual(r.reason, .noStart)
        XCTAssertFalse(r.started)
        XCTAssertEqual(r.state, .done)
        XCTAssertEqual(code, 0)
    }

    func testWaitExitCodes() {
        var waiting = machine(Obs(state: .working))
        XCTAssertEqual(result(waiting.update(["p": Obs(state: .waiting, seq: 1)], now: t0 + 1))!.1, 2)
        var error = machine(Obs(state: .working))
        XCTAssertEqual(result(error.update(["p": Obs(state: .error, seq: 1)], now: t0 + 1))!.1, 3)
        var timeout = machine(Obs(state: .working), config: .init(timeout: 10))
        XCTAssertEqual(timeout.update(["p": Obs(state: .working)], now: t0 + 9), .waiting)
        let (r, code) = result(timeout.update(["p": Obs(state: .working)], now: t0 + 10))!
        XCTAssertEqual(r.reason, .timeout)
        XCTAssertEqual(code, 124)
        var gone = machine(Obs(state: .working))
        let (g, goneCode) = result(gone.update(["p": Obs(state: .unknown, gone: true)], now: t0 + 1))!
        XCTAssertEqual(g.reason, .gone)
        XCTAssertEqual(goneCode, 1)
        var unknown = machine(Obs(state: .unknown))
        XCTAssertEqual(result(unknown.update(["p": Obs(state: .unknown)], now: t0 + 0.1))!.1, 1, "상태 hook 이 없으면 기다릴 수 없다")
    }

    func testWaitAllVersusAny() {
        let base: [String: Obs] = ["a": Obs(state: .working), "b": Obs(state: .working)]
        var all = WaitMachine(baseline: base, order: ["a", "b"], config: .init(), now: t0)
        XCTAssertEqual(all.update(["a": Obs(state: .done, seq: 1), "b": Obs(state: .working)], now: t0 + 1), .waiting, "모두 끝나야")
        guard case .finished(let results, let pending, let code) = all.update(["a": Obs(state: .done, seq: 1), "b": Obs(state: .waiting, seq: 2)], now: t0 + 2)
        else { return XCTFail() }
        XCTAssertEqual(results.map(\.id), ["a", "b"])
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(code, 2, "하나라도 입력 대기면 2")

        var any = WaitMachine(baseline: base, order: ["a", "b"], config: .init(any: true), now: t0)
        guard case .finished(let first, let rest, let anyCode) = any.update(["a": Obs(state: .working), "b": Obs(state: .done, seq: 1)], now: t0 + 1)
        else { return XCTFail() }
        XCTAssertEqual(first.map(\.id), ["b"])
        XCTAssertEqual(rest, ["a"])
        XCTAssertEqual(anyCode, 0)
        // 시간 초과: 못 끝낸 칸은 timeout
        var late = WaitMachine(baseline: base, order: ["a", "b"], config: .init(timeout: 5), now: t0)
        guard case .finished(let all5, _, let code5) = late.update(["a": Obs(state: .done, seq: 1), "b": Obs(state: .working)], now: t0 + 5)
        else { return XCTFail() }
        XCTAssertEqual(all5.map(\.reason), [.finished, .timeout])
        XCTAssertEqual(code5, 124)
    }

    func testPaneStateMapping() {
        func reading(_ state: String?, foreground: String? = "claude", background: WorkStateRules.Background? = nil,
                     withSession: Bool = true) -> PaneReading {
            let info = PaneInfo(id: "p", title: "t", cwd: "/tmp", pid: 1, tty: nil, foreground: foreground, cols: 80, rows: 24,
                                bufferedBytes: 0, createdAt: Date())
            var record: SessionRecord?
            if withSession { record = SessionRecord(sessionId: "s", cwd: "/tmp", transcriptPath: nil, pid: 1, pidStartedAt: 0, startedAt: Date()) }
            var r = PaneReading(pane: info, session: record, codex: nil, cwd: "/tmp")
            r.state = state
            r.background = background
            return r
        }
        XCTAssertEqual(CliPanes.state(of: reading("working"), agents: []), .working)
        XCTAssertEqual(CliPanes.state(of: reading("orchestrating", background: .init(agents: 2)), agents: []), .working, "오케스트레이션 중은 작업 중")
        XCTAssertEqual(CliPanes.state(of: reading("waiting"), agents: []), .waiting)
        XCTAssertEqual(CliPanes.state(of: reading("done"), agents: []), .done)
        XCTAssertEqual(CliPanes.state(of: reading("idle"), agents: []), .idle)
        XCTAssertEqual(CliPanes.state(of: reading("error"), agents: []), .error)
        XCTAssertEqual(CliPanes.state(of: reading(nil), agents: []), .unknown)
        XCTAssertEqual(CliPanes.state(of: reading(nil, foreground: "zsh", withSession: false), agents: []), .idle, "셸 프롬프트")
        XCTAssertEqual(CliPanes.state(of: reading(nil, foreground: "sleep", withSession: false), agents: []), .working, "셸에서 명령이 도는 중")
        XCTAssertEqual(CliPanes.subagentCount(of: reading("orchestrating", background: .init(agents: 2, shells: 1)), agents: []), 2)
        let agent = SubagentActivity(id: "a", sessionId: "s", paneId: "p", description: "d", lastActive: Date(), running: true)
        XCTAssertEqual(CliPanes.subagentCount(of: reading("working"), agents: [agent]), 1)
    }

    func testAgentReadiness() {
        func sample(_ t: TimeInterval, bytes: Int, session: Bool = false, codex: Bool = false, fg: String? = "claude") -> AgentReadiness.Sample {
            .init(foreground: fg, hasSession: session, hasCodexSession: codex, bufferedBytes: bytes, at: t0 + t)
        }
        var claude = AgentReadiness(kind: .claude)
        claude.observe(sample(0, bytes: 10, fg: "zsh"))
        XCTAssertFalse(claude.isReady, "아직 셸")
        claude.observe(sample(1, bytes: 500, session: true))
        XCTAssertFalse(claude.isReady, "출력이 아직 나오는 중")
        claude.observe(sample(1.5, bytes: 500, session: true))
        XCTAssertFalse(claude.isReady)
        claude.observe(sample(2, bytes: 500, session: true))
        XCTAssertTrue(claude.isReady, "SessionStart 를 보고 잠잠해졌다")
        // hook 기록(SessionStart)을 못 봤으면 얼마가 지나도 보내지 않는다 — 폴더 신뢰 확인 창에서 Enter 가 승인이 되지 않게
        var hookless = AgentReadiness(kind: .claude)
        hookless.observe(sample(0, bytes: 5))
        for second in stride(from: 3.0, through: 60, by: 3) { hookless.observe(sample(second, bytes: 5)) }
        XCTAssertFalse(hookless.isReady, "claude 가 앞에서 돌아도 세션 기록이 없으면 확인 창일 수 있다")
        // codex: 세션 기록(스레드)이 생긴 뒤 잠잠해지면
        var codex = AgentReadiness(kind: .codex)
        codex.observe(sample(0, bytes: 5, fg: "codex"))
        codex.observe(sample(5, bytes: 5, fg: "codex"))
        XCTAssertFalse(codex.isReady, "프로세스만 있고 세션 기록이 없다")
        codex.observe(sample(6, bytes: 9, codex: true, fg: "codex"))
        XCTAssertFalse(codex.isReady)
        codex.observe(sample(7.3, bytes: 9, codex: true, fg: "codex"))
        XCTAssertTrue(codex.isReady)
    }

    func testFirstInstructionNeedsConfirmationAndExplainsWhenUnsent() {
        XCTAssertFalse(FirstInstruction.canConfirm(kind: .claude, claudeHookInstalled: false), "hook 이 없으면 처음 지시를 보내지 않는다")
        XCTAssertTrue(FirstInstruction.canConfirm(kind: .claude, claudeHookInstalled: true))
        XCTAssertTrue(FirstInstruction.canConfirm(kind: .codex, claudeHookInstalled: false), "codex 는 세션 기록으로 확인")
        XCTAssertEqual(FirstInstruction.exitCode, 2)
        let message = FirstInstruction.unsentMessage(kind: .claude, shortId: "ab12cd34", reason: .notConfirmed)
        XCTAssertTrue(message.contains("처음 지시를 보내지 못함: claude 가 확인을 기다리는 중일 수 있음, agentdeck read ab12cd34 로 확인"))
        let noHook = FirstInstruction.unsentMessage(kind: .claude, shortId: "ab12cd34", reason: .noHook)
        XCTAssertTrue(noHook.contains("처음 지시를 보내지 못함: claude 가 확인을 기다리는 중일 수 있음, agentdeck read ab12cd34 로 확인"))
        XCTAssertTrue(noHook.contains("hook"))
    }

    // MARK: - send 거절 · wait 관찰 실패

    func testSendRefusesWaitingPaneUnlessForced() {
        let refusal = SendGuard.refusal(state: .waiting, message: "권한 요청", shortId: "ab12cd34", force: false)
        XCTAssertEqual(refusal?.code, 2)
        XCTAssertTrue(refusal?.message.contains("권한 요청") == true)
        XCTAssertTrue(refusal?.message.contains("--force") == true)
        XCTAssertNil(SendGuard.refusal(state: .waiting, message: nil, shortId: "ab12cd34", force: true), "--force 일 때만")
        for state in [PaneState.working, .done, .idle, .error, .unknown] {
            XCTAssertNil(SendGuard.refusal(state: state, message: nil, shortId: "x", force: false), "\(state)")
        }
        XCTAssertEqual(SendGuard.refusal(state: .dormant, message: nil, shortId: "x", force: true)?.code, 1, "꺼진 칸은 --force 로도 안 됨")
    }

    func testObservationGuardSkipsTransientFailuresAndFailsWhenClosedOrLong() {
        var guardian = ObservationGuard(tolerance: 30)
        XCTAssertEqual(guardian.record(observed: true, linkClosed: false, now: t0), .ok)
        XCTAssertEqual(guardian.record(observed: false, linkClosed: false, now: t0 + 1), .skip, "일시 실패는 그 회차만 건너뜀")
        XCTAssertEqual(guardian.record(observed: false, linkClosed: false, now: t0 + 20), .skip)
        XCTAssertEqual(guardian.record(observed: true, linkClosed: false, now: t0 + 21), .ok)
        // 성공하면 실패 시간이 처음부터 다시
        XCTAssertEqual(guardian.record(observed: false, linkClosed: false, now: t0 + 40), .skip)
        XCTAssertEqual(guardian.record(observed: false, linkClosed: false, now: t0 + 69), .skip)
        XCTAssertEqual(guardian.record(observed: false, linkClosed: false, now: t0 + 70), .fail, "연속 30초")
        var closed = ObservationGuard(tolerance: 30)
        XCTAssertEqual(closed.record(observed: false, linkClosed: true, now: t0), .fail, "연결이 닫힘")
    }

    func testWaitMachineIgnoresSkippedObservationsAndLostExitCode() {
        // nil 관찰(건너뜀)은 machine 에 안 들어가므로 상태가 그대로 — 건너뛴 사이에 working 이었던 칸이 끝난 것으로 보이지 않는다
        var machine = WaitMachine(baseline: ["a": .init(state: .idle, seq: 1)], order: ["a"], config: .init(timeout: nil, grace: 3), now: t0)
        XCTAssertEqual(machine.update(["a": .init(state: .working, seq: 2)], now: t0 + 1), .waiting)
        // (여기서 데몬 읽기 실패 회차들 — update 를 부르지 않는다)
        guard case .finished(let results, _, let code) = machine.update(["a": .init(state: .done, seq: 3)], now: t0 + 9) else { return XCTFail() }
        XCTAssertEqual(results.first?.reason, .finished)
        XCTAssertEqual(code, 0)
        // 오래 못 읽은 실패: 칸이 사라진 것(gone)이 아니라 lost, 종료 코드 1
        guard case .finished(let lost, let pending, let lostCode) = WaitMachine.lost(order: ["a", "b"], states: ["a": .working]) else { return XCTFail() }
        XCTAssertEqual(lost.map(\.reason), [.lost, .lost])
        XCTAssertEqual(lost.map(\.state), [.working, .unknown])
        XCTAssertEqual(lost.map(\.exitCode), [1, 1])
        XCTAssertEqual(lostCode, 1)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - 읽기 결과가 예전 makeRows 와 같다

    private func paneInfo(_ foreground: String?) -> PaneInfo {
        PaneInfo(id: "p", title: "tmp", cwd: "/tmp", pid: 1, tty: nil, foreground: foreground, cols: 80, rows: 24, bufferedBytes: 0, createdAt: Date())
    }

    /// 예전 TermModel.workStatus 가 하던 호출(대화 파일 수정 시각은 입력 대기일 때만, 백그라운드 확인 결과 포함)
    func testPaneStateReaderClaudeMatchesOldMakeRows() throws {
        let now = t0 + 1000
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: transcript))
        try FileManager.default.setAttributes([.modificationDate: t0 + 500], ofItemAtPath: transcript) // 입력 대기(t0) 한참 뒤에 늘었다

        func record(_ state: String?, seq: Int = 5, at: Date? = nil) -> SessionRecord {
            var r = SessionRecord(sessionId: "s", cwd: "/tmp", transcriptPath: transcript, pid: 1, pidStartedAt: 0, startedAt: t0)
            r.state = state
            r.stateAt = at ?? (state == nil ? nil : t0)
            r.stateSeq = state == nil ? nil : seq
            r.stateMessage = state == "waiting" ? "권한 요청" : nil
            return r
        }
        func read(_ r: SessionRecord, seen: WorkStateRules.Seen? = nil) -> PaneReading {
            var reading = PaneReading(pane: paneInfo("claude"), session: r, codex: nil, cwd: "/tmp")
            PaneStateReader.claudeState(&reading, session: r, seen: seen, transcriptFallback: { _ in nil }, now: now)
            return reading
        }
        // 작업 중·완료(안 봄)·완료(봄 → 쉬는 중)·오류
        XCTAssertEqual(read(record("working")).state, "working")
        XCTAssertEqual(read(record("done")).state, "done")
        XCTAssertEqual(read(record("done"), seen: .init(seq: 5, at: t0)).state, "idle", "본 완료는 쉬는 중")
        XCTAssertEqual(read(record("done", seq: 6), seen: .init(seq: 5, at: t0)).state, "done", "새 번호의 완료는 아직 안 봄")
        XCTAssertEqual(read(record("error")).state, "error")
        // 입력 대기 + 대화 파일이 그 뒤 늘었으면(허락하고 이어서 일함) 작업 중
        let waiting = read(record("waiting"))
        XCTAssertEqual(waiting.state, "working")
        XCTAssertEqual(waiting.message, "권한 요청")
        XCTAssertEqual(waiting.seq, 5)
        XCTAssertEqual(waiting.at, t0)
        // 파일이 안 늘었으면 입력 대기 그대로
        try FileManager.default.setAttributes([.modificationDate: t0 - 5], ofItemAtPath: transcript)
        XCTAssertEqual(read(record("waiting")).state, "waiting")
        // 같은 입력으로 예전 호출과 같은 값
        let r = record("done")
        XCTAssertEqual(read(r).state, WorkStateRules.effective(state: r.state, at: r.stateAt, seq: r.stateSeq, transcriptModifiedAt: nil, seen: nil, now: now))
        // 상태 기록이 없으면 nil → 명령줄에서는 unknown(예전 앱의 .unknown)
        XCTAssertNil(read(record(nil)).state)
        XCTAssertEqual(CliPanes.state(of: read(record(nil)), agents: []), .unknown)
    }

    func testPaneStateReaderCodexShellAndDormant() {
        let codex = CodexSession(id: "c", cwd: "/w", title: "t", transcript: nil, state: "done", stateAt: t0, stateSeq: nil, message: nil)
        var reading = PaneReading(pane: paneInfo("codex"), session: nil, codex: nil, cwd: "/w")
        PaneStateReader.codexState(&reading, codex: codex, seen: nil, now: t0 + 10)
        XCTAssertEqual(reading.state, "done")
        PaneStateReader.codexState(&reading, codex: codex, seen: .init(seq: nil, at: t0), now: t0 + 10)
        XCTAssertEqual(reading.state, "idle", "본 완료는 쉬는 중")
        XCTAssertEqual(reading.at, t0)
        // 셸: hook 상태가 없다 — 앞에서 도는 프로그램으로
        let shell = PaneReading(pane: paneInfo("zsh"), session: nil, codex: nil, cwd: "/tmp")
        XCTAssertNil(shell.state)
        XCTAssertEqual(shell.kind, .shell)
        XCTAssertEqual(CliPanes.state(of: shell, agents: []), .idle)
        XCTAssertEqual(CliPanes.state(of: PaneReading(pane: paneInfo("npm"), session: nil, codex: nil, cwd: "/tmp"), agents: []), .working)
        // 꺼진 칸
        let dormant = CliPanes.dormant(id: "d", shortId: "d", name: "n", kind: .claude, cwd: "/w")
        XCTAssertEqual(dormant.state, .dormant)
        XCTAssertNil(dormant.stateSeq)
    }

    // MARK: - 이름: 저장된 이름 먼저

    func testStoredNameUsesNamesJsonWithoutTranscript() {
        let record = SessionRecord(sessionId: "s1", cwd: "/w/repo", transcriptPath: "/nonexistent/should-not-be-read.jsonl", pid: 1, pidStartedAt: 0, startedAt: t0)
        let claude = PaneReading(pane: paneInfo("claude"), session: record, codex: nil, cwd: "/w/repo")
        XCTAssertNil(PaneNaming.storedName(claude, names: [:]), "저장된 이름이 없으면 비싼 길이 필요하다")
        XCTAssertEqual(PaneNaming.storedName(claude, names: ["session:s1": SavedName(title: "직접", source: "user")]), "직접")
        XCTAssertEqual(PaneNaming.storedName(claude, names: ["session:s1": SavedName(title: "자동 제목", source: "auto")]), "자동 제목", "auto 도 저장된 이름")
        XCTAssertNil(PaneNaming.storedName(claude, names: ["pane:p": SavedName(title: "칸 이름", source: "user")]), "세션이 있는 칸은 칸 이름을 안 쓴다(앱과 같음)")
        let shell = PaneReading(pane: paneInfo("zsh"), session: nil, codex: nil, cwd: "/w/repo")
        XCTAssertEqual(PaneNaming.storedName(shell, names: [:]), "repo")
        XCTAssertEqual(PaneNaming.storedName(shell, names: ["pane:p": SavedName(title: "칸 이름", source: "user")]), "칸 이름")
    }

    // MARK: - 붙여넣기 인코딩

    func testPlainSingleLineSendsTextThenEnterSeparately() {
        let steps = PasteEncoding.plan(text: "안녕 hello", bracketedPaste: true, enter: true)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].bytes, Array("안녕 hello".utf8))
        XCTAssertGreaterThan(steps[0].delayAfter, 0, "글과 Enter 를 같은 덩어리로 보내지 않는다")
        XCTAssertEqual(steps[1].bytes, [0x0d])
    }

    func testMultilineAndLongUseBracketedPaste() {
        let multi = PasteEncoding.plan(text: "a\nb\n", bracketedPaste: true, enter: true)
        XCTAssertEqual(multi[0].bytes, PasteEncoding.pasteStart + Array("a\nb".utf8) + PasteEncoding.pasteEnd, "끝 줄바꿈은 Enter 가 대신")
        XCTAssertEqual(multi.last?.bytes, [0x0d])
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(PasteEncoding.plan(text: long, bracketedPaste: true, enter: false).count, 1)
        XCTAssertEqual(PasteEncoding.plan(text: long, bracketedPaste: true, enter: false)[0].bytes.prefix(6), PasteEncoding.pasteStart[...])
    }

    func testBracketedPasteOffFallsBackToCarriageReturns() {
        let steps = PasteEncoding.plan(text: "ls\npwd", bracketedPaste: false, enter: true)
        XCTAssertEqual(steps[0].bytes, Array("ls\rpwd".utf8))
    }

    func testSanitizeBlocksPasteEscape() {
        let evil = "ok\u{1b}[201~rm -rf /\r\nnext\u{7}"
        let clean = PasteEncoding.sanitize(evil)
        XCTAssertFalse(clean.contains("\u{1b}"))
        XCTAssertFalse(clean.contains("\r"))
        XCTAssertEqual(clean, "ok[201~rm -rf /\nnext")
        let steps = PasteEncoding.plan(text: evil, bracketedPaste: true, enter: false)
        // 붙여넣기 끝 표시는 맨 끝에 하나뿐
        let bytes = steps[0].bytes
        XCTAssertEqual(Array(bytes.suffix(6)), PasteEncoding.pasteEnd)
        let endMarks = (0...(bytes.count - 6)).filter { Array(bytes[$0..<($0 + 6)]) == PasteEncoding.pasteEnd }
        XCTAssertEqual(endMarks.count, 1)
    }

    /// claude·codex 칸은 한 줄 글도 붙여넣기로 — `!`·`/` 로 시작하는 글이 모드·명령으로 해석되지 않게. 셸 칸은 그대로.
    func testAgentPanesGetSingleLineAsBracketedPasteButShellDoesNot() {
        XCTAssertTrue(PasteEncoding.alwaysPaste(kind: .claude))
        XCTAssertTrue(PasteEncoding.alwaysPaste(kind: .codex))
        XCTAssertFalse(PasteEncoding.alwaysPaste(kind: .shell))
        let agent = PasteEncoding.plan(text: "!rm -rf x", bracketedPaste: true, enter: true, alwaysPaste: true)
        XCTAssertEqual(agent.first?.bytes, PasteEncoding.pasteStart + Array("!rm -rf x".utf8) + PasteEncoding.pasteEnd)
        XCTAssertEqual(agent.last?.bytes, PasteEncoding.enter)
        let slash = PasteEncoding.plan(text: "/clear", bracketedPaste: true, enter: true, alwaysPaste: true)
        XCTAssertEqual(slash.first?.bytes, PasteEncoding.pasteStart + Array("/clear".utf8) + PasteEncoding.pasteEnd)
        // 붙여넣기 모드가 꺼져 있으면(아직 안 뜸) 어쩔 수 없이 그대로
        XCTAssertEqual(PasteEncoding.plan(text: "/clear", bracketedPaste: false, enter: true, alwaysPaste: true).first?.bytes, Array("/clear".utf8))
        // 셸 칸: 한 줄은 그대로
        XCTAssertEqual(PasteEncoding.plan(text: "ls", bracketedPaste: true, enter: true, alwaysPaste: false).first?.bytes, Array("ls".utf8))
        // 빈 글은 Enter 만
        XCTAssertEqual(PasteEncoding.plan(text: "", bracketedPaste: true, enter: true, alwaysPaste: true).map(\.bytes), [PasteEncoding.enter])
    }

    func testNoEnterSendsOnlyText() {
        XCTAssertEqual(PasteEncoding.plan(text: "abc", bracketedPaste: true, enter: false), [PasteEncoding.Step(Array("abc".utf8))])
    }

    // MARK: - 마지막 assistant 글

    func line(_ type: String, id: String? = nil, text: String? = nil, blocks: [[String: Any]]? = nil, sidechain: Bool = false,
              meta: Bool = false) -> String {
        var message: [String: Any] = [:]
        if let id { message["id"] = id }
        if let blocks { message["content"] = blocks } else if let text { message["content"] = type == "user" ? text as Any : [["type": "text", "text": text]] }
        var object: [String: Any] = ["type": type, "message": message]
        if sidechain { object["isSidechain"] = true }
        if meta { object["isMeta"] = true }
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    func testLastClaudeTextIsFinalMessageAfterToolUse() {
        let d = data([
            line("user", text: "분석해 줘"),
            line("assistant", id: "m1", text: "확인해 보겠습니다."),
            line("assistant", id: "m1", blocks: [["type": "tool_use", "name": "Bash", "input": [:]]]),
            line("user", blocks: [["type": "tool_result", "content": "ok"]]),
            line("assistant", id: "m2", text: "결과: 문제 없음."),
        ])
        XCTAssertEqual(TurnReply.lastClaudeText(in: d), "결과: 문제 없음.")
    }

    func testLastClaudeTextJoinsPiecesOfSameMessage() {
        let d = data([
            line("user", text: "q"),
            line("assistant", id: "m1", text: "첫 문단"),
            line("assistant", id: "m1", text: "둘째 문단"),
        ])
        XCTAssertEqual(TurnReply.lastClaudeText(in: d), "첫 문단\n\n둘째 문단")
    }

    func testLastClaudeTextDoesNotReturnPreviousTurn() {
        let d = data([
            line("user", text: "지난 질문"),
            line("assistant", id: "m1", text: "지난 답"),
            line("user", text: "이번 질문"),
            line("assistant", id: "m2", blocks: [["type": "tool_use", "name": "Edit", "input": [:]]]),
        ])
        XCTAssertNil(TurnReply.lastClaudeText(in: d), "이번 턴에 글이 없으면 지난 답을 돌려주지 않는다")
    }

    func testLastClaudeTextSkipsSidechainAndNoise() {
        let d = data([
            line("user", text: "q"),
            line("assistant", id: "m1", text: "진짜 답"),
            line("assistant", id: "s1", text: "하위 에이전트 말", sidechain: true),
            "{\"type\":\"attachment\"}",
            "깨진 줄",
            line("user", text: "<system-reminder>", meta: true),
        ])
        XCTAssertEqual(TurnReply.lastClaudeText(in: d), "진짜 답")
        XCTAssertNil(TurnReply.lastClaudeText(in: Data()))
    }

    func testReadFromOffsetOnlyReturnsAppendedPart() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("turn-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        try data([line("user", text: "old"), line("assistant", id: "m0", text: "지난 답")]).write(to: path)
        let offset = TurnReply.size(of: path.path)
        XCTAssertGreaterThan(offset, 0)
        XCTAssertNil(TurnReply.lastClaudeText(in: TurnReply.read(path: path.path, from: offset)), "보내기 전 기록은 이번 턴이 아니다")
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        handle.write(data([line("user", text: "new"), line("assistant", id: "m1", text: "이번 답")]))
        try handle.close()
        XCTAssertEqual(TurnReply.lastClaudeText(in: TurnReply.read(path: path.path, from: offset)), "이번 답")
        XCTAssertEqual(TurnReply.size(of: nil), 0)
    }

    func testLastCodexText() {
        func item(_ role: String, _ text: String) -> String {
            let payload: [String: Any] = ["type": "message", "role": role, "content": [["type": "output_text", "text": text]]]
            return String(data: try! JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": payload]), encoding: .utf8)!
        }
        XCTAssertEqual(TurnReply.lastCodexText(in: data([item("user", "q"), item("assistant", "a1"), item("assistant", "a2")])), "a2")
        XCTAssertNil(TurnReply.lastCodexText(in: data([item("assistant", "old"), item("user", "new q")])))
    }

    // MARK: - 표·JSON·시간

    func testTableAlignsKoreanWidth() {
        XCTAssertEqual(CliOutput.displayWidth("한글ab"), 6)
        let table = CliOutput.table(headers: ["ID", "이름", "상태"], rows: [["a1", "리뷰어", "done"], ["b22", "x", "working"]])
        let lines = table.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        // 둘째 칸 시작 위치가 모든 줄에서 같다(화면 칸 수 기준)
        let starts = lines.map { CliOutput.displayWidth(String($0.prefix(while: { $0 != "d" && $0 != "w" && $0 != "상" }))) }
        XCTAssertEqual(Set(starts).count, 1, table)
    }

    func testFitTruncatesWithEllipsis() {
        XCTAssertEqual(CliOutput.fit("abcdef", width: 4), "abc…")
        XCTAssertEqual(CliOutput.fit("한글한글", width: 5), "한글…")
        XCTAssertEqual(CliOutput.fit("ab", width: 4), "ab  ")
    }

    func testJsonIsStableAndKeepsKorean() throws {
        let pane = CliPane(id: "p1", shortId: "p1", name: "리뷰어", kind: .claude, state: .working, cwd: "/a/b", subagents: 2, isSelf: true)
        let text = CliOutput.json(pane)
        XCTAssertTrue(text.contains("\"name\" : \"리뷰어\""))
        XCTAssertTrue(text.contains("\"self\" : true"))
        XCTAssertTrue(text.contains("\"state\" : \"working\""))
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(object?["subagents"] as? Int, 2)
        XCTAssertEqual(object?["cwd"] as? String, "/a/b", "슬래시를 이스케이프하지 않는다")
    }

    func testParseDuration() {
        XCTAssertEqual(CliOutput.parseDuration("90"), 90)
        XCTAssertEqual(CliOutput.parseDuration("45s"), 45)
        XCTAssertEqual(CliOutput.parseDuration("10m"), 600)
        XCTAssertEqual(CliOutput.parseDuration("1h30m"), 5400)
        XCTAssertEqual(CliOutput.parseDuration("1m30s"), 90)
        XCTAssertEqual(CliOutput.parseDuration("1.5m"), 90)
        XCTAssertNil(CliOutput.parseDuration("0"))
        XCTAssertNil(CliOutput.parseDuration("abc"))
        XCTAssertNil(CliOutput.parseDuration("5x"))
        XCTAssertNil(CliOutput.parseDuration(""))
        XCTAssertNil(CliOutput.parseDuration("10m5"))
    }

    // MARK: - 화면 글 읽기

    func feed(_ text: String, cols: Int = 20, rows: Int = 5) -> ScreenText {
        var screen = ScreenText(cols: cols, rows: rows)
        screen.feed(Array(text.utf8))
        return screen
    }

    func testScreenPlainTextAndColorCodesStripped() {
        let screen = feed("\u{1b}[31m빨강\u{1b}[0m abc\r\n둘째 줄\r\n")
        XCTAssertEqual(screen.lines, ["빨강 abc", "둘째 줄"])
    }

    func testScreenRedrawInPlaceKeepsOnlyLastVersion() {
        // claude 처럼 줄을 지우고 같은 자리에 다시 그린다: 위로 1줄, 줄 지우기, 새 글
        let screen = feed("진행 1\r\n" + "\u{1b}[1A\u{1b}[2K\r진행 2\r\n" + "\u{1b}[1A\u{1b}[2K\r완료\r\n")
        XCTAssertEqual(screen.lines, ["완료"])
    }

    func testScreenCursorPositioningAndErase() {
        let screen = feed("\u{1b}[2J\u{1b}[2;3Hxy\u{1b}[1;1Hab\u{1b}[2;4H\u{1b}[K")
        XCTAssertEqual(screen.lines, ["ab", "  x"])
    }

    func testScreenScrollbackKeepsOldLines() {
        let screen = feed((1...8).map { "줄\($0)" }.joined(separator: "\r\n"), rows: 3)
        XCTAssertEqual(screen.lines, (1...8).map { "줄\($0)" })
        XCTAssertEqual(screen.tail(2), ["줄7", "줄8"])
    }

    func testScreenAltScreenShowsOnlyAltAndRestoresMain() {
        var screen = ScreenText(cols: 20, rows: 4)
        screen.feed(Array("메인 글\r\n\u{1b}[?1049h전체 화면 앱".utf8))
        XCTAssertEqual(screen.lines, ["전체 화면 앱"])
        screen.feed(Array("\u{1b}[?1049l".utf8))
        XCTAssertEqual(screen.lines, ["메인 글"])
    }

    func testScreenWrapWideCharsAndOSC() {
        let screen = feed("\u{1b}]0;제목\u{7}한글한글한글한글한글한글", cols: 10, rows: 4)
        XCTAssertEqual(screen.lines, ["한글한글한", "글한글한글", "한글"])
    }

    func testScreenScrollRegionAndInsertDelete() {
        let screen = feed("a\r\nb\r\nc\u{1b}[2;1H\u{1b}[L", rows: 4)
        XCTAssertEqual(screen.lines, ["a", "", "b", "c"])
        let del = feed("a\r\nb\r\nc\u{1b}[2;1H\u{1b}[M", rows: 4)
        XCTAssertEqual(del.lines, ["a", "c"])
    }

    func testScreenFeedsReplayWithModePrefixAndPartialUTF8() {
        var screen = ScreenText(cols: 20, rows: 3)
        let bytes = Array("\u{1b}[?2004h가나다".utf8)
        screen.feed(Array(bytes[0..<(bytes.count - 2)]))
        screen.feed(Array(bytes[(bytes.count - 2)...]))
        XCTAssertEqual(screen.lines, ["가나다"])
    }

    // MARK: - 앱 요청 파일

    func testRequestQueueRoundTripAndExpiry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("req-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = AppRequestQueue(dir: dir)
        XCTAssertTrue(queue.pending().isEmpty)
        let now = Date()
        let place = AppRequest(action: .place, pane: "new", anchor: "main", placement: .stack, name: "작업", createdAt: now)
        let focus = AppRequest(action: .focus, pane: "x", createdAt: now.addingTimeInterval(1))
        let stale = AppRequest(action: .focus, pane: "old", createdAt: now.addingTimeInterval(-AppRequestQueue.ttl - 5))
        XCTAssertTrue(queue.send(focus))
        XCTAssertTrue(queue.send(place))
        XCTAssertTrue(queue.send(stale))
        let pending = queue.pending(now: now.addingTimeInterval(2))
        XCTAssertEqual(pending.map(\.request.pane), ["new", "x"], "오래된 순, 낡은 요청은 버림")
        XCTAssertEqual(pending[0].request.anchor, "main")
        XCTAssertEqual(pending[0].request.placement, .stack)
        XCTAssertEqual(pending[0].request.name, "작업")
        // 숨김 임시 파일이나 남은 쓰레기는 요청이 아니다
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }, [])
        queue.remove(pending[0])
        XCTAssertEqual(queue.pending(now: now.addingTimeInterval(2)).map(\.request.pane), ["x"])
        // 망가진 파일은 지운다
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        XCTAssertEqual(queue.pending(now: now.addingTimeInterval(2)).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("broken.json").path))
        let mode = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode.map { $0 & 0o777 }, 0o700, "폴더는 사용자만")
    }

    private func tempQueueDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("req-\(UUID().uuidString)", isDirectory: true)
    }

    func testRequestQueueIgnoresOddIdsAndMismatchedFileNames() throws {
        let dir = tempQueueDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = AppRequestQueue(dir: dir)
        queue.ensureDirectory()
        let now = Date()
        func write(_ request: AppRequest, as name: String) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(request).write(to: dir.appendingPathComponent(name))
        }
        let good = AppRequest(action: .focus, pane: "x", createdAt: now)
        try write(good, as: "\(good.id).json")
        // id 가 UUID 가 아니다(경로 조각·이상한 글자) — 파일만 지우고 무시
        var bad = AppRequest(action: .focus, pane: "evil", createdAt: now)
        bad.id = "../../escape"
        try write(bad, as: "weird.json")
        var spaced = AppRequest(action: .focus, pane: "evil2", createdAt: now)
        spaced.id = "not a uuid"
        try write(spaced, as: "not a uuid.json")
        // 파일 이름과 안의 id 가 다르다 — 다른 요청의 파일을 지우거나 되풀이하지 못하게 무시하고 그 파일만 지운다
        let other = AppRequest(action: .focus, pane: "other", createdAt: now)
        try write(good.withPane("liar"), as: "\(other.id).json")
        let outside = dir.deletingLastPathComponent().appendingPathComponent("escape.json")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let pending = queue.pending(now: now)
        XCTAssertEqual(pending.map(\.request.pane), ["x"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["\(good.id).json"], "이상한 파일은 지워졌다")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "폴더 밖은 건드리지 않는다")
        // 지울 때는 읽은 파일(URL) 그대로
        XCTAssertEqual(pending[0].url.lastPathComponent, "\(good.id).json")
        queue.remove(pending[0])
        XCTAssertTrue(queue.pending(now: now).isEmpty)
        // 보낸 쪽이 거두기(칸을 못 만들었을 때)
        let again = AppRequest(action: .focus, pane: "y", createdAt: now)
        XCTAssertTrue(queue.send(again))
        queue.discard(again)
        XCTAssertTrue(queue.pending(now: now).isEmpty)
        XCTAssertTrue(AppRequestQueue.isValidId(UUID().uuidString))
        XCTAssertFalse(AppRequestQueue.isValidId("../x"))
        XCTAssertFalse(AppRequestQueue.isValidId(""))
    }

    func pendingItem(_ request: AppRequest) -> AppRequestQueue.Pending {
        .init(url: URL(fileURLWithPath: "/tmp/\(request.id).json"), request: request)
    }

    func testApplierPlacesOnlyAfterPaneIsListedAndIsIdempotent() {
        var workspace = Workspace(tabs: [TabState(id: "t1", root: .pane("A"), focused: "A"), TabState(id: "t2", root: .pane("Z"), focused: "Z")],
                                  selected: "t2")
        var applier = AppRequestApplier()
        let request = AppRequest(action: .place, pane: "N", anchor: "A", placement: .right, name: "리뷰어")
        // 칸이 아직 데몬 목록에 없다 — 남겨 둔다(요청은 칸 만들기보다 먼저 남겨진다)
        var result = applier.apply([pendingItem(request)], to: &workspace, live: ["A", "Z"])
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.done.isEmpty)
        XCTAssertTrue(result.names.isEmpty)
        XCTAssertEqual(workspace.allPanes.sorted(), ["A", "Z"])
        // 목록에 나타났다 — 붙이고 이름을 돌려준다
        result = applier.apply([pendingItem(request)], to: &workspace, live: ["A", "Z", "N"])
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.done.map(\.request.id), [request.id])
        XCTAssertEqual(result.names.map(\.pane), ["N"])
        XCTAssertEqual(result.names.map(\.name), ["리뷰어"])
        XCTAssertEqual(workspace.tabs[0].root.neighbor(of: "A", toward: .right), "N")
        XCTAssertEqual(workspace.selected, "t2", "보던 탭은 그대로")
        let placed = workspace
        // 파일 지우기가 실패해 같은 요청이 또 읽혀도 다시 적용하지 않는다(지우기만 다시)
        workspace.tabs[0].root = .pane("A") // 사용자가 그동안 배치를 바꿨다고 치고
        result = applier.apply([pendingItem(request)], to: &workspace, live: ["A", "Z", "N"])
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.names.isEmpty)
        XCTAssertEqual(result.done.map(\.request.id), [request.id], "지우라고만 돌려준다")
        XCTAssertNotEqual(workspace, placed)
        XCTAssertEqual(workspace.tabs[0].root, .pane("A"), "되풀이 적용 없음")
    }

    func testApplierRepeatedNewBesideSameAnchorStacksAndFocusMovesTab() {
        var workspace = Workspace(tabs: [TabState(id: "t1", root: .pane("A"), focused: "A"), TabState(id: "t2", root: .pane("Z"), focused: "Z")],
                                  selected: "t2")
        var applier = AppRequestApplier()
        let live: Set<String> = ["A", "Z", "N1", "N2"]
        let first = AppRequest(action: .place, pane: "N1", anchor: "A", placement: .right)
        let second = AppRequest(action: .place, pane: "N2", anchor: "A", placement: .right)
        _ = applier.apply([pendingItem(first), pendingItem(second)], to: &workspace, live: live)
        XCTAssertEqual(workspace.tabs[0].root.neighbor(of: "A", toward: .right), "N1")
        XCTAssertEqual(workspace.tabs[0].root.neighbor(of: "N1", toward: .down), "N2")
        // focus: 그 칸이 있는 탭으로 가고 앱을 앞으로
        let focus = AppRequest(action: .focus, pane: "N2")
        let result = applier.apply([pendingItem(focus)], to: &workspace, live: live)
        XCTAssertTrue(result.activate)
        XCTAssertEqual(workspace.selected, "t1")
        XCTAssertEqual(workspace.tabs[0].focused, "N2")
        // 없는 칸으로 focus 는 남겨 둔다
        let missing = applier.apply([pendingItem(AppRequest(action: .focus, pane: "nope"))], to: &workspace, live: live)
        XCTAssertTrue(missing.done.isEmpty)
        // 앵커가 없는 place 는 배치하지 않고(이름만) 처리한 것으로 본다 — reconcile 이 새 탭으로 붙인다
        var lone = workspace
        let orphan = AppRequest(action: .place, pane: "N3", anchor: "gone", placement: .stack, name: "x")
        let r = applier.apply([pendingItem(orphan)], to: &lone, live: live.union(["N3"]))
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.done.count, 1)
        XCTAssertEqual(lone, workspace)
    }

    func testDaemonStateSupportsCliFeature() {
        XCTAssertFalse(DaemonState(pid: 1, footprint: 0, panes: []).supports(DaemonState.cliFeature), "예전 데몬(features 없음)")
        XCTAssertFalse(DaemonState(pid: 1, footprint: 0, panes: [], features: [DaemonState.browserFeature]).supports(DaemonState.cliFeature))
        XCTAssertTrue(DaemonState(pid: 1, footprint: 0, panes: [], features: [DaemonState.browserFeature, DaemonState.cliFeature]).supports(DaemonState.cliFeature))
    }

    // MARK: - 이름·확인한 완료

    func testClaudeNamePriority() {
        let summary = TranscriptSummary(aiTitle: "AI 제목", customTitle: "내가 지음", lastPrompt: nil)
        func name(_ user: String? = nil, _ s: TranscriptSummary) -> String {
            PaneNaming.claudeName(userTitle: user, summary: s, sessionCwd: "/w/repo", folder: "repo",
                                  firstPrompt: { "첫 질문입니다" }, autoTitle: { _ in nil })
        }
        XCTAssertEqual(name("직접", summary), "직접")
        XCTAssertEqual(name(nil, summary), "내가 지음")
        XCTAssertEqual(name(nil, TranscriptSummary(aiTitle: "AI 제목", customTitle: "repo@main")), "AI 제목", "기계적인 이름은 건너뜀")
        XCTAssertEqual(name(nil, TranscriptSummary()), "첫 질문입니다")
        XCTAssertEqual(PaneNaming.claudeName(userTitle: nil, summary: TranscriptSummary(), sessionCwd: "/w/repo", folder: "repo",
                                             firstPrompt: { nil }, autoTitle: { _ in nil }), "repo")
        XCTAssertEqual(PaneNaming.codexName(userTitle: nil, paneUserTitle: "패널", title: "긴 제목", folder: "f"), "패널")
    }

    func testSeenStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seen-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(SeenStore.load(from: url).isEmpty)
        let seen = ["s1": WorkStateRules.Seen(seq: 4, at: Date(timeIntervalSince1970: 1000))]
        SeenStore.save(seen, to: url)
        XCTAssertEqual(SeenStore.load(from: url), seen)
        // 앱과 같은 판단: 번호가 같거나 작으면 본 것, 새 번호면 아직
        let loaded = SeenStore.load(from: url)["s1"]
        XCTAssertTrue(WorkStateRules.isSeen(loaded, seq: 4, at: Date()))
        XCTAssertFalse(WorkStateRules.isSeen(loaded, seq: 5, at: Date()))
    }
}

private extension AppRequest {
    func withPane(_ pane: String) -> AppRequest {
        var copy = self
        copy.pane = pane
        return copy
    }
}
