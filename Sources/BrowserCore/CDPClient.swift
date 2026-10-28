import Foundation

/// CDP 메시지를 주고받는 통로. 실제로는 WebSocket, 시험에서는 가짜.
public protocol CDPTransport: AnyObject {
    func send(_ text: String)
    func close()
    /// 받은 글·끊김을 알린다. 아무 스레드에서나 불릴 수 있다
    var onMessage: ((String) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
}

public enum CDPError: Error, Equatable {
    case closed
    case timeout(String)
    case protocolError(String)
}

/// CDP 이벤트(요청 id 없는 메시지). `sessionId` 는 flatten 으로 붙은 탭의 연결 이름.
public struct CDPEvent {
    public let method: String
    public let params: [String: Any]
    public let sessionId: String?
}

/// 브라우저 하나에 대한 CDP 연결. 요청마다 id 를 붙여 응답을 짝짓고, 나머지는 이벤트로 넘긴다.
/// 끊기면 기다리던 요청은 모두 `.closed` 로 끝난다.
public final class CDPClient {
    private let transport: CDPTransport
    private let lock = NSLock()
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var closed = false

    public var onEvent: ((CDPEvent) -> Void)?
    public var onClose: (() -> Void)?

    public init(transport: CDPTransport) {
        self.transport = transport
        transport.onMessage = { [weak self] in self?.receive($0) }
        transport.onClose = { [weak self] _ in self?.fail() }
    }

    public func send(_ method: String, _ params: [String: Any] = [:], sessionId: String? = nil,
                     timeout: TimeInterval = 5) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            lock.lock()
            if closed { lock.unlock(); cont.resume(throwing: CDPError.closed); return }
            nextId += 1
            let id = nextId
            pending[id] = cont
            lock.unlock()
            var message: [String: Any] = ["id": id, "method": method, "params": params]
            if let sessionId { message["sessionId"] = sessionId }
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let text = String(data: data, encoding: .utf8) else {
                resolve(id, .failure(CDPError.protocolError("encode \(method)")))
                return
            }
            transport.send(text)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, .failure(CDPError.timeout(method)))
            }
        }
    }

    /// 응답을 기다리지 않는 요청(프레임 확인·사람 입력). 부른 순서 그대로 보낸다 — 입력은 순서가 바뀌면 안 된다
    /// (조합 중 글자 → 확정이 뒤바뀌면 글자가 겹친다). 응답은 짝이 없으니 버려진다.
    public func post(_ method: String, _ params: [String: Any] = [:], sessionId: String? = nil) {
        lock.lock()
        if closed { lock.unlock(); return }
        nextId += 1
        var message: [String: Any] = ["id": nextId, "method": method, "params": params]
        lock.unlock()
        if let sessionId { message["sessionId"] = sessionId }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        transport.send(text)
    }

    public func close() {
        transport.close()
        fail()
    }

    private func resolve(_ id: Int, _ result: Result<[String: Any], Error>) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(with: result)
    }

    private func receive(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let id = message["id"] as? Int {
            if let error = message["error"] as? [String: Any] {
                resolve(id, .failure(CDPError.protocolError(error["message"] as? String ?? "error")))
            } else {
                resolve(id, .success(message["result"] as? [String: Any] ?? [:]))
            }
        } else if let method = message["method"] as? String {
            onEvent?(CDPEvent(method: method, params: message["params"] as? [String: Any] ?? [:],
                              sessionId: message["sessionId"] as? String))
        }
    }

    private func fail() {
        lock.lock()
        let wasClosed = closed
        closed = true
        let waiting = pending
        pending = [:]
        lock.unlock()
        for cont in waiting.values { cont.resume(throwing: CDPError.closed) }
        if !wasClosed { onClose?() }
    }
}

/// URLSession WebSocket 으로 된 통로
public final class WebSocketTransport: NSObject, CDPTransport, URLSessionWebSocketDelegate {
    public var onMessage: ((String) -> Void)?
    public var onClose: ((Error?) -> Void)?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!

    /// 연결이 열리면 돌아온다(열리지 않으면 오류)
    public static func connect(_ url: URL, timeout: TimeInterval = 3) async throws -> WebSocketTransport {
        let transport = WebSocketTransport()
        do {
            try await transport.open(url, timeout: timeout)
        } catch {
            transport.close() // 세션(대리자를 붙잡고 있음)을 남기지 않는다
            throw error
        }
        return transport
    }

    private var opened: CheckedContinuation<Void, Error>?
    private let openLock = NSLock()

    /// 열림·시간 초과·실패 중 먼저 온 것 하나만 기다림을 끝낸다
    private func takeOpened() -> CheckedContinuation<Void, Error>? {
        openLock.locked {
            defer { opened = nil }
            return opened
        }
    }

    private func open(_ url: URL, timeout: TimeInterval) async throws {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        // 큰 프레임(이미지)도 받는다 — 기본 1MB 는 넘을 수 있다
        task.maximumMessageSize = 64 << 20
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            openLock.locked { opened = cont }
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let cont = self.takeOpened() else { return }
                self.task.cancel()
                cont.resume(throwing: CDPError.timeout("connect"))
            }
        }
        receiveLoop()
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)): self.onMessage?(text); self.receiveLoop()
            case .success(.data(let data)): self.onMessage?(String(decoding: data, as: UTF8.self)); self.receiveLoop()
            case .success: self.receiveLoop()
            case .failure(let error): self.onClose?(error)
            }
        }
    }

    public func send(_ text: String) {
        task.send(.string(text)) { [weak self] error in if let error { self?.onClose?(error) } }
    }

    public func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        takeOpened()?.resume()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let cont = takeOpened() { cont.resume(throwing: error ?? CDPError.closed); return }
        onClose?(error)
    }
}
