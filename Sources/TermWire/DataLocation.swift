import Darwin
import Foundation

/// 환경 변수. 새 이름은 `AGENTDECK_*`, 예전 이름(`CLAUDE_TERM_*`·`CLAUDE_SESSIONS_*`)도 계속 읽는다
/// (예전 데몬이 띄운 셸·hook 은 예전 이름을 들고 있다).
public enum AgentDeckEnv {
    /// 뒷부분 → 예전 이름. 표에 없으면 `CLAUDE_TERM_<뒷부분>`.
    static let legacyNames = [
        "HOME": "CLAUDE_SESSIONS_HOME",
        "TERM_HOME": "CLAUDE_TERM_HOME",
        "PANE": "CLAUDE_SESSIONS_PANE",
    ]

    public static func name(_ suffix: String) -> String { "AGENTDECK_" + suffix }
    public static func legacyName(_ suffix: String) -> String { legacyNames[suffix] ?? "CLAUDE_TERM_" + suffix }

    /// 새 이름이 있으면 그것, 없으면 예전 이름
    public static func value(_ suffix: String,
                             in env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        env[name(suffix)] ?? env[legacyName(suffix)]
    }

    /// 비어 있지 않은 값만
    public static func nonEmpty(_ suffix: String,
                                in env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        value(suffix, in: env).flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func isOn(_ suffix: String, in env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        value(suffix, in: env) == "1"
    }
}

/// 앱 데이터 위치(세션 기록 `sessions/`·`codex-sessions/`, 데몬·화면 `term/`).
/// 기본은 `~/Library/Application Support/AgentDeck`. 예전 이름 `ClaudeSessions` 폴더는 이렇게 다룬다:
/// - 예전 데몬이 살아 있으면 앱은 그 데몬에 붙고 예전 폴더를 그대로 쓴다(legacy). 새 데몬은 띄우지 않는다.
/// - 데몬이 하나도 없을 때 앱이 예전 폴더를 새 폴더로 옮기고(이름 바꾸기), 예전 폴더에 표식(MIGRATED_TO)을 남긴다.
/// - hook·데몬·ctl 은 옮기지 않고 위 규칙대로 쓸 곳만 고른다(`helperUsesLegacy`).
public enum DataLocation {
    public enum Mode: String {
        /// 새 위치
        case standard
        /// 예전 데몬에 붙어 예전 폴더를 쓰는 중(재시작하면 옮긴다)
        case legacy
        /// 환경 변수로 정한 위치(개발·시험). 옮기기 없음
        case custom
    }

    public static let folderName = "AgentDeck"
    public static let legacyFolderName = "ClaudeSessions"
    public static let markerName = "MIGRATED_TO"

    // MARK: 위치

    /// 시험용 AGENTDECK_APP_SUPPORT: ~/Library/Application Support 대신(Foundation 의 홈 폴더는 HOME 을 따르지 않는다)
    public static func appSupportBase(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let base = env["AGENTDECK_APP_SUPPORT"], !base.isEmpty { return URL(fileURLWithPath: base, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    public static func standardRoot(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        appSupportBase(env).appendingPathComponent(folderName, isDirectory: true)
    }

    public static func legacyRoot(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        appSupportBase(env).appendingPathComponent(legacyFolderName, isDirectory: true)
    }

    /// AGENTDECK_HOME(예전 CLAUDE_SESSIONS_HOME)
    public static func explicitRoot(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        AgentDeckEnv.nonEmpty("HOME", in: env).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// AGENTDECK_TERM_HOME(예전 CLAUDE_TERM_HOME): 소켓·배치 등 term 폴더만 따로
    public static func explicitTerm(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        AgentDeckEnv.nonEmpty("TERM_HOME", in: env).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static func termDir(of root: URL) -> URL { root.appendingPathComponent("term", isDirectory: true) }

    private static let lock = NSLock()
    private static var chosen: (root: URL, mode: Mode)?

    /// 이 프로세스가 쓰는 데이터 위치. 환경 변수가 있으면 늘 그것(시험이 도중에 바꿀 수 있게 매번 읽는다).
    public static var root: URL {
        if let explicit = explicitRoot() { return explicit }
        return current().root
    }

    public static var mode: Mode {
        explicitRoot() != nil ? .custom : current().mode
    }

    /// 데몬 소켓·로그·배치(term) 폴더
    public static var termDir: URL { explicitTerm() ?? termDir(of: root) }

    /// 위치를 정한다(앱이 시작할 때·옮긴 뒤, 데몬이 앱에게 받은 위치로)
    public static func use(root: URL, mode: Mode) {
        lock.lock()
        chosen = (root, mode)
        lock.unlock()
    }

    /// 아직 안 정했으면 hook·데몬 규칙으로 정한다(옮기지는 않는다)
    private static func current() -> (root: URL, mode: Mode) {
        lock.lock()
        defer { lock.unlock() }
        if let chosen { return chosen }
        let legacy = helperUsesLegacy(probe())
        let picked = legacy ? (legacyRoot(), Mode.legacy) : (standardRoot(), Mode.standard)
        chosen = picked
        return picked
    }

    // MARK: 정하기(순수 함수)

    public struct Facts: Equatable {
        /// 새 위치(AgentDeck/term)의 데몬이 살아 있음
        public var standardDaemon = false
        /// 예전 위치(ClaudeSessions/term)의 데몬이 살아 있음
        public var legacyDaemon = false
        /// 새 폴더에 무엇이든 있음
        public var standardHasData = false
        /// 예전 폴더에 표식 말고 무엇이든 있음
        public var legacyHasData = false
        /// 예전 폴더에 표식(MIGRATED_TO)이 있음
        public var legacyMigrated = false

        public init(standardDaemon: Bool = false, legacyDaemon: Bool = false, standardHasData: Bool = false,
                    legacyHasData: Bool = false, legacyMigrated: Bool = false) {
            self.standardDaemon = standardDaemon
            self.legacyDaemon = legacyDaemon
            self.standardHasData = standardHasData
            self.legacyHasData = legacyHasData
            self.legacyMigrated = legacyMigrated
        }
    }

    public enum Plan: Equatable {
        /// 새 위치를 쓴다
        case standard
        /// 예전 데몬에 붙어 예전 폴더를 쓴다
        case legacy
        /// 예전 폴더를 새 폴더로 옮긴 뒤 새 위치를 쓴다
        case migrate
    }

    /// 앱이 켤 때(그리고 예전 데몬이 끝났을 때): 새 데몬 → 예전 데몬 → 안 옮긴 예전 데이터 순.
    /// 둘 다 살아 있으면 새 것(예전 것은 건드리지 않는다). 표식이 있으면 다시 옮기지 않는다.
    public static func appPlan(_ facts: Facts) -> Plan {
        if facts.standardDaemon { return .standard }
        if facts.legacyDaemon { return .legacy }
        if facts.legacyHasData && !facts.legacyMigrated { return .migrate }
        return .standard
    }

    /// hook·데몬·ctl: 앱이 지금 읽는 곳(또는 곧 옮겨 갈 곳)에 적는다. 안 옮긴 예전 데이터가 있으면 예전 폴더에
    /// (앱이 켤 때 함께 옮겨진다 — 새 폴더에 따로 쓰면 옮기기와 엇갈린다).
    public static func helperUsesLegacy(_ facts: Facts) -> Bool {
        appPlan(facts) != .standard
    }

    // MARK: 살펴보기

    public static func probe(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Facts {
        let standard = standardRoot(env), legacy = legacyRoot(env)
        return Facts(standardDaemon: daemonAlive(termDir: termDir(of: standard)),
                     legacyDaemon: daemonAlive(termDir: termDir(of: legacy)),
                     standardHasData: hasData(standard),
                     legacyHasData: hasData(legacy),
                     legacyMigrated: FileManager.default.fileExists(atPath: legacy.appendingPathComponent(markerName).path))
    }

    /// 폴더가 있고 표식·.DS_Store 말고 무엇이든 있으면 true
    public static func hasData(_ dir: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { $0 != markerName && $0 != ".DS_Store" }
    }

    /// 그 폴더의 데몬이 살아 있는지: daemon.pid 의 프로세스가 이 앱의 데몬 실행 파일(예전 이름 포함)이거나 소켓에 붙을 수 있으면 true.
    /// PID 재사용(재부팅 뒤)·남은 소켓 파일에는 속지 않고, 잠깐 소켓이 안 받아도 살아 있는 데몬의 폴더를 옮기지 않게 둘 중 하나로 본다.
    public static func daemonAlive(termDir: URL) -> Bool {
        if let pid = daemonPid(termDir: termDir), kill(pid, 0) == 0, isDaemonExecutable(pid) { return true }
        guard let fd = UnixSocket.connect(in: termDir) else { return false }
        Darwin.close(fd)
        return true
    }

    public static func daemonPid(termDir: URL) -> pid_t? {
        guard let text = try? String(contentsOf: termDir.appendingPathComponent("daemon.pid"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }
        return pid
    }

    // MARK: 앱

    /// 앱이 켤 때 한 번: 위치를 정하고, 데몬이 하나도 없으면 예전 폴더를 옮긴다. 환경 변수로 정했으면 그대로.
    @discardableResult
    public static func prepareForApp(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Plan {
        if explicitRoot(env) != nil { return .standard }
        let facts = probe(env)
        let plan = appPlan(facts)
        switch plan {
        case .standard:
            use(root: standardRoot(env), mode: .standard)
            if facts.legacyDaemon { log("예전 위치에도 데몬이 떠 있지만 새 위치 데몬을 쓴다") }
        case .legacy:
            use(root: legacyRoot(env), mode: .legacy)
            log("예전 위치의 데몬에 붙는다(옮기기는 그 데몬이 끝난 뒤): \(legacyRoot(env).path)")
        case .migrate:
            migrateNow(env)
        }
        return plan
    }

    /// 마지막 옮기기 실패(앱이 상태 줄에 보인다). 성공하면 nil.
    public private(set) static var migrationError: String?

    /// 예전 폴더를 새 폴더로 옮기고 새 위치를 쓴다. 데몬이 없을 때만 부른다. 옮겼으면 true.
    /// 옮기지 못하면 예전 폴더를 데이터 위치로 삼아 이 앱의 데몬을 거기서 띄운다(hook 도 그 데몬을 보고 예전 폴더에 적는다).
    /// 다음에 켤 때 그 데몬이 끝나 있으면 다시 시도한다.
    @discardableResult
    public static func migrateNow(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let standard = standardRoot(env), legacy = legacyRoot(env)
        do {
            let result = try migrate(from: legacy, to: standard)
            use(root: standard, mode: .standard)
            migrationError = nil
            log("예전 데이터를 옮김: \(legacy.path) → \(standard.path) (\(result.summary))")
            return true
        } catch {
            use(root: legacy, mode: .standard)
            migrationError = error.localizedDescription
            log("예전 데이터를 옮기지 못해 예전 위치를 그대로 쓴다: \(error)")
            return false
        }
    }

    // MARK: 옮기기

    public struct Migration: Equatable {
        /// 폴더째 이름을 바꿨다(새 폴더가 없을 때)
        public var renamed = false
        /// 하나씩 옮긴 항목(새 폴더가 이미 있을 때, 예전 폴더 기준 상대 경로)
        public var moved: [String] = []
        /// 새 폴더에 같은 이름이 있어 예전 폴더에 남겨 둔 항목
        public var kept: [String] = []

        public init() {}

        public var summary: String {
            if renamed { return "폴더째 옮김" }
            return "\(moved.count)개 옮김" + (kept.isEmpty ? "" : ", 겹쳐서 남김 \(kept.count)개: \(kept.prefix(5).joined(separator: ", "))")
        }
    }

    /// 예전 폴더 내용을 새 폴더로 옮긴다(같은 볼륨이라 이름 바꾸기). 지우는 것은 없다:
    /// 새 폴더가 없으면 폴더째, 있으면 없는 항목만 옮기고(폴더는 안으로 들어가 합침) 겹치는 파일은 예전 폴더에 남긴다.
    /// 끝나면 예전 폴더에 표식(MIGRATED_TO, 새 위치)을 남긴다. 여러 번 불러도 된다.
    public static func migrate(from legacy: URL, to standard: URL, now: Date = Date()) throws -> Migration {
        let fm = FileManager.default
        var result = Migration()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue else { return result }
        try fm.createDirectory(at: standard.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: standard.path) {
            try fm.moveItem(at: legacy, to: standard)
            result.renamed = true
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        } else {
            merge(legacy, into: standard, relative: "", result: &result)
        }
        let marker = "\(standard.path)\n\(ISO8601DateFormatter().string(from: now))\n"
        try Data(marker.utf8).write(to: legacy.appendingPathComponent(markerName), options: .atomic)
        return result
    }

    private static func merge(_ source: URL, into dest: URL, relative: String, result: inout Migration) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).sorted()
        for name in names where !(relative.isEmpty && name == markerName) && name != ".DS_Store" {
            let from = source.appendingPathComponent(name), to = dest.appendingPathComponent(name)
            let path = relative.isEmpty ? name : relative + "/" + name
            var fromDir: ObjCBool = false, toDir: ObjCBool = false
            fm.fileExists(atPath: from.path, isDirectory: &fromDir)
            if !fm.fileExists(atPath: to.path, isDirectory: &toDir) {
                do {
                    try fm.moveItem(at: from, to: to)
                    result.moved.append(path)
                } catch {
                    result.kept.append(path)
                }
            } else if fromDir.boolValue && toDir.boolValue {
                merge(from, into: to, relative: path, result: &result)
            } else {
                result.kept.append(path)
            }
        }
    }

    // MARK: 예전 데몬 끄기

    /// 데몬을 끈다: 소켓으로 화면마다 끝내기(셸·claude 에 끊김 신호, 3초 뒤 강제)를 보내 화면이 다 끝나길 기다린 뒤,
    /// daemon.pid 가 이 앱의 데몬 실행 파일(예전 이름 포함)일 때만 SIGTERM(안 끝나면 SIGKILL). 끝났으면 true.
    @discardableResult
    public static func stopDaemon(termDir: URL, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        if let fd = UnixSocket.connect(in: termDir) {
            killAllPanes(fd: fd, until: deadline)
        }
        guard let pid = daemonPid(termDir: termDir) else { return !daemonAlive(termDir: termDir) }
        guard kill(pid, 0) == 0 else { return true }
        guard isDaemonExecutable(pid) else {
            log("daemon.pid(\(pid))가 이 앱의 데몬이 아니라 끄지 않음")
            return false
        }
        kill(pid, SIGTERM)
        let hard = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < hard { usleep(50_000) }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            usleep(200_000)
        }
        return kill(pid, 0) != 0
    }

    public static let daemonExecutableNames = ["AgentDeckDaemon", "ClaudeTermDaemon"]

    static func isDaemonExecutable(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return daemonExecutableNames.contains((String(cString: buffer) as NSString).lastPathComponent)
    }

    /// 짧은 동기 클라이언트: 목록을 받아 화면마다 kill 을 보내고, 목록이 빌 때까지(또는 deadline) 기다린다
    private static func killAllPanes(fd: Int32, until deadline: Date) {
        let queue = DispatchQueue(label: "agentdeck.stop-daemon")
        let connection = Connection(fd: fd, queue: queue)
        let empty = DispatchSemaphore(value: 0)
        var asked = Set<String>()
        queue.sync {
            connection.onClose = { empty.signal() }
            connection.onFrame = { frame in
                guard frame.type == .state, let state = frame.json(DaemonState.self) else { return }
                if state.panes.isEmpty { empty.signal(); return }
                for pane in state.panes where !asked.contains(pane.id) {
                    asked.insert(pane.id)
                    connection.send(Frame(.kill, Array(pane.id.utf8)))
                }
            }
            connection.start()
            connection.send(Frame(.list))
        }
        // 화면이 끝날 때마다 데몬이 목록을 다시 보내지만, 놓치지 않게 가끔 다시 묻는다
        while empty.wait(timeout: .now() + 0.5) == .timedOut, Date() < deadline {
            queue.sync { connection.send(Frame(.list)) }
        }
        queue.sync { connection.close() }
    }

    // MARK: 기록

    /// 지금 term 폴더의 daemon.log 에 한 줄(데몬 기록과 같은 형식)
    public static func log(_ message: String, in dir: URL? = nil) {
        let dir = dir ?? termDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("daemon.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
