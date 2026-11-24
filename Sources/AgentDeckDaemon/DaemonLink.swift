import Foundation
import SessionCore
import TermWire

/// 명령줄(`agentdeck`)이 데몬과 주고받는 동기 연결. 데몬에 보내고 답 메시지를 기다린다.
final class DaemonLink {
    private let queue = DispatchQueue(label: "agentdeck.cli.link")
    private var connection: Connection!
    private let condition = NSCondition()
    private var frames: [Frame] = []
    private var closed = false

    /// 데몬이 없으면 nil
    init?(home: URL = TermPaths.home) {
        // 소켓 경로가 길면 UnixSocket.connect 가 그 폴더(데이터 폴더의 term)로 chdir 한다 — 명령의 현재 폴더(새 칸의 기본 폴더·
        // --cwd·--file 의 상대 경로)가 데몬 폴더로 바뀌지 않게 연결한 뒤 되돌린다.
        let before = FileManager.default.currentDirectoryPath
        defer { if FileManager.default.currentDirectoryPath != before { _ = chdir(before) } }
        guard let fd = UnixSocket.connect(in: home) else { return nil }
        connection = Connection(fd: fd, queue: queue)
        connection.onFrame = { [weak self] frame in
            guard let self else { return }
            condition.lock()
            frames.append(frame)
            condition.broadcast()
            condition.unlock()
        }
        connection.onClose = { [weak self] in
            guard let self else { return }
            condition.lock()
            closed = true
            condition.broadcast()
            condition.unlock()
        }
        queue.sync { connection.start() }
    }

    deinit { queue.sync { connection?.close() } }

    /// 데몬과의 연결이 닫혔는가(닫혔으면 더 읽을 수 없다 — 그냥 느린 것과 구분한다)
    var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    func send(_ frame: Frame) {
        queue.sync { connection.send(frame) }
    }

    /// 쌓인 메시지를 버린다(이전 요청의 답이 섞이지 않게 새 요청 앞에서)
    private func drain() {
        condition.lock()
        frames.removeAll()
        condition.unlock()
    }

    private func wait(timeout: TimeInterval, _ match: (Frame) -> Bool) -> Frame? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let index = frames.firstIndex(where: match) { return frames.remove(at: index) }
            if closed { return nil }
            if !condition.wait(until: deadline) { return nil }
        }
    }

    /// 지금 화면 목록
    func state(timeout: TimeInterval = 3) -> DaemonState? {
        drain()
        send(Frame(.list))
        return wait(timeout: timeout) { $0.type == .state }?.json(DaemonState.self)
    }

    enum LinkError: Error, CustomStringConvertible {
        case daemon(String)
        case timeout
        var description: String {
            switch self {
            case .daemon(let message): return message
            case .timeout: return "데몬이 답하지 않음"
            }
        }
    }

    /// 칸을 만들고 목록에 나타날 때까지 기다린다
    func create(_ request: CreateRequest) throws {
        drain()
        send(Frame(.create, json: request))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let frame = wait(timeout: max(deadline.timeIntervalSinceNow, 0.1)) { $0.type == .state || $0.type == .error }
            guard let frame else { break }
            if frame.type == .error { throw LinkError.daemon(frame.text) }
            if frame.json(DaemonState.self)?.panes.contains(where: { $0.id == request.id }) == true { return }
        }
        throw LinkError.timeout
    }

    /// 칸의 지난 출력(replay). 칸이 없으면 nil.
    func replay(_ id: String) -> [UInt8]? {
        drain()
        send(Frame(.attach, Array(id.utf8)))
        let frame = wait(timeout: 5) { $0.type == .exited || ($0.type == .replay && $0.paneData?.id == id) }
        send(Frame(.detach, Array(id.utf8)))
        guard let frame, frame.type == .replay, let data = frame.paneData else { return nil }
        return Array(data.bytes)
    }

    /// 칸에 입력을 보낸다. 데몬이 앞의 메시지를 다 읽은 것까지 확인하고 돌아온다.
    @discardableResult
    func input(_ id: String, _ bytes: [UInt8]) -> Bool {
        let chunk = 256 << 10
        var start = 0
        while start < bytes.count {
            let end = min(start + chunk, bytes.count)
            send(Frame(.input, pane: id, bytes: bytes[start..<end]))
            start = end
        }
        return state() != nil
    }

    func kill(_ id: String) {
        send(Frame(.kill, Array(id.utf8)))
    }
}
