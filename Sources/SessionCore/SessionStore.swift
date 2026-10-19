import Darwin
import Foundation

/// hook 이 남기는 세션 기록 한 건. 파일 하나 = 세션 하나.
public struct SessionRecord: Codable, Equatable, Identifiable {
    public var sessionId: String
    public var cwd: String
    public var transcriptPath: String?
    /// 세션을 돌리던 claude 프로세스. PID 재사용을 걸러내려고 시작 시각도 같이 둔다.
    public var pid: Int32
    public var pidStartedAt: Double
    public var startedAt: Date
    /// 마지막 SessionStart(새로 시작·이어 열기) 시각. 한 프로세스에 기록이 겹칠 때 최신 세션을 고르는 데 쓴다.
    public var activeSince: Date?
    /// 창 닫기·앱 종료처럼 사용자가 명시적으로 끝내지 않은 SessionEnd 시각. 재부팅이면 비어 있을 수 있다.
    public var endedAt: Date?
    public var endReason: String?
    /// 세션을 띄운 터미널(TERM_PROGRAM). 예: ghostty, iTerm.app
    public var termProgram: String?
    /// claude 의 제어 터미널(예: /dev/ttys015)
    public var tty: String?
    /// AgentDeck 화면 ID(셸 환경 AGENTDECK_PANE, 예전 데몬의 셸은 CLAUDE_SESSIONS_PANE). 있으면 화면과 정확히 짝짓는다.
    public var pane: String?
    /// 작업 상태(hook 이 적는다): working | waiting | done | idle | error
    public var state: String?
    public var stateAt: Date?
    /// 상태에 딸린 글(입력 대기 이유, 오류 종류)
    public var stateMessage: String?
    /// 상태를 적을 때마다 1씩 오르는 번호. 날짜는 초 단위로만 저장되므로(예전 빌드와 같은 형식)
    /// 같은 초 안의 상태 변화(입력 대기 → 완료)는 이 번호로 구분한다. 예전 기록에는 없다.
    public var stateSeq: Int?

    public var id: String { sessionId }

    public init(sessionId: String, cwd: String, transcriptPath: String?, pid: Int32, pidStartedAt: Double,
                startedAt: Date, endedAt: Date? = nil, endReason: String? = nil, termProgram: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.pid = pid
        self.pidStartedAt = pidStartedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.termProgram = termProgram
    }

    /// 같은 claude 프로세스인가(PID + 시작 시각).
    public func isSameProcess(as other: SessionRecord) -> Bool {
        pid == other.pid && abs(pidStartedAt - other.pidStartedAt) < 1
    }

    /// 지금도 그 claude 프로세스에서 열려 있는가.
    public var isRunning: Bool {
        endedAt == nil && ProcessUtil.isAlive(pid: pid, startedAt: pidStartedAt)
    }
}

public struct SessionStore {
    public let dir: URL

    public init(dir: URL = Paths.sessionsDir) {
        self.dir = dir
    }

    /// 세션 ID 는 UUID 형식만 받는다(파일 경로로 쓰므로).
    public static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private func url(for id: String) -> URL? {
        Self.isValidId(id) ? dir.appendingPathComponent("\(id).json") : nil
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func save(_ record: SessionRecord) throws {
        guard let url = url(for: record.sessionId) else { throw StoreError.invalidId(record.sessionId) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: url, options: .atomic)
    }

    public func load(_ id: String) -> SessionRecord? {
        guard let url = url(for: id), let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SessionRecord.self, from: data)
    }

    public func all() -> [SessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // 잠금 파일(.lock)·쓰는 중인 임시 파일은 확장자로 걸러진다
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
    }

    /// 한 claude 프로세스에는 열린 세션이 하나뿐이다. 프로세스 안에서 /resume 으로 세션을 바꾸면
    /// 빈 세션은 SessionEnd 없이 버려지므로, 같은 프로세스의 "열림" 기록은 가장 최근 것만 남긴다.
    @discardableResult
    public func removeSupersededSessions() -> [String] {
        withLock { removeSupersededSessionsLocked() }
    }

    private func removeSupersededSessionsLocked() -> [String] {
        let open = all().filter { $0.endedAt == nil }
        var removed: [String] = []
        var groups: [[SessionRecord]] = []
        for record in open {
            if let index = groups.firstIndex(where: { $0[0].isSameProcess(as: record) }) {
                groups[index].append(record)
            } else {
                groups.append([record])
            }
        }
        for group in groups where group.count > 1 {
            let latest = group.max { lastActive($0) < lastActive($1) }!
            for record in group where record.sessionId != latest.sessionId {
                remove(record.sessionId)
                removed.append(record.sessionId)
            }
        }
        return removed
    }

    /// 파일 수정 시각은 쓰지 않는다(연결·가져오기 때 다시 저장되면 오래된 기록이 최신처럼 보인다).
    private func lastActive(_ record: SessionRecord) -> Date {
        record.activeSince ?? record.startedAt
    }

    public func remove(_ id: String) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 앱·CLI·여러 hook 이 기록을 동시에 읽고 고칠 때 서로 덮어쓰지 않도록 프로세스 사이 잠금을 건다.
    /// 같은 스레드에서 다시 불러도 된다(안쪽 호출은 잠금을 다시 잡지 않는다).
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        let key = "AgentDeck.storeLock." + dir.path
        let thread = Thread.current.threadDictionary
        let depth = thread[key] as? Int ?? 0
        if depth > 0 {
            thread[key] = depth + 1
            defer { thread[key] = depth }
            return try body()
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        thread[key] = 1
        defer {
            thread[key] = nil
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return try body()
    }

    /// 최신 기록을 다시 읽어 고친 뒤 저장한다(잠금 안에서). 기록이 없으면 아무것도 안 한다.
    @discardableResult
    public func update(_ id: String, _ change: (inout SessionRecord) -> Void) -> SessionRecord? {
        withLock {
            guard var record = load(id) else { return nil }
            change(&record)
            try? save(record)
            return record
        }
    }

    public enum StoreError: Error {
        case invalidId(String)
    }
}
