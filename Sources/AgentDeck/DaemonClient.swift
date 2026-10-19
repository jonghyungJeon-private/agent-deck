import Darwin
import Foundation
import SessionCore
import TermWire

/// 앱 쪽 데몬 연결. 데몬이 없으면 띄운다. 모든 콜백은 메인 스레드에서 불린다.
final class DaemonClient {
    var onState: ((DaemonState) -> Void)?
    /// (화면 ID, 바이트, 붙기 전 출력인지)
    var onOutput: ((String, ArraySlice<UInt8>, Bool) -> Void)?
    var onExited: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onDisconnect: (() -> Void)?

    private var connection: Connection?
    var isConnected: Bool { connection.map { !$0.isClosed } ?? false }
    /// 붙기(띄우기·기다리기·launchctl)는 이 줄에서 한다 — 메인 스레드가 멈추지 않게
    private let connectQueue = DispatchQueue(label: "AgentDeck.daemon-connect", qos: .userInitiated)
    /// disconnect 하면 늘어난다(그 전에 시작한 붙기의 결과는 버린다)
    private var generation = 0

    /// 메인 스레드 밖에서 붙는다(데몬이 없으면 띄우고 기다린다 — launch 가 false 면 띄우지 않는다, 예전 데몬에 붙는 동안).
    /// 끝나면 메인 스레드에서 completion(붙었으면 연결도 이미 시작됨). 이미 붙어 있으면 바로 부른다.
    func connect(launch: Bool, completion: @escaping (DaemonConnector.Result) -> Void) {
        if let connection, !connection.isClosed {
            completion(.connected(fd: -1, route: .existing))
            return
        }
        let started = generation
        let env = LiveDaemonEnvironment(daemonPath: daemonPath, root: DataLocation.root, termDir: TermPaths.home)
        connectQueue.async { [weak self] in
            let result = DaemonConnector.run(launch: launch, env: env)
            DispatchQueue.main.async {
                guard let self, started == self.generation else {
                    if case .connected(let fd, _) = result { Darwin.close(fd) } // 그동안 끊기로 했다
                    return
                }
                if case .connected(let fd, _) = result { self.attach(fd: fd) }
                completion(result)
            }
        }
    }

    private func attach(fd: Int32) {
        let connection = Connection(fd: fd, queue: .main)
        connection.onFrame = { [weak self] frame in self?.handle(frame) }
        connection.onClose = { [weak self] in
            self?.connection = nil
            self?.onDisconnect?()
        }
        connection.start()
        self.connection = connection
    }

    private func handle(_ frame: Frame) {
        switch frame.type {
        case .state:
            if let state = frame.json(DaemonState.self) { onState?(state) }
        case .replay, .output:
            if let data = frame.paneData { onOutput?(data.id, data.bytes, frame.type == .replay) }
        case .exited:
            if let data = frame.paneData { onExited?(data.id) }
        case .error:
            onError?(frame.text)
        default:
            break
        }
    }

    /// 연결을 끊는다(onDisconnect 는 부르지 않는다 — 데이터 위치를 옮기는 동안). 진행 중인 붙기 결과도 버린다.
    func disconnect() {
        generation += 1
        guard let connection else { return }
        connection.onClose = nil
        connection.onFrame = nil
        connection.close()
        self.connection = nil
    }

    func send(_ frame: Frame) {
        connection?.send(frame)
    }

    func list() { send(Frame(.list)) }
    func create(_ request: CreateRequest) { send(Frame(.create, json: request)) }
    func attach(_ id: String) { send(Frame(.attach, Array(id.utf8))) }
    func detach(_ id: String) { send(Frame(.detach, Array(id.utf8))) }
    func kill(_ id: String) { send(Frame(.kill, Array(id.utf8))) }
    func input(_ id: String, _ bytes: some Collection<UInt8>) { send(Frame(.input, pane: id, bytes: bytes)) }
    func resize(_ id: String, cols: Int, rows: Int) {
        send(Frame(.resize, json: ResizeRequest(id: id, cols: cols, rows: rows)))
    }

    private var daemonPath: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(HookInstaller.daemonExecutable).path
    }
}

/// 실제 소켓·launchctl·posix_spawn(메인 스레드 밖에서 불린다 — 데이터 위치는 시작할 때 정해 넘긴다)
private struct LiveDaemonEnvironment: DaemonConnectEnvironment {
    let daemonPath: String
    let root: URL
    let termDir: URL

    var directOnly: Bool { AgentDeckEnv.isOn("DAEMON_DIRECT") }

    func connect() -> Int32? { UnixSocket.connect(in: termDir) }

    /// 데몬을 launchd 작업으로 띄운다(DaemonLaunchAgent — 앱의 coalition 밖이라 앱이 어떻게 끝나든, 강제 종료돼도 데몬과 셸이 남는다).
    /// 앱이 정한 데이터 위치를 인자로 넘긴다(데몬이 따로 고르다 예전 폴더로 가지 않게, 셸 환경에는 남지 않게).
    /// 이미 돌고 있는 데몬(예전 방식으로 뜬 것 포함)은 건드리지 않는다: 소켓에 못 붙을 때만 여기 온다.
    func launchViaLaunchd() -> DaemonLaunchAgent.Outcome {
        DaemonLaunchAgent.launch(program: daemonPath, root: root, termDir: termDir)
    }

    /// 이미 돌던 데몬(소켓에 붙었다)의 daemon.pid 가 이 폴더의 launchd 작업 pid 인지.
    /// launchctl 이 답하지 않거나 pid 를 모르면 nil(모를 때는 경고하지 않는다).
    func existingIsLaunchd() -> Bool? {
        guard let pid = DataLocation.daemonPid(termDir: termDir),
              let status = DaemonLaunchAgent.statusIfKnown(label: DaemonLaunchAgent.label(termDir: termDir))
        else { return nil }
        if status.running { return status.pid.map { $0 == pid } }
        return false
    }

    func now() -> Date { Date() }
    func sleep(_ seconds: TimeInterval) { usleep(useconds_t(seconds * 1_000_000)) }
    func log(_ message: String) { DataLocation.log(message, in: termDir) }

    /// 예전 방식: 앱과 다른 세션(setsid). 앱이 정상 종료되면 남지만 앱의 coalition 에 남아,
    /// macOS 가 앱을 강제 종료(남은 앱 정리·Dock 강제 종료)하면 함께 죽는다.
    func spawnDirect() -> Bool {
        let path = daemonPath, root = root, term = termDir
        try? FileManager.default.createDirectory(at: term, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let errorLog = term.appendingPathComponent("daemon-stderr.log").path

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, errorLog, O_WRONLY | O_CREAT | O_APPEND, 0o600)

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("--root"), strdup(root.path), nil]
        defer { argv.forEach { free($0) } }
        guard posix_spawn(&pid, path, &actions, &attr, argv, environ) == 0 else { return false }
        // 데몬이 앱보다 먼저 끝나면 좀비가 남지 않게 거둔다
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return true
    }
}
