import Foundation

/// 데몬에 붙기(없으면 띄우기)의 순서. 소켓·launchctl·posix_spawn·시계는 밖에서 넣는다(시험은 가짜로).
/// 앱은 이것을 메인 스레드 밖에서 돌린다(launchctl·기다리기가 몇 초 걸릴 수 있다).
public protocol DaemonConnectEnvironment {
    /// 소켓에 붙어 본다(바로 돌아온다)
    func connect() -> Int32?
    /// launchd 작업으로 띄운다(DaemonLaunchAgent.launch)
    func launchViaLaunchd() -> DaemonLaunchAgent.Outcome
    /// 예전 방식(posix_spawn + setsid). 띄웠으면 true
    func spawnDirect() -> Bool
    /// 이미 돌던 데몬이 launchd 작업인지(모르면 nil)
    func existingIsLaunchd() -> Bool?
    /// AGENTDECK_DAEMON_DIRECT=1(시험): 처음부터 예전 방식
    var directOnly: Bool { get }
    func now() -> Date
    func sleep(_ seconds: TimeInterval)
    func log(_ message: String)
}

public enum DaemonConnector {
    /// 어떻게 붙었나
    public enum Route: Equatable {
        /// 이미 돌던 데몬
        case existing
        /// 이미 돌던 데몬인데 launchd 작업이 아님(예전 방식으로 뜬 것)
        case existingDirect
        /// launchd 작업으로 띄움
        case launchd
        /// launchd 가 안 돼 예전 방식(posix_spawn)으로 띄움
        case direct

        /// 앱이 강제 종료되면 데몬(과 모든 화면)이 함께 끝날 수 있다(앱의 coalition 안)
        public var limited: Bool { self == .existingDirect || self == .direct }
    }

    public enum Result: Equatable {
        case connected(fd: Int32, route: Route)
        case failed(String)
    }

    /// 띄운 뒤 소켓이 생기길 기다리는 시간(한 번에)
    public static let waitTimeout: TimeInterval = 3
    public static let pollInterval: TimeInterval = 0.05

    /// launch 가 false 면 띄우지 않는다(예전 데몬에 붙는 동안 — 같은 폴더에 데몬 둘을 만들지 않게).
    /// 순서: 붙기 → launchd → (3초 안에 안 뜨면) launchd 한 번 더 → 예전 방식. 예전 방식은 한 번만 띄운다.
    public static func run(launch: Bool, env: DaemonConnectEnvironment) -> Result {
        if let fd = env.connect() {
            guard launch else { return .connected(fd: fd, route: .existing) }
            return .connected(fd: fd, route: env.existingIsLaunchd() == false ? .existingDirect : .existing)
        }
        guard launch else { return .failed("데몬 소켓에 연결하지 못했습니다") }

        if env.directOnly {
            env.log("AGENTDECK_DAEMON_DIRECT=1: 데몬을 예전 방식(posix_spawn)으로 띄움")
            return direct(env)
        }
        if case .failed(let reason) = launchd(env) {
            env.log("launchd 로 띄우지 못해 예전 방식(posix_spawn)으로 띄움: \(reason)")
            return direct(env)
        }
        if let fd = wait(env) { return .connected(fd: fd, route: .launchd) }

        // 막 끝나는 데몬의 작업이 아직 내려가는 중이었으면(돌고 있음으로 보임) 한 번 더 올린다
        env.log("데몬이 \(Int(waitTimeout))초 안에 뜨지 않아 launchd 로 한 번 더 띄움")
        if case .failed(let reason) = launchd(env) {
            env.log("launchd 로 다시 띄우지 못해 예전 방식(posix_spawn)으로 띄움: \(reason)")
            return direct(env)
        }
        if let fd = wait(env) { return .connected(fd: fd, route: .launchd) }

        // launchd 작업을 올렸는데도 데몬이 안 뜸(실행 파일이 없어짐·관리 정책 등)
        env.log("launchd 작업의 데몬이 \(Int(waitTimeout))초 안에 뜨지 않아 예전 방식(posix_spawn)으로 띄움")
        return direct(env)
    }

    private static func launchd(_ env: DaemonConnectEnvironment) -> DaemonLaunchAgent.Outcome {
        let outcome = env.launchViaLaunchd()
        switch outcome {
        case .bootstrapped(let label):
            env.log("데몬을 launchd 작업으로 띄움: \(label)")
        case .kickstarted(let label):
            env.log("이미 올라가 있던 launchd 작업을 다시 시작함(예전 plist 내용): \(label)")
        case .alreadyRunning(let label, let pid):
            env.log("launchd 작업이 이미 돌고 있음: \(label) pid \(pid.map(String.init) ?? "?")")
        case .failed:
            break
        }
        return outcome
    }

    private static func direct(_ env: DaemonConnectEnvironment) -> Result {
        guard env.spawnDirect() else {
            env.log("예전 방식(posix_spawn)으로도 데몬을 띄우지 못함")
            return .failed("데몬을 띄우지 못했습니다")
        }
        if let fd = wait(env) {
            env.log("데몬을 예전 방식(posix_spawn)으로 띄움 — 앱을 강제 종료하면 세션이 함께 끝날 수 있음")
            return .connected(fd: fd, route: .direct)
        }
        env.log("예전 방식으로 띄운 데몬도 \(Int(waitTimeout))초 안에 뜨지 않음")
        return .failed("데몬이 뜨지 않았습니다")
    }

    private static func wait(_ env: DaemonConnectEnvironment) -> Int32? {
        let deadline = env.now().addingTimeInterval(waitTimeout)
        while env.now() < deadline {
            env.sleep(pollInterval)
            if let fd = env.connect() { return fd }
        }
        return nil
    }
}

/// 앱의 데몬 연결 상태(화면에 보이는 것)와 다시 붙기 간격. 순수 값이라 시험한다.
/// 붙기는 한 번에 하나만. 실패하면 1·2·4·8·16·30초…(최대 30초) 뒤에야 다시 시도한다(2초 새로 고침이 그 전엔 건너뛴다).
public struct DaemonLink: Equatable {
    public enum Phase: Equatable {
        /// 아직 시도 안 함·끊김(다음 새로 고침에 바로 시도)
        case idle
        case connecting
        case connected
        /// 실패. retryAt 전에는 저절로 다시 시도하지 않는다.
        case failed(message: String, retryAt: Date)
    }

    public private(set) var phase: Phase = .idle
    /// 이어진 실패 횟수(붙으면 0)
    public private(set) var failures = 0
    /// 지금 데몬이 앱의 coalition 안에 있음(예전 방식으로 뜸) — 앱을 강제 종료하면 세션이 끝날 수 있다
    public private(set) var limited = false

    public static let backoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    public init() {}

    public static func retryDelay(afterFailures count: Int) -> TimeInterval {
        backoff[min(max(count, 1), backoff.count) - 1]
    }

    public var isConnecting: Bool { phase == .connecting }
    public var isConnected: Bool { phase == .connected }

    /// 지금 시도해도 되나. force(사용자가 새 화면을 열 때 등)면 기다리던 간격을 건너뛴다. 이미 붙는 중이면 늘 false.
    public func canAttempt(now: Date, force: Bool = false) -> Bool {
        switch phase {
        case .connecting, .connected: return false
        case .idle: return true
        case .failed(_, let retryAt): return force || now >= retryAt
        }
    }

    /// 시도를 시작한다. 시작했으면 true.
    @discardableResult
    public mutating func begin(now: Date, force: Bool = false) -> Bool {
        guard canAttempt(now: now, force: force) else { return false }
        phase = .connecting
        return true
    }

    /// 시도가 끝났다. 실패면 다음 시도까지 기다릴 초를 돌려준다.
    @discardableResult
    public mutating func finish(_ result: DaemonConnector.Result, now: Date) -> TimeInterval? {
        switch result {
        case .connected(_, let route):
            phase = .connected
            failures = 0
            limited = route.limited
            return nil
        case .failed(let message):
            failures += 1
            let delay = Self.retryDelay(afterFailures: failures)
            phase = .failed(message: message, retryAt: now.addingTimeInterval(delay))
            return delay
        }
    }

    /// 연결이 끊겼다(데몬이 끝남 등). 다음 새로 고침에 바로 다시 붙는다. 띄운 방식 표시는 새로 붙을 때 다시 정한다.
    public mutating func disconnected() {
        if phase == .connected { phase = .idle }
    }

    /// 앱이 일부러 끊었다(지금 옮기기 동안) — 진행 중이던 시도 결과는 버린다
    public mutating func reset() {
        phase = .idle
        failures = 0
    }
}
