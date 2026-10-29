import CryptoKit
import Foundation

/// 에이전트 전용 브라우저(Chrome for Testing) 한 판. 앱 판마다 고정한다(screencast 등을 확인한 판, 받은 파일은 SHA-256 으로 확인).
/// Chrome for Testing 은 스스로 업데이트하지 않으므로 앱을 낼 때마다 최신 안정판으로 올린다(docs/RELEASING.md).
public struct BrowserRelease: Equatable, Sendable {
    public var version: String
    public var url: URL
    public var sha256: String
    /// 버전 폴더 안 실행 파일(상대 경로)
    public var executable: String

    public init(version: String, url: URL, sha256: String, executable: String) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.executable = executable
    }

    public static let pinned = BrowserRelease(
        version: "156.0.8078.73",
        url: URL(string: "https://storage.googleapis.com/chrome-for-testing-public/156.0.8078.73/mac-arm64/chrome-mac-arm64.zip")!,
        sha256: "a46be48ee2e33b3edc1a98a39668b9f0abb8f23f031bc4df195e2388e6de28d1",
        executable: "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing")
}

/// `<폴더>/<버전>/` 에 브라우저를 받아 둔다. 다 받고 확인(해시·한 번 띄워 보기)한 뒤에만 표식(`abx-browser.json`)을 쓰고
/// 제자리로 옮기므로, abx(`ABX_BROWSERS_DIR`)는 표식이 있는 판만 쓴다. 받는 중·실패한 것은 점으로 시작하는 임시 폴더에만 있다.
public final class BrowserInstaller: @unchecked Sendable {
    public static let marker = "abx-browser.json"
    /// 받기(약 200MB)·풀기(약 370MB)·임시 파일에 필요한 빈 공간
    static let requiredSpace: Int64 = 800 * 1024 * 1024

    public let dir: URL
    public let release: BrowserRelease

    public init(dir: URL, release: BrowserRelease = .pinned) {
        self.dir = dir
        self.release = release
    }

    public var versionDir: URL { dir.appendingPathComponent(release.version, isDirectory: true) }
    public var executableURL: URL { versionDir.appendingPathComponent(release.executable) }

    public enum State: Equatable {
        /// 확인을 마친 판이 있다(abx 가 새 세션에 쓴다)
        case installed
        /// 실행 파일은 있지만 확인 표식이 없다(개발용으로 손수 푼 것 등) — 띄워 보고 표식만 쓰면 된다
        case unverified
        case missing
    }

    public func state() -> State {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executableURL.path) else { return .missing }
        return fm.fileExists(atPath: versionDir.appendingPathComponent(Self.marker).path) ? .installed : .unverified
    }

    public enum InstallError: LocalizedError, Equatable {
        case noSpace(needed: Int64, free: Int64)
        /// 다른 AgentDeck(같은 사용자)이 받는 중
        case busy
        case download(String)
        case checksum(expected: String, actual: String)
        case unpack(String)
        case launch(String)

        public var errorDescription: String? {
            let mb = { (bytes: Int64) in "\(bytes / 1024 / 1024)MB" }
            switch self {
            case .noSpace(let needed, let free): return "빈 공간이 모자랍니다(필요 \(mb(needed)), 남음 \(mb(free)))"
            case .busy: return "다른 AgentDeck 창이 받는 중입니다 — 끝난 뒤 다시 시도하세요"
            case .download(let detail): return "받지 못했습니다: \(detail)"
            case .checksum: return "받은 파일이 예상과 다릅니다(해시 불일치) — 다시 시도하세요"
            case .unpack(let detail): return "풀지 못했습니다: \(detail)"
            case .launch(let detail): return "받은 브라우저가 뜨지 않습니다: \(detail)"
            }
        }
    }

    /// 받고 확인해서 제자리에 둔다. progress 는 받기 진행(0…1, 아무 스레드). 이미 있으면 바로 끝난다.
    public func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        switch state() {
        case .installed: return
        case .unverified:
            // 손수 푼 같은 판: 띄워지면 표식만 쓴다. 망가졌으면(뜨지 않음) 아래에서 새로 받아 바꾼다.
            do {
                try verifyLaunch(executableURL)
                try Task.checkCancellation()
                try writeMarker(in: versionDir)
                return
            } catch let error as CancellationError {
                throw error
            } catch {}
        case .missing: break
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 같은 폴더에 받는 다른 앱(인스턴스)과 겹치지 않게 정리부터 놓기까지 잠근다(프로세스가 끝나면 풀린다)
        let lock = open(dir.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw InstallError.download("잠금 파일을 만들지 못했습니다") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw InstallError.busy }
        if state() == .installed { return } // 기다리는 사이 다른 쪽이 마쳤다
        cleanLeftovers()
        let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard free >= Self.requiredSpace else { throw InstallError.noSpace(needed: Self.requiredSpace, free: free) }

        let token = UUID().uuidString
        let zip = dir.appendingPathComponent(".download-\(token).zip")
        let staging = dir.appendingPathComponent(".staging-\(token)", isDirectory: true)
        defer {
            try? fm.removeItem(at: zip)
            try? fm.removeItem(at: staging)
        }
        try await download(to: zip, progress: progress)
        try Task.checkCancellation()
        let actual = try Self.sha256(of: zip)
        guard actual == release.sha256 else { throw InstallError.checksum(expected: release.sha256, actual: actual) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path], error: InstallError.unpack)
        // 해시가 맞는 것만: 받은 파일에 격리 속성이 붙었으면 뗀다(앱이 받은 파일은 보통 붙지 않는다)
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path], error: InstallError.unpack)
        let executable = staging.appendingPathComponent(release.executable)
        guard fm.isExecutableFile(atPath: executable.path) else { throw InstallError.unpack("실행 파일이 없습니다: \(release.executable)") }
        try Task.checkCancellation()
        try verifyLaunch(executable)
        try Task.checkCancellation()
        try writeMarker(in: staging)
        // 표식 없는 예전 것(끊긴 설치·손수 푼 것)이 있으면 비우고 놓는다(잠금 안이라 다른 앱이 놓은 확인된 판은 위에서 걸렀다)
        if fm.fileExists(atPath: versionDir.path) {
            let aside = dir.appendingPathComponent(".old-\(token)", isDirectory: true)
            try fm.moveItem(at: versionDir, to: aside)
            try? fm.removeItem(at: aside)
        }
        try fm.moveItem(at: staging, to: versionDir)
    }

    // MARK: -

    private func writeMarker(in folder: URL) throws {
        let body: [String: String] = ["version": release.version, "executable": release.executable, "sha256": release.sha256]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent(Self.marker), options: .atomic)
    }

    /// 지난번에 끊긴 받기·풀기 흔적을 지운다
    private func cleanLeftovers() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix(".download-") || name.hasPrefix(".staging-") || name.hasPrefix(".old-") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private func download(to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                session.downloadTask(with: release.url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 창 없이 한 번 띄워 DevTools 포트가 열리는지 본다(빈 임시 프로필, 끝나면 지운다)
    func verifyLaunch(_ executable: URL, timeout: TimeInterval = 30) throws {
        let fm = FileManager.default
        let profile = fm.temporaryDirectory.appendingPathComponent("agentdeck-browser-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: profile) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--headless=new", "--remote-debugging-port=0", "--user-data-dir=\(profile.path)",
                             "--no-first-run", "--no-default-browser-check", "--use-mock-keychain", "--password-store=basic",
                             "about:blank"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw InstallError.launch(error.localizedDescription) }
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning, Date() < deadline { usleep(50_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let port = profile.appendingPathComponent("DevToolsActivePort")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: port, encoding: .utf8), let first = text.split(separator: "\n").first,
               Int(first) != nil { return }
            if Task.isCancelled { throw CancellationError() }
            guard process.isRunning else { throw InstallError.launch("종료 코드 \(process.terminationStatus)") }
            usleep(100_000)
        }
        throw InstallError.launch("\(Int(timeout))초 안에 뜨지 않았습니다")
    }

    private func run(_ tool: String, _ arguments: [String], error: (String) -> InstallError) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        do { try process.run() } catch let failure { throw error(failure.localizedDescription) }
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw error(message.split(separator: "\n").first.map(String.init) ?? "종료 코드 \(process.terminationStatus)")
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 이 콜백이 끝나면 임시 파일이 지워지므로 여기서 옮긴다
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(BrowserInstaller.InstallError.download("HTTP \(http.statusCode)")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(BrowserInstaller.InstallError.download(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(BrowserInstaller.InstallError.download(error.localizedDescription))) }
    }
}
