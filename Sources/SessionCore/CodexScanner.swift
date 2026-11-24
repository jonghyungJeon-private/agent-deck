import Foundation
import TermWire

/// 화면마다 도는 codex 와 그 세션을 짝짓는다(앱과 `agentdeck` 명령이 같은 규칙을 쓴다 — SessionCore).
/// 짝짓기 기록(`term/codex-bindings.json`)은 앱만 쓴다(`persist`). 명령줄 도구는 읽기만 해 앱과 서로 덮어쓰지 않는다.
public final class CodexScanner {
    public struct Match {
        public var process: ProcInfo
        public var args: [String]
        public var session: CodexSession?
        public var home: URL
    }
    struct Binding: Codable, Equatable {
        var pid: pid_t
        var startedAt: Double
        var sessionId: String
    }
    private var bindings: [String: Binding] = [:]
    private var readers: [URL: CodexSessions] = [:]
    /// 데이터 위치를 옮기면(예전 폴더 → 새 폴더) 따라가도록 매번 계산한다
    private var url: URL { TermPaths.home.appendingPathComponent("codex-bindings.json") }
    private let persist: Bool
    public init(persist: Bool = true) {
        self.persist = persist
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Binding].self, from: data) { bindings = saved }
    }
    public func reader(_ home: URL) -> CodexSessions {
        if let reader = readers[home] { return reader }
        let reader = CodexSessions(home: home); readers[home] = reader; return reader
    }
    /// 인자·환경 읽기를 (pid, 시작 시각)별로 기억해 두므로 이 객체 하나를 계속 쓴다(worker 에서만).
    private let finder = CodexProcessFinder()

    public func scan(_ panes: [PaneInfo], snapshot: ProcessSnapshot) -> [String: Match] {
        let before = bindings
        let paneIds = Set(panes.map(\.id))
        let shells = Dictionary(panes.map { ($0.pid, $0.id) }, uniquingKeysWith: { a, _ in a })
        let found = finder.find(snapshot: snapshot, shells: shells, paneIds: paneIds)
        var result: [String: Match] = [:]
        let hooks = CodexHook.store.all().filter { $0.endedAt == nil }
        for candidate in found.candidates {
            let (process, args, env, pane) = (candidate.process, candidate.args, candidate.env, candidate.pane)
            let home = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? CodexSessions.defaultHome
            let previous = bindings[pane].flatMap { $0.pid == process.pid && abs($0.startedAt - process.startTime) < 0.001 ? $0.sessionId : nil }
            let hook = hooks.filter { $0.pane == pane && ($0.stateAt?.timeIntervalSince1970 ?? 0) >= process.startTime }
                .max { ($0.stateAt ?? .distantPast) < ($1.stateAt ?? .distantPast) }
            let observed = found.evidence[pane].flatMap { $0.startTime >= process.startTime ? ($0.sessionId, $0.startTime) : nil }
            let id: String?
            if let hook, (hook.stateAt?.timeIntervalSince1970 ?? 0) >= (observed?.1 ?? 0) {
                id = hook.sessionId
            } else { id = observed?.0 ?? previous ?? CodexArguments.sessionId(args) }
            if let id { bindings[pane] = Binding(pid: process.pid, startedAt: process.startTime, sessionId: id) }
            var session = id.flatMap { reader(home).session($0) }
            if let hook, hook.sessionId == id, var value = session, let at = hook.stateAt, at >= (value.stateAt ?? .distantPast) {
                value.state = hook.state; value.stateAt = at; value.message = hook.stateMessage; value.stateSeq = hook.stateSeq; session = value
            }
            result[pane] = Match(process: process, args: args, session: session, home: home)
        }
        bindings = bindings.filter { result[$0.key] != nil }
        if persist, before != bindings, let data = try? JSONEncoder().encode(bindings) { try? data.write(to: url, options: .atomic) }
        return result
    }
}
