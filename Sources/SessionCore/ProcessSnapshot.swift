import Darwin
import Foundation
import TermWire

/// 한 시점의 프로세스 목록(ProcessUtil.snapshot() 으로 sysctl 한 번에 읽는다).
/// 갱신마다 한 번 찍어 Codex 훑기·claude 계보·감싼 셸 찾기가 같이 쓴다.
/// 순서는 커널이 돌려준 순서 그대로(proc_listallpids 와 같은 순서)라 "처음 것" 고르기가 예전과 같다.
public struct ProcessSnapshot {
    public let processes: [ProcInfo]
    private let index: [pid_t: Int]
    private let childIndex: [pid_t: [Int]]

    public init(_ processes: [ProcInfo]) {
        self.processes = processes
        var index: [pid_t: Int] = [:]
        var childIndex: [pid_t: [Int]] = [:]
        index.reserveCapacity(processes.count)
        for (i, p) in processes.enumerated() where index[p.pid] == nil {
            index[p.pid] = i
            childIndex[p.ppid, default: []].append(i)
        }
        self.index = index
        self.childIndex = childIndex
    }

    public subscript(pid: pid_t) -> ProcInfo? { index[pid].map { processes[$0] } }

    /// 자식(좀비 포함, 커널 순서)
    public func children(of pid: pid_t) -> [ProcInfo] { (childIndex[pid] ?? []).map { processes[$0] } }

    /// pid 자신부터 부모 쪽으로 maxHops 개까지 올라가며 match 를 만족하는 첫 pid.
    /// 목록에 없거나 pid 가 1 이하(launchd)면 멈춘다.
    public func ancestor(from pid: pid_t, maxHops: Int, where match: (pid_t) -> Bool) -> pid_t? {
        var current = pid
        for _ in 0..<maxHops {
            guard current > 1, let info = self[current] else { return nil }
            if match(current) { return current }
            current = info.ppid
        }
        return nil
    }

    /// pid(자신 포함)에서 위로 올라가 처음 만나는 화면 셸의 화면 ID
    public func pane(of pid: pid_t, shells: [pid_t: String], maxHops: Int) -> String? {
        ancestor(from: pid, maxHops: maxHops) { shells[$0] != nil }.flatMap { shells[$0] }
    }

    /// roots 와 그 아래 모든 프로세스(너비 우선, 각 root 다음 그 자손 순). 목록에 없는 root 는 건너뛴다.
    public func descendants<S: Sequence>(of roots: S) -> [ProcInfo] where S.Element == pid_t {
        var seen = Set<pid_t>()
        var result: [ProcInfo] = []
        for root in roots {
            guard let first = self[root], seen.insert(root).inserted else { continue }
            var queue = [first]
            var head = 0
            while head < queue.count {
                let p = queue[head]; head += 1
                result.append(p)
                for child in children(of: p.pid) where seen.insert(child.pid).inserted { queue.append(child) }
            }
        }
        return result
    }

    /// Kiro CLI 처럼 셸을 한 겹 감싼 화면: 셸 이름인 자식을 따라 가장 안쪽 셸까지 내려간다.
    public func innermostShell(from pid: pid_t, names: Set<String>, maxSteps: Int = 8) -> pid_t {
        var current = pid
        for _ in 0..<maxSteps {
            guard let next = children(of: current).first(where: { names.contains($0.command) }) else { break }
            current = next.pid
        }
        return current
    }
}

/// 같은 PID 라도 시작 시각이 다르면(재사용) 다른 프로세스. exec 로 이름이 바뀌면 인자·환경도 바뀌므로 이름도 넣는다.
public struct ProcessKey: Hashable {
    public var pid: pid_t
    public var startTime: Double
    public var command: String
    public init(_ p: ProcInfo) { pid = p.pid; startTime = p.startTime; command = p.command }
}

/// 프로세스별로 한 번만 읽은 값(인자·환경은 프로세스가 사는 동안 바뀌지 않는다). 읽기 실패도 기억한다.
public struct ProcessValueCache<Value> {
    private var store: [ProcessKey: Value?] = [:]
    public init() {}
    public var count: Int { store.count }
    public func cached(_ p: ProcInfo) -> Value?? { store[ProcessKey(p)] }
    public mutating func set(_ value: Value?, for p: ProcInfo) { store[ProcessKey(p)] = .some(value) }
    /// 스냅샷에 (같은 시작 시각·이름으로) 없는 프로세스 것은 버린다.
    public mutating func prune(keeping snapshot: ProcessSnapshot) {
        store = store.filter { key, _ in
            guard let p = snapshot[key.pid] else { return false }
            return p.startTime == key.startTime && p.command == key.command && !p.isZombie
        }
    }
}

/// 화면 안에서 도는 Codex CLI 와 그 세션 단서를 찾는다(인자·환경 읽기를 최소로).
/// - 화면 셸 아래(계보 40단계 안)의 "codex" 만 후보로 보고, 그 인자·환경만 읽는다.
/// - 단서(AGENTDECK_PANE — 예전 CLAUDE_SESSIONS_PANE — + CODEX_THREAD_ID 환경)는 후보가 있을 때만, 화면 셸의 자손에서
///   (Codex 의 자손 먼저, 최근 것 먼저) 찾는다. 한 번 읽은 프로세스는 (pid, 시작 시각) 으로 기억한다.
/// - 한 번에 새로 읽는 환경 수는 maxEnvReads 로 막고, 못 읽은 것은 다음 훑기에서 읽는다.
public final class CodexProcessFinder {
    public typealias Reader = (pid_t) -> ([String], [String: String])?
    public struct Candidate {
        public var process: ProcInfo
        public var args: [String]
        public var env: [String: String]
        public var pane: String
    }
    public struct Evidence: Equatable {
        public var sessionId: String
        public var startTime: Double
        public init(sessionId: String, startTime: Double) { self.sessionId = sessionId; self.startTime = startTime }
    }
    public struct Result {
        public var candidates: [Candidate] = []
        /// 화면 ID → 그 화면에서 가장 최근에 시작한, Codex 세션 ID 를 환경에 가진 프로세스
        public var evidence: [String: Evidence] = [:]
        /// 이번에 실제로 인자·환경(KERN_PROCARGS2)을 읽은 횟수
        public var reads = 0
        /// 읽기 한도 때문에 다음으로 미룬 수
        public var deferred = 0
    }
    /// 단서용 환경에서 필요한 두 값만 기억한다
    struct Mark { var pane: String; var sessionId: String }

    public static let maxHops = 40
    public var maxEnvReads: Int
    private let reader: Reader
    private var codexCache = ProcessValueCache<([String], [String: String])>()
    private var markCache = ProcessValueCache<Mark>()

    public init(maxEnvReads: Int = 32, reader: @escaping Reader = ProcessUtil.argumentsAndEnvironment) {
        self.maxEnvReads = maxEnvReads
        self.reader = reader
    }

    public var cachedCount: Int { codexCache.count + markCache.count }

    public func find(snapshot: ProcessSnapshot, shells: [pid_t: String], paneIds: Set<String>) -> Result {
        var result = Result()
        defer { codexCache.prune(keeping: snapshot); markCache.prune(keeping: snapshot) }
        var budget = maxEnvReads
        func codexValue(_ p: ProcInfo) -> ([String], [String: String])? {
            if let hit = codexCache.cached(p) { return hit }
            let value = reader(p.pid); result.reads += 1
            // 실패는 기억하지 않는다(잠깐 못 읽은 것일 수 있고, codex 는 몇 개뿐이다)
            if value != nil { codexCache.set(value, for: p) }
            return value
        }
        // 1) 화면 셸 아래의 대화형 codex
        for p in snapshot.processes where p.command == "codex" && p.hasTTY && !p.isZombie {
            guard let pane = snapshot.pane(of: p.pid, shells: shells, maxHops: Self.maxHops),
                  let (args, env) = codexValue(p), CodexArguments.isInteractive(args) else { continue }
            result.candidates.append(Candidate(process: p, args: args, env: env, pane: pane))
        }
        guard let oldest = result.candidates.map(\.process.startTime).min() else { return result }

        // 2) 단서: 후보보다 먼저 시작한 프로세스는 쓰이지 않으므로(시작 시각 >= codex 만 인정) 뺀다
        let fromCodex = snapshot.descendants(of: result.candidates.map(\.process.pid))
        let fromCodexPids = Set(fromCodex.map(\.pid))
        let rest = snapshot.descendants(of: shells.keys.sorted()).filter { !fromCodexPids.contains($0.pid) }
        let byRecent: (ProcInfo, ProcInfo) -> Bool = { $0.startTime > $1.startTime }
        let pool = (fromCodex.sorted(by: byRecent) + rest.sorted(by: byRecent))
            .filter { !$0.isZombie && $0.startTime >= oldest }
        var marks: [pid_t: Mark] = [:]
        for p in pool {
            let mark: Mark?
            if p.command == "codex", let hit = codexCache.cached(p) {
                mark = hit.flatMap { Self.mark($0.1) }
            } else if let hit = markCache.cached(p) {
                mark = hit
            } else if budget > 0 {
                budget -= 1; result.reads += 1
                mark = reader(p.pid).flatMap { Self.mark($0.1) }
                markCache.set(mark, for: p)
            } else { result.deferred += 1; continue }
            if let mark { marks[p.pid] = mark }
        }
        // 예전처럼 커널 순서로 돌며 화면마다 가장 늦게 시작한 것(같으면 먼저 본 것)을 남긴다
        for p in snapshot.processes {
            guard let mark = marks[p.pid], paneIds.contains(mark.pane),
                  p.startTime > (result.evidence[mark.pane]?.startTime ?? 0) else { continue }
            result.evidence[mark.pane] = Evidence(sessionId: mark.sessionId, startTime: p.startTime)
        }
        return result
    }

    static func mark(_ env: [String: String]) -> Mark? {
        guard let pane = AgentDeckEnv.value("PANE", in: env), let id = env["CODEX_THREAD_ID"], UUID(uuidString: id) != nil else { return nil }
        return Mark(pane: pane, sessionId: id)
    }
}
