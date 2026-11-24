import Darwin
import Foundation
import TermWire

/// 화면 하나의 종류. 앱의 목록·탭과 `agentdeck` 명령이 같은 기준으로 가른다.
public enum PaneKind: String, Codable, Equatable {
    case claude, codex, shell

    public static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "ksh", "dash", "nu"]

    /// 앞에서 셸만 도는가("zsh (kiro-cli-term)" 처럼 감싼 셸도 셸로 본다)
    public static func isShellProgram(_ foreground: String?) -> Bool {
        guard let name = foreground?.split(separator: " ").first else { return false }
        return shellNames.contains(String(name))
    }
}

/// 화면 하나를 읽은 결과: 짝지은 세션, 작업 폴더, 보완 규칙까지 적용한 작업 상태.
/// 앱(TermModel.makeRows)과 `agentdeck` 명령이 같은 `PaneStateReader` 를 쓰므로 상태가 어긋나지 않는다.
public struct PaneReading {
    public var pane: PaneInfo
    /// 이 화면에서 도는 claude 세션(hook 기록)
    public var session: SessionRecord?
    /// 이 화면에서 도는 codex
    public var codex: CodexScanner.Match?
    /// 지금 작업 폴더(claude·codex 가 돌면 그쪽, 아니면 셸의). 작업 트리로 옮겨 가면 따라간다.
    public var cwd: String
    /// 보완 규칙(WorkStateRules.effective)까지 적용한 상태: working | orchestrating | waiting | done | idle | error. 모르면 nil.
    public var state: String?
    public var message: String?
    public var at: Date?
    public var seq: Int?
    /// 응답을 마칠 때 남은 백그라운드 일을 파일로 확인한 결과(claude)
    public var background: WorkStateRules.Background?

    public var codexSession: CodexSession? { codex?.session }

    public var kind: PaneKind {
        if codex != nil || pane.foreground == "codex" { return .codex }
        if session != nil || pane.foreground == "claude" { return .claude }
        return .shell
    }

    /// 상태 기록(세션)의 열쇠: codex 는 "codex:<세션>", claude 는 세션 ID
    public var statusSessionId: String? { codexSession.map { "codex:" + $0.id } ?? session?.sessionId }
}

/// 화면 목록(데몬이 알려 준)에서 각 화면의 세션·폴더·상태를 읽는다. 파일과 프로세스 표만 읽고 아무것도 고치지 않는다
/// (codex 짝짓기 기록만 `persist` 일 때 쓴다 — 앱).
public final class PaneStateReader {
    public let codexScanner: CodexScanner

    public init(persistBindings: Bool = true) {
        codexScanner = CodexScanner(persist: persistBindings)
    }

    /// seen: 화면에서 확인한 "완료"(세션별). transcriptFallback: hook 기록에 대화 파일 경로가 없을 때 세션 ID 로 찾는 방법.
    public func read(_ panes: [PaneInfo], seen: [String: WorkStateRules.Seen] = [:],
                     transcriptFallback: (String) -> String? = { _ in nil }, now: Date = Date()) -> [PaneReading] {
        // hook 기록 중 실행 중인 세션을 화면에 짝짓는다. claude 에서 부모 프로세스를 따라 올라가 화면의 셸을 만나면 그 화면이다.
        // (Kiro CLI 처럼 셸을 자기 가상 터미널로 한 겹 감싸는 도구가 있으면 claude 의 tty 가 화면의 tty 와 다르다.)
        // 계보로 못 찾으면 tty 로 짝짓는다. 프로세스 목록은 sysctl 한 번으로 찍어 아래 계보 찾기들이 같이 쓴다.
        let snapshot = ProcessUtil.snapshot()
        let codexMatches = codexScanner.scan(panes, snapshot: snapshot)
        let running = SessionStore().all().filter(\.isRunning)
        func device(_ tty: String?) -> String? { tty.map { ($0 as NSString).lastPathComponent } } // "/dev/ttys002" ↔ "ttys002"
        let shells = Dictionary(panes.map { ($0.pid, $0.id) }, uniquingKeysWith: { first, _ in first })
        var sessionByPane: [String: SessionRecord] = [:]
        // hook 이 남긴 화면 ID 가 맞으면 그대로(가장 정확). 같은 화면에 여럿이면 최근 것.
        let paneIds = Set(panes.map(\.id))
        for record in running.sorted(by: { ($0.activeSince ?? $0.startedAt) < ($1.activeSince ?? $1.startedAt) }) {
            if let pane = record.pane, paneIds.contains(pane) { sessionByPane[pane] = record }
        }
        for record in running where !sessionByPane.values.contains(where: { $0.sessionId == record.sessionId }) {
            if let pane = snapshot.pane(of: record.pid, shells: shells, maxHops: 32), sessionByPane[pane] == nil {
                sessionByPane[pane] = record
            }
        }
        // 감싼 셸이 있는 화면은 안쪽 셸의 폴더를 읽어야 cd 를 따라간다
        let wrapped = panes.contains { ($0.foreground ?? "").contains(" (") }
        func innermostShell(_ pid: pid_t) -> pid_t { snapshot.innermostShell(from: pid, names: PaneKind.shellNames) }
        return panes.map { pane -> PaneReading in
            let codexMatch = codexMatches[pane.id]
            let session = codexMatch == nil ? (sessionByPane[pane.id]
                ?? device(pane.tty).flatMap { tty in running.first { device($0.tty) == tty } }) : nil
            let shell = wrapped ? innermostShell(pane.pid) : pane.pid
            let codexSessionCwd: String? = codexMatch?.session?.cwd
            let codexProcessCwd: String? = codexMatch.flatMap { ProcessUtil.cwd($0.process.pid) }
            let claudeCwd: String? = session.flatMap { ProcessUtil.cwd($0.pid) ?? $0.cwd }
            let agentCwd: String? = codexSessionCwd.flatMap { $0.isEmpty ? nil : $0 } ?? codexProcessCwd ?? claudeCwd
            var reading = PaneReading(pane: pane, session: session, codex: codexMatch,
                                      cwd: agentCwd ?? ProcessUtil.cwd(shell) ?? pane.cwd)
            if let codex = codexMatch?.session {
                Self.codexState(&reading, codex: codex, seen: seen["codex:" + codex.id], now: now)
            } else if let session {
                Self.claudeState(&reading, session: session, seen: seen[session.sessionId],
                                 transcriptFallback: transcriptFallback, now: now)
            }
            return reading
        }
    }

    /// codex 상태(hook·rollout·SQLite 가 읽어 낸 상태에 "본 완료" 규칙만 얹는다)
    static func codexState(_ reading: inout PaneReading, codex: CodexSession, seen: WorkStateRules.Seen?, now: Date) {
        reading.state = WorkStateRules.effective(state: codex.state, at: codex.stateAt, seq: codex.stateSeq,
                                                 transcriptModifiedAt: nil, seen: seen, now: now)
        reading.message = codex.message
        reading.at = codex.stateAt
        reading.seq = codex.stateSeq
    }

    /// claude 상태. hook 이 없는 때는 가볍게 보완한다(WorkStateRules.effective):
    /// 입력 대기 뒤에 대화 파일이 다시 늘면(권한을 허락해 이어서 일함) 작업 중으로 본다.
    static func claudeState(_ reading: inout PaneReading, session: SessionRecord, seen: WorkStateRules.Seen?,
                            transcriptFallback: (String) -> String?, now: Date) {
        let at = session.stateAt
        let transcript = session.transcriptPath ?? transcriptFallback(session.sessionId)
        let modified = session.state == "waiting" ? WorkStateRules.transcriptModifiedAt(transcript) : nil
        // 응답을 마칠 때(Stop) 남은 백그라운드 일이 있었던 세션만 그 일들을 파일로 확인한다(일마다 stat 몇 번)
        var background: WorkStateRules.Background?
        if let tasks = session.background, let stoppedAt = at, ["done", "idle", "waiting"].contains(session.state ?? "") {
            background = BackgroundWork.inspect(tasks, transcriptPath: transcript, sessionId: session.sessionId, stoppedAt: stoppedAt)
        }
        reading.state = WorkStateRules.effective(state: session.state, at: at, seq: session.stateSeq,
                                                 transcriptModifiedAt: modified, seen: seen, background: background, now: now)
        reading.message = session.stateMessage
        reading.at = at
        reading.seq = session.stateSeq
        reading.background = background
    }
}

/// 실행 중인 claude·codex 의 하위 에이전트를 훑는다(앱은 10초에 한 번, 명령줄은 부를 때마다).
public struct AgentScanTarget {
    public var paneId: String
    public var session: SessionRecord?
    public var codex: CodexSession?
    public var codexHome: String?

    public init(paneId: String, session: SessionRecord?, codex: CodexSession?, codexHome: String?) {
        self.paneId = paneId
        self.session = session
        self.codex = codex
        self.codexHome = codexHome
    }
}

public final class AgentActivityScanner {
    private let subagents = SubagentScanner()
    private var lastScan = Date.distantPast
    private var lastAgents: [SubagentActivity] = []

    public init() {}

    /// worktrees: 화면의 저장소에서 메인이 아닌 작업 트리 경로(하위 에이전트를 작업 트리에 붙일 때 — 필요 없으면 비워 둔다).
    /// minInterval 이 안 지났으면 지난 결과를 그대로 돌려준다.
    public func scan(_ targets: [AgentScanTarget], worktrees: (String) -> [String] = { _ in [] },
                     codexReader: (URL) -> CodexSessions, minInterval: TimeInterval = 10) -> [SubagentActivity] {
        guard Date().timeIntervalSince(lastScan) >= minInterval else { return lastAgents }
        lastScan = Date()
        let sessions = targets.compactMap { target -> (paneId: String, sessionId: String, transcript: String, worktrees: [String])? in
            guard let session = target.session,
                  let path = session.transcriptPath ?? TranscriptReader.locate(sessionId: session.sessionId)
            else { return nil }
            return (target.paneId, session.sessionId, path, worktrees(target.paneId))
        }
        lastAgents = subagents.scan(sessions)
        for target in targets {
            guard let codex = target.codex else { continue }
            let home = URL(fileURLWithPath: target.codexHome ?? CodexSessions.defaultHome.path)
            for (child, status) in codexReader(home).children(of: codex.id) {
                let at = child.stateAt ?? .distantPast
                guard let activity = CodexChildRules.activity(state: child.state, stateAt: child.stateAt,
                    edgeStatus: status, lastActivityAt: child.lastActivityAt) else { continue }
                let trees = worktrees(target.paneId)
                let tree = trees.first { child.cwd == $0 || child.cwd.hasPrefix($0 + "/") }
                lastAgents.append(SubagentActivity(id: child.id, sessionId: "codex:" + codex.id, paneId: target.paneId,
                    description: child.title.isEmpty ? "Codex 하위 에이전트" : SessionNaming.preview(of: child.title),
                    agentType: "codex", worktreePath: tree, lastActive: at, lastText: child.lastText,
                    running: activity == .running))
            }
        }
        return lastAgents
    }

    /// 이 codex 가 띄운 하위 에이전트 중 일하는 것 수(부모가 턴을 마쳤어도 이게 있으면 오케스트레이션 중)
    public static func runningCodexChildren(of codexId: String, in agents: [SubagentActivity]) -> Int {
        agents.filter { $0.sessionId == "codex:" + codexId && $0.agentType == "codex" && $0.isRunning }.count
    }
}
