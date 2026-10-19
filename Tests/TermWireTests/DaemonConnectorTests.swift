import Foundation
@testable import TermWire
import XCTest

/// 데몬에 붙기(없으면 띄우기)의 순서와 다시 붙기 간격. 소켓·launchctl·posix_spawn·시계는 가짜.
final class DaemonConnectorTests: XCTestCase {
    /// 가짜 환경: 시계는 sleep 할 때만 간다. 띄우면 정한 시간 뒤 소켓이 받는다.
    final class FakeEnv: DaemonConnectEnvironment {
        var clock = Date(timeIntervalSince1970: 1_000)
        var start: Date
        /// 이 시각부터 소켓이 받는다(nil = 데몬 없음)
        var socketReadyAt: Date?
        /// launchViaLaunchd 가 차례로 돌려줄 결과(다 쓰면 bootstrapped)
        var launchdOutcomes: [DaemonLaunchAgent.Outcome] = []
        /// launchd 로 올린 뒤 데몬이 뜨기까지(nil = 끝내 안 뜸)
        var launchdDaemonAfter: TimeInterval?
        var directDaemonAfter: TimeInterval?
        var directSpawns = true
        var existingLaunchd: Bool? = true
        var directOnly = false
        var calls: [String] = []
        var logs: [String] = []

        init() { start = clock }

        var elapsed: TimeInterval { clock.timeIntervalSince(start) }

        func connect() -> Int32? {
            if let at = socketReadyAt, clock >= at { return 42 }
            return nil
        }

        func launchViaLaunchd() -> DaemonLaunchAgent.Outcome {
            calls.append("launchd")
            let outcome = launchdOutcomes.isEmpty ? .bootstrapped(label: "dev.agentdeck.daemon.test") : launchdOutcomes.removeFirst()
            if case .failed = outcome { return outcome }
            if socketReadyAt == nil, let after = launchdDaemonAfter { socketReadyAt = clock.addingTimeInterval(after) }
            return outcome
        }

        func spawnDirect() -> Bool {
            calls.append("direct")
            guard directSpawns else { return false }
            if socketReadyAt == nil, let after = directDaemonAfter { socketReadyAt = clock.addingTimeInterval(after) }
            return true
        }

        func existingIsLaunchd() -> Bool? {
            calls.append("check")
            return existingLaunchd
        }

        func now() -> Date { clock }
        func sleep(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }
        func log(_ message: String) { logs.append(message) }
    }

    // MARK: 붙기 순서

    func testExistingDaemonIsUsedWithoutLaunching() {
        let env = FakeEnv()
        env.socketReadyAt = env.clock
        XCTAssertEqual(DaemonConnector.run(launch: true, env: env), .connected(fd: 42, route: .existing))
        XCTAssertEqual(env.calls, ["check"])
        XCTAssertEqual(env.elapsed, 0)
    }

    func testExistingDaemonOutsideLaunchdIsLimited() {
        let env = FakeEnv()
        env.socketReadyAt = env.clock
        env.existingLaunchd = false
        let result = DaemonConnector.run(launch: true, env: env)
        XCTAssertEqual(result, .connected(fd: 42, route: .existingDirect))
        XCTAssertTrue(DaemonConnector.Route.existingDirect.limited)
        // launchctl 이 답하지 않으면(모름) 경고하지 않는다
        env.existingLaunchd = nil
        XCTAssertEqual(DaemonConnector.run(launch: true, env: env), .connected(fd: 42, route: .existing))
    }

    /// 예전 데몬에 붙는 동안(launch=false): 띄우지도, launchd 를 묻지도 않는다(예전 동작 그대로)
    func testLegacyAttachNeverLaunches() {
        let env = FakeEnv()
        env.socketReadyAt = env.clock
        XCTAssertEqual(DaemonConnector.run(launch: false, env: env), .connected(fd: 42, route: .existing))
        env.socketReadyAt = nil
        guard case .failed = DaemonConnector.run(launch: false, env: env) else { return XCTFail("붙지 못하면 실패") }
        XCTAssertEqual(env.calls, [])
        XCTAssertEqual(env.elapsed, 0, "기다리지 않는다")
    }

    func testLaunchdOk() {
        let env = FakeEnv()
        env.launchdDaemonAfter = 0.2
        XCTAssertEqual(DaemonConnector.run(launch: true, env: env), .connected(fd: 42, route: .launchd))
        XCTAssertEqual(env.calls, ["launchd"])
        XCTAssertLessThan(env.elapsed, 0.5)
        XCTAssertTrue(env.logs.contains { $0.contains("launchd 작업으로 띄움") })
    }

    /// 3초 안에 안 뜸(막 끝나던 작업이 내려가는 중) → launchd 로 한 번 더 → 뜸. 예전 방식은 쓰지 않는다.
    func testLaunchdSlowThenOk() {
        let env = FakeEnv()
        env.launchdDaemonAfter = 4
        env.launchdOutcomes = [.bootstrapped(label: "x"), .alreadyRunning(label: "x", pid: 77)]
        XCTAssertEqual(DaemonConnector.run(launch: true, env: env), .connected(fd: 42, route: .launchd))
        XCTAssertEqual(env.calls, ["launchd", "launchd"])
        XCTAssertGreaterThanOrEqual(env.elapsed, 4)
        XCTAssertLessThan(env.elapsed, 4.2)
    }

    /// launchctl 실패 → 바로 예전 방식(한 번만) → 세션 유지 제한 경고
    func testLaunchdFailsFallsBackToDirectAndWarns() {
        let env = FakeEnv()
        env.launchdOutcomes = [.failed("bootstrap 5: Input/output error")]
        env.directDaemonAfter = 0.1
        let result = DaemonConnector.run(launch: true, env: env)
        XCTAssertEqual(result, .connected(fd: 42, route: .direct))
        XCTAssertEqual(env.calls, ["launchd", "direct"])
        XCTAssertTrue(env.logs.contains { $0.contains("posix_spawn") && $0.contains("bootstrap 5") })
        XCTAssertTrue(env.logs.contains { $0.contains("강제 종료하면 세션이 함께 끝날 수 있음") })

        var link = DaemonLink()
        link.begin(now: env.clock)
        XCTAssertNil(link.finish(result, now: env.clock))
        XCTAssertTrue(link.limited)
        XCTAssertTrue(link.isConnected)
    }

    /// launchd 작업은 올라갔지만 데몬이 끝내 안 뜸 → 한 번 더 → 예전 방식
    func testLaunchdNeverStartsThenDirect() {
        let env = FakeEnv()
        env.directDaemonAfter = 0.1
        XCTAssertEqual(DaemonConnector.run(launch: true, env: env), .connected(fd: 42, route: .direct))
        XCTAssertEqual(env.calls, ["launchd", "launchd", "direct"])
    }

    func testDirectOnlyForTests() {
        let env = FakeEnv()
        env.directOnly = true
        env.directDaemonAfter = 0.1
        XCTAssertEqual(DaemonConnector.run(launch: true, env: env), .connected(fd: 42, route: .direct))
        XCTAssertEqual(env.calls, ["direct"])
    }

    /// 다 실패: 정해진 시간 안에 끝나고(무한히 기다리지 않음) 예전 방식은 한 번만, 결과는 실패
    func testAllFail() {
        let env = FakeEnv()
        guard case .failed = DaemonConnector.run(launch: true, env: env) else { return XCTFail() }
        XCTAssertEqual(env.calls, ["launchd", "launchd", "direct"])
        XCTAssertLessThan(env.elapsed, 3 * DaemonConnector.waitTimeout + 0.5)

        let spawnFails = FakeEnv()
        spawnFails.launchdOutcomes = [.failed("launchctl 시간 초과")]
        spawnFails.directSpawns = false
        guard case .failed = DaemonConnector.run(launch: true, env: spawnFails) else { return XCTFail() }
        XCTAssertEqual(spawnFails.calls, ["launchd", "direct"])
        XCTAssertEqual(spawnFails.elapsed, 0, "띄우지 못했으면 기다리지 않는다")
    }

    // MARK: 연결 상태·다시 시도 간격

    func testAllFailGivesErrorStateAndBackoffSchedule() {
        let t0 = Date(timeIntervalSince1970: 0)
        var link = DaemonLink()
        var now = t0
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            XCTAssertTrue(link.begin(now: now))
            XCTAssertFalse(link.begin(now: now), "붙는 중에는 두 번 시작하지 않는다")
            XCTAssertFalse(link.canAttempt(now: now, force: true))
            let delay = link.finish(.failed("데몬이 뜨지 않았습니다"), now: now)!
            delays.append(delay)
            guard case .failed(let message, let retryAt) = link.phase else { return XCTFail() }
            XCTAssertEqual(message, "데몬이 뜨지 않았습니다")
            XCTAssertEqual(retryAt, now.addingTimeInterval(delay))
            // 2초 새로 고침이 그 전에 와도 건너뛴다. 사용자가 새 화면을 열면(force) 바로.
            XCTAssertFalse(link.canAttempt(now: now.addingTimeInterval(delay - 0.1)))
            XCTAssertTrue(link.canAttempt(now: now.addingTimeInterval(delay - 0.1), force: true))
            now = retryAt
            XCTAssertTrue(link.canAttempt(now: now))
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(link.failures, 8)

        // 붙으면 처음부터
        link.begin(now: now)
        link.finish(.connected(fd: 3, route: .launchd), now: now)
        XCTAssertEqual(link.phase, .connected)
        XCTAssertEqual(link.failures, 0)
        XCTAssertFalse(link.limited)
        XCTAssertFalse(link.canAttempt(now: now, force: true))
        // 끊기면 다음 새로 고침에 바로(기다리지 않음)
        link.disconnected()
        XCTAssertEqual(link.phase, .idle)
        XCTAssertTrue(link.canAttempt(now: now))
        link.begin(now: now)
        XCTAssertEqual(link.finish(.failed("x"), now: now), 1)
    }

    func testResetDropsInFlightAttempt() {
        var link = DaemonLink()
        link.begin(now: Date())
        link.reset()
        XCTAssertEqual(link.phase, .idle)
        XCTAssertTrue(link.begin(now: Date()))
    }

    // MARK: launchctl 시간 제한

    /// 답하지 않는 자식은 시간이 지나면 그 자식만 끝내고 실패(-2)로 돌려준다
    func testRunTimesOutAndKillsOnlyItsChild() {
        let started = Date()
        let result = DaemonLaunchAgent.run("/bin/sleep", ["5"], timeout: 0.3)
        XCTAssertEqual(result.status, -2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        let echo = DaemonLaunchAgent.run("/bin/echo", ["hi"], timeout: 3)
        XCTAssertEqual(echo.status, 0)
        XCTAssertEqual(echo.output, "hi\n")
    }
}
