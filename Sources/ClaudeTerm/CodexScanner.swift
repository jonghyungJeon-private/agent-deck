import Foundation
import SessionCore
import TermWire

/// UI 앱에서 실행하므로 기존 터미널 데몬을 재시작할 필요가 없다.
final class CodexScanner {
    struct Match {
        var process: ProcInfo
        var args: [String]
        var session: CodexSession?
        var home: URL
    }
    struct Binding: Codable, Equatable {
        var pid: pid_t
        var startedAt: Double
        var sessionId: String
    }
    private var bindings: [String: Binding] = [:]
    private var readers: [URL: CodexSessions] = [:]
    private let url = TermPaths.home.appendingPathComponent("codex-bindings.json")
    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Binding].self, from: data) { bindings = saved }
    }
    func reader(_ home: URL) -> CodexSessions {
        if let reader = readers[home] { return reader }
        let reader = CodexSessions(home: home); readers[home] = reader; return reader
    }
    /// 인자·환경 읽기를 (pid, 시작 시각)별로 기억해 두므로 이 객체 하나를 계속 쓴다(worker 에서만).
    private let finder = CodexProcessFinder()

    func scan(_ panes: [PaneInfo], snapshot: ProcessSnapshot) -> [String: Match] {
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
        if before != bindings, let data = try? JSONEncoder().encode(bindings) { try? data.write(to: url, options: .atomic) }
        return result
    }
}
