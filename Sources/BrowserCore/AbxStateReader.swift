import Darwin
import Foundation

/// abx 세션의 상태를 abx 를 띄우지 않고 파일로 읽는다(`abx status --json` 과 같은 규칙 — abx `runtime.ts` 의 `status()`).
/// 화면이 여럿이어도 세션마다 프로세스를 띄우지 않으려는 것이다. abx 의 파일 형식이 바뀌면 같이 고친다
/// (시험: 같은 폴더를 `abx status --json` 결과와 비교).
/// - 실행 중: 엔진 소켓(`<socketDir>/<세션>.sock`)이 연결을 받아야 한다(남은 소켓 파일은 아님)
/// - CDP 주소: 실행 옵션(`<세션>.launch.json`)의 프로필 폴더에 Chrome 이 쓰는 `DevToolsActivePort`
/// - 제어: handoff 파일 → 사용자(진행 중인 writer 가 살아 있으면 넘기는 중), 잠금 소켓 + 살아 있는 잠금 pid → 에이전트, 아니면 쉼
/// - 탭: abx 가 탭 목록을 볼 때마다 쓰는 `<stateDir>/<세션>.tabs.json`
public struct AbxStateReader {
    public init() {}

    public func status(_ session: AbxSession) -> AbxStatus {
        let socketDir = URL(fileURLWithPath: session.socketDir)
        let stateDir = URL(fileURLWithPath: session.stateDir)
        let name = session.name
        let launch = (try? Data(contentsOf: socketDir.appendingPathComponent("\(name).launch.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let running = Self.accepts(socketDir.appendingPathComponent("\(name).sock").path)
        var cdpUrl: String?
        if running, let profile = launch?["profileDir"] as? String,
           let port = try? String(contentsOfFile: (profile as NSString).appendingPathComponent("DevToolsActivePort"), encoding: .utf8) {
            let lines = port.split(separator: "\n").map(String.init)
            if lines.count >= 2, !lines[0].isEmpty { cdpUrl = "ws://127.0.0.1:\(lines[0])\(lines[1])" }
        }
        let handoff = try? String(contentsOfFile: stateDir.appendingPathComponent("\(name).handoff").path, encoding: .utf8)
        let control: AbxStatus.Control
        if handoff != nil {
            control = Self.writerBusy(stateDir.appendingPathComponent("\(name).writer").path) ? .switching : .user
        } else if FileManager.default.fileExists(atPath: socketDir.appendingPathComponent("\(name).lock.sock").path),
                  let pid = (try? String(contentsOfFile: socketDir.appendingPathComponent("\(name).lock.pid").path, encoding: .utf8))
                    .flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), Self.alive(pid) {
            control = .agent
        } else {
            control = .idle
        }
        let tabs = (try? Data(contentsOf: stateDir.appendingPathComponent("\(name).tabs.json")))
            .flatMap { try? JSONDecoder().decode([AbxStatus.Tab].self, from: $0) } ?? []
        return AbxStatus(session: name, running: running, headless: (launch?["headed"] as? Bool).map { !$0 },
                         cdpUrl: cdpUrl, control: control, handoff: handoff, tabs: tabs)
    }

    /// 살아 있는 프로세스인가(EPERM = 남의 프로세스지만 살아 있음)
    static func alive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func writerBusy(_ path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let lease = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (lease["pid"] as? NSNumber)?.int32Value else { return false }
        return alive(pid)
    }

    /// 유닉스 소켓이 연결을 받는가(서버가 죽고 남은 소켓 파일이면 false). 막히지 않게 짧게.
    static func accepts(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        // 로컬 소켓의 connect 는 바로 끝난다(받는 쪽이 없으면 ECONNREFUSED)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}

/// abx 의 writer 자리(`<stateDir>/<세션>.writer`, abx `runtime.ts` 의 withWriter 와 같은 규칙): 한 번에 한 쪽만 브라우저를 바꾼다.
/// 임시 파일을 만들어 link() 로 놓으므로 반쯤 쓴 파일이 보이지 않고, 주인이 죽었거나 오래된(120초) 자리는 되찾는다.
/// 앱은 페이지 크기를 바꾸는 짧은 동안만 잡는다(그동안 에이전트 동작은 기다린다).
public final class AbxWriterLease {
    private let path: String
    private let token: String

    private init(path: String, token: String) {
        self.path = path
        self.token = token
    }

    /// 잡으면 돌려준다. 다른 쪽(에이전트 동작)이 잡고 있으면 `wait` 동안 기다리다 nil.
    public static func acquire(stateDir: String, session: String, wait: TimeInterval = 1.5) -> AbxWriterLease? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let path = (stateDir as NSString).appendingPathComponent(session + ".writer")
        let token = UUID().uuidString.lowercased()
        let tmp = path + "." + token
        let body = #"{"pid":\#(getpid()),"token":"\#(token)"}"#
        guard fm.createFile(atPath: tmp, contents: Data(body.utf8)) else { return nil }
        defer { unlink(tmp) }
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if link(tmp, path) == 0 { return AbxWriterLease(path: path, token: token) }
            guard errno == EEXIST else { return nil }
            if let owner = owner(path) {
                let age = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date).map { Date().timeIntervalSince($0) } ?? 0
                if !AbxStateReader.alive(owner.pid) || age > 120 {
                    releaseIfOwner(path, token: owner.token) // 판단한 그 자리만 되찾는다
                    continue
                }
            }
            if Date() >= deadline { return nil }
            usleep(50_000)
        }
    }

    public func release() { Self.releaseIfOwner(path, token: token) }

    private static func owner(_ path: String) -> (pid: Int32, token: String)? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (json["pid"] as? NSNumber)?.int32Value, let token = json["token"] as? String else { return nil }
        return (pid, token)
    }

    private static func releaseIfOwner(_ path: String, token: String) {
        if owner(path)?.token == token { unlink(path) }
    }
}
