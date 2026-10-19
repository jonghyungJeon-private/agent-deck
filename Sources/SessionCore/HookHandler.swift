import Foundation
import TermWire

/// Claude Code hook 으로 실행되는 부분(`AgentDeckDaemon hook`). 어떤 경우에도 Claude 쪽에 오류를 내지 않고,
/// 아무것도 출력하지 않는다(UserPromptSubmit 의 출력은 claude 문맥에 붙으므로).
/// - SessionStart / SessionEnd: 세션 기록(되살리기·짝짓기)
/// - UserPromptSubmit / Stop / StopFailure / Notification / PermissionRequest: 작업 상태(목록 표시·알림)
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
        let notification_type: String?
        let message: String?
        let error: String?
        /// Stop 때 아직 도는 백그라운드 일(하위 에이전트·셸 등)
        let background_tasks: BackgroundTaskList?
    }

    /// 상태를 적는 hook 이벤트
    public static let statusEvents: Set<String> = ["UserPromptSubmit", "Stop", "StopFailure", "Notification", "PermissionRequest"]
    /// 사람의 입력을 기다리는 알림 종류
    static let waitingNotifications: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]

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
            case let name where statusEvents.contains(name):
                try status(event, context: context, store: store, reservations: reservations)
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
        record.pane = AgentDeckEnv.value("PANE", in: context.environment) ?? record.pane
        record.state = "idle"
        record.stateAt = context.now
        record.stateMessage = nil
        record.stateSeq = (record.stateSeq ?? 0) + 1
        record.background = nil
        try store.save(record)
        // 열라고 보낸 세션이 실제로 떴다
        reservations.release([event.session_id])
        // 같은 프로세스에서 이전에 열려 있던 세션(/resume 으로 떠난 빈 세션 등)을 정리한다.
        for other in store.all() where other.sessionId != record.sessionId
            && other.endedAt == nil && other.isSameProcess(as: record) {
            store.remove(other.sessionId)
        }
    }

    /// 작업 상태를 적는다. 기록이 없으면(hook 을 세션 도중에 넣은 경우) 먼저 세션을 기록한다.
    static func status(_ event: Input, context: Context, store: SessionStore, reservations: LaunchReservations) throws {
        let state: String
        var message: String?
        switch event.hook_event_name {
        case "UserPromptSubmit": state = "working"
        case "Stop": state = "done"  // 백그라운드 일이 남았으면 앱이 "오케스트레이션 중"으로 보인다(WorkStateRules)
        case "StopFailure":
            state = "error"
            message = event.error
        case "PermissionRequest":
            state = "waiting"
            message = "권한 요청"
        case "Notification":
            guard let type = event.notification_type else { return }
            if waitingNotifications.contains(type) {
                state = "waiting"
                message = event.message
            } else if type == "idle_prompt" {
                state = "idle"
            } else {
                return
            }
        default: return
        }
        if store.load(event.session_id) == nil {
            try sessionStart(event, context: context, store: store, reservations: reservations)
        }
        guard var record = store.load(event.session_id), record.endedAt == nil else { return }
        // 오래 기다림 알림(입력 없이 약 60초)은 작업 중을 쉬는 중으로 바로잡는다(Esc 로 멈추면 Stop 이 오지 않는다).
        // 권한·질문 대기는 더 구체적이므로 덮지 않는다.
        if state == "idle", record.state == "waiting" { return }
        record.state = state
        record.stateAt = context.now
        record.stateMessage = message.map { String($0.prefix(200)) }
        record.stateSeq = (record.stateSeq ?? 0) + 1
        record.pane = AgentDeckEnv.value("PANE", in: context.environment) ?? record.pane
        // 남은 백그라운드 일은 Stop 이 알려 준다. 다른 상태(질문·입력 대기 등)에선 그대로 둔다.
        if event.hook_event_name == "Stop" { record.background = event.background_tasks?.tasks }
        try store.save(record)
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
