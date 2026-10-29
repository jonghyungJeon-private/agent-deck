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

    func testPostKeepsCallOrder() {
        let t = FakeTransport()
        let client = CDPClient(transport: t)
        for i in 0..<50 { client.post("Input.insertText", ["text": "\(i)"], sessionId: "S") }
        XCTAssertEqual(t.sent.compactMap { ($0["params"] as? [String: Any])?["text"] as? String }, (0..<50).map(String.init))
        t.reply(t.sent[0]["id"] as! Int, [:]) // 짝 없는 응답은 조용히 버린다
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

final class BrowserInputTests: XCTestCase {
    func testMouseAndDrag() {
        let down = BrowserInput.mouse(.pressed, at: CGPoint(x: 10, y: 20), button: .left, clickCount: 2, modifiers: .shift)
        XCTAssertEqual(down["type"] as? String, "mousePressed")
        XCTAssertEqual(down["buttons"] as? Int, 1)
        XCTAssertEqual(down["clickCount"] as? Int, 2)
        XCTAssertEqual(down["modifiers"] as? Int, 8)
        let drag = BrowserInput.mouse(.moved, at: .zero, button: .left)
        XCTAssertEqual(drag["buttons"] as? Int, 1) // 누른 채 움직임
        XCTAssertEqual(BrowserInput.mouse(.released, at: .zero, button: .left)["buttons"] as? Int, 0)
    }

    func testWheelFlipsSignAndScalesLines() {
        // 트랙패드(정밀)로 내용을 위로 올림(+) = 아래로 스크롤 → CDP delta 는 −
        let precise = BrowserInput.wheel(at: .zero, scrollingDeltaX: 0, scrollingDeltaY: 12, precise: true)
        XCTAssertEqual(precise["deltaY"] as? CGFloat, -12)
        let lines = BrowserInput.wheel(at: .zero, scrollingDeltaX: 0, scrollingDeltaY: -1, precise: false)
        XCTAssertEqual(lines["deltaY"] as? CGFloat, 40)
    }

    func testEditingSelectors() {
        let enter = BrowserInput.command(selector: "insertNewline:")!
        XCTAssertEqual(enter.key, BrowserInput.enter)
        XCTAssertEqual(enter.commands, []) // 폼 제출은 DOM 키로
        let word = BrowserInput.command(selector: "deleteWordBackward:")!
        XCTAssertEqual(word.key, BrowserInput.backspace)
        XCTAssertEqual(word.modifiers, .alt)
        XCTAssertEqual(word.commands, ["deleteWordBackward"])
        let select = BrowserInput.command(selector: "moveWordLeftAndModifySelection:")!
        XCTAssertEqual(select.key, BrowserInput.left)
        XCTAssertEqual(select.modifiers, [.alt, .shift])
        XCTAssertEqual(select.commands, ["moveWordLeftAndModifySelection"])
        XCTAssertNil(BrowserInput.command(selector: "noSuchCommand:"))
        // 페이지·스크롤 키는 Chrome 편집 명령 이름이 달라 키 동작에만 맡긴다
        XCTAssertEqual(BrowserInput.command(selector: "pageUpAndModifySelection:")?.commands, [])
        XCTAssertEqual(BrowserInput.command(selector: "pageUpAndModifySelection:")?.modifiers, .shift)
    }

    func testPressAndCharacters() {
        let events = BrowserInput.press(BrowserInput.enter)
        XCTAssertEqual(events.map { $0["type"] as? String }, ["keyDown", "keyUp"])
        XCTAssertEqual(events[0]["text"] as? String, "\r")
        XCTAssertEqual(BrowserInput.press(BrowserInput.left)[0]["type"] as? String, "rawKeyDown")
        let a = BrowserInput.character("a")!
        XCTAssertEqual(a[0]["text"] as? String, "a")
        XCTAssertEqual(a[0]["windowsVirtualKeyCode"] as? Int, 65)
        XCTAssertNil(BrowserInput.character("한")) // 입력기 글자는 insertText
        // Shift+A: 글자는 "A", Shift 는 그대로, 자리(code)는 KeyA
        let shiftA = BrowserInput.character("A", keyCode: 0, modifiers: .shift)!
        XCTAssertEqual(shiftA[0]["key"] as? String, "A")
        XCTAssertEqual(shiftA[0]["code"] as? String, "KeyA")
        XCTAssertEqual(shiftA[0]["modifiers"] as? Int, 8)
        // 기호: Shift+/ = "?" 는 Slash 자리, VK 191
        let question = BrowserInput.character("?", keyCode: 44, modifiers: .shift)!
        XCTAssertEqual(question[0]["code"] as? String, "Slash")
        XCTAssertEqual(question[0]["windowsVirtualKeyCode"] as? Int, 191)
        XCTAssertNil(BrowserInput.character("ab"))
        let all = BrowserInput.shortcut("selectAll")!
        XCTAssertEqual(all[0]["commands"] as? [String], ["selectAll"])
        XCTAssertEqual(all[0]["modifiers"] as? Int, 4)
    }
}

final class AbxStateReaderTests: XCTestCase {
    private var dir: URL!
    private var session: AbxSession!

    override func setUpWithError() throws {
        // 소켓 경로 한도 때문에 짧은 임시 경로
        dir = URL(fileURLWithPath: "/tmp/abxr-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("state"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("profile"), withIntermediateDirectories: true)
        session = AbxSession(name: "s1", socketDir: dir.path, stateDir: dir.appendingPathComponent("state").path,
                             profileDir: dir.appendingPathComponent("profile").path)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ text: String, state: Bool = false) throws {
        try text.write(to: (state ? dir.appendingPathComponent("state") : dir).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 연결을 받는 유닉스 소켓(엔진 대신)
    private func listen(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        Darwin.listen(fd, 4)
        return fd
    }

    func testNothingRunning() {
        let s = AbxStateReader().status(session)
        XCTAssertFalse(s.running)
        XCTAssertNil(s.cdpUrl)
        XCTAssertEqual(s.control, .idle)
        XCTAssertEqual(s.tabs, [])
    }

    func testRunningWithCdpTabsAndAgentLock() throws {
        let server = listen(dir.appendingPathComponent("s1.sock").path)
        defer { close(server) }
        try write("s1.launch.json", #"{"headed":false,"profileDir":"\#(dir.appendingPathComponent("profile").path)"}"#)
        try "5123\n/devtools/browser/abc\n".write(to: dir.appendingPathComponent("profile/DevToolsActivePort"), atomically: true, encoding: .utf8)
        try write("s1.tabs.json", #"[{"id":"t1","targetId":"T","url":"https://a","title":"A","active":true}]"#, state: true)
        try write("s1.lock.sock", "")
        try write("s1.lock.pid", "\(getpid())")
        let s = AbxStateReader().status(session)
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.headless, true)
        XCTAssertEqual(s.cdpUrl, "ws://127.0.0.1:5123/devtools/browser/abc")
        XCTAssertEqual(s.activeTab?.targetId, "T")
        XCTAssertEqual(s.control, .agent)
    }

    func testStaleFilesAreNotLife() throws {
        try write("s1.sock", "") // 서버 없이 남은 소켓 자리
        try write("s1.lock.sock", "")
        try write("s1.lock.pid", "999999") // 죽은 pid
        let s = AbxStateReader().status(session)
        XCTAssertFalse(s.running)
        XCTAssertEqual(s.control, .idle)
    }

    func testHandoffAndSwitching() throws {
        try write("s1.handoff", "로그인해 주세요", state: true)
        XCTAssertEqual(AbxStateReader().status(session).control, .user)
        XCTAssertEqual(AbxStateReader().status(session).handoff, "로그인해 주세요")
        try write("s1.writer", #"{"pid":\#(getpid()),"token":"x"}"#, state: true) // 아직 동작 중인 writer
        XCTAssertEqual(AbxStateReader().status(session).control, .switching)
    }
}

final class AbxWriterLeaseTests: XCTestCase {
    func testOneHolderAtATimeAndStaleReclaim() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lease-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let first = try XCTUnwrap(AbxWriterLease.acquire(stateDir: dir, session: "s", wait: 0))
        XCTAssertNil(AbxWriterLease.acquire(stateDir: dir, session: "s", wait: 0.1)) // 잡혀 있음
        // abx 가 읽는 모양: {"pid":…,"token":…}
        let data = try XCTUnwrap(FileManager.default.contents(atPath: dir + "/s.writer"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["pid"] as? NSNumber)?.int32Value, getpid())
        first.release()
        let second = try XCTUnwrap(AbxWriterLease.acquire(stateDir: dir, session: "s", wait: 0))
        second.release()
        // 죽은 주인의 자리는 되찾는다
        try #"{"pid":999999,"token":"dead"}"#.write(toFile: dir + "/s.writer", atomically: true, encoding: .utf8)
        let third = try XCTUnwrap(AbxWriterLease.acquire(stateDir: dir, session: "s", wait: 0))
        third.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/s.writer"))
    }
}

final class AbxRunnerSkillTests: XCTestCase {
    /// 가짜 abx: `skill` 을 알면 스킬을, 모르면(예전 판) 브라우저를 띄우는 흉내 — 단 ABX_AUTOSTART=0 이면 띄우지 않고 실패
    func fakeAbx(knowsSkill: Bool) throws -> (AbxRunner, launched: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let launched = dir.appendingPathComponent("launched").path
        let script = dir.appendingPathComponent("abx")
        try """
            #!/bin/sh
            if [ "$1" = skill ] && [ \(knowsSkill ? 1 : 0) = 1 ]; then printf -- '---\\nname: abx\\n---\\n# abx'; exit 0; fi
            [ "$ABX_AUTOSTART" = 0 ] && { echo "error: browser is not running"; exit 1; }
            touch "\(launched)"; exit 1
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (AbxRunner(executable: script), launched)
    }

    func testSkillFromNewAbx() throws {
        let (runner, _) = try fakeAbx(knowsSkill: true)
        XCTAssertEqual(try runner.skill(), "---\nname: abx\n---\n# abx")
    }

    func testOldAbxIsAskedWithoutStartingABrowser() throws {
        let (runner, launched) = try fakeAbx(knowsSkill: false)
        XCTAssertNil(try runner.skill())
        XCTAssertFalse(FileManager.default.fileExists(atPath: launched))
    }
}

final class BrowserInstallerTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// 가짜 브라우저 zip: --user-data-dir 에 DevToolsActivePort 를 쓰고 기다리는(떠 있는) 스크립트
    func fakeRelease(writesPort: Bool = true) throws -> BrowserRelease {
        let src = dir.appendingPathComponent("src/browser/bin")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let script = src.appendingPathComponent("chrome")
        try """
            #!/bin/sh
            for a in "$@"; do case "$a" in --user-data-dir=*) d="${a#--user-data-dir=}";; esac; done
            \(writesPort ? "mkdir -p \"$d\"; printf '9222\\n/devtools/browser/x\\n' > \"$d/DevToolsActivePort\"" : "exit 3")
            exec sleep 30
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let zip = dir.appendingPathComponent("browser.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", src.deletingLastPathComponent().path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        return BrowserRelease(version: "1.2.3", url: zip, sha256: try BrowserInstaller.sha256(of: zip), executable: "browser/bin/chrome")
    }

    func testInstallsVerifiesAndMarks() async throws {
        let installer = BrowserInstaller(dir: dir.appendingPathComponent("browsers"), release: try fakeRelease())
        XCTAssertEqual(installer.state(), .missing)
        try await installer.install()
        XCTAssertEqual(installer.state(), .installed)
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.versionDir.appendingPathComponent("abx-browser.json"))) as? [String: String]
        XCTAssertEqual(marker?["executable"], "browser/bin/chrome")
        XCTAssertEqual(marker?["version"], "1.2.3")
        // 임시 파일이 남지 않는다(abx 가 보는 폴더에는 버전 폴더와 잠금 파일만)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installer.dir.path).sorted(), [".install.lock", "1.2.3"])
    }

    func testWrongHashOrBrokenBrowserLeavesNothing() async throws {
        var release = try fakeRelease()
        release.sha256 = String(repeating: "0", count: 64)
        let installer = BrowserInstaller(dir: dir.appendingPathComponent("browsers"), release: release)
        do { try await installer.install(); XCTFail("hash") } catch let error as BrowserInstaller.InstallError {
            guard case .checksum = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installer.dir.path), [".install.lock"])

        try FileManager.default.removeItem(at: dir.appendingPathComponent("src"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("browser.zip"))
        let broken = BrowserInstaller(dir: dir.appendingPathComponent("browsers"), release: try fakeRelease(writesPort: false))
        do { try await broken.install(); XCTFail("launch") } catch let error as BrowserInstaller.InstallError {
            guard case .launch = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(broken.state(), .missing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: broken.dir.path), [".install.lock"])
    }

    func testASecondInstallerWaitsItsTurn() async throws {
        let installer = BrowserInstaller(dir: dir.appendingPathComponent("browsers"), release: try fakeRelease())
        try FileManager.default.createDirectory(at: installer.dir, withIntermediateDirectories: true)
        // 다른 앱이 받는 중(잠금을 쥐고 있음)
        let held = open(installer.dir.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(held, LOCK_EX), 0)
        do { try await installer.install(); XCTFail("busy") } catch let error as BrowserInstaller.InstallError {
            XCTAssertEqual(error, .busy)
        }
        close(held)
        try await installer.install()
        XCTAssertEqual(installer.state(), .installed)
    }

    func testReplacesABrokenUnverifiedCopy() async throws {
        let installer = BrowserInstaller(dir: dir.appendingPathComponent("browsers"), release: try fakeRelease())
        let bin = installer.executableURL
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.path, contents: Data("#!/bin/sh\nexit 1\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(installer.state(), .unverified)
        try await installer.install()
        XCTAssertEqual(installer.state(), .installed)
        XCTAssertNotEqual(try String(contentsOf: bin, encoding: .utf8), "#!/bin/sh\nexit 1\n")
    }

    func testAdoptsAnUnverifiedCopyByLaunchingIt() async throws {
        let release = try fakeRelease()
        let installer = BrowserInstaller(dir: dir.appendingPathComponent("browsers"), release: release)
        // 손수 푼 것(표식 없음)
        let bin = installer.executableURL
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir.appendingPathComponent("src/browser/bin/chrome"), to: bin)
        XCTAssertEqual(installer.state(), .unverified)
        try await installer.install()
        XCTAssertEqual(installer.state(), .installed)
    }
}
