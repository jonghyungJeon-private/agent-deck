import Foundation
import TermWire

/// `agentdeck` 가 보여 주는 칸 상태. 앱의 목록·탭 점과 같은 기준이다(`PaneStateReader` 가 정한 상태를 옮긴 것).
public enum PaneState: String, Codable, Equatable {
    case working, waiting, done, idle, error
    /// 데몬이 꺼져 사라진 칸(앱에서 탭을 열 때 되살린다)
    case dormant
    /// claude·codex 인데 상태 hook 이 아직 없다(연결 전) — 끝났는지 알 수 없다
    case unknown

    /// 일이 끝났다고 볼 수 있는 상태(사용자가 안 본 완료도 포함). 입력 대기·오류도 "기다릴 것이 끝난" 상태다.
    public var isSettled: Bool {
        switch self {
        case .done, .idle, .waiting, .error: return true
        case .working, .dormant, .unknown: return false
        }
    }

    /// 사용자·에이전트가 다음 지시를 보내도 되는 상태(입력 대기·작업 중·꺼짐이 아닐 때)
    public var acceptsPrompt: Bool { self == .done || self == .idle }

    /// 상태 하나로 칸이 끝났는지 본 종료 코드: 0 끝남, 2 입력 대기, 3 오류, 1 그 밖에
    public var exitCode: Int32 {
        switch self {
        case .done, .idle: return 0
        case .waiting: return 2
        case .error: return 3
        case .working, .dormant, .unknown: return 1
        }
    }
}

/// 한 칸의 명령줄용 요약
public struct CliPane: Codable, Equatable {
    public var id: String
    public var shortId: String
    public var name: String
    public var kind: PaneKind
    public var state: PaneState
    /// 상태에 딸린 글(입력 대기 이유, 오류 종류)
    public var message: String?
    public var cwd: String
    /// 작업 중인 하위 에이전트 수(claude 하위 에이전트·codex 자식·백그라운드 에이전트)
    public var subagents: Int
    /// 부른 칸 자신
    public var isSelf: Bool
    /// 상태가 마지막으로 바뀐 시각(hook 기록 — 셸·상태 없음은 nil)
    public var stateAt: Date?
    /// 상태 번호(hook 이 상태를 적을 때마다 오름)
    public var stateSeq: Int?

    enum CodingKeys: String, CodingKey {
        case id, shortId, name, kind, state, message, cwd, subagents, stateAt, stateSeq
        case isSelf = "self"
    }

    public init(id: String, shortId: String, name: String, kind: PaneKind, state: PaneState, message: String? = nil,
                cwd: String, subagents: Int = 0, isSelf: Bool = false, stateAt: Date? = nil, stateSeq: Int? = nil) {
        self.id = id
        self.shortId = shortId
        self.name = name
        self.kind = kind
        self.state = state
        self.message = message
        self.cwd = cwd
        self.subagents = subagents
        self.isSelf = isSelf
        self.stateAt = stateAt
        self.stateSeq = stateSeq
    }
}

public enum CliPanes {
    /// 읽은 칸들을 명령줄용 요약으로. agents: 하위 에이전트 훑기 결과, names: names.json.
    public static func summarize(_ readings: [PaneReading], agents: [SubagentActivity], names: [String: SavedName],
                                 selfId: String?, nameOf: ((PaneReading) -> String)? = nil) -> [CliPane] {
        let ids = PaneSelector.shortIds(readings.map(\.pane.id))
        return readings.map { reading in
            let state = state(of: reading, agents: agents)
            let subagents = subagentCount(of: reading, agents: agents)
            return CliPane(id: reading.pane.id, shortId: ids[reading.pane.id] ?? String(reading.pane.id.prefix(8)).lowercased(),
                           name: nameOf?(reading) ?? PaneNaming.displayName(reading, names: names),
                           kind: reading.kind, state: state, message: reading.message, cwd: reading.cwd,
                           subagents: subagents,
                           isSelf: selfId.map { $0.lowercased() == reading.pane.id.lowercased() } ?? false,
                           stateAt: reading.at, stateSeq: reading.seq)
        }
    }

    /// 앱의 점과 같은 기준: 오케스트레이션 중(백그라운드 일·하위 에이전트가 도는 중)은 작업 중이다.
    /// 셸은 hook 이 없으므로 앞에서 도는 프로그램으로 본다 — 셸 프롬프트면 쉬는 중, 다른 프로그램이 돌면 작업 중.
    public static func state(of reading: PaneReading, agents: [SubagentActivity]) -> PaneState {
        switch reading.kind {
        case .shell:
            return PaneKind.isShellProgram(reading.pane.foreground) || reading.pane.foreground == nil ? .idle : .working
        case .claude, .codex:
            var state = reading.state
            if let codex = reading.codexSession, state == "done" || state == "idle" || state == "orchestrating",
               AgentActivityScanner.runningCodexChildren(of: codex.id, in: agents) > 0 {
                state = "orchestrating"
            }
            switch state {
            case "working", "orchestrating": return .working
            case "waiting": return .waiting
            case "done": return .done
            case "idle": return .idle
            case "error": return .error
            default: return .unknown
            }
        }
    }

    public static func subagentCount(of reading: PaneReading, agents: [SubagentActivity]) -> Int {
        let running = agents.filter { $0.paneId == reading.pane.id && $0.isRunning }.count
        return max(running, reading.background?.agents ?? 0)
    }

    /// 데몬이 꺼져 사라진 칸(layout.json 의 꺼진 칸)
    public static func dormant(id: String, shortId: String, name: String, kind: PaneKind, cwd: String) -> CliPane {
        CliPane(id: id, shortId: shortId, name: name, kind: kind, state: .dormant, cwd: cwd)
    }
}

/// `agentdeck wait`: 시작을 본 뒤 끝나기를 기다리는 상태 기계. 시간과 관찰 값만 받는 순수 로직이다.
///
/// 함정 둘을 알아서 피한다.
/// - 사용자가 안 본 완료(done)는 앱에서 쉬는 중(idle)으로 안 바뀐다 — idle 만 기다리면 영원히 기다린다. done·idle·waiting·error 모두 끝으로 본다.
/// - 지시 직후에는 아직 idle·done 이다 — 그것을 끝으로 착각하지 않도록, 일을 시작한 것(working 을 보거나 새 상태 기록이 생긴 것)을 본 뒤에만 끝을 본다.
///   시작을 끝내 못 보면(이미 끝난 상태에서 부름) `grace` 뒤 지금 상태로 돌려준다.
public struct WaitMachine {
    public struct Observation: Equatable {
        public var state: PaneState
        public var seq: Int?
        public var at: Date?
        /// 칸이 데몬에서 사라졌는가(닫힘)
        public var gone: Bool

        public init(state: PaneState, seq: Int? = nil, at: Date? = nil, gone: Bool = false) {
            self.state = state
            self.seq = seq
            self.at = at
            self.gone = gone
        }

        init(_ pane: CliPane) {
            self.init(state: pane.state, seq: pane.stateSeq, at: pane.stateAt)
        }
    }

    public enum Reason: String, Codable, Equatable {
        /// 일을 시작한 것을 보고 끝나는 것도 봤다
        case finished
        /// 시작을 못 봐서 유예가 지난 뒤 지금 상태를 돌려준다
        case noStart = "no-start"
        case timeout
        /// 칸이 사라짐(닫힘)
        case gone
        /// 상태를 알 수 없다(hook 연결 전·꺼진 칸)
        case unknown
        /// 데몬을 오래 읽지 못했다(연결이 닫혔거나 일시 실패가 길다) — 칸이 어떤지 모른다
        case lost
    }

    public struct PaneResult: Equatable {
        public var id: String
        public var state: PaneState
        public var reason: Reason
        public var started: Bool

        /// 이 칸 하나의 종료 코드
        public var exitCode: Int32 {
            switch reason {
            case .timeout: return 124
            case .gone, .unknown, .lost: return 1
            case .finished, .noStart: return state.exitCode
            }
        }
    }

    public struct Config: Equatable {
        public var timeout: TimeInterval?
        public var grace: TimeInterval
        public var any: Bool

        public init(timeout: TimeInterval? = nil, grace: TimeInterval = 3, any: Bool = false) {
            self.timeout = timeout
            self.grace = grace
            self.any = any
        }
    }

    public enum Decision: Equatable {
        case waiting
        /// results: 끝난 칸(시간 초과면 기다린 모든 칸, 못 끝낸 칸은 timeout). pending: --any 로 먼저 끝나서 돌아올 때 아직 일하는 칸
        case finished(results: [PaneResult], pending: [String], exitCode: Int32)
    }

    private struct Track {
        var baseline: Observation
        var started: Bool
        var result: PaneResult?
        var last: Observation
    }

    private var tracks: [String: Track] = [:]
    private let order: [String]
    private let config: Config
    private let startedAt: Date

    /// baseline: 지시를 보내기 전에 본 칸별 관찰(이미 working 이면 시작한 것으로 본다)
    public init(baseline: [String: Observation], order: [String], config: Config = Config(), now: Date) {
        self.order = order
        self.config = config
        startedAt = now
        for id in order {
            let base = baseline[id] ?? Observation(state: .unknown, gone: true)
            tracks[id] = Track(baseline: base, started: base.state == .working, result: nil, last: base)
        }
    }

    /// 새 일이 있었는가: 상태 번호(없으면 시각)가 기준 때보다 달라졌다. 같은 기록에서 상태만 바뀐 것
    /// (사용자가 완료를 봐서 쉬는 중이 됨)은 새 일이 아니다.
    static func isNewEvent(_ now: Observation, since base: Observation) -> Bool {
        if let a = now.seq, let b = base.seq { return a != b }
        if let a = now.at, let b = base.at { return a != b }
        return false
    }

    public mutating func update(_ observed: [String: Observation], now: Date) -> Decision {
        let elapsed = now.timeIntervalSince(startedAt)
        for id in order {
            guard var track = tracks[id], track.result == nil else { continue }
            let obs = observed[id] ?? Observation(state: .unknown, gone: true)
            track.last = obs
            func finish(_ reason: Reason) {
                track.result = PaneResult(id: id, state: obs.state, reason: reason, started: track.started)
            }
            if obs.gone {
                finish(.gone)
            } else if obs.state == .dormant || obs.state == .unknown {
                finish(.unknown)
            } else if !track.started {
                if obs.state == .working {
                    track.started = true
                } else if obs.state.isSettled, Self.isNewEvent(obs, since: track.baseline) {
                    // 시작과 끝이 한 번의 관찰 사이에 지나갔다(짧은 일)
                    track.started = true
                    finish(.finished)
                } else if elapsed >= config.grace {
                    finish(.noStart)
                }
            } else if obs.state.isSettled {
                finish(.finished)
            }
            tracks[id] = track
        }
        let done = order.compactMap { tracks[$0]?.result }
        let pending = order.filter { tracks[$0]?.result == nil }
        let timedOut = config.timeout.map { elapsed >= $0 } ?? false
        let complete = config.any ? !done.isEmpty : pending.isEmpty
        guard complete || timedOut else { return .waiting }
        if !complete {
            // 시간 초과: 끝나지 못한 칸은 지금 상태로 timeout 으로 낸다
            let results = order.map { id -> PaneResult in
                tracks[id]?.result ?? PaneResult(id: id, state: tracks[id]?.last.state ?? .unknown, reason: .timeout,
                                                 started: tracks[id]?.started ?? false)
            }
            return .finished(results: results, pending: pending, exitCode: 124)
        }
        return .finished(results: done, pending: pending, exitCode: Self.combinedExitCode(done))
    }

    /// 관찰을 오래 못 해 기다리던 칸 모두를 실패로 끝낸다(`ObservationGuard` 가 .fail 일 때)
    public static func lost(order: [String], states: [String: PaneState] = [:]) -> Decision {
        let results = order.map { PaneResult(id: $0, state: states[$0] ?? .unknown, reason: .lost, started: false) }
        return .finished(results: results, pending: [], exitCode: 1)
    }

    /// 여러 칸의 종료 코드: 오류(3) > 입력 대기(2) > 기타 실패(1) > 끝남(0)
    public static func combinedExitCode(_ results: [PaneResult]) -> Int32 {
        let codes = results.map(\.exitCode)
        for code in [Int32(3), 2, 124, 1] where codes.contains(code) { return code }
        return 0
    }
}

/// `agentdeck wait` 가 데몬 목록을 읽을 때의 일시 실패 처리(순수 로직). 한 번 못 읽었다고 곧바로 실패로 끝내면 안 된다 —
/// 칸이 사라졌다고(gone) 잘못 알리는 일은 없지만 기다리던 일을 접게 된다. 못 읽은 회차는 건너뛰고,
/// 연결이 닫혔거나 연속으로 오래(`tolerance`) 못 읽을 때만 실패로 본다.
public struct ObservationGuard {
    public enum Verdict: Equatable {
        /// 읽었다
        case ok
        /// 못 읽었다 — 이 회차는 건너뛴다
        case skip
        /// 연결이 닫혔거나 연속 실패가 길다
        case fail
    }

    /// 이 시간 넘게 연달아 못 읽으면 실패
    public static let tolerance: TimeInterval = 30

    private var failingSince: Date?
    public let tolerance: TimeInterval

    public init(tolerance: TimeInterval = ObservationGuard.tolerance) {
        self.tolerance = tolerance
    }

    public mutating func record(observed: Bool, linkClosed: Bool, now: Date) -> Verdict {
        if observed {
            failingSince = nil
            return .ok
        }
        if linkClosed { return .fail }
        let since = failingSince ?? now
        failingSince = since
        return now.timeIntervalSince(since) >= tolerance ? .fail : .skip
    }
}

/// `agentdeck send` 가 보내도 되는 상태인가. 입력 대기(권한 요청·질문)인 칸에 글을 보내면 Enter 가 사람 대신 "Yes" 를 고르거나
/// 글이 질문의 답이 된다 — `--force` 가 아니면 거절한다(종료 코드 2).
public enum SendGuard {
    public struct Refusal: Equatable {
        public var message: String
        public var code: Int32
    }

    public static func refusal(state: PaneState, message: String?, shortId: String, force: Bool) -> Refusal? {
        switch state {
        case .dormant:
            return Refusal(message: "꺼진 칸입니다 — 앱에서 그 탭을 열어 되살린 뒤 보내세요: \(shortId)", code: 1)
        case .waiting where !force:
            return Refusal(message: "\(shortId) 가 입력을 기다리는 중입니다(\(message ?? "권한 요청·질문")). 글과 Enter 가 사람 대신 답이 되므로 보내지 않았습니다. "
                + "사람이 답한 뒤 다시 하세요(agentdeck read \(shortId) 로 내용 확인). 정말 보내려면 --force", code: 2)
        default:
            return nil
        }
    }
}

/// `agentdeck new --claude "지시"` 의 처음 지시를 못 보냈을 때의 안내(종료 코드 2)
public enum FirstInstruction {
    public enum Reason: Equatable {
        /// 상태 hook 이 연결돼 있지 않아 에이전트가 떴는지·확인 창이 떠 있는지 알 수 없다
        case noHook
        /// 제한 시간 안에 에이전트가 뜬 것을 확인하지 못했다
        case notConfirmed
    }

    public static let exitCode: Int32 = 2

    public static func unsentMessage(kind: PaneKind, shortId: String, reason: Reason) -> String {
        let base = "처음 지시를 보내지 못함: \(kind.rawValue) 가 확인을 기다리는 중일 수 있음, agentdeck read \(shortId) 로 확인"
        switch reason {
        case .notConfirmed: return base + "(뜬 뒤에 agentdeck send 로 보내세요. 칸은 남아 있음)"
        case .noHook: return base + " — \(kind.rawValue) 상태 hook 이 연결돼 있지 않아 떴는지 알 수 없어 보내지 않았습니다(설정 → 연결에서 hook 연결)"
        }
    }

    /// 에이전트가 뜬 것을 확인할 수 있는가: claude 는 SessionStart hook 이 있어야(없으면 확인 창을 구분할 수 없다), codex 는 세션 기록이 생기면 된다
    public static func canConfirm(kind: PaneKind, claudeHookInstalled: Bool) -> Bool {
        kind == .claude ? claudeHookInstalled : true
    }
}

/// `agentdeck new --claude "지시"`: 에이전트가 입력을 받을 만큼 떴는지 본다(순수 로직).
/// 뜨기 전에 보낸 글은 셸이 먼저 받아 에이전트 입력으로 이어지지 않고, 폴더 신뢰 확인 같은 창에는 Enter 가 "승인" 이 되므로,
/// 에이전트가 **자기 기록을 남긴 뒤에만** 보낸다 — claude 는 SessionStart hook 으로 세션이 짝지어진 뒤(확인 창을 지나야 시작됨),
/// codex 는 codex 세션 기록(상태)이 생긴 뒤. 확인하지 못하면 보내지 않는다(추측으로 보내지 않음).
public struct AgentReadiness {
    /// 이 시간 안에 확인하지 못하면 포기한다
    public static let timeout: TimeInterval = 45

    public struct Sample {
        public var foreground: String?
        /// claude: SessionStart hook 으로 이 칸에 세션이 짝지어짐
        public var hasSession: Bool
        /// codex: 이 칸의 codex 세션 기록(스레드)이 있음
        public var hasCodexSession: Bool
        public var bufferedBytes: Int
        public var at: Date

        public init(foreground: String?, hasSession: Bool, hasCodexSession: Bool, bufferedBytes: Int, at: Date) {
            self.foreground = foreground
            self.hasSession = hasSession
            self.hasCodexSession = hasCodexSession
            self.bufferedBytes = bufferedBytes
            self.at = at
        }
    }

    public let kind: PaneKind
    private var lastBytes = -1
    private var quietSince: Date?
    private var latest: Date?
    private var linked = false

    public init(kind: PaneKind) {
        self.kind = kind
    }

    /// 출력이 이만큼 잠잠하면 입력을 받을 준비가 된 것(처음 화면을 다 그린 뒤)
    var quietNeeded: TimeInterval { kind == .codex ? 1.2 : 0.8 }

    public mutating func observe(_ sample: Sample) {
        latest = sample.at
        switch kind {
        case .claude: linked = sample.hasSession
        case .codex: linked = sample.hasCodexSession
        case .shell: linked = true
        }
        if sample.bufferedBytes != lastBytes {
            lastBytes = sample.bufferedBytes
            quietSince = sample.at
        }
    }

    public var isReady: Bool {
        guard linked, let latest, let quietSince else { return false }
        return latest.timeIntervalSince(quietSince) >= quietNeeded
    }
}
