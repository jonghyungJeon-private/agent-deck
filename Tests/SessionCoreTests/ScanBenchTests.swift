import XCTest
import SessionCore

/// 프로세스 훑기 전후 비교(읽기 전용). 평소엔 건너뛴다.
///   SCANBENCH=1 swift test -c release -Xswiftc -enable-testing --filter ScanBench
/// 화면 셸은 실제 ClaudeTerm 화면(환경에 CLAUDE_SESSIONS_PANE 이 있고 부모엔 없는 프로세스)을 쓴다.
final class ScanBenchTests: XCTestCase {
    struct Legacy { var candidates: [String]; var evidence: [String: CodexProcessFinder.Evidence]; var reads: Int }

    /// 바꾸기 전 CodexScanner.scan 의 프로세스 부분 + makeRows 의 감싼 셸용 자식 목록 만들기
    func legacyScan(shells: [pid_t: String], paneIds: Set<String>, wrapped: Bool) -> Legacy {
        var reads = 0
        var candidates: [String] = []
        var evidence: [String: CodexProcessFinder.Evidence] = [:]
        for pid in ProcessUtil.allPids() {
            guard let info = legacyInfo(pid), !info.isZombie else { continue }
            let env = ProcessUtil.environment(pid) ?? [:]; reads += 1
            if let pane = env["CLAUDE_SESSIONS_PANE"], paneIds.contains(pane),
               let id = env["CODEX_THREAD_ID"], UUID(uuidString: id) != nil,
               info.startTime > (evidence[pane]?.startTime ?? 0) { evidence[pane] = .init(sessionId: id, startTime: info.startTime) }
            guard info.command == "codex", info.hasTTY else { continue }
            reads += 1
            guard let args = ProcessUtil.arguments(pid), CodexArguments.isInteractive(args) else { continue }
            var pane: String?
            var p = pid
            for _ in 0..<40 {
                if let id = shells[p] { pane = id; break }
                guard let parent = legacyInfo(p)?.ppid, parent > 1 else { break }
                p = parent
            }
            if let pane { candidates.append("\(pid)@\(pane)") }
        }
        if wrapped {
            var children: [pid_t: [ProcInfo]] = [:]
            for pid in ProcessUtil.allPids() {
                if let info = legacyInfo(pid) { children[info.ppid, default: []].append(info) }
            }
            XCTAssertFalse(children.isEmpty)
        }
        return Legacy(candidates: candidates, evidence: evidence, reads: reads)
    }

    /// main(86214eb) 의 ProcessUtil.info 그대로(devname 을 매번 부른다)
    func legacyInfo(_ pid: pid_t) -> ProcInfo? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = kp.kp_proc.p_starttime
        let hasTTY = (kp.kp_proc.p_flag & P_CONTROLT) != 0
        var tty: String?
        if hasTTY, kp.kp_eproc.e_tdev != -1, let name = devname(kp.kp_eproc.e_tdev, S_IFCHR) {
            tty = "/dev/" + String(cString: name)
        }
        let command = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return ProcInfo(pid: pid, ppid: kp.kp_eproc.e_ppid, startTime: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000,
                        hasTTY: hasTTY, tty: tty, command: command, isZombie: kp.kp_proc.p_stat == SZOMB)
    }

    func ms(_ body: () -> Void) -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    }

    func testScanBench() throws {
        guard ProcessInfo.processInfo.environment["SCANBENCH"] != nil else { throw XCTSkip("SCANBENCH=1 일 때만") }
        let n = Int(ProcessInfo.processInfo.environment["SCANBENCH_N"] ?? "") ?? 20
        // 실제 화면 셸 찾기(읽기 전용)
        var envs: [pid_t: String] = [:]
        let all = ProcessUtil.snapshot()
        for p in all.processes where !p.isZombie {
            if let pane = ProcessUtil.environment(p.pid)?["CLAUDE_SESSIONS_PANE"] { envs[p.pid] = pane }
        }
        var shells: [pid_t: String] = [:]
        for (pid, pane) in envs where envs[all[pid]?.ppid ?? 0] == nil { shells[pid] = pane }
        let paneIds = Set(shells.values)
        let codexAll = all.processes.filter { $0.command == "codex" }.count
        print("SCANBENCH processes=\(all.processes.count) panes=\(shells.count) codex(all)=\(codexAll) n=\(n)")
        // 커널 순서가 proc_listallpids 와 같은지(같은 순간이 아니라 몇 개는 다를 수 있다)
        let listed = ProcessUtil.allPids()
        let common = Set(listed).intersection(all.processes.map(\.pid))
        let sameOrder = listed.filter(common.contains) == all.processes.map(\.pid).filter(common.contains)
        print("SCANBENCH kernelOrderMatchesAllPids=\(sameOrder)")

        for wrapped in [false, true] {
            var legacy: Legacy!
            let oldTimes = (0..<n).map { _ in ms { legacy = legacyScan(shells: shells, paneIds: paneIds, wrapped: wrapped) } }
            let finder = CodexProcessFinder()
            var cold: CodexProcessFinder.Result!
            let coldTime = ms {
                let s = ProcessUtil.snapshot()
                cold = finder.find(snapshot: s, shells: shells, paneIds: paneIds)
                if wrapped { for pid in shells.keys { _ = s.innermostShell(from: pid, names: ["zsh", "bash"]) } }
            }
            var warm: CodexProcessFinder.Result!
            var warmReads = 0
            let newTimes = (0..<n).map { _ in ms {
                let s = ProcessUtil.snapshot()
                warm = finder.find(snapshot: s, shells: shells, paneIds: paneIds)
                warmReads += warm.reads
                if wrapped { for pid in shells.keys { _ = s.innermostShell(from: pid, names: ["zsh", "bash"]) } }
            } }
            func stat(_ xs: [Double]) -> String {
                let s = xs.sorted()
                return String(format: "avg %.2fms median %.2fms min %.2fms", xs.reduce(0, +) / Double(xs.count), s[s.count / 2], s[0])
            }
            print("SCANBENCH wrapped=\(wrapped) OLD \(stat(oldTimes)) reads/scan=\(legacy.reads)")
            print("SCANBENCH wrapped=\(wrapped) NEW cold \(String(format: "%.2fms", coldTime)) reads=\(cold.reads) | warm \(stat(newTimes)) reads/scan=\(Double(warmReads) / Double(n)) deferred=\(warm.deferred)")
            let newCandidates = warm.candidates.map { "\($0.process.pid)@\($0.pane)" }
            print("SCANBENCH candidates old=\(legacy.candidates) new=\(newCandidates)")
            XCTAssertEqual(Set(newCandidates), Set(legacy.candidates))
            for c in warm.candidates {
                let used = { (e: CodexProcessFinder.Evidence?) in e.flatMap { $0.startTime >= c.process.startTime ? $0 : nil } }
                print("SCANBENCH evidence[\(c.pane)] old=\(String(describing: used(legacy.evidence[c.pane]))) new=\(String(describing: used(warm.evidence[c.pane])))")
                XCTAssertEqual(used(warm.evidence[c.pane]), used(legacy.evidence[c.pane]))
            }
        }
    }
}
