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

    /// 연결한다. 데몬이 없으면 띄우고 최대 3초 기다린다(launch 가 false 면 띄우지 않는다 — 예전 데몬에 붙는 동안).
    @discardableResult
    func connect(launch: Bool = true) -> Bool {
        if isConnected { return true }
        var fd = UnixSocket.connect(in: TermPaths.home)
        if fd == nil, launch {
            let viaLaunchd = launchDaemon()
            for _ in 0..<60 where fd == nil {
                usleep(50_000)
                fd = UnixSocket.connect(in: TermPaths.home)
            }
            // 막 끝나는 데몬의 작업이 아직 내려가는 중이었으면(돌고 있음으로 보임) 한 번 더 올린다
            if fd == nil, viaLaunchd {
                DataLocation.log("데몬이 3초 안에 뜨지 않아 launchd 로 한 번 더 띄움")
                if launchDaemon() {
                    for _ in 0..<60 where fd == nil {
                        usleep(50_000)
                        fd = UnixSocket.connect(in: TermPaths.home)
                    }
                }
            }
            // launchd 가 작업을 올렸는데도 데몬이 안 뜸(실행 파일이 없어짐·관리 정책 등): 예전 방식으로 한 번 더
            if fd == nil, viaLaunchd {
                DataLocation.log("launchd 작업의 데몬이 3초 안에 뜨지 않아 예전 방식(posix_spawn)으로 띄움")
                spawnDaemonDirectly()
                for _ in 0..<60 where fd == nil {
                    usleep(50_000)
                    fd = UnixSocket.connect(in: TermPaths.home)
                }
            }
        }
        guard let fd else { return false }
        let connection = Connection(fd: fd, queue: .main)
        connection.onFrame = { [weak self] frame in self?.handle(frame) }
        connection.onClose = { [weak self] in
            self?.connection = nil
            self?.onDisconnect?()
        }
        connection.start()
        self.connection = connection
        return true
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

    /// 연결을 끊는다(onDisconnect 는 부르지 않는다 — 데이터 위치를 옮기는 동안)
    func disconnect() {
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

    /// 데몬을 launchd 작업으로 띄운다(DaemonLaunchAgent — 앱의 coalition 밖이라 앱이 어떻게 끝나든, 강제 종료돼도 데몬과 셸이 남는다).
    /// 앱이 정한 데이터 위치를 인자로 넘긴다(데몬이 따로 고르다 예전 폴더로 가지 않게, 셸 환경에는 남지 않게).
    /// launchctl 이 안 되면 예전 방식(posix_spawn + setsid)으로 띄운다 — 그 데몬은 앱의 coalition 에 남는다.
    /// 이미 돌고 있는 데몬(예전 방식으로 뜬 것 포함)은 건드리지 않는다: 소켓에 못 붙을 때만 여기 온다.
    /// launchd 로 띄웠으면 true(시작만 하고 기다리지는 않는다).
    private func launchDaemon() -> Bool {
        if AgentDeckEnv.isOn("DAEMON_DIRECT") {
            DataLocation.log("AGENTDECK_DAEMON_DIRECT=1: 데몬을 예전 방식(posix_spawn)으로 띄움")
            spawnDaemonDirectly()
            return false
        }
        switch DaemonLaunchAgent.launch(program: daemonPath, root: DataLocation.root, termDir: TermPaths.home) {
        case .bootstrapped(let label):
            DataLocation.log("데몬을 launchd 작업으로 띄움: \(label)")
        case .kickstarted(let label):
            DataLocation.log("이미 올라가 있던 launchd 작업을 다시 시작함(예전 plist 내용): \(label)")
        case .alreadyRunning(let label, let pid):
            DataLocation.log("launchd 작업이 이미 돌고 있음: \(label) pid \(pid.map(String.init) ?? "?")")
        case .failed(let reason):
            DataLocation.log("launchd 로 띄우지 못해 예전 방식(posix_spawn)으로 띄움: \(reason)")
            spawnDaemonDirectly()
            return false
        }
        return true
    }

    private var daemonPath: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(HookInstaller.daemonExecutable).path
    }

    /// 예전 방식: 앱과 다른 세션(setsid). 앱이 정상 종료되면 남지만 앱의 coalition 에 남아,
    /// macOS 가 앱을 강제 종료(남은 앱 정리·Dock 강제 종료)하면 함께 죽는다.
    private func spawnDaemonDirectly() {
        let path = daemonPath, root = DataLocation.root, term = TermPaths.home
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
        guard posix_spawn(&pid, path, &actions, &attr, argv, environ) == 0 else { return }
        // 데몬이 앱보다 먼저 끝나면 좀비가 남지 않게 거둔다
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }
}
