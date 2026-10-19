import CPTY
import Darwin
import Foundation
import SessionCore
import TermWire

// 내장 터미널의 세션을 붙잡고 있는 데몬. 앱을 끄거나 업데이트해도 셸·claude 가 계속 돌게 한다.
// 화면을 그리지 않고, 화면마다 지난 출력만 상한을 두고 보관한다(앱이 다시 붙을 때 되살리는 용도).
//   AgentDeckDaemon [--root <폴더>] : 데몬(이미 떠 있으면 바로 끝남). 앱이 정한 데이터 위치를 --root 로 받는다
//   AgentDeckDaemon hook            : Claude Code hook(세션 기록)
//   AgentDeckDaemon codex-hook      : Codex hook(작업 상태)
//   AgentDeckDaemon unhook          : 이 앱의 hook 을 Claude Code·Codex 설정에서 뺀다(삭제할 때)
//   AgentDeckDaemon ctl ...         : 시험·진단용 클라이언트 (list | new <cwd> [명령] | send <id> <글> | dump <id> | kill <id>)
// hook·ctl 은 쓸 데이터 위치를 스스로 고른다(DataLocation: 새 데몬 → 예전 데몬 → 안 옮긴 예전 데이터 → 새 위치).

if CommandLine.arguments.dropFirst().first == "ctl" {
    exit(Ctl.run(Array(CommandLine.arguments.dropFirst(2))))
}
// Claude Code hook(SessionStart/SessionEnd): 세션 기록을 남긴다. 데몬 실행 파일이 맡아 AppKit 을 띄우지 않고 가볍게 끝난다.
if CommandLine.arguments.dropFirst().first == "hook" {
    exit(HookHandler.runFromCommandLine())
}

if CommandLine.arguments.dropFirst().first == "codex-hook" {
    exit(CodexHook.run())
}
if CommandLine.arguments.dropFirst().first == "unhook" {
    exit(Unhook.run(Array(CommandLine.arguments.dropFirst(2))))
}

// 앱이 정한 위치(앱은 예전 데이터를 옮긴 뒤에만 새 위치로 띄운다). 셸에는 넘기지 않으려고 환경 변수 대신 인자로 받는다.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--root" {
    DataLocation.use(root: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), mode: .standard)
}

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)
InheritedEnvironment.scrub()
Daemon.shared.start()
dispatchMain()

enum Log {
    static func write(_ message: String) { DataLocation.log(message) }
}

/// 지난 출력. 상한을 넘으면 앞에서부터 버린다(줄 경계에서 자르려고 노력한다).
/// 버린 부분은 모드 추적기에 먹여, 남은 출력이 시작하는 시점의 터미널 모드(대체 화면 등)를 기억한다.
/// 그래야 긴 claude 세션에서 맨 앞의 `ESC[?1049h` 가 잘려 나가도 다시 붙을 때 대체 화면으로 되살린다.
struct OutputBuffer {
    static let defaultCapacity = 2 << 20
    /// 시험용: 1 이면 앞 모드를 붙이지 않는다(예전 데몬 흉내 — 앱 쪽 대비책 확인용)
    static let modePrefixDisabled = AgentDeckEnv.isOn("NO_MODE_PREFIX")

    let capacity: Int
    private(set) var bytes: [UInt8] = []
    /// 남은 출력(`bytes`) 맨 앞 시점의 모드
    private(set) var baseline = TerminalModeTracker()

    init(capacity: Int = defaultCapacity) {
        self.capacity = capacity
    }

    /// 앱이 붙을 때 보낼 지난 출력: 기본값과 다른 모드를 되살리는 앞부분 + 남은 출력
    var replay: [UInt8] {
        guard !Self.modePrefixDisabled else { return bytes }
        let prefix = baseline.prefix()
        return prefix.isEmpty ? bytes : prefix + bytes
    }

    mutating func append(_ chunk: ArraySlice<UInt8>) {
        bytes.append(contentsOf: chunk)
        // 매번 자르면 비싸므로 1/4 넘게 넘쳤을 때만 자른다
        guard bytes.count > capacity + capacity / 4 else { return }
        var cut = bytes.count - capacity
        let window = bytes[cut..<min(cut + 4096, bytes.count)]
        if let newline = window.firstIndex(of: 0x0a) { cut = newline + 1 }
        baseline.feed(bytes[0..<cut])
        bytes.removeFirst(cut)
    }
}

final class Pane {
    let id: String
    let title: String
    let cwd: String
    let pid: pid_t
    let fd: Int32
    let tty: String?
    let createdAt = Date()
    var cols: Int
    var rows: Int
    var output = OutputBuffer()
    var viewers: [ObjectIdentifier: Connection] = [:]
    var pendingInput: [UInt8] = []
    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    var exitSource: DispatchSourceProcess?
    var killTimer: DispatchSourceTimer?
    /// 아직 취소 처리가 끝나지 않은 fd 소스 수. 0 이 되어야 fd 를 닫는다(dispatch 규칙).
    var liveSources = 0
    var closing = false

    func sourceCancelled() {
        liveSources -= 1
        if liveSources == 0, closing { close(fd) }
    }

    init(id: String, title: String, cwd: String, pid: pid_t, fd: Int32, cols: Int, rows: Int) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.pid = pid
        self.fd = fd
        self.cols = cols
        self.rows = rows
        tty = ptsname(fd).map { (String(cString: $0) as NSString).lastPathComponent }
    }

    var foreground: String? {
        let group = cpty_foreground(fd)
        guard group > 0 else { return nil }
        if let argv0 = ProcessUtil.arguments(group)?.first {
            return (argv0 as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return ProcessUtil.info(group)?.command
    }

    var info: PaneInfo {
        PaneInfo(id: id, title: title, cwd: cwd, pid: pid, tty: tty, foreground: foreground, cols: cols, rows: rows,
                 bufferedBytes: output.bytes.count, createdAt: createdAt)
    }
}

final class Daemon {
    static let shared = Daemon()
    /// 화면도 앱 연결도 없이 이만큼 지나면 끝낸다(쓸 일 없을 때 메모리를 차지하지 않게)
    static let idleExit: TimeInterval = 60

    let queue = DispatchQueue.main
    let home = TermPaths.home
    var panes: [String: Pane] = [:]
    var order: [String] = []
    var clients: [ObjectIdentifier: Connection] = [:]
    var listenSource: DispatchSourceRead?
    var idleSince: Date? = Date()
    var lockFd: Int32 = -1

    func start() {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // 한 사용자당 데몬 하나
        lockFd = open(home.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFd >= 0, flock(lockFd, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
        let listenFd: Int32
        do {
            listenFd = try UnixSocket.listen(in: home)
        } catch {
            Log.write("소켓을 만들지 못함: \(error)")
            exit(1)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: queue)
        source.setEventHandler { [unowned self] in acceptClients(listenFd) }
        source.resume()
        listenSource = source
        try? "\(getpid())\n".write(to: home.appendingPathComponent("daemon.pid"), atomically: true, encoding: .utf8)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [unowned self] in exitIfIdle() }
        timer.resume()
        idleTimer = timer
        Log.write("시작")
    }

    var idleTimer: DispatchSourceTimer?

    func exitIfIdle() {
        guard panes.isEmpty, clients.isEmpty else {
            idleSince = nil
            return
        }
        let since = idleSince ?? Date()
        idleSince = since
        guard Date().timeIntervalSince(since) >= Self.idleExit else { return }
        Log.write("화면·연결이 없어 끝냄")
        unlink(home.appendingPathComponent(TermPaths.socketName).path)
        exit(0)
    }

    func acceptClients(_ listenFd: Int32) {
        while true {
            let fd = accept(listenFd, nil, nil)
            guard fd >= 0 else { return }
            // 다른 사용자가 붙지 못하게(소켓 파일 권한과 별개로 한 번 더)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let connection = Connection(fd: fd, queue: queue)
            let key = ObjectIdentifier(connection)
            clients[key] = connection
            idleSince = nil
            connection.onFrame = { [unowned self, unowned connection] frame in handle(frame, from: connection) }
            connection.onClose = { [unowned self] in
                clients.removeValue(forKey: key)
                for pane in panes.values { pane.viewers.removeValue(forKey: key) }
            }
            connection.start()
        }
    }

    /// 이 데몬 실행의 ID(앱이 데몬이 바뀌었는지 알아보는 데 쓴다)
    let instance = UUID().uuidString

    var state: DaemonState {
        DaemonState(pid: getpid(), footprint: Memory.footprint(), panes: order.compactMap { panes[$0]?.info },
                    instance: instance)
    }

    func broadcastState() {
        let frame = Frame(.state, json: state)
        clients.values.forEach { $0.send(frame) }
    }

    func handle(_ frame: Frame, from client: Connection) {
        switch frame.type {
        case .list:
            client.send(Frame(.state, json: state))
        case .create:
            guard let request = frame.json(CreateRequest.self) else { return }
            do {
                try create(request)
                broadcastState()
            } catch {
                client.send(Frame(.error, Array("화면을 만들지 못함: \(error)".utf8)))
            }
        case .attach:
            guard let pane = panes[frame.text] else {
                client.send(Frame(.exited, pane: frame.text))
                return
            }
            pane.viewers[ObjectIdentifier(client)] = client
            client.send(Frame(.replay, pane: pane.id, bytes: pane.output.replay))
        case .detach:
            panes[frame.text]?.viewers.removeValue(forKey: ObjectIdentifier(client))
        case .input:
            guard let data = frame.paneData, let pane = panes[data.id] else { return }
            write(Array(data.bytes), to: pane)
        case .resize:
            guard let request = frame.json(ResizeRequest.self), let pane = panes[request.id],
                  request.cols > 0, request.rows > 0
            else { return }
            pane.cols = request.cols
            pane.rows = request.rows
            _ = cpty_resize(pane.fd, UInt16(clamping: request.cols), UInt16(clamping: request.rows))
        case .kill:
            if let pane = panes[frame.text] { terminate(pane) }
        case .state, .replay, .output, .exited, .error:
            break
        }
    }

    // MARK: - 화면

    func environment(for id: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "AgentDeck"
        env[AgentDeckEnv.name("PANE")] = id
        // 예전 이름(앱을 예전 화면 안에서 띄웠으면 남아 있다)은 빼서 다른 화면 ID 로 읽히지 않게
        env.removeValue(forKey: AgentDeckEnv.legacyName("PANE"))
        // Finder 로 띄운 앱에는 LANG 이 없다. 없으면 한글이 깨지므로 지금 언어 설정으로 채운다.
        if (env["LANG"] ?? "").isEmpty, (env["LC_ALL"] ?? "").isEmpty, (env["LC_CTYPE"] ?? "").isEmpty {
            let locale = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
            env["LANG"] = (locale.contains("_") ? locale : "en_US") + ".UTF-8"
        }
        for key in ["TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "GHOSTTY_RESOURCES_DIR",
                    "GHOSTTY_BIN_DIR", "GHOSTTY_SHELL_FEATURES", "__CFBundleIdentifier", "XPC_SERVICE_NAME"] {
            env.removeValue(forKey: key)
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    func create(_ request: CreateRequest) throws {
        guard panes[request.id] == nil else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        // argv[0] 앞의 "-" = 로그인 셸(사용자 PATH 등 설정 파일을 읽는다)
        let argv = ["-" + (shell as NSString).lastPathComponent]
        let env = environment(for: request.id)
        let cols = UInt16(clamping: max(request.cols, 2))
        let rows = UInt16(clamping: max(request.rows, 2))
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var master: Int32 = -1
        let pid = cpty_spawn(shell, &cArgv, &cEnv, request.cwd, cols, rows, &master)
        guard pid > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let pane = Pane(id: request.id, title: request.title ?? (request.cwd as NSString).lastPathComponent,
                        cwd: request.cwd, pid: pid, fd: master, cols: Int(cols), rows: Int(rows))
        panes[pane.id] = pane
        order.append(pane.id)

        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [unowned self] in readOutput(pane) }
        read.setCancelHandler { pane.sourceCancelled() }
        pane.liveSources += 1
        read.resume()
        pane.readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [unowned self] in finish(pane) }
        exit.resume()
        pane.exitSource = exit

        if let input = request.input, !input.isEmpty { write(Array(input.utf8), to: pane) }
        Log.write("화면 \(pane.id) 시작 pid \(pid) \(pane.tty ?? "-") \(request.cwd)")
    }

    func readOutput(_ pane: Pane) {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(pane.fd, $0.baseAddress, $0.count) }
            if count > 0 {
                let bytes = chunk[0..<count]
                pane.output.append(bytes)
                if !pane.viewers.isEmpty {
                    let frame = Frame(.output, pane: pane.id, bytes: bytes)
                    pane.viewers.values.forEach { $0.send(frame) }
                }
                if count < chunk.count { return }
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                return
            } else {
                // 셸 쪽이 모두 닫힘(EIO). 끝 처리는 프로세스 종료 이벤트에서 한다.
                pane.readSource?.cancel()
                return
            }
        }
    }

    func write(_ bytes: [UInt8], to pane: Pane) {
        pane.pendingInput.append(contentsOf: bytes)
        flushInput(pane)
    }

    func flushInput(_ pane: Pane) {
        if pane.closing { pane.pendingInput = [] } // 닫는 중인 fd 에는 쓰지 않는다
        while !pane.pendingInput.isEmpty {
            let written = pane.pendingInput.withUnsafeBytes { Darwin.write(pane.fd, $0.baseAddress, $0.count) }
            if written > 0 {
                pane.pendingInput.removeFirst(written)
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                pane.pendingInput = []
                break
            }
        }
        if pane.pendingInput.isEmpty {
            pane.writeSource?.cancel()
            pane.writeSource = nil
        } else if pane.writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: pane.fd, queue: queue)
            source.setEventHandler { [unowned self] in flushInput(pane) }
            source.setCancelHandler { pane.sourceCancelled() }
            pane.liveSources += 1
            source.resume()
            pane.writeSource = source
        }
    }

    /// 셸과 그 안의 프로그램(claude 등)에 끊김 신호를 보낸다. 3초 안에 안 끝나면 강제로 끝낸다.
    func terminate(_ pane: Pane) {
        let group = cpty_foreground(pane.fd)
        if group > 0 { killpg(group, SIGHUP) }
        killpg(pane.pid, SIGHUP)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3)
        timer.setEventHandler { [weak pane] in
            guard let pane else { return }
            let group = cpty_foreground(pane.fd)
            if group > 0 { killpg(group, SIGKILL) }
            killpg(pane.pid, SIGKILL)
        }
        timer.resume()
        pane.killTimer = timer
    }

    func finish(_ pane: Pane) {
        var status: Int32 = 0
        waitpid(pane.pid, &status, WNOHANG)
        readOutput(pane) // 남은 출력
        pane.closing = true
        pane.readSource?.cancel()
        pane.writeSource?.cancel()
        pane.exitSource?.cancel()
        pane.killTimer?.cancel()
        if pane.liveSources == 0 { close(pane.fd) }
        panes.removeValue(forKey: pane.id)
        order.removeAll { $0 == pane.id }
        let frame = Frame(.exited, pane: pane.id)
        pane.viewers.values.forEach { $0.send(frame) }
        pane.viewers = [:]
        Log.write("화면 \(pane.id) 끝남 (상태 \(status))")
        broadcastState()
    }
}

/// 시험·진단용 클라이언트
enum Ctl {
    static func run(_ args: [String]) -> Int32 {
        guard let fd = UnixSocket.connect(in: TermPaths.home) else {
            FileHandle.standardError.write(Data("데몬에 연결할 수 없음 (\(TermPaths.home.path))\n".utf8))
            return 1
        }
        let queue = DispatchQueue(label: "ctl")
        let connection = Connection(fd: fd, queue: queue)
        let done = DispatchSemaphore(value: 0)
        var result: Int32 = 0
        var collected: [UInt8] = []
        let command = args.first ?? "list"

        queue.sync {
            connection.onClose = { done.signal() }
            connection.onFrame = { frame in
                switch (command, frame.type) {
                case ("list", .state), ("new", .state):
                    if let state = frame.json(DaemonState.self) {
                        print("데몬 pid \(state.pid) 메모리 \(Memory.format(state.footprint)) 화면 \(state.panes.count)")
                        for pane in state.panes {
                            print("\(pane.id)  \(pane.tty ?? "-")  pid \(pane.pid)  앞: \(pane.foreground ?? "-")  "
                                + "\(pane.cols)x\(pane.rows)  출력 \(pane.bufferedBytes)B  \(pane.cwd)")
                        }
                    }
                    done.signal()
                case ("dump", .replay):
                    collected.append(contentsOf: frame.paneData?.bytes ?? [])
                    FileHandle.standardOutput.write(Data(collected))
                    done.signal()
                case ("send", .state), ("kill", .state), ("resize", .state):
                    done.signal()
                case (_, .exited):
                    print("화면 없음: \(frame.paneData?.id ?? "")")
                    result = 1
                    done.signal()
                case (_, .error):
                    print(frame.text)
                    result = 1
                    done.signal()
                default:
                    break
                }
            }
            connection.start()
            switch command {
            case "list":
                connection.send(Frame(.list))
            case "new" where args.count >= 2:
                let input = args.count >= 3 ? args[2] + "\n" : nil
                connection.send(Frame(.create, json: CreateRequest(id: UUID().uuidString, cwd: args[1], cols: 100,
                                                                   rows: 30, input: input)))
            case "send" where args.count >= 3:
                let text = args[2].replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\r", with: "\r")
                connection.send(Frame(.input, pane: args[1], bytes: Array(text.utf8)))
                connection.send(Frame(.list))
            case "dump" where args.count >= 2:
                connection.send(Frame(.attach, Array(args[1].utf8)))
            case "kill" where args.count >= 2:
                connection.send(Frame(.kill, Array(args[1].utf8)))
                connection.send(Frame(.list))
            case "resize" where args.count >= 4:
                connection.send(Frame(.resize, json: ResizeRequest(id: args[1], cols: Int(args[2]) ?? 80,
                                                                   rows: Int(args[3]) ?? 24)))
                connection.send(Frame(.list))
            default:
                print("사용법: ctl list | new <cwd> [명령] | send <id> <글> | dump <id> | kill <id> | resize <id> <열> <행>")
                result = 2
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 5)
        queue.sync { connection.close() }
        return result
    }
}
