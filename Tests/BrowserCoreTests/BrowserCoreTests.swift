import XCTest
@testable import BrowserCore

/// 보낸 글을 모아 두고, 시험이 응답·이벤트를 넣어 주는 가짜 통로
final class FakeTransport: CDPTransport {
    var onMessage: ((String) -> Void)?
    var onClose: ((Error?) -> Void)?
    private let lock = NSLock()
    private var _sent: [[String: Any]] = []
    var sent: [[String: Any]] { lock.locked { _sent } }

    func send(_ text: String) {
        let message = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        lock.locked { _sent.append(message) }
    }
    func close() { onClose?(nil) }

    func reply(_ id: Int, _ result: [String: Any]) { push(["id": id, "result": result]) }
    func push(_ message: [String: Any]) {
        onMessage?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
    /// 보낸 요청이 n 개가 될 때까지 기다린다
    func waitSent(_ n: Int) async {
        for _ in 0..<200 where sent.count < n { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

final class CDPClientTests: XCTestCase {
    func testRequestsArePairedWithResponsesById() async throws {
        let t = FakeTransport()
        let client = CDPClient(transport: t)
        async let a = client.send("Target.getTargets")
        async let b = client.send("Page.enable", sessionId: "S1")
        await t.waitSent(2)
        let ids = t.sent.map { $0["id"] as! Int }
        XCTAssertEqual(t.sent.first(where: { $0["method"] as? String == "Page.enable" })?["sessionId"] as? String, "S1")
        // 거꾸로 답해도 짝이 맞는다
        let enable = t.sent.first(where: { $0["method"] as? String == "Page.enable" })!["id"] as! Int
        t.reply(enable, ["ok": true])
        t.reply(ids.first(where: { $0 != enable })!, ["targetInfos": []])
        let (ra, rb) = try await (a, b)
        XCTAssertNotNil(ra["targetInfos"])
        XCTAssertEqual(rb["ok"] as? Bool, true)
    }

    func testProtocolErrorAndClose() async {
        let t = FakeTransport()
        let client = CDPClient(transport: t)
        async let failing = client.send("Nope.method")
        async let waiting = client.send("Page.enable")
        await t.waitSent(2)
        let nope = t.sent.first(where: { $0["method"] as? String == "Nope.method" })!["id"] as! Int
        t.push(["id": nope, "error": ["message": "not found"]])
        do { _ = try await failing; XCTFail() } catch { XCTAssertEqual(error as? CDPError, .protocolError("not found")) }
        t.close()
        do { _ = try await waiting; XCTFail() } catch { XCTAssertEqual(error as? CDPError, .closed) }
        do { _ = try await client.send("After.close"); XCTFail() } catch { XCTAssertEqual(error as? CDPError, .closed) }
    }

    func testTimeout() async {
        let client = CDPClient(transport: FakeTransport())
        do { _ = try await client.send("Slow.call", timeout: 0.05); XCTFail() } catch {
            XCTAssertEqual(error as? CDPError, .timeout("Slow.call"))
        }
    }

    func testEventsCarryTheirSession() {
        let t = FakeTransport()
        let client = CDPClient(transport: t)
        var got: CDPEvent?
        client.onEvent = { got = $0 }
        t.push(["method": "Target.targetCreated", "params": ["targetInfo": ["type": "page"]], "sessionId": "S9"])
        XCTAssertEqual(got?.method, "Target.targetCreated")
        XCTAssertEqual(got?.sessionId, "S9")
    }
}

final class ScreencastTests: XCTestCase {
    func frameEvent(session: String, ack: Int) -> CDPEvent {
        CDPEvent(method: "Page.screencastFrame", params: [
            "data": Data([0xFF, 0xD8, 0xFF]).base64EncodedString(), "sessionId": ack,
            "metadata": ["deviceWidth": 1280, "deviceHeight": 800, "timestamp": 1.5],
        ], sessionId: session)
    }

    func testShowAttachesStartsAndAcksOnlyItsOwnFrames() async throws {
        let t = FakeTransport()
        let client = CDPClient(transport: t)
        let stream = ScreencastStream(client: client)
        var frames: [ScreencastFrame] = []
        stream.onFrame = { frames.append($0) }
        let showing = Task { try await stream.show(target: "T1") }
        await t.waitSent(1)
        t.reply(t.sent[0]["id"] as! Int, ["sessionId": "S1"])
        await t.waitSent(2)
        t.reply(t.sent[1]["id"] as! Int, [:]) // Page.enable
        await t.waitSent(3)
        XCTAssertEqual(t.sent[2]["method"] as? String, "Page.startScreencast")
        XCTAssertEqual((t.sent[2]["params"] as? [String: Any])?["format"] as? String, "jpeg")
        t.reply(t.sent[2]["id"] as! Int, [:])
        try await showing.value

        XCTAssertFalse(stream.handle(frameEvent(session: "OTHER", ack: 1)))
        XCTAssertTrue(stream.handle(frameEvent(session: "S1", ack: 7)))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].viewport, CGSize(width: 1280, height: 800))
        await t.waitSent(4)
        let ack = t.sent[3]
        XCTAssertEqual(ack["method"] as? String, "Page.screencastFrameAck")
        XCTAssertEqual((ack["params"] as? [String: Any])?["sessionId"] as? Int, 7) // 정수 ack id
        XCTAssertEqual(ack["sessionId"] as? String, "S1") // 문자열 CDP session
    }
}

final class ScreencastChoiceTests: XCTestCase {
    func testChoosesWantedThenCurrentThenFirst() {
        XCTAssertEqual(ScreencastStream.choose(wanted: "B", current: "A", open: ["A", "B"]), "B")
        // 기록된 탭이 이미 닫힘 → 보던 탭 유지(떼었다 붙이지 않음)
        XCTAssertEqual(ScreencastStream.choose(wanted: "GONE", current: "A", open: ["A", "B"]), "A")
        // 막 띄워 기록이 없음 → 첫 페이지
        XCTAssertEqual(ScreencastStream.choose(wanted: nil, current: nil, open: ["A", "B"]), "A")
        XCTAssertNil(ScreencastStream.choose(wanted: "X", current: nil, open: []))
    }

    func testStopDuringAttachDetachesTheLateSession() async throws {
        let t = FakeTransport()
        let client = CDPClient(transport: t)
        let stream = ScreencastStream(client: client)
        let showing = Task { try await stream.show(target: "T1") }
        await t.waitSent(1) // attachToTarget 보냄
        await stream.stop() // 응답 전에 멈춤(세대가 바뀜)
        t.reply(t.sent[0]["id"] as! Int, ["sessionId": "LATE"])
        try await showing.value
        await t.waitSent(2)
        // 늦게 온 연결은 설치하지 않고 뗀다: screencast 를 시작하지 않는다
        let methods = t.sent.map { $0["method"] as? String }
        XCTAssertFalse(methods.contains("Page.startScreencast"))
        XCTAssertTrue(methods.contains("Page.stopScreencast"))
        XCTAssertNil(stream.currentTarget)
    }
}

final class ViewportTests: XCTestCase {
    func testLetterboxAndMapping() {
        // 1280×800 페이지를 1000×1000 칸에: 가로에 맞춰 1000×625, 위아래 여백 187.5
        let v = ViewportTransform(bounds: CGSize(width: 1000, height: 1000), viewport: CGSize(width: 1280, height: 800))
        XCTAssertEqual(v.imageRect, CGRect(x: 0, y: 187.5, width: 1000, height: 625))
        XCTAssertNil(v.cssPoint(CGPoint(x: 500, y: 100))) // 여백
        XCTAssertEqual(v.cssPoint(CGPoint(x: 500, y: 500)), CGPoint(x: 640, y: 400)) // 가운데
        XCTAssertEqual(v.cssPoint(CGPoint(x: 0, y: 187.5)), CGPoint(x: 0, y: 0))
    }

    func testEmptySizes() {
        XCTAssertEqual(ViewportTransform(bounds: .zero, viewport: CGSize(width: 10, height: 10)).imageRect, .zero)
        XCTAssertNil(ViewportTransform(bounds: CGSize(width: 10, height: 10), viewport: .zero).cssPoint(.zero))
    }

    func testLatestFrameQueueKeepsOnlyTheNewest() {
        var q = LatestFrameQueue<Int>()
        XCTAssertEqual(q.offer(1), 1) // 바로 처리
        XCTAssertNil(q.offer(2))
        XCTAssertNil(q.offer(3)) // 2 는 버림
        XCTAssertEqual(q.dropped, 1)
        XCTAssertEqual(q.finish(), 3)
        XCTAssertNil(q.finish())
        XCTAssertFalse(q.busy)
        XCTAssertEqual(q.offer(4), 4)
    }
}

final class AbxStatusTests: XCTestCase {
    func testDecodesAbxStatusJSON() throws {
        // abx `status --json` 의 실제 모양
        let json = """
        {"session":"ad-1","running":true,"headless":true,"cdpUrl":"ws://127.0.0.1:5000/devtools/browser/x","control":"switching",
         "handoff":"log in please","tabs":[{"id":"t1","targetId":"AB","url":"https://a","title":"A","active":false},
         {"id":"t2","targetId":"CD","url":"https://b","title":"B","active":true}]}
        """
        let s = try AbxStatus.decode(Data(json.utf8))
        XCTAssertEqual(s.control, .switching)
        XCTAssertEqual(s.activeTab?.targetId, "CD")
        let idle = try AbxStatus.decode(Data(#"{"session":"x","running":false,"headless":null,"cdpUrl":null,"control":"idle","handoff":null,"tabs":[]}"#.utf8))
        XCTAssertNil(idle.activeTab)
        XCTAssertNil(idle.headless)
    }

    func testSessionEnvironment() {
        let s = AbxSession(name: "ad-1", socketDir: "/tmp/s", stateDir: "/tmp/st", profileDir: "/tmp/p")
        XCTAssertEqual(s.environment["ABX_STATE_DIR"], "/tmp/st")
        XCTAssertEqual(s.environment["ABX_SESSION"], "ad-1")
    }
}
