import Darwin
import Foundation

/// 앱 ↔ 데몬 메시지. 한 메시지 = [길이 u32(빅엔디언, 종류+본문)][종류 u8][본문].
/// 화면 데이터(입력·출력)는 본문이 [화면 ID 길이 u8][화면 ID][바이트], 나머지는 JSON.
public enum WireType: UInt8 {
    /// 앱 → 데몬: 화면 목록 요청(본문 없음)
    case list = 1
    /// 데몬 → 앱: DaemonState(JSON)
    case state = 2
    /// 앱 → 데몬: CreateRequest(JSON)
    case create = 3
    /// 앱 → 데몬: 화면 보기 시작(본문 = 화면 ID). 데몬은 replay 를 보낸 뒤 output 을 계속 보낸다.
    case attach = 4
    /// 데몬 → 앱: 붙기 전까지 쌓인 출력
    case replay = 5
    /// 데몬 → 앱: 새 출력
    case output = 6
    /// 앱 → 데몬: 키 입력
    case input = 7
    /// 앱 → 데몬: ResizeRequest(JSON)
    case resize = 8
    /// 앱 → 데몬: 화면 보기 그만(본문 = 화면 ID)
    case detach = 9
    /// 앱 → 데몬: 화면 닫기(셸·claude 종료, 본문 = 화면 ID)
    case kill = 10
    /// 데몬 → 앱: 화면의 셸이 끝남(본문 = 화면 ID)
    case exited = 11
    /// 데몬 → 앱: 요청 실패(본문 = UTF-8 설명)
    case error = 12
}

public struct Frame: Equatable {
    public var type: WireType
    public var body: [UInt8]

    public init(_ type: WireType, _ body: [UInt8] = []) {
        self.type = type
        self.body = body
    }

    public init<T: Encodable>(_ type: WireType, json value: T) {
        self.init(type, Array((try? JSONEncoder().encode(value)) ?? Data()))
    }

    public init(_ type: WireType, pane id: String, bytes: some Collection<UInt8> = [UInt8]()) {
        let idBytes = Array(id.utf8.prefix(255))
        var body = [UInt8(idBytes.count)]
        body.reserveCapacity(1 + idBytes.count + bytes.count)
        body.append(contentsOf: idBytes)
        body.append(contentsOf: bytes)
        self.init(type, body)
    }

    public func json<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(body))
    }

    /// 화면 데이터 본문을 (화면 ID, 바이트)로 나눈다
    public var paneData: (id: String, bytes: ArraySlice<UInt8>)? {
        guard let count = body.first.map(Int.init), body.count >= 1 + count,
              let id = String(bytes: body[1..<(1 + count)], encoding: .utf8)
        else { return nil }
        return (id, body[(1 + count)...])
    }

    public var text: String { String(decoding: body, as: UTF8.self) }

    public func encoded() -> [UInt8] {
        let length = UInt32(body.count + 1)
        var out: [UInt8] = [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff),
                            UInt8(length & 0xff), type.rawValue]
        out.reserveCapacity(5 + body.count)
        out.append(contentsOf: body)
        return out
    }
}

public enum WireError: Error {
    case tooLarge(Int)
    case unknownType(UInt8)
}

/// 소켓에서 받은 바이트를 메시지로 자른다
public struct FrameDecoder {
    public static let maxFrame = 16 << 20

    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    public mutating func append(_ bytes: some Collection<UInt8>) {
        buffer.append(contentsOf: bytes)
    }

    public mutating func next() throws -> Frame? {
        guard buffer.count - start >= 4 else { compact(); return nil }
        let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8
            | Int(buffer[start + 3])
        guard length >= 1, length <= Self.maxFrame else { throw WireError.tooLarge(length) }
        guard buffer.count - start >= 4 + length else { compact(); return nil }
        let raw = buffer[start + 4]
        let body = Array(buffer[(start + 5)..<(start + 4 + length)])
        start += 4 + length
        guard let type = WireType(rawValue: raw) else { throw WireError.unknownType(raw) }
        return Frame(type, body)
    }

    private mutating func compact() {
        if start > 0 {
            buffer.removeFirst(start)
            start = 0
        }
    }
}

public struct CreateRequest: Codable, Equatable {
    public var id: String
    public var cwd: String
    public var cols: Int
    public var rows: Int
    /// 셸이 뜬 뒤 입력할 명령(끝에 줄바꿈 포함). 없으면 셸만 연다.
    public var input: String?
    public var title: String?

    public init(id: String, cwd: String, cols: Int, rows: Int, input: String? = nil, title: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.input = input
        self.title = title
    }
}

public struct ResizeRequest: Codable, Equatable {
    public var id: String
    public var cols: Int
    public var rows: Int

    public init(id: String, cols: Int, rows: Int) {
        self.id = id
        self.cols = cols
        self.rows = rows
    }
}

public struct PaneInfo: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var cwd: String
    /// 화면의 셸
    public var pid: Int32
    /// 이 화면의 터미널 장치(예: ttys012). Claude Code hook 기록의 tty 와 같으면 그 세션이 이 화면에서 돈다.
    public var tty: String?
    /// 지금 앞에서 돌고 있는 프로그램(zsh, claude 등)
    public var foreground: String?
    public var cols: Int
    public var rows: Int
    /// 데몬이 보관 중인 지난 출력 크기
    public var bufferedBytes: Int
    public var createdAt: Date

    public init(id: String, title: String, cwd: String, pid: Int32, tty: String?, foreground: String?,
                cols: Int, rows: Int, bufferedBytes: Int, createdAt: Date) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.pid = pid
        self.tty = tty
        self.foreground = foreground
        self.cols = cols
        self.rows = rows
        self.bufferedBytes = bufferedBytes
        self.createdAt = createdAt
    }
}

public struct DaemonState: Codable, Equatable {
    public var pid: Int32
    /// 데몬 자신의 메모리(phys_footprint, 바이트)
    public var footprint: UInt64
    public var panes: [PaneInfo]
    /// 데몬이 뜰 때마다 새로 정하는 ID. PID 는 재부팅 뒤 다시 쓰일 수 있어 데몬이 바뀌었는지는 이것으로 본다(예전 데몬은 nil).
    public var instance: String?

    public init(pid: Int32, footprint: UInt64, panes: [PaneInfo], instance: String? = nil) {
        self.pid = pid
        self.footprint = footprint
        self.panes = panes
        self.instance = instance
    }
}

public enum TermPaths {
    /// 데몬 소켓·로그 위치. 개발·시험용으로 CLAUDE_TERM_HOME 으로 바꿀 수 있다.
    public static var home: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CLAUDE_TERM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let sessions = env["CLAUDE_SESSIONS_HOME"], !sessions.isEmpty {
            return URL(fileURLWithPath: sessions, isDirectory: true).appendingPathComponent("term", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeSessions/term", isDirectory: true)
    }

    public static let socketName = "daemon.sock"
}

public enum Memory {
    /// 활동 상태 보기의 "메모리"와 같은 값(phys_footprint). 모르면 0.
    public static func footprint(of pid: pid_t = getpid()) -> UInt64 {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    public static func format(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

/// 유닉스 소켓. sockaddr_un 경로는 104바이트까지라, 넘으면(긴 시험용 폴더) 그 폴더로 이동해 상대 경로로 연다.
/// 보통 위치(~/Library/Application Support/ClaudeSessions/term)는 짧아서 절대 경로를 쓴다.
public enum UnixSocket {
    private static func address(for path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func address(in dir: URL, name: String) -> sockaddr_un? {
        if let addr = address(for: dir.appendingPathComponent(name).path) { return addr }
        guard chdir(dir.path) == 0 else { return nil }
        return address(for: name)
    }

    /// 데몬 쪽: 소켓을 만들고 listen 한다. 남아 있던 소켓 파일은 지운다(호출 전에 단일 실행 잠금을 잡아야 한다).
    public static func listen(in dir: URL, name: String = TermPaths.socketName) throws -> Int32 {
        let path = dir.appendingPathComponent(name).path
        unlink(path)
        guard var addr = address(in: dir, name: name) else { throw POSIXError(.ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// 앱 쪽: 데몬에 연결한다. 데몬이 없으면 nil.
    public static func connect(in dir: URL, name: String = TermPaths.socketName) -> Int32? {
        guard var addr = address(in: dir, name: name) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}
