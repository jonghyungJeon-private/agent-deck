import Foundation

/// 새 버전 확인: 비공개 GitHub 저장소의 최신 릴리스를 gh CLI 로 읽어 앱 버전과 비교한다.
/// gh 가 없거나 로그인·권한이 없거나 오프라인이면 실패로 돌려주고, 앱은 조용히 넘어간다(물어볼 때만 알린다).
public enum UpdateCheck {
    /// 릴리스를 올리는 저장소(owner/repo). 바꾸면 scripts/install.sh 의 REPO 와 README 도 같이 바꾼다.
    public static let repository = "jonghyungJeon-private/agent-deck"
    /// 자동 확인 간격(앱을 켤 때·앞으로 나올 때, 이만큼 지났을 때만)
    public static let interval: TimeInterval = 24 * 60 * 60

    /// 동료가 터미널에 붙여 넣는 설치·업데이트 명령(gh 로그인 필요)
    public static var installCommand: String {
        "gh api repos/\(repository)/contents/scripts/install.sh -H 'Accept: application/vnd.github.raw' | bash"
    }

    public struct Release: Codable, Equatable {
        public var tag: String
        public var url: String
        public init(tag: String, url: String) { self.tag = tag; self.url = url }
    }

    public enum Failure: Error, Equatable {
        /// gh 가 설치돼 있지 않다
        case noGh
        /// gh 가 실패했다(로그인 안 됨·저장소 권한 없음·오프라인 등). gh 가 남긴 첫 줄
        case failed(String)
    }

    // MARK: - 버전 비교

    /// "v1.2.3" · "1.2" · "1.2.3-beta.1" → 숫자 부분과 꼬리(pre-release). 못 읽으면 nil
    static func parse(_ text: String) -> (numbers: [Int], pre: String?)? {
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        let (core, pre): (Substring, String?) = {
            if let dash = body.firstIndex(of: "-") { return (body[..<dash], String(body[body.index(after: dash)...])) }
            return (body, nil)
        }()
        let core2 = core.split(separator: "+", maxSplits: 1).first ?? core
        let numbers = core2.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil }) else { return nil }
        return (numbers.map { $0! }, pre)
    }

    /// tag 가 current 보다 새 버전이면 true. 못 읽는 값이면 false(엉뚱한 알림을 띄우지 않게).
    /// 숫자는 자리별로(빈 자리는 0), 숫자가 같으면 정식판이 pre-release(1.2.0-beta)보다 새것.
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        guard let a = parse(tag), let b = parse(current) else { return false }
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x > y }
        }
        switch (a.pre, b.pre) {
        case (nil, .some): return true
        case (.some(let p), .some(let q)): return p.compare(q, options: .numeric) == .orderedDescending
        default: return false
        }
    }

    // MARK: - gh

    /// gh 위치: Homebrew(Apple Silicon·Intel) → PATH. 앱은 Finder 에서 떠서 PATH 가 짧으므로 흔한 곳을 먼저 본다.
    public static func ghPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        return (["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] + path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `gh release view --json tagName,url` 결과 읽기
    public static func decode(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tagName"] as? String, !tag.isEmpty else { return nil }
        return Release(tag: tag, url: object["url"] as? String ?? "https://github.com/\(repository)/releases")
    }

    /// 최신 릴리스를 읽는다(호출한 스레드를 막는다 — 메인 스레드에서 부르지 않는다). timeout 을 넘기면 gh 를 끈다.
    public static func latestRelease(gh: String? = ghPath(), timeout: TimeInterval = 20) -> Result<Release, Failure> {
        guard let gh else { return .failure(.noGh) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["release", "view", "--repo", repository, "--json", "tagName,url"]
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return .failure(.failed(error.localizedDescription)) }
        // 출력은 작지만 파이프가 차서 멈추지 않게 끝나기 전에 읽는다
        let output = Collected(), errors = Collected()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) { output.data = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .utility).async(group: group) { errors.data = err.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            return .failure(.failed("응답이 없습니다(\(Int(timeout))초)"))
        }
        group.wait()
        guard process.terminationStatus == 0, let release = decode(output.data) else {
            let message = String(decoding: errors.data, as: UTF8.self).split(separator: "\n").first.map(String.init)
            return .failure(.failed(message ?? "gh 종료 코드 \(process.terminationStatus)"))
        }
        return .success(release)
    }

    /// 읽기 스레드가 채우고 group.wait 뒤에만 읽는다
    private final class Collected: @unchecked Sendable { var data = Data() }

    // MARK: - 마지막 확인 기록

    /// 마지막으로 확인한 시각과 그때 본 최신 릴리스. 다시 켰을 때 gh 를 부르지 않고도 알림을 이어 보인다.
    public struct Stamp: Codable, Equatable {
        public var checkedAt: Date
        public var latest: Release?
        public init(checkedAt: Date, latest: Release?) { self.checkedAt = checkedAt; self.latest = latest }

        public static func load(from url: URL) -> Stamp? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Stamp.self, from: data)
        }

        public func save(to url: URL) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(self).write(to: url, options: .atomic)
        }

        public func isDue(now: Date = Date()) -> Bool {
            now.timeIntervalSince(checkedAt) >= UpdateCheck.interval || now < checkedAt
        }
    }
}
