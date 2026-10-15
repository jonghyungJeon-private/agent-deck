import Darwin
import Foundation
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

    /// 연결한다. 데몬이 없으면 띄우고 최대 3초 기다린다.
    @discardableResult
    func connect() -> Bool {
        if isConnected { return true }
        var fd = UnixSocket.connect(in: TermPaths.home)
        if fd == nil {
            launchDaemon()
            for _ in 0..<60 where fd == nil {
                usleep(50_000)
                fd = UnixSocket.connect(in: TermPaths.home)
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

    /// 데몬을 앱과 다른 세션(setsid)으로 띄운다. 앱이 끝나도 데몬과 그 안의 셸은 남는다.
    private func launchDaemon() {
        let path = Bundle.main.executableURL!.deletingLastPathComponent()
            .appendingPathComponent("ClaudeTermDaemon").path
        try? FileManager.default.createDirectory(at: TermPaths.home, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let errorLog = TermPaths.home.appendingPathComponent("daemon-stderr.log").path

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
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        guard posix_spawn(&pid, path, &actions, &attr, argv, environ) == 0 else { return }
        // 데몬이 앱보다 먼저 끝나면 좀비가 남지 않게 거둔다
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }
}
