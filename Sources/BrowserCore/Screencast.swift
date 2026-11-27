import Foundation

/// screencast 프레임 하나(JPEG). `viewport` 는 이 프레임이 그린 페이지의 CSS 크기.
public struct ScreencastFrame {
    public let jpeg: Data
    public let viewport: CGSize
    /// 페이지가 그린 시각(초, 1970 기준)
    public let timestamp: Double
    /// 이 그림을 보낸 탭(받은 그 순간의 탭 — 뒤에 탭을 옮겨도 그대로)
    public var targetId: String? = nil
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

/// 페이지가 띄운 대화상자(alert·confirm·prompt·beforeunload). 창 없는(headless) Chrome 은 이것을 그리지 않고,
/// 누군가 `Page.handleJavaScriptDialog` 로 답할 때까지 그 탭은 멈춘다(스크립트도, 렌더러가 답하는 DevTools 요청도).
/// 답할 수 있는 것은 대화상자가 뜰 때 그 탭에 붙어 Page 를 켜 둔 연결뿐이다 — 그 연결을 떼면 아무도 닫지 못한다.
public struct PageDialog: Equatable {
    /// 뜰 때마다 새 번호 — 답은 사람이 본 바로 그 대화상자에만(두 번 눌러 다음 대화상자에 답이 가지 않게)
    public let id: Int
    public let targetId: String
    /// alert | confirm | prompt | beforeunload
    public let type: String
    public let message: String
    public let defaultPrompt: String
    public let url: String

    public init(id: Int = 0, targetId: String, type: String, message: String, defaultPrompt: String = "", url: String = "") {
        self.id = id
        self.targetId = targetId
        self.type = type
        self.message = message
        self.defaultPrompt = defaultPrompt
        self.url = url
    }
}

/// 탭(CDP target) 하나의 화면을 받아 넘긴다. 받은 프레임은 곧바로 확인(ack)한다 —
/// 확인하지 않으면 Chrome 이 다음 프레임을 보내지 않는다. 보이지 않을 때는 `stop()` 으로 멈춘다.
/// 보는 탭의 대화상자(`onDialog`)와 응답하지 않는 탭(`onUnresponsive`)도 알린다.
public final class ScreencastStream {
    private let client: CDPClient
    private let settings: ScreencastSettings
    /// 탭에 붙은 뒤 Page.enable 을 기다리는 시간. 넘기면 그 탭은 "응답 없음"(대화상자가 떠 있는데 답할 연결이 없는 탭 등)
    private let enableTimeout: TimeInterval
    /// 이미 답을 보낸 대화상자(PageDialog.id)
    private var answered: Set<Int> = []
    /// 대화상자 번호는 앱 전체에서 하나씩 늘린다 — 다시 붙어 새 스트림이 되어도 예전 번호와 겹치지 않게(칸은 답을 보낸 번호를 기억한다)
    private static let idLock = NSLock()
    private static var lastDialogId = 0
    fileprivate static func newDialogId() -> Int { idLock.locked { lastDialogId += 1; return lastDialogId } }
    /// 응답 없는 탭에 다시 물어보는 간격(오래 도는 스크립트 등은 이동 없이 풀린다 — 이동 알림만 기다리면 계속 막힌 것으로 남는다)
    private let probeInterval: TimeInterval
    fileprivate let lock = NSLock()
    fileprivate var targetId: String?
    private var sessionId: String?
    /// 탭을 바꾸거나 멈춘 뒤 늦게 온 프레임을 버리려는 세대 번호
    private var generation = 0
    /// 이 스트림이 붙여 둔 연결 → 탭(보는 탭 + 대화상자 때문에 남겨 둔 탭)
    fileprivate var sessionTargets: [String: String] = [:]
    /// 답하지 않은 대화상자(탭마다)
    fileprivate var dialogs: [String: PageDialog] = [:]
    /// 대화상자가 떠 있는 채로 다른 탭으로 옮겨 간 탭의 연결: 떼지 않고 둔다(떼면 그 대화상자는 아무도 닫을 수 없다).
    /// 그 탭으로 돌아오면 이 연결을 다시 쓴다. 대화상자가 닫히면(누가 답했든) 뗀다.
    private var kept: [String: String] = [:]
    /// 떠나며 떼는 중인 연결(탭 → 연결): 떼기가 끝나기 전에 그 탭으로 돌아오면 새로 붙지 않고 이것을 다시 쓴다 —
    /// 떼는 사이 그 탭에 대화상자가 떴으면 답할 수 있는 연결은 이것뿐이다
    private var detaching: [String: String] = [:]
    /// Page.enable 이 답한 연결 — 떼던 연결을 다시 쓸 수 있는 것은 이것뿐(켜는 중에 떠났다 돌아오면 새로 붙어 응답 여부를 다시 잰다)
    private var ready: Set<String> = []
    /// 보는 탭이 응답하지 않는다(Page.enable 이 시간 안에 끝나지 않음)
    private var unresponsive = false

    public var onFrame: ((ScreencastFrame) -> Void)?
    /// 보는 탭의 대화상자가 바뀌었다(nil = 없음). 아무 스레드에서나 불린다
    public var onDialog: ((PageDialog?) -> Void)?
    /// 탭(target)이 응답하지 않게 됐다(true)·다시 응답한다(false) — 보는 탭이거나 막 떠난 탭. 아무 스레드에서나 불린다
    public var onUnresponsive: ((String, Bool) -> Void)?

    public init(client: CDPClient, settings: ScreencastSettings = ScreencastSettings(), enableTimeout: TimeInterval = 5,
                probeInterval: TimeInterval = 3) {
        self.client = client
        self.settings = settings
        self.enableTimeout = enableTimeout
        self.probeInterval = probeInterval
    }

    public var currentTarget: String? { lock.locked { targetId } }
    /// 보는 탭이 응답하지 않는 중(그 탭에 계산·크기 맞추기를 보내면 시간만 쓴다)
    public var isUnresponsive: Bool { lock.locked { unresponsive } }
    /// 보는 탭의 대화상자
    public var currentDialog: PageDialog? { lock.locked { targetId.flatMap { dialogs[$0] } } }
    /// 보는 탭의 렌더러가 막혀 있다(대화상자가 떠 있거나 응답 없음): 계산을 보내면 시간 초과까지 기다리기만 한다
    public var isBlocked: Bool { lock.locked { blocked } }
    private var blocked: Bool { unresponsive || targetId.map { dialogs[$0] != nil } == true }

    /// 이 탭을 보기 시작한다(이미 보고 있으면 그대로). 다른 탭을 보던 중이면 그쪽은 멈춘다 —
    /// 그 탭에 답하지 않은 대화상자가 있으면 연결은 남겨 둔다(screencast 만 멈춤).
    /// 붙는 동안 다른 `show`·`stop` 이 오면(세대가 바뀌면) 늦게 붙은 연결은 떼고 끝낸다.
    /// 붙었는데 페이지가 답하지 않으면(Page.enable 시간 초과) 실패로 끝내지 않는다: 그 탭을 보는 채로
    /// `onUnresponsive(true)` 를 알리고 screencast 는 시작한다(브라우저가 주는 마지막 그림이라도) — 다시 붙기를 되풀이하지 않게.
    public func show(target: String) async throws {
        typealias Claim = (generation: Int, detach: String?, park: String?, reuse: String?, wasUnresponsive: String?, hadDialog: Bool)
        let claimed: Claim? = lock.locked {
            if targetId == target { return nil }
            generation += 1
            var detach = sessionId, park: String?
            if let previous = sessionId, let old = targetId, dialogs[old] != nil {
                kept[old] = previous
                park = previous
                detach = nil
            } else if let previous = sessionId, let old = targetId, !unresponsive, ready.contains(previous) {
                detaching[old] = previous // 응답 없거나 아직 켜는 중인 탭의 연결은 다시 쓰지 않는다(돌아오면 새로 붙어 다시 잰다)
            }
            let wasUnresponsive = unresponsive ? targetId : nil
            defer { targetId = target; sessionId = nil; unresponsive = false }
            let reuse = kept.removeValue(forKey: target) ?? detaching.removeValue(forKey: target)
            return (generation, detach, park, reuse, wasUnresponsive, park != nil)
        }
        guard let claimed else { return }
        // 떠나는 탭의 카드는 바로 걷는다(새 탭의 것은 붙은 뒤 announce 가 — 새 탭이 막혀 있으면 몇 초 걸린다)
        if let old = claimed.wasUnresponsive { onUnresponsive?(old, false) }
        if claimed.hadDialog { onDialog?(nil) }
        if let previous = claimed.detach { await detachOrKeep(previous) }
        if let parked = claimed.park {
            _ = try? await client.send("Page.stopScreencast", sessionId: parked, timeout: 2)
            // 그 사이 그 탭으로 돌아와 이 연결을 다시 쓰고 있으면 멈춤이 다시 받기보다 늦게 닿았을 수 있다: 그림을 다시 받는다
            if lock.locked({ sessionId == parked }) { client.post("Page.startScreencast", screencastParams, sessionId: parked) }
        }
        if let session = claimed.reuse {
            // 대화상자 때문에 남겨 둔(또는 떼던) 연결: Page 는 이미 켜져 있다(다시 켜면 멈춘 렌더러를 기다린다)
            guard install(session, generation: claimed.generation) else { await release(session); return }
            _ = try? await client.send("Page.startScreencast", screencastParams, sessionId: session)
            announce(target: target, generation: claimed.generation)
            return
        }
        do {
            let attached = try await client.send("Target.attachToTarget", ["targetId": target, "flatten": true])
            guard let session = attached["sessionId"] as? String else { throw CDPError.protocolError("attachToTarget") }
            lock.locked { sessionTargets[session] = target }
            guard install(session, generation: claimed.generation) else { await release(session); return }
            var answered = true
            do {
                _ = try await client.send("Page.enable", sessionId: session, timeout: enableTimeout)
            } catch CDPError.timeout {
                answered = false
            }
            // 세대 확인과 표시를 한 자물쇠 안에서: 그새 다른 탭으로 옮겼으면 옛 탭의 시간 초과가 새 탭을 막힌 것으로 만들지 않는다
            let stillCurrent: Bool = lock.locked {
                if answered { ready.insert(session) }
                guard generation == claimed.generation else { return false }
                if !answered { unresponsive = true }
                return true
            }
            guard stillCurrent else { return } // 새 show·stop 이 이 연결을 이미 가져가 뗐다
            _ = try await client.send("Page.startScreencast", screencastParams, sessionId: session)
            announce(target: target, generation: claimed.generation)
            if !answered { probe(session, target: target, generation: claimed.generation) }
        } catch {
            // 실패하면 이 탭을 본다고 남기지 않는다(다음에 다시 시도할 수 있게)
            lock.locked { if generation == claimed.generation { targetId = nil; unresponsive = false } }
            throw error
        }
    }

    /// 렌더러가 살아 있어야 오는 Page 알림
    static let rendererEvents: Set<String> = ["Page.frameNavigated", "Page.frameStartedLoading", "Page.frameStoppedLoading",
                                              "Page.loadEventFired", "Page.domContentEventFired", "Page.navigatedWithinDocument",
                                              "Page.lifecycleEvent"]

    private var screencastParams: [String: Any] {
        ["format": "jpeg", "quality": settings.quality, "maxWidth": settings.maxWidth, "maxHeight": settings.maxHeight, "everyNthFrame": 1]
    }

    /// 붙은 연결을 이 스트림의 것으로 — 그새 다른 show·stop 이 왔으면 false
    /// 응답 없는 탭: 이 탭을 보는 동안 `probeInterval` 마다 Page.enable(이미 켜졌으면 아무 일 없음)을 다시 보내 답이 오면 풀린 것으로 본다.
    /// 다른 탭으로 옮기거나 멈추거나(세대가 바뀜) 다른 길로 풀리면 그만둔다.
    private func probe(_ session: String, target: String, generation claimed: Int) {
        Task { [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: UInt64(self.probeInterval * 1_000_000_000))
                guard self.lock.locked({ self.generation == claimed && self.sessionId == session && self.unresponsive }) else { return }
                guard (try? await self.client.send("Page.enable", sessionId: session, timeout: self.enableTimeout)) != nil else { continue }
                let recovered: Bool = self.lock.locked {
                    self.ready.insert(session)
                    guard self.generation == claimed, self.sessionId == session, self.unresponsive else { return false }
                    self.unresponsive = false
                    return true
                }
                if recovered { self.onUnresponsive?(target, false) }
                return
            }
        }
    }

    private func install(_ session: String, generation claimed: Int) -> Bool {
        lock.locked {
            guard generation == claimed else { return false }
            sessionId = session
            return true
        }
    }

    /// 새 탭을 보기 시작했다: 그 탭의 대화상자·응답 여부를 알린다(그새 다른 탭으로 옮겼으면 조용히).
    /// 응답 여부는 지금 값으로 — 그새 렌더러가 풀렸으면 알리지 않는다
    private func announce(target: String, generation claimed: Int) {
        let state: (dialog: PageDialog?, hung: Bool)? = lock.locked { generation == claimed ? (dialogs[target], unresponsive) : nil }
        guard let state else { return }
        onDialog?(state.dialog)
        if state.hung { onUnresponsive?(target, true) }
    }

    /// 이 스트림이 쓰지 않게 된 연결: 대화상자가 떠 있는 탭이면 남겨 두고, 아니면 뗀다
    private func release(_ session: String) async {
        let park: Bool = lock.locked {
            guard let target = sessionTargets[session], dialogs[target] != nil, kept[target] == nil, targetId != target else { return false }
            kept[target] = session
            return true
        }
        if !park { await detachOrKeep(session) }
    }

    /// 다 쓴 연결을 뗀다 — screencast 를 멈추는 사이 그 탭에 대화상자가 떴으면(알림이 늦게 옴) 떼지 않고 남겨 둔다.
    /// 그 사이 그 탭으로 돌아와 이 연결을 다시 쓰게 됐으면 떼지 않고, 멈춤이 다시 받기보다 늦게 닿았을 수 있어 그림을 다시 받는다
    private func detachOrKeep(_ session: String) async {
        _ = try? await client.send("Page.stopScreencast", sessionId: session, timeout: 2)
        enum Outcome { case detach, keep, reused }
        let outcome: Outcome = lock.locked {
            guard let target = sessionTargets[session] else { return .detach }
            if detaching[target] == session { detaching[target] = nil }
            if sessionId == session { return .reused }
            if kept[target] == session { return .keep }
            guard dialogs[target] != nil, targetId != target, kept[target] == nil else { return .detach }
            kept[target] = session
            return .keep
        }
        if outcome == .reused { client.post("Page.startScreencast", screencastParams, sessionId: session) }
        if outcome != .detach { return }
        _ = try? await client.send("Target.detachFromTarget", ["sessionId": session], timeout: 2)
        lock.locked { _ = sessionTargets.removeValue(forKey: session); _ = ready.remove(session) }
    }

    /// 답하지 않은 대화상자가 있다(보는 탭이든 남겨 둔 탭이든)
    public var hasPendingDialogs: Bool { lock.locked { !dialogs.isEmpty } }

    /// 칸이 잠깐 안 보인다(가려짐·최소화): 그림만 멈추고 연결은 둔다 — 대화상자에 답할 연결을 지키려고(떼면 그 탭은 응답 없음이 된다).
    /// `resumeFrames` 와 같이 부른 순서대로 보낸다(곧바로 다시 보여도 멈춤이 다시 받기 뒤에 도착해 화면이 서지 않게)
    public func suspendFrames() {
        guard let session = lock.locked({ sessionId }) else { return }
        client.post("Page.stopScreencast", sessionId: session)
    }

    /// 다시 보인다: 그림을 다시 받는다
    public func resumeFrames() {
        guard let session = lock.locked({ sessionId }) else { return }
        client.post("Page.startScreencast", screencastParams, sessionId: session)
    }

    public func stop() async {
        let sessions: [String] = lock.locked {
            generation += 1
            defer { targetId = nil; sessionId = nil; unresponsive = false; kept = [:]; dialogs = [:]; detaching = [:] }
            return (sessionId.map { [$0] } ?? []) + Array(kept.values)
        }
        for session in sessions { await detach(session) }
    }

    private func detach(_ session: String) async {
        _ = try? await client.send("Page.stopScreencast", sessionId: session, timeout: 2)
        _ = try? await client.send("Target.detachFromTarget", ["sessionId": session], timeout: 2)
        lock.locked { _ = sessionTargets.removeValue(forKey: session); _ = ready.remove(session) }
    }

    /// `target` 탭의 대화상자에 답한다(`accept`: 확인·나가기, `text`: prompt 에 넣을 글) — 사람이 본 그 대화상자의 탭으로.
    /// 누른 뒤 보는 탭이 바뀌었어도 다른 탭의 대화상자에 답이 가지 않는다(그 탭이 남겨 둔 연결이면 그리로). 이미 닫혔으면 그렇다고 알린다.
    /// `dialogId`: 사람이 본 대화상자 — 그것이 아직 떠 있을 때 한 번만 답한다.
    /// false = 보내지 못했다(다시 답할 수 있다). 이미 답했거나 그 대화상자가 없어졌으면 true(더 할 일 없음)
    @discardableResult
    public func answerDialog(target: String, dialogId: Int, accept: Bool, text: String? = nil) async -> Bool {
        enum Pick { case send(String), done, unsendable }
        let pick: Pick = lock.locked {
            guard dialogs[target]?.id == dialogId, !answered.contains(dialogId) else { return .done }
            guard let session = targetId == target ? sessionId : kept[target] else { return .unsendable }
            answered.insert(dialogId)
            return .send(session)
        }
        guard case .send(let session) = pick else {
            if case .done = pick { return true }
            return false
        }
        var params: [String: Any] = ["accept": accept]
        if let text { params["promptText"] = text }
        do {
            _ = try await client.send("Page.handleJavaScriptDialog", params, sessionId: session)
            return true
        } catch CDPError.protocolError {
            // "No dialog is showing": 다른 쪽(abx 등)이 먼저 답했다 — 닫힘 알림을 놓쳤어도 지운다
            dialogClosed(target: target)
            return true
        } catch {
            lock.locked { _ = answered.remove(dialogId) } // 닿지 않았다: 다시 누를 수 있게
            return false
        }
    }

    /// `target` 이 보는 탭이면 새로고침한다(누른 뒤 다른 탭으로 옮겼으면 아무것도 하지 않는다). 아무도 답할 수 없는 대화상자가 떠 있어
    /// 멈춘 탭도 이것으로 풀린다(대화상자는 취소로 닫힌다). 다시 답하는지 Page.enable 로 본다.
    public func reload(target: String) async {
        guard let session = lock.locked({ targetId == target ? sessionId : nil }) else { return }
        guard (try? await client.send("Page.reload", sessionId: session)) != nil else { return }
        let answered = (try? await client.send("Page.enable", sessionId: session, timeout: enableTimeout)) != nil
        let changed: Bool = lock.locked {
            if answered { ready.insert(session) }
            guard sessionId == session, unresponsive == answered else { return false }
            unresponsive = !answered
            return true
        }
        if changed { onUnresponsive?(target, !answered) }
    }

    /// 탭이 닫혔거나(targetDestroyed) 그 연결이 끊겼다(detachedFromTarget) — 닫힌 탭은 대화상자 닫힘 알림 없이 사라질 수 있다.
    /// 그 연결로는 더 답할 수 없으니 그 탭의 대화상자·남겨 둔 연결을 잊는다.
    private func forget(_ event: CDPEvent) {
        let result: (target: String, shown: Bool, hadDialog: Bool, wasHung: Bool)? = lock.locked {
            let target: String
            if event.method == "Target.targetDestroyed" {
                guard let t = event.params["targetId"] as? String else { return nil }
                target = t
                ready.subtract(sessionTargets.filter { $0.value == t }.keys)
                sessionTargets = sessionTargets.filter { $0.value != t }
                kept[t] = nil
                detaching[t] = nil
            } else {
                guard let session = event.params["sessionId"] as? String, let t = sessionTargets.removeValue(forKey: session) else { return nil }
                ready.remove(session)
                target = t
                if detaching[t] == session { detaching[t] = nil }
                if kept[t] == session { kept[t] = nil } else if !(targetId == t && sessionId == session) { return nil }
            }
            let shown = targetId == target
            let hadDialog = dialogs.removeValue(forKey: target) != nil
            let wasHung = shown && unresponsive
            if wasHung { unresponsive = false }
            return (target, shown, hadDialog, wasHung)
        }
        guard let result, result.shown else { return }
        if result.hadDialog { onDialog?(nil) }
        if result.wasHung { onUnresponsive?(result.target, false) }
    }

    fileprivate func dialogClosed(target: String) {
        let (shown, park): (Bool, String?) = lock.locked {
            guard dialogs.removeValue(forKey: target) != nil else { return (false, nil) }
            return (targetId == target, kept.removeValue(forKey: target))
        }
        if shown { onDialog?(nil) }
        if let park { Task { await detachOrKeep(park) } } // 그새 같은 탭에 새 대화상자가 떴으면 남겨 둔다
    }

    /// 지금 보는 탭에 명령을 보낸다(입력 이벤트처럼 순서만 지키면 되는 것). 보는 탭이 없으면 버린다.
    /// 같은 연결로 보낸 요청은 보낸 순서대로 처리된다.
    public func post(_ method: String, _ params: [String: Any]) {
        guard let session = lock.locked({ sessionId }) else { return }
        client.post(method, params, sessionId: session)
    }

    /// 지금 보는 탭에서 식을 계산한다(값으로 받음). 못 하면 nil.
    public func evaluate(_ expression: String) async -> Any? {
        // 막힌 탭에는 보내지 않는다(대화상자가 닫히기 전엔 답이 오지 않는다 — 크기 맞추기가 writer 자리를 쥔 채 기다리게 된다)
        guard let session = lock.locked({ blocked ? nil : sessionId }),
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
        // Chrome 내부 페이지(chrome://newtab 등)는 보여 줄 탭이 아니다(abx 도 탭으로 치지 않는다)
        return infos.filter { ($0["type"] as? String) == "page" && !BrowserTabs.internalPage($0["url"] as? String ?? "") }
            .compactMap { $0["targetId"] as? String }
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
        if event.method == "Page.javascriptDialogOpening" || event.method == "Page.javascriptDialogClosed" {
            return handleDialog(event)
        }
        if event.method == "Target.targetDestroyed" || event.method == "Target.detachedFromTarget" {
            forget(event) // 다른 쪽(feed)도 이 알림을 쓴다
            return false
        }
        guard event.method == "Page.screencastFrame" else {
            // 응답 없던 탭에서 렌더러가 보내는 Page 알림(이동·읽기)이 왔다: 막혔던 렌더러가 풀려(다른 쪽이 대화상자에 답했거나
            // 이동) 미뤄진 Page.enable 이 돌았다. screencast 알림(screencastVisibilityChanged 등)은 브라우저가 보내 막혀도 온다
            if Self.rendererEvents.contains(event.method), let session = event.sessionId {
                let recovered: String? = lock.locked {
                    guard unresponsive, session == sessionId else { return nil }
                    unresponsive = false
                    return targetId
                }
                if let recovered { onUnresponsive?(recovered, false) }
            }
            return false
        }
        let (current, target): (String?, String?) = lock.locked { (sessionId, targetId) }
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
        onFrame?(ScreencastFrame(jpeg: jpeg, viewport: CGSize(width: width, height: height), timestamp: time, targetId: target))
        return true
    }
}

extension ScreencastStream {
    /// 대화상자 알림: 이 스트림이 붙인 연결의 것만(보는 탭, 남겨 둔 탭)
    fileprivate func handleDialog(_ event: CDPEvent) -> Bool {
        guard let session = event.sessionId, let target = lock.locked({ sessionTargets[session] }) else { return false }
        if event.method == "Page.javascriptDialogClosed" {
            dialogClosed(target: target)
            return true
        }
        let p = event.params
        let id = Self.newDialogId()
        let dialog = PageDialog(id: id, targetId: target, type: p["type"] as? String ?? "alert", message: p["message"] as? String ?? "",
                                defaultPrompt: p["defaultPrompt"] as? String ?? "", url: p["url"] as? String ?? "")
        let shown: Bool = lock.locked {
            dialogs[target] = dialog
            return targetId == target
        }
        if shown { onDialog?(dialog) }
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
