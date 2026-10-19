import Darwin
import Foundation

/// 데몬을 launchd 작업(사용자 GUI 도메인 `gui/<uid>`)으로 띄운다.
///
/// 왜: 앱이 posix_spawn(+setsid)으로 띄우면 데몬과 그 셸·claude 가 앱의 **coalition** 에 남는다. 앱이 끝나면 loginwindow 가
/// 그 coalition 을 "남은 앱"으로 붙잡고 Background Task Management 에 묻는데, 허락되지 않은 앱(새 묶음 ID·새 경로·작업 트리 빌드 등)이면
/// `_LSForceQuitApplication … killing coalition pid` 로 데몬과 모든 화면을 SIGKILL 한다(Dock 의 남은 아이콘을 "강제 종료"해도 같다).
/// launchd 작업은 자기 coalition 을 가지므로 앱이 어떻게 끝나든 데몬은 남는다.
///
/// 방법: 데이터 위치의 term 폴더에 plist 를 쓰고 `launchctl bootstrap gui/<uid> <plist>`.
/// 데몬은 끝날 때 자기 작업을 내린다(`spawnBootout` — 올라간 채 남은 작업은 LaunchServices 가 올린 앱의 `loadedJobs` 로 묶어
/// 앱을 Dock 에 "남은 앱"으로 붙잡는다). 강제로 끝나 올라간 채 남은 작업은 다음에 내리고(bootout) 새 plist 로 다시 올린다.
/// **돌고 있는 작업은 절대 내리지 않는다**(내리면 launchd 가 데몬에 SIGTERM → 모든 화면이 끝난다).
/// launchd 로 띄운 데몬은 앱의 환경을 이어받지 않으므로 앱 환경을 plist 의 EnvironmentVariables 로 넘기고,
/// 올린 뒤에는 plist 에서 환경을 지운다(launchd 는 올릴 때 읽은 내용을 쓰고, 토큰 같은 값이 파일에 남지 않게).
public enum DaemonLaunchAgent {
    public static let labelPrefix = "dev.agentdeck.daemon."
    public static let plistName = "dev.agentdeck.daemon.plist"
    static let launchctlPath = "/bin/launchctl"

    // MARK: 순수 함수

    /// 데몬 하나 = term 폴더 하나(소켓·잠금)라서 그 경로로 이름을 정한다. 같은 경로면 늘 같은 이름(FNV-1a 64비트의 앞 12자리).
    /// 경로는 글자로만 다듬는다(빈 칸·`.` 빼기). `standardizedFileURL` 은 폴더가 있을 때만 `/private` 를 떼어
    /// 폴더를 만들기 전후로 이름이 바뀌므로 쓰지 않는다(시험에서 실제로 겪음).
    public static func label(termDir: URL) -> String {
        label(forPath: termDir.path)
    }

    public static func label(forPath path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        let normalized = (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
        let hex = String(fnv1a64(normalized), radix: 16)
        let padded = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        return labelPrefix + padded.prefix(12)
    }

    static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// 앱 환경 중 데몬(→ 화면 셸)에 넘기지 않는 것: launchd 가 작업마다 새로 정하는 값, 앱 자신의 표시,
    /// 셸이 프로세스마다 정하는 값, 앱을 띄운 화면·claude 세션의 표시(데몬이 화면마다 새로 넣거나 지운다).
    /// 나머지(PATH·LANG/LC_*·SHELL·HOME·USER·LOGNAME·TMPDIR·SSH_AUTH_SOCK·AGENTDECK_* 시험 변수 등)는 그대로 — 예전처럼 앱 환경을 다 이어받는 것과 같게.
    public static let droppedKeys: Set<String> = [
        "XPC_SERVICE_NAME", "XPC_FLAGS", "__CFBundleIdentifier",
        "_", "PWD", "OLDPWD",
        "AGENTDECK_PANE", "CLAUDE_SESSIONS_PANE", "CODEX_THREAD_ID",
    ]

    public static func environmentSnapshot(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        env.filter { key, value in
            !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
                && !droppedKeys.contains(key) && !isClaudeSessionMarker(key)
        }
    }

    /// SessionCore.InheritedEnvironment 와 같은 규칙(TermWire 는 SessionCore 에 기대지 않는다)
    static func isClaudeSessionMarker(_ key: String) -> Bool {
        key == "CLAUDECODE" || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT" || key.hasPrefix("CLAUDE_CODE_")
    }

    /// launchd 작업 정의. environment 가 nil 이면 EnvironmentVariables 를 넣지 않는다(올린 뒤 남겨 두는 파일).
    public static func plist(label: String, program: String, root: String, logPath: String,
                             environment: [String: String]?) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [program, "--root", root],
            "RunAtLoad": true,
            "KeepAlive": false,
            // 데몬이 끝나도 화면 셸(각자 setsid)과 그 아래 프로세스를 launchd 가 거두지 않게
            "AbandonProcessGroup": true,
            "ProcessType": "Interactive",
            "StandardInPath": "/dev/null",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        if let environment { plist["EnvironmentVariables"] = environment }
        return plist
    }

    public static func plistData(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    public struct ServiceStatus: Equatable {
        public var loaded = false
        public var running = false
        public var pid: pid_t?

        public init(loaded: Bool = false, running: Bool = false, pid: pid_t? = nil) {
            self.loaded = loaded
            self.running = running
            self.pid = pid
        }
    }

    /// `launchctl print gui/<uid>/<label>` 결과 읽기. 실패(올라가 있지 않음)면 loaded=false.
    /// 맨 위 단계(탭 하나)의 `state = running`·`pid = N` 만 본다(안쪽 블록에도 state 가 있다).
    public static func parsePrint(_ output: String, exitStatus: Int32) -> ServiceStatus {
        guard exitStatus == 0 else { return ServiceStatus() }
        var status = ServiceStatus(loaded: true)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let text = line.dropFirst()
            if text.hasPrefix("state = ") {
                status.running = text.dropFirst("state = ".count) == "running"
            } else if text.hasPrefix("pid = "), let pid = Int32(text.dropFirst("pid = ".count)), pid > 0 {
                status.pid = pid
            }
        }
        if status.pid != nil { status.running = true }
        return status
    }

    // MARK: 띄우기

    public enum Outcome: Equatable {
        /// 새로 올렸다(RunAtLoad 로 바로 뜬다)
        case bootstrapped(label: String)
        /// 이미 올라가 있어 다시 시작만 했다(plist 를 다시 읽지 않는다 — 이전에 올린 경로·환경)
        case kickstarted(label: String)
        /// 이미 돌고 있다(건드리지 않았다)
        case alreadyRunning(label: String, pid: pid_t?)
        case failed(String)
    }

    public static var domain: String { "gui/\(getuid())" }

    public static func service(_ label: String) -> String { "\(domain)/\(label)" }

    public static func status(label: String) -> ServiceStatus {
        let result = launchctl(["print", service(label)])
        return parsePrint(result.output, exitStatus: result.status)
    }

    /// status 와 같지만 launchctl 을 실행하지 못했거나 시간 안에 답하지 않았으면 nil(모름 — "올라가 있지 않음"과 다르다)
    public static func statusIfKnown(label: String) -> ServiceStatus? {
        let result = launchctl(["print", service(label)])
        return result.status < 0 ? nil : parsePrint(result.output, exitStatus: result.status)
    }

    /// 데몬을 launchd 작업으로 띄운다. 실패하면 .failed(앱이 예전 방식으로 띄운다).
    public static func launch(program: String, root: URL, termDir: URL,
                              environment: [String: String] = environmentSnapshot()) -> Outcome {
        let label = label(termDir: termDir)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: termDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failed("term 폴더를 만들지 못함: \(error)")
        }
        let plistURL = termDir.appendingPathComponent(plistName)
        let logPath = termDir.appendingPathComponent("daemon-stderr.log").path

        let before = status(label: label)
        if before.running { return .alreadyRunning(label: label, pid: before.pid) }

        let full = plist(label: label, program: program, root: root.path, logPath: logPath, environment: environment)
        let bare = plist(label: label, program: program, root: root.path, logPath: logPath, environment: nil)
        do {
            try writePrivate(plistData(full), to: plistURL)
        } catch {
            return .failed("plist 를 쓰지 못함: \(error)")
        }
        // 올린 뒤(또는 실패해도) 환경은 파일에 남기지 않는다. 남는 파일은 이름·경로 기록(삭제 스크립트가 Label 을 읽는다).
        defer { try? writePrivate(plistData(bare), to: plistURL) }

        if before.loaded {
            // 데몬이 쉬다 끝나 작업만 남은 상태. 돌고 있지 않음을 위에서 확인했다.
            _ = launchctl(["bootout", service(label)])
            let deadline = Date().addingTimeInterval(2)
            while status(label: label).loaded, Date() < deadline { usleep(50_000) }
        }
        let boot = launchctl(["bootstrap", domain, plistURL.path])
        if boot.status == 0 { return .bootstrapped(label: label) }

        // 이미 올라가 있음(내리기가 늦었거나 다른 앱이 같은 위치로 먼저 올림): 돌고 있으면 그대로, 아니면 시작만
        let after = status(label: label)
        if after.running { return .alreadyRunning(label: label, pid: after.pid) }
        if after.loaded {
            let kick = launchctl(["kickstart", service(label)])
            if kick.status == 0 { return .kickstarted(label: label) }
            return .failed("bootstrap \(boot.status): \(boot.output.trimmed); kickstart \(kick.status): \(kick.output.trimmed)")
        }
        return .failed("bootstrap \(boot.status): \(boot.output.trimmed)")
    }

    /// 데몬이 끝날 때 자기 작업을 내린다. 올라간 채 남은 작업은 LaunchServices 가 그 작업을 올린 앱에 묶어(`loadedJobs`)
    /// 앱이 끝난 뒤에도 Dock 에 남은 아이콘으로 붙잡으므로, 데몬이 끝나면 작업도 내려 예전처럼 데몬과 함께 사라지게 한다.
    /// launchctl 을 새 세션으로 띄우고 그 pid 를 돌려준다(부른 쪽이 끝나길 기다린다 — 내리기가 끝나기 전에 앱이 새 데몬을 올리면
    /// 늦게 닿은 내리기가 새 데몬을 내릴 수 있다). 돌고 있는 자신을 내리면 launchd 가 SIGTERM 을 보낸다.
    public static func spawnBootout(label: String) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID))
        let words: [String] = [launchctlPath, "bootout", service(label)]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, launchctlPath, &actions, &attr, argv, environ) == 0 ? pid : nil
    }

    /// 이 프로세스가 launchd 작업으로 떴으면 그 이름(launchd 가 XPC_SERVICE_NAME 에 넣는다)
    public static func ownLabel(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        env["XPC_SERVICE_NAME"].flatMap { $0.hasPrefix(labelPrefix) ? $0 : nil }
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// launchctl 한 번에 기다리는 최대 시간. 넘으면 띄운 그 launchctl 만 SIGKILL 하고 실패로 본다.
    public static let launchctlTimeout: TimeInterval = 3

    /// /bin/launchctl 을 셸 없이 실행하고 표준 출력·오류를 합쳐 돌려준다(timeout 이 지나면 status -2).
    /// Foundation Process 의 waitUntilExit 는 메인 실행 루프를 돌려(앱 이벤트가 끼어든다) posix_spawn + waitpid 로 한다.
    static func launchctl(_ args: [String], timeout: TimeInterval = launchctlTimeout) -> (status: Int32, output: String) {
        run(launchctlPath, args, timeout: timeout)
    }

    /// 실행 파일을 셸 없이 띄워 출력을 읽는다. timeout 이 지나면 그 자식만 SIGKILL(다른 프로세스는 건드리지 않는다).
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { return (-1, "pipe 실패") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, pipe[1], 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        close(pipe[1])
        guard spawned == 0 else {
            close(pipe[0])
            return (-1, "\((path as NSString).lastPathComponent) 을 실행하지 못함: \(String(cString: strerror(spawned)))")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var output = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { timedOut = true; break }
            var poller = pollfd(fd: pipe[0], events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(left * 1000, 1000).rounded(.up)))
            if ready < 0 { if errno == EINTR { continue } else { break } }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { read(pipe[0], $0.baseAddress, $0.count) }
            if count > 0 { output.append(contentsOf: buffer[0..<count]) }
            else if count < 0, errno == EINTR { continue }
            else { break }
        }
        close(pipe[0])
        if timedOut { kill(pid, SIGKILL) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        if timedOut {
            return (-2, "\((path as NSString).lastPathComponent) \(args.first ?? "") 이 \(timeout)초 안에 끝나지 않아 멈춤")
        }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        return (code, String(decoding: output, as: UTF8.self))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
