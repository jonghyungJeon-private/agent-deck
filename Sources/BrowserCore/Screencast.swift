import Foundation

/// screencast 프레임 하나(JPEG). `viewport` 는 이 프레임이 그린 페이지의 CSS 크기.
public struct ScreencastFrame {
    public let jpeg: Data
    public let viewport: CGSize
    /// 페이지가 그린 시각(초, 1970 기준)
    public let timestamp: Double
}

public struct ScreencastSettings: Equatable {
    public var quality: Int = 75
    public var maxWidth: Int = 1440
    public var maxHeight: Int = 900
    public init() {}
    public init(quality: Int, maxWidth: Int, maxHeight: Int) {
        self.quality = quality
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }
}

/// 탭(CDP target) 하나의 화면을 받아 넘긴다. 받은 프레임은 곧바로 확인(ack)한다 —
/// 확인하지 않으면 Chrome 이 다음 프레임을 보내지 않는다. 보이지 않을 때는 `stop()` 으로 멈춘다.
public final class ScreencastStream {
    private let client: CDPClient
    private let settings: ScreencastSettings
    private let lock = NSLock()
    private var targetId: String?
    private var sessionId: String?
    /// 탭을 바꾸거나 멈춘 뒤 늦게 온 프레임을 버리려는 세대 번호
    private var generation = 0

    public var onFrame: ((ScreencastFrame) -> Void)?

    public init(client: CDPClient, settings: ScreencastSettings = ScreencastSettings()) {
        self.client = client
        self.settings = settings
    }

    public var currentTarget: String? { lock.locked { targetId } }

    /// 이 탭을 보기 시작한다(이미 보고 있으면 그대로). 다른 탭을 보던 중이면 그쪽은 멈춘다.
    /// 붙는 동안 다른 `show`·`stop` 이 오면(세대가 바뀌면) 늦게 붙은 연결은 떼고 끝낸다.
    public func show(target: String) async throws {
        let claimed: (generation: Int, previous: String?)? = lock.locked {
            if targetId == target { return nil }
            generation += 1
            defer { targetId = target; sessionId = nil }
            return (generation, sessionId)
        }
        guard let claimed else { return }
        if let previous = claimed.previous { await detach(previous) }
        let current = { self.lock.locked { self.generation == claimed.generation } }
        do {
            let attached = try await client.send("Target.attachToTarget", ["targetId": target, "flatten": true])
            guard let session = attached["sessionId"] as? String else { throw CDPError.protocolError("attachToTarget") }
            let installed: Bool = lock.locked {
                guard generation == claimed.generation else { return false }
                sessionId = session
                return true
            }
            guard installed else { await detach(session); return }
            _ = try await client.send("Page.enable", sessionId: session)
            guard current() else { return } // 새 show·stop 이 이 연결을 이미 가져가 뗐다
            _ = try await client.send("Page.startScreencast", [
                "format": "jpeg", "quality": settings.quality,
                "maxWidth": settings.maxWidth, "maxHeight": settings.maxHeight, "everyNthFrame": 1,
            ], sessionId: session)
        } catch {
            // 실패하면 이 탭을 본다고 남기지 않는다(다음에 다시 시도할 수 있게)
            lock.locked { if generation == claimed.generation { targetId = nil } }
            throw error
        }
    }

    public func stop() async {
        let session: String? = lock.locked {
            generation += 1
            defer { targetId = nil; sessionId = nil }
            return sessionId
        }
        if let session { await detach(session) }
    }

    private func detach(_ session: String) async {
        _ = try? await client.send("Page.stopScreencast", sessionId: session, timeout: 2)
        _ = try? await client.send("Target.detachFromTarget", ["sessionId": session], timeout: 2)
    }

    /// 지금 보는 탭에 명령을 보낸다(입력 이벤트처럼 순서만 지키면 되는 것). 보는 탭이 없으면 버린다.
    /// 같은 연결로 보낸 요청은 보낸 순서대로 처리된다.
    public func post(_ method: String, _ params: [String: Any]) {
        guard let session = lock.locked({ sessionId }) else { return }
        client.post(method, params, sessionId: session)
    }

    /// 지금 보는 탭에서 식을 계산한다(값으로 받음). 못 하면 nil.
    public func evaluate(_ expression: String) async -> Any? {
        guard let session = lock.locked({ sessionId }),
              let result = try? await client.send("Runtime.evaluate", ["expression": expression, "returnByValue": true], sessionId: session)
        else { return nil }
        return (result["result"] as? [String: Any])?["value"]
    }

    /// 지금 보는 탭의 창을 넓혀·줄여 페이지 크기(CSS 픽셀)를 `size` 로 맞춘다. 창 크기 = 페이지 + 창 테두리(주소창 자리 등)
    /// 이므로 지금 차이를 재서 더한다. 같은 창의 탭은 모두 같은 크기가 된다. 성공하면 true.
    @discardableResult
    public func fit(to size: CGSize) async -> Bool {
        guard let target = currentTarget,
              let window = try? await client.send("Browser.getWindowForTarget", ["targetId": target]),
              let windowId = window["windowId"] as? Int,
              let inset = await evaluate("[outerWidth - innerWidth, outerHeight - innerHeight]") as? [Int], inset.count == 2
        else { return false }
        let bounds: [String: Any] = ["width": Int(size.width.rounded()) + inset[0], "height": Int(size.height.rounded()) + inset[1],
                                     "windowState": "normal"]
        return (try? await client.send("Browser.setWindowBounds", ["windowId": windowId, "bounds": bounds])) != nil
    }

    /// 탭의 주소·제목
    public func info(target: String) async -> (url: String, title: String)? {
        guard let result = try? await client.send("Target.getTargetInfo", ["targetId": target]),
              let info = result["targetInfo"] as? [String: Any] else { return nil }
        return (info["url"] as? String ?? "", info["title"] as? String ?? "")
    }

    /// 열린 페이지(탭)들의 target id(브라우저가 아는 순서). 못 읽으면 nil.
    public func pages() async -> [String]? {
        guard let result = try? await client.send("Target.getTargets"),
              let infos = result["targetInfos"] as? [[String: Any]] else { return nil }
        return infos.filter { ($0["type"] as? String) == "page" }.compactMap { $0["targetId"] as? String }
    }

    /// 보여 줄 탭 고르기: 원하는 탭이 열려 있으면 그것, 아니면 지금 보는 탭(있으면), 아니면 첫 페이지.
    /// 오래된 기록(이미 닫힌 탭) 때문에 보던 화면을 떼었다 붙였다 하지 않게 한다.
    public static func choose(wanted: String?, current: String?, open pages: [String]) -> String? {
        if let wanted, pages.contains(wanted) { return wanted }
        if let current, pages.contains(current) { return current }
        return pages.first
    }

    /// CDPClient 의 이벤트를 여기로 넘긴다. 이 스트림의 프레임이면 처리하고 true.
    @discardableResult
    public func handle(_ event: CDPEvent) -> Bool {
        guard event.method == "Page.screencastFrame" else { return false }
        let current: String? = lock.locked { sessionId }
        guard let session = event.sessionId, session == current else { return false }
        // 확인은 항상 먼저(그려지지 않을 프레임이라도) — 정수 ack id 와 문자열 sessionId 는 다른 것
        if let ackId = event.params["sessionId"] as? Int {
            client.post("Page.screencastFrameAck", ["sessionId": ackId], sessionId: session)
        }
        guard let base64 = event.params["data"] as? String, let jpeg = Data(base64Encoded: base64),
              let meta = event.params["metadata"] as? [String: Any] else { return true }
        let width = (meta["deviceWidth"] as? NSNumber)?.doubleValue ?? 0
        let height = (meta["deviceHeight"] as? NSNumber)?.doubleValue ?? 0
        let time = (meta["timestamp"] as? NSNumber)?.doubleValue ?? 0
        onFrame?(ScreencastFrame(jpeg: jpeg, viewport: CGSize(width: width, height: height), timestamp: time))
        return true
    }
}

extension NSLock {
    /// `withLock` 은 macOS 14 부터라 직접 둔다
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
