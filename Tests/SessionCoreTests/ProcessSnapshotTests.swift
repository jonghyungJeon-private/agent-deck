import XCTest
@testable import SessionCore
import TermWire

final class ProcessSnapshotTests: XCTestCase {
    let sid1 = "01a13e6f-d93c-78d1-99ca-4e2a62355053"
    let sid2 = "11111111-2222-4333-8444-555555555555"

    func proc(_ pid: pid_t, _ ppid: pid_t, _ command: String, start: Double = 100, tty: Bool = true, zombie: Bool = false) -> ProcInfo {
        ProcInfo(pid: pid, ppid: ppid, startTime: start, hasTTY: tty, command: command, isZombie: zombie)
    }

    /// 화면 두 개(셸 10, 20)와 화면 밖 프로세스가 섞인 목록
    ///   1 launchd ─ 5 daemon ─ 10 zsh(pane-a) ─ 11 codex ─ 12 zsh ─ 13 node
    ///                       └ 20 zsh(pane-b) ─ 21 kiro ─ 22 zsh ─ 23 claude
    ///           └ 30 codex(화면 밖)  └ 40 Terminal ─ 41 zsh ─ 42 codex
    var tree: [ProcInfo] {
        [proc(1, 0, "launchd", start: 1), proc(5, 1, "daemon", start: 10),
         proc(10, 5, "zsh", start: 50), proc(11, 10, "codex", start: 200), proc(12, 11, "zsh", start: 210), proc(13, 12, "node", start: 220),
         proc(20, 5, "zsh", start: 60), proc(21, 20, "kiro-cli-term", start: 61), proc(22, 21, "zsh", start: 62), proc(23, 22, "claude", start: 63),
         proc(30, 1, "codex", start: 300), proc(40, 1, "Terminal", start: 5), proc(41, 40, "zsh", start: 6), proc(42, 41, "codex", start: 400)]
    }
    var shells: [pid_t: String] { [10: "pane-a", 20: "pane-b"] }

    func testDescendantsAndChildrenIndex() {
        let s = ProcessSnapshot(tree)
        XCTAssertEqual(s.descendants(of: [10]).map(\.pid), [10, 11, 12, 13])
        XCTAssertEqual(s.descendants(of: [20, 10]).map(\.pid), [20, 21, 22, 23, 10, 11, 12, 13])
        // 겹치는 root·없는 root 는 한 번만/건너뜀
        XCTAssertEqual(s.descendants(of: [11, 10, 999]).map(\.pid), [11, 12, 13, 10])
        XCTAssertEqual(s.children(of: 1).map(\.pid), [5, 30, 40])
        XCTAssertEqual(s[23]?.command, "claude")
        XCTAssertNil(s[999])
    }

    func testAncestryToPane() {
        let s = ProcessSnapshot(tree)
        XCTAssertEqual(s.pane(of: 13, shells: shells, maxHops: 40), "pane-a")
        XCTAssertEqual(s.pane(of: 10, shells: shells, maxHops: 40), "pane-a") // 셸 자신
        XCTAssertEqual(s.pane(of: 23, shells: shells, maxHops: 40), "pane-b") // 감싼 셸 너머
        XCTAssertNil(s.pane(of: 30, shells: shells, maxHops: 40))
        XCTAssertNil(s.pane(of: 42, shells: shells, maxHops: 40))
        // 단계 수 한도: 13 → 12 → 11 → 10 은 네 번째에 만난다
        XCTAssertNil(s.pane(of: 13, shells: shells, maxHops: 3))
        XCTAssertEqual(s.pane(of: 13, shells: shells, maxHops: 4), "pane-a")
        // 가장 가까운 셸이 이긴다
        XCTAssertEqual(s.pane(of: 13, shells: [10: "outer", 12: "inner"], maxHops: 40), "inner")
    }

    func testInnermostShell() {
        let names: Set<String> = ["zsh", "bash"]
        let s = ProcessSnapshot(tree)
        XCTAssertEqual(s.innermostShell(from: 20, names: names), 20) // kiro 는 셸이 아니라 멈춘다
        let wrapped = ProcessSnapshot([proc(20, 5, "zsh"), proc(21, 20, "node"), proc(22, 20, "bash"), proc(23, 22, "zsh"), proc(24, 22, "bash"), proc(25, 23, "vim")])
        XCTAssertEqual(wrapped.innermostShell(from: 20, names: names), 23) // 각 단계에서 커널 순서상 첫 셸
        XCTAssertEqual(wrapped.innermostShell(from: 20, names: names, maxSteps: 1), 22)
        XCTAssertEqual(wrapped.innermostShell(from: 999, names: names), 999)
    }

    func testCacheForgetsReusedPid() {
        var cache = ProcessValueCache<String>()
        let first = proc(50, 1, "codex", start: 100)
        cache.set("a", for: first)
        XCTAssertEqual(cache.cached(first), .some("a"))
        let reused = proc(50, 1, "codex", start: 101)
        XCTAssertNil(cache.cached(reused))
        let exec = proc(50, 1, "node", start: 100)
        XCTAssertNil(cache.cached(exec))
        cache.set(nil, for: proc(51, 1, "x"))
        XCTAssertEqual(cache.cached(proc(51, 1, "x")).map { $0 == nil }, true) // 실패도 기억
        cache.prune(keeping: ProcessSnapshot([reused, proc(51, 1, "x")]))
        XCTAssertEqual(cache.count, 1)
        XCTAssertNil(cache.cached(first))
    }

    // MARK: - CodexProcessFinder

    final class FakeReader {
        var data: [pid_t: ([String], [String: String])] = [:]
        var reads: [pid_t] = []
        func read(_ pid: pid_t) -> ([String], [String: String])? { reads.append(pid); return data[pid] }
    }

    func testNoCodexUnderPanesReadsNothing() {
        let fake = FakeReader()
        let finder = CodexProcessFinder(reader: fake.read)
        // 화면 밖 codex(30, 42)와 claude 만 도는 화면 → 읽기 없음
        var list = tree.filter { ![11, 12, 13].contains($0.pid) }
        list.append(proc(14, 10, "vim", start: 500))
        let result = finder.find(snapshot: ProcessSnapshot(list), shells: shells, paneIds: ["pane-a", "pane-b"])
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.evidence.isEmpty)
        XCTAssertEqual(result.reads, 0)
        XCTAssertEqual(fake.reads, [])
    }

    func testFindsCodexAndEvidenceAndCaches() {
        let fake = FakeReader()
        fake.data[11] = (["/opt/codex", "--yolo"], ["CODEX_HOME": "/h", "AGENTDECK_PANE": "pane-a"])
        fake.data[12] = (["zsh"], ["AGENTDECK_PANE": "pane-a", "CODEX_THREAD_ID": sid1])
        fake.data[13] = (["node"], ["AGENTDECK_PANE": "pane-a", "CODEX_THREAD_ID": sid2])
        fake.data[30] = (["codex"], [:])
        let finder = CodexProcessFinder(reader: fake.read)
        let snapshot = ProcessSnapshot(tree)
        let first = finder.find(snapshot: snapshot, shells: shells, paneIds: ["pane-a", "pane-b"])
        XCTAssertEqual(first.candidates.map(\.process.pid), [11])
        XCTAssertEqual(first.candidates.first?.pane, "pane-a")
        XCTAssertEqual(first.candidates.first?.env["CODEX_HOME"], "/h")
        // 가장 늦게 시작한 13 이 단서
        XCTAssertEqual(first.evidence["pane-a"], .init(sessionId: sid2, startTime: 220))
        // codex(11) 하나 + 그 자손 둘(12, 13). 화면 밖·codex 보다 먼저 시작한 것(셸 10, pane-b 쪽)은 읽지 않는다.
        XCTAssertEqual(Set(fake.reads), [11, 12, 13])
        XCTAssertEqual(first.reads, 3)

        // 같은 프로세스들이면 다시 읽지 않는다
        fake.reads = []
        let second = finder.find(snapshot: snapshot, shells: shells, paneIds: ["pane-a", "pane-b"])
        XCTAssertEqual(second.reads, 0)
        XCTAssertEqual(fake.reads, [])
        XCTAssertEqual(second.evidence, first.evidence)
        XCTAssertEqual(second.candidates.map(\.args), first.candidates.map(\.args))

        // 13 이 끝나고 같은 PID 가 다른 시작 시각으로 재사용되면 다시 읽는다
        var list = tree
        list[list.firstIndex { $0.pid == 13 }!] = proc(13, 12, "node", start: 230)
        // (예전 데몬이 띄운 셸은 예전 이름 CLAUDE_SESSIONS_PANE 을 들고 있다 — 그것도 읽는다)
        fake.data[13] = (["node"], ["CLAUDE_SESSIONS_PANE": "pane-a", "CODEX_THREAD_ID": sid1])
        fake.reads = []
        let third = finder.find(snapshot: ProcessSnapshot(list), shells: shells, paneIds: ["pane-a", "pane-b"])
        XCTAssertEqual(fake.reads, [13])
        XCTAssertEqual(third.evidence["pane-a"], .init(sessionId: sid1, startTime: 230))

        // 없어진 화면 ID 를 가리키는 단서는 버린다
        let gone = finder.find(snapshot: ProcessSnapshot(list), shells: shells, paneIds: ["pane-b"])
        XCTAssertNil(gone.evidence["pane-a"])
    }

    func testNonInteractiveAndUnreadableCodex() {
        let fake = FakeReader()
        fake.data[11] = (["codex", "app-server"], [:])
        let finder = CodexProcessFinder(reader: fake.read)
        let list = [proc(10, 5, "zsh"), proc(11, 10, "codex", start: 200), proc(12, 10, "codex", start: 201), proc(13, 10, "codex", start: 202, tty: false)]
        let snapshot = ProcessSnapshot(list)
        let result = finder.find(snapshot: snapshot, shells: shells, paneIds: ["pane-a"])
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(fake.reads, [11, 12]) // tty 없는 codex 는 읽지 않는다
        fake.reads = []
        _ = finder.find(snapshot: snapshot, shells: shells, paneIds: ["pane-a"])
        XCTAssertEqual(fake.reads, [12]) // 읽은 결과는 기억, 실패는 다시 시도
    }

    func testEnvReadCapDefersToNextScan() {
        let fake = FakeReader()
        fake.data[11] = (["codex"], [:])
        var list = [proc(10, 5, "zsh", start: 1), proc(11, 10, "codex", start: 100)]
        for i in 0..<10 {
            let pid = pid_t(100 + i)
            list.append(proc(pid, 11, "sh", start: 101 + Double(i)))
            fake.data[pid] = (["sh"], ["AGENTDECK_PANE": "pane-a", "CODEX_THREAD_ID": i == 0 ? sid1 : "not-a-uuid"])
        }
        let finder = CodexProcessFinder(maxEnvReads: 4, reader: fake.read)
        let snapshot = ProcessSnapshot(list)
        let first = finder.find(snapshot: snapshot, shells: shells, paneIds: ["pane-a"])
        XCTAssertEqual(first.reads, 5) // codex 1 + 단서 4(최근 것부터)
        XCTAssertEqual(first.deferred, 6)
        XCTAssertEqual(Array(fake.reads.dropFirst()), [109, 108, 107, 106])
        XCTAssertNil(first.evidence["pane-a"])
        _ = finder.find(snapshot: snapshot, shells: shells, paneIds: ["pane-a"])
        let third = finder.find(snapshot: snapshot, shells: shells, paneIds: ["pane-a"])
        XCTAssertEqual(third.deferred, 0)
        XCTAssertEqual(third.evidence["pane-a"], .init(sessionId: sid1, startTime: 101))
        XCTAssertEqual(fake.reads.count, 11) // 각 프로세스는 한 번씩만
    }

    /// 예전 방식(모든 프로세스의 인자·환경을 읽는다)과 결과가 같은지: 무작위 프로세스 나무로 비교
    func testMatchesLegacyFullScan() {
        var rng = SystemRandomNumberGenerator()
        for round in 0..<200 {
            var list = [proc(1, 0, "launchd", start: 0), proc(2, 1, "daemon", start: 1)]
            var data: [pid_t: ([String], [String: String])] = [:]
            let panes: [(pid_t, String)] = [(10, "p1"), (11, "p2"), (12, "p3")]
            for (pid, id) in panes { list.append(proc(pid, 2, "zsh", start: 5)); data[pid] = (["zsh"], ["AGENTDECK_PANE": id]) }
            var next: pid_t = 100
            for _ in 0..<Int.random(in: 5...60, using: &rng) {
                let parent = list.randomElement(using: &rng)!
                let pid = next; next += 1
                let command = ["codex", "zsh", "node", "codex", "git"].randomElement(using: &rng)!
                let start = parent.startTime + Double(Int.random(in: 0...50, using: &rng))
                list.append(proc(pid, parent.pid, command, start: start, tty: Int.random(in: 0..<5, using: &rng) > 0,
                                 zombie: Int.random(in: 0..<20, using: &rng) == 0))
                var env = data[parent.pid]?.1 ?? [:]
                if parent.command == "codex" || Bool.random(using: &rng) { env["CODEX_THREAD_ID"] = [sid1, sid2, "x"].randomElement(using: &rng)! }
                let args = command == "codex" ? (Bool.random(using: &rng) ? ["codex", "resume", sid1] : ["codex", "exec", "hi"]) : [command]
                data[pid] = (args, env)
            }
            let snapshot = ProcessSnapshot(list)
            let shells = Dictionary(uniqueKeysWithValues: panes)
            let paneIds = Set(panes.map(\.1).dropLast()) // p3 은 없어진 화면
            let legacy = legacyScan(snapshot, data: data, shells: shells, paneIds: paneIds)
            let finder = CodexProcessFinder(maxEnvReads: 10_000) { data[$0] }
            let result = finder.find(snapshot: snapshot, shells: shells, paneIds: paneIds)
            XCTAssertEqual(result.candidates.map { "\($0.process.pid)@\($0.pane)" }, legacy.candidates, "round \(round)")
            // 단서는 그 단서를 쓰는(시작 시각이 codex 이후인) 경우만 같으면 된다
            for candidate in result.candidates {
                let used = { (e: CodexProcessFinder.Evidence?) in e.flatMap { $0.startTime >= candidate.process.startTime ? $0 : nil } }
                XCTAssertEqual(used(result.evidence[candidate.pane]), used(legacy.evidence[candidate.pane]), "round \(round)")
            }
        }
    }

    /// 바꾸기 전 CodexScanner.scan 의 후보·단서 고르기를 그대로 옮긴 것
    func legacyScan(_ s: ProcessSnapshot, data: [pid_t: ([String], [String: String])], shells: [pid_t: String], paneIds: Set<String>)
        -> (candidates: [String], evidence: [String: CodexProcessFinder.Evidence]) {
        var candidates: [String] = []
        var evidence: [String: CodexProcessFinder.Evidence] = [:]
        for info in s.processes where !info.isZombie {
            let env = data[info.pid]?.1 ?? [:]
            if let pane = AgentDeckEnv.value("PANE", in: env), paneIds.contains(pane),
               let id = env["CODEX_THREAD_ID"], UUID(uuidString: id) != nil,
               info.startTime > (evidence[pane]?.startTime ?? 0) { evidence[pane] = .init(sessionId: id, startTime: info.startTime) }
            guard info.command == "codex", info.hasTTY, let args = data[info.pid]?.0, CodexArguments.isInteractive(args) else { continue }
            var pane: String?
            var pid = info.pid
            for _ in 0..<40 {
                if let id = shells[pid] { pane = id; break }
                guard let parent = s[pid]?.ppid, parent > 1 else { break }
                pid = parent
            }
            if let pane { candidates.append("\(info.pid)@\(pane)") }
        }
        return (candidates, evidence)
    }

    func testLiveSnapshotMatchesPerPidInfo() throws {
        let snapshot = ProcessUtil.snapshot()
        XCTAssertGreaterThan(snapshot.processes.count, 10)
        for pid in [getpid(), getppid()] {
            let live = try XCTUnwrap(ProcessUtil.info(pid))
            XCTAssertEqual(snapshot[pid], live)
        }
        // 자식 목록은 부모 PID 와 맞아야 한다
        XCTAssertTrue(snapshot.children(of: getppid()).contains { $0.pid == getpid() })
    }
}
