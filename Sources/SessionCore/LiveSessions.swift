import Foundation

/// 지금 떠 있는 claude 프로세스로 "이 세션이 정말 열려 있는가"를 판단한다.
/// 기록(hook)은 세션마다 프로세스 하나만 기억하므로, 같은 세션을 두 화면에서 열었거나 기록이 늦을 때를 여기서 보충한다.
public enum LiveSessions {
    /// 터미널에서 돌고 있는 claude 프로세스
    public struct Process: Equatable {
        public var pid: pid_t
        public var startTime: Double
        public var tty: String?
        /// 실행 인자(`--resume <id>` 등)에 보이는 세션. 세션 안에서 /resume 으로 바꿨으면 지금 세션과 다를 수 있다.
        public var argumentSessionId: String?
        public var termProgram: String?
        public var cwd: String?

        public init(pid: pid_t, startTime: Double, tty: String?, argumentSessionId: String?,
                    termProgram: String? = nil, cwd: String? = nil) {
            self.pid = pid
            self.startTime = startTime
            self.tty = tty
            self.argumentSessionId = argumentSessionId
            self.termProgram = termProgram
            self.cwd = cwd
        }

        func isSameProcess(as record: SessionRecord) -> Bool {
            pid == record.pid && abs(startTime - record.pidStartedAt) < 0.001
        }
    }

    public static func systemProcesses() -> [Process] {
        ProcessUtil.allPids().compactMap { pid in
            guard let args = ProcessUtil.arguments(pid), let argv0 = args.first,
                  (argv0 as NSString).lastPathComponent == "claude",
                  let info = ProcessUtil.info(pid), info.hasTTY, !info.isZombie,
                  !args.dropFirst().contains(where: { $0 == "-p" || $0 == "--print" || $0.hasPrefix("--print=") })
            else { return nil }
            return Process(pid: pid, startTime: info.startTime, tty: info.tty,
                           argumentSessionId: ClaudeArguments.sessionId(args),
                           termProgram: ProcessUtil.environment(pid)?["TERM_PROGRAM"], cwd: ProcessUtil.cwd(pid))
        }
    }

    /// 기록이 맡고 있지 않은 프로세스(아무 "열림" 기록의 프로세스도 아닌 것)
    static func unowned(_ processes: [Process], records: [SessionRecord], isRunning: (SessionRecord) -> Bool) -> [Process] {
        let owners = records.filter(isRunning)
        return processes.filter { process in !owners.contains { process.isSameProcess(as: $0) } }
    }

    /// 지금 열려 있는 세션 ID: 기록상 실행 중이거나, 기록이 맡지 않은 claude 프로세스의 실행 인자에 보이는 세션.
    /// 이 안에 있는 세션은 절대 다시 열지 않는다.
    public static func openIds(records: [SessionRecord], processes: [Process],
                               isRunning: (SessionRecord) -> Bool = { $0.isRunning }) -> Set<String> {
        var ids = Set(records.filter(isRunning).map(\.sessionId))
        for process in unowned(processes, records: records, isRunning: isRunning) {
            if let id = process.argumentSessionId { ids.insert(id) }
        }
        return ids
    }

    /// "꺼짐" 기록인데 그 세션을 실행 인자로 연 claude 가 아직 떠 있으면(같은 세션을 두 화면에서 열고 하나만 닫은 경우 등)
    /// 그 프로세스로 기록을 옮긴다. 옮긴 세션 ID 를 돌려준다.
    @discardableResult
    public static func adopt(into store: SessionStore, processes: [Process],
                             isRunning: (SessionRecord) -> Bool = { $0.isRunning }) -> [String] {
        let records = store.all()
        var adopted: [String] = []
        for process in unowned(processes, records: records, isRunning: isRunning) {
            guard let id = process.argumentSessionId, !adopted.contains(id),
                  var record = records.first(where: { $0.sessionId == id }), !isRunning(record)
            else { continue }
            record.take(process)
            if (try? store.save(record)) != nil { adopted.append(id) }
        }
        return adopted
    }
}

extension SessionRecord {
    /// 기록을 이 프로세스가 맡게 한다(열림 상태로).
    mutating func take(_ process: LiveSessions.Process) {
        pid = process.pid
        pidStartedAt = process.startTime
        tty = process.tty ?? tty
        termProgram = process.termProgram ?? termProgram
        endedAt = nil
        endReason = nil
    }
}

/// 방금 열라고 보낸 세션. claude 가 실제로 뜨기(SessionStart)까지 몇 초 걸리는 동안
/// 같은 세션을 또 열지 않도록 잡아 둔다. 앱과 CLI 가 같이 보도록 파일에 둔다.
public struct LaunchReservations {
    /// 셸이 뜨고 claude 가 시작될 때까지 넉넉히 기다리는 시간. 그 안에 안 뜨면 다시 열 수 있다.
    public static let ttl: TimeInterval = 45

    public let url: URL

    public init(url: URL = Paths.appSupport.appendingPathComponent("launching.json")) {
        self.url = url
    }

    public func active(now: Date = Date()) -> [String: Date] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return raw.compactMapValues { at in
            let date = Date(timeIntervalSince1970: at)
            return now.timeIntervalSince(date) < Self.ttl && date <= now.addingTimeInterval(5) ? date : nil
        }
    }

    func save(_ entries: [String: Date]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let raw = entries.mapValues(\.timeIntervalSince1970)
        try? JSONEncoder().encode(raw).write(to: url, options: .atomic)
    }

    /// 열어도 되는 세션만 골라 잡아 두고 돌려준다. 지금 열려 있거나(open) 이미 여는 중인 세션은 뺀다.
    /// SessionStore.withLock 안에서 불러야 앱·CLI·hook 이 동시에 고쳐도 안전하다.
    public func reserve(_ ids: [String], open: Set<String>, now: Date = Date()) -> [String] {
        var entries = active(now: now)
        var granted: [String] = []
        for id in ids where !open.contains(id) && entries[id] == nil && !granted.contains(id) {
            entries[id] = now
            granted.append(id)
        }
        if !granted.isEmpty { save(entries) }
        return granted
    }

    public func release(_ ids: [String], now: Date = Date()) {
        var entries = active(now: now)
        let before = entries.count
        ids.forEach { entries.removeValue(forKey: $0) }
        if entries.count != before || FileManager.default.fileExists(atPath: url.path) { save(entries) }
    }
}

/// 세션을 열기 직전에 다시 확인하고 잡아 두는 공용 절차(앱의 클릭·모두 열기, CLI open·restore-all).
public enum LaunchGate {
    /// 후보 중 지금 열어도 되는 세션만 돌려준다(이미 떠 있는 claude 가 있거나 방금 연 세션은 뺀다).
    public static func claim(_ ids: [String], store: SessionStore = SessionStore(),
                             reservations: LaunchReservations = LaunchReservations(),
                             processes: [LiveSessions.Process]? = nil) -> [String] {
        let processes = processes ?? LiveSessions.systemProcesses()
        return store.withLock {
            let records = store.all()
            let open = LiveSessions.openIds(records: records, processes: processes)
            // 기록이 없어졌거나(/exit 등) 대화 파일이 없는 세션은 열 수 없다
            let resumable = ids.filter { id in records.contains { $0.sessionId == id } }
            return reservations.reserve(resumable, open: open)
        }
    }
}
