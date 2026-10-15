import Foundation

/// Claude Code 의 SessionStart / SessionEnd hook 으로 실행되는 부분.
/// `ClaudeSessions hook` 으로 호출되며, 어떤 경우에도 Claude 쪽에 오류를 내지 않는다.
public enum HookHandler {
    /// 사용자가 직접 끝내거나 떠난 경우(/exit, Ctrl-D, /clear, 세션 안에서 /resume 으로 전환, 로그아웃). 이때만 기록을 지운다.
    /// 그 밖의 사유(창 닫기·앱 종료 등 "other")와 재부팅(훅 자체가 안 불림)은 기록을 남겨 복원 대상으로 둔다.
    public static let explicitEndReasons: Set<String> = ["clear", "logout", "prompt_input_exit", "resume"]

    struct Input: Decodable {
        let session_id: String
        let hook_event_name: String
        let cwd: String?
        let transcript_path: String?
        let source: String?
        let reason: String?
    }

    public struct Context {
        public var claudePid: pid_t
        public var claudeProcess: ProcInfo?
        public var claudeArgs: [String]
        public var environment: [String: String]
        public var now: Date
        /// 지금 떠 있는 claude 프로세스들(SessionEnd 때 같은 세션을 연 다른 화면이 남았는지 본다). nil 이면 그때 조사한다.
        public var liveProcesses: [LiveSessions.Process]?

        public init(claudePid: pid_t, claudeProcess: ProcInfo?, claudeArgs: [String],
                    environment: [String: String], now: Date = Date(), liveProcesses: [LiveSessions.Process]? = nil) {
            self.claudePid = claudePid
            self.claudeProcess = claudeProcess
            self.claudeArgs = claudeArgs
            self.environment = environment
            self.now = now
            self.liveProcesses = liveProcesses
        }

        public static func current() -> Context {
            let pid = ProcessUtil.findClaudeAncestor()
            return Context(
                claudePid: pid,
                claudeProcess: ProcessUtil.info(pid),
                claudeArgs: ProcessUtil.arguments(pid) ?? [],
                environment: ProcessInfo.processInfo.environment
            )
        }
    }

    public static func handle(input: Data, context: Context, store: SessionStore,
                              reservations: LaunchReservations = LaunchReservations()) throws {
        let event = try JSONDecoder().decode(Input.self, from: input)
        guard SessionStore.isValidId(event.session_id) else { return }
        // 앱의 새로 고침·다른 hook 과 동시에 기록을 고치지 않도록 잠금 안에서 처리한다.
        try store.withLock {
            switch event.hook_event_name {
            case "SessionStart": try sessionStart(event, context: context, store: store, reservations: reservations)
            case "SessionEnd": try sessionEnd(event, context: context, store: store)
            default: break
            }
        }
    }

    static func sessionStart(_ event: Input, context: Context, store: SessionStore,
                             reservations: LaunchReservations) throws {
        guard isInteractive(context), let proc = context.claudeProcess else { return }
        var record = store.load(event.session_id) ?? SessionRecord(
            sessionId: event.session_id, cwd: event.cwd ?? "", transcriptPath: nil,
            pid: proc.pid, pidStartedAt: proc.startTime, startedAt: context.now
        )
        if let cwd = event.cwd, !cwd.isEmpty { record.cwd = cwd }
        if let path = event.transcript_path, !path.isEmpty { record.transcriptPath = path }
        record.pid = proc.pid
        record.pidStartedAt = proc.startTime
        record.endedAt = nil
        record.endReason = nil
        record.activeSince = context.now
        record.tty = proc.tty ?? record.tty
        record.termProgram = context.environment["TERM_PROGRAM"] ?? record.termProgram
        try store.save(record)
        // 열라고 보낸 세션이 실제로 떴다
        reservations.release([event.session_id])
        // 같은 프로세스에서 이전에 열려 있던 세션(/resume 으로 떠난 빈 세션 등)을 정리한다.
        for other in store.all() where other.sessionId != record.sessionId
            && other.endedAt == nil && other.isSameProcess(as: record) {
            store.remove(other.sessionId)
        }
    }

    static func sessionEnd(_ event: Input, context: Context, store: SessionStore) throws {
        let reason = event.reason ?? "other"
        // 어느 프로세스가 끝나는지 모르면 남아 있는 기록을 건드리지 않는다(잘못 "꺼짐"으로 만들지 않게).
        guard let proc = context.claudeProcess else { return }
        let existing = store.load(event.session_id)
        // 같은 세션을 두 화면에서 연 뒤 하나만 닫은 경우: 기록이 지금도 도는 다른 프로세스 것이면 건드리지 않는다.
        if let record = existing, !(record.pid == proc.pid && abs(record.pidStartedAt - proc.startTime) < 0.001),
           record.isRunning {
            return
        }
        // 기록을 맡던 프로세스가 끝나도, 같은 세션을 실행 인자로 연 다른 claude 가 남아 있으면 그쪽으로 넘긴다.
        // (세션 안에서 /resume 으로 다른 세션으로 옮겨 간 프로세스는 실행 인자가 낡았으므로 뺀다)
        let processes = LiveSessions.unowned(context.liveProcesses ?? LiveSessions.systemProcesses(),
                                             records: store.all().filter { $0.sessionId != event.session_id },
                                             isRunning: { $0.isRunning })
        if var record = existing, let survivor = processes.first(where: {
            $0.argumentSessionId == event.session_id
                && !($0.pid == proc.pid && abs($0.startTime - proc.startTime) < 0.001)
        }) {
            record.take(survivor)
            try store.save(record)
            return
        }
        // 대화를 한 번도 안 한 세션은 Claude 가 대화 파일을 만들지 않아 `claude --resume` 으로 열 수 없다.
        let path = event.transcript_path ?? existing?.transcriptPath
        let resumable = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        if explicitEndReasons.contains(reason) || !resumable {
            store.remove(event.session_id)
        } else if var record = existing {
            record.endedAt = context.now
            record.endReason = reason
            try store.save(record)
        }
    }

    /// `claude -p` 같은 비대화형 실행이나 SDK·IDE 가 띄운(터미널 없는) 세션은 기록하지 않는다.
    static func isInteractive(_ context: Context) -> Bool {
        guard let proc = context.claudeProcess, proc.hasTTY else { return false }
        let headless = context.claudeArgs.dropFirst().contains {
            $0 == "-p" || $0 == "--print" || $0.hasPrefix("--print=")
        }
        return !headless
    }

    /// 실행 파일의 `hook` 하위 명령 진입점. 항상 0 을 돌려준다.
    public static func runFromCommandLine() -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        do {
            try handle(input: input, context: .current(), store: SessionStore())
        } catch {
            logError("\(error)")
        }
        return 0
    }

    static func logError(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = Paths.hookErrorLog
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
