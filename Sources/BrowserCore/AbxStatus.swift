import Darwin
import Foundation

/// abx 세션 하나를 가리키는 값. 에이전트 셸에 넣는 `ABX_*` 환경 변수와 같다.
public struct AbxSession: Codable, Equatable, Sendable {
    /// `ABX_SESSION`
    public var name: String
    /// `ABX_SOCKET_DIR` — 엔진 소켓·잠금 소켓이 있는 곳
    public var socketDir: String
    /// `ABX_STATE_DIR` — abx 상태 파일(활성 탭·handoff·잠금)
    public var stateDir: String
    /// `ABX_PROFILE_DIR`
    public var profileDir: String

    public init(name: String, socketDir: String, stateDir: String, profileDir: String) {
        self.name = name
        self.socketDir = socketDir
        self.stateDir = stateDir
        self.profileDir = profileDir
    }

    public var environment: [String: String] {
        ["ABX_SESSION": name, "ABX_SOCKET_DIR": socketDir, "ABX_PROFILE_DIR": profileDir, "ABX_STATE_DIR": stateDir]
    }
}

/// `abx status --json` 의 결과(abx `runtime.ts` 의 `Status` 와 같은 모양)
public struct AbxStatus: Codable, Equatable, Sendable {
    public enum Control: String, Codable, Sendable {
        /// 에이전트가 입력을 쥐고 있다(잠금)
        case agent
        /// 사용자에게 넘겼다(handoff)
        case user
        /// 넘기기를 요청했고 진행 중인 abx 동작이 끝나길 기다리는 중
        case switching
        /// 아무도 쥐고 있지 않다(`abx done`·쉬다 풀림)
        case idle
    }

    public struct Tab: Codable, Equatable, Sendable {
        public var id: String
        public var targetId: String
        public var url: String
        public var title: String
        public var active: Bool
    }

    public var session: String
    public var running: Bool
    public var headless: Bool?
    public var cdpUrl: String?
    public var control: Control
    public var handoff: String?
    public var tabs: [Tab]

    /// abx 가 마지막으로 본 활성 탭(에이전트가 보고 있는 탭)
    public var activeTab: Tab? { tabs.first(where: \.active) }

    public static func decode(_ data: Data) throws -> AbxStatus {
        try JSONDecoder().decode(AbxStatus.self, from: data)
    }
}

/// abx 실행 파일로 상태를 읽는다. `status --json` 은 파일만 읽고 브라우저를 띄우지 않는다.
public struct AbxRunner {
    public var executable: URL
    /// abx 를 소스로 쓸 때(`node …/cli.ts`) 앞에 붙는 인자
    public var leadingArguments: [String]

    public init(executable: URL, leadingArguments: [String] = []) {
        self.executable = executable
        self.leadingArguments = leadingArguments
    }

    /// 찾는 순서: `AGENTDECK_ABX`(실행 파일 경로) → 앱 묶음의 Helpers/abx → PATH 의 `abx`
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              bundleHelpers: URL? = nil) -> AbxRunner? {
        let fm = FileManager.default
        if let path = environment["AGENTDECK_ABX"], fm.isExecutableFile(atPath: path) {
            return AbxRunner(executable: URL(fileURLWithPath: path))
        }
        if let helpers = bundleHelpers?.appendingPathComponent("abx"), fm.isExecutableFile(atPath: helpers.path) {
            return AbxRunner(executable: helpers)
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        let home = environment["HOME"] ?? NSHomeDirectory()
        for dir in path.split(separator: ":").map(String.init) + ["\(home)/.local/bin"] {
            let candidate = (dir as NSString).appendingPathComponent("abx")
            if fm.isExecutableFile(atPath: candidate) { return AbxRunner(executable: URL(fileURLWithPath: candidate)) }
        }
        return nil
    }

    public enum RunError: Error, Equatable { case timeout }

    /// abx 명령을 돌리고 표준 출력을 돌려준다(메인 스레드에서 부르지 않는다).
    /// 시간을 넘기면 SIGTERM, 그래도 안 끝나면 SIGKILL 로 끝내고 `.timeout`.
    public func run(_ arguments: [String], session: AbxSession?, extraEnvironment: [String: String] = [:],
                    timeout: TimeInterval = 10) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = leadingArguments + arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in (session?.environment ?? [:]).merging(extraEnvironment, uniquingKeysWith: { $1 }) { env[k] = v }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let reader = DispatchGroup()
        let box = OutputBox()
        reader.enter()
        DispatchQueue.global().async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        let finished = reader.wait(timeout: .now() + timeout) == .success && Self.waitExit(process, until: deadline)
        if !finished {
            process.terminate()
            if !Self.waitExit(process, until: Date().addingTimeInterval(1)) { kill(process.processIdentifier, SIGKILL) }
            _ = Self.waitExit(process, until: Date().addingTimeInterval(1))
            try? out.fileHandleForReading.close() // 손자 프로세스가 파이프를 쥐고 있어도 읽기를 끝낸다
            _ = reader.wait(timeout: .now() + 1)
            throw RunError.timeout
        }
        return (process.terminationStatus, box.data)
    }

    private final class OutputBox: @unchecked Sendable { var data = Data() }

    /// 끝날 때까지(또는 시각까지) 기다린다. 끝났으면 true
    private static func waitExit(_ process: Process, until deadline: Date) -> Bool {
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }

    /// 이 abx 에 맞는 에이전트 스킬(SKILL.md 전체, `abx skill`). 예전 abx 라 없으면 nil.
    /// 예전 abx 는 모르는 명령을 엔진에 넘기며 브라우저를 띄우므로, 띄우지 않게(ABX_AUTOSTART=0) 빈 세션으로 묻는다.
    public func skill() throws -> String? {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-abx-skill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let probe = AbxSession(name: "agentdeck-skill", socketDir: scratch.path, stateDir: scratch.appendingPathComponent("state").path,
                               profileDir: scratch.appendingPathComponent("profile").path)
        let result = try run(["skill"], session: probe, extraEnvironment: ["ABX_AUTOSTART": "0"])
        guard result.status == 0, let text = String(data: result.output, encoding: .utf8),
              text.hasPrefix("---\n") else { return nil }
        return text
    }

    public func status(_ session: AbxSession) throws -> AbxStatus {
        try AbxStatus.decode(run(["status", "--json"], session: session).output)
    }
}
