import CoreServices
import Foundation
import TermLayout

/// files 도구가 보일 때만 도는 감시: 루트 폴더의 FSEvents(1초 모음) + `git status` 한 번 실행(백그라운드).
/// 보이지 않거나 루트가 바뀌면 스트림을 멈춘다. 타이머는 쓰지 않는다.
final class FilesWatcher {
    /// git 상태(메인 스레드). nil = git 이 없거나 저장소가 아님 → 색 없이.
    var onStatus: ((GitStatusSnapshot?) -> Void)?
    /// 내용이 바뀐 폴더(절대 경로, 메인 스레드). 전체를 다시 읽어야 하면 루트가 들어간다.
    var onDirectoriesChanged: ((Set<String>) -> Void)?
    /// 지금 읽어 둔 폴더(절대 경로). FSEvents 콜백(백그라운드)이 상관없는 사건을 거르는 데 쓴다.
    var loadedDirectories: Set<String> {
        get { lock.withLock { _loaded } }
        set { lock.withLock { _loaded = newValue } }
    }

    private(set) var root: String?
    /// FSEvents 는 실제 경로(/tmp → /private/tmp 등 링크를 푼 것)로 알린다. 그 앞부분을 루트 표기로 바꿔 맞춘다.
    private var aliases: [(real: String, shown: String)] {
        get { lock.withLock { _aliases } }
        set { lock.withLock { _aliases = newValue } }
    }
    private var _aliases: [(real: String, shown: String)] = []
    private var isGit = false
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "ClaudeTerm.files", qos: .utility)
    private let lock = NSLock()
    private var _loaded: Set<String> = []
    /// 루트가 바뀔 때마다 올라간다(늦게 온 옛 결과를 버린다)
    private var generation = 0
    private var running = false
    private var pending = false
    private var lastRun = Date.distantPast
    private var scheduled: DispatchWorkItem?
    /// 무시된 폴더(이 안의 변화만 있으면 git 을 다시 돌리지 않는다)
    private var ignoredFolders: [String] = []
    static let minInterval: TimeInterval = 1

    /// 측정용: git 실행 횟수·마지막 걸린 시간
    private(set) var runs = 0
    private(set) var lastDuration: TimeInterval = 0

    var isRunning: Bool { stream != nil }

    func start(root: String, isGit: Bool) {
        stop()
        self.root = root
        self.isGit = isGit
        generation += 1
        startStream(root: root)
        if isGit { requestStatus(delay: 0) } else { onStatus?(nil) }
    }

    func stop() {
        generation += 1
        scheduled?.cancel()
        scheduled = nil
        pending = false
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        root = nil
        ignoredFolders = []
    }

    func noteIgnored(_ snapshot: GitStatusSnapshot?) {
        guard let root, let snapshot else { ignoredFolders = []; return }
        ignoredFolders = snapshot.folders.filter { $0.value == .ignored }.map { root + "/" + $0.key + "/" }
    }

    /// 보이기 시작·루트 바뀜·파일 변화에서 부른다. 짧게 모았다가 한 번만, 실행 중이면 끝난 뒤 한 번 더.
    func requestStatus(delay: TimeInterval = 0.15) {
        guard isGit, root != nil else { return }
        if running { pending = true; return }
        scheduled?.cancel()
        let wait = max(delay, Self.minInterval - Date().timeIntervalSince(lastRun))
        let work = DispatchWorkItem { [weak self] in self?.runStatus() }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(wait, 0), execute: work)
    }

    private func runStatus() {
        guard let root, isGit else { return }
        running = true
        pending = false
        lastRun = Date()
        let generation = self.generation
        queue.async { [weak self] in
            let started = Date()
            let snapshot = GitRunner.status(root: root)
            let duration = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                guard generation == self.generation else { return }
                self.runs += 1
                self.lastDuration = duration
                self.noteIgnored(snapshot)
                self.onStatus?(snapshot)
                if self.pending { self.requestStatus(delay: Self.minInterval) }
            }
        }
    }

    // MARK: - FSEvents

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func startStream(root: String) {
        var paths = [root]
        // 작업 트리는 커밋·스테이징 기록(index, HEAD)이 루트 밖(.git/worktrees/<이름>)에 있다
        if isGit, let gitDir = GitWorktrees.gitDir(worktreeRoot: root), !gitDir.hasPrefix(root + "/") {
            paths.append(gitDir)
        }
        aliases = paths.map { (Self.realPath($0), $0) }.filter { $0.0 != $0.1 }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FilesWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
            watcher.handle(list, flagList)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, // 1초 모아서
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// 백그라운드(queue)에서 불린다
    private func handle(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        let loaded = loadedDirectories
        let aliases = self.aliases
        var directories: Set<String> = []
        /// git 상태가 바뀌었을 수 있는 경로
        var candidates: [String] = []
        var rescan = false
        for (index, raw) in paths.enumerated() {
            let flag = index < flags.count ? Int(flags[index]) : 0
            if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 { rescan = true }
            var path = raw
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            for alias in aliases where path == alias.real || path.hasPrefix(alias.real + "/") {
                path = alias.shown + path.dropFirst(alias.real.count)
                break
            }
            if path.contains("/.git/") || path.hasSuffix("/.git") {
                // 색인·HEAD·브랜치가 바뀌면 상태만 다시(objects·logs 는 무시)
                if !path.contains("/objects") && !path.contains("/logs") { candidates.append(path) }
                continue
            }
            candidates.append(path) // 작업 폴더의 변화(무시된 폴더 안이면 아래에서 거른다)
            if loaded.contains(path) { directories.insert(path) }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let root = self.root else { return }
            if rescan { directories.insert(root) }
            if !directories.isEmpty { self.onDirectoriesChanged?(directories) }
            // 무시된 폴더(.build, node_modules …) 안에서만 일어난 변화는 git 상태가 바뀌지 않는다
            let ignored = self.ignoredFolders
            let relevant = rescan || candidates.contains { path in
                let dir = path.hasSuffix("/") ? path : path + "/"
                return !ignored.contains { dir.hasPrefix($0) }
            }
            if relevant { self.requestStatus(delay: 0) }
        }
    }

    deinit { stop() }
}

/// git 실행(백그라운드에서만)
enum GitRunner {
    /// 쓸 git. /usr/bin/git 은 개발 도구가 없으면 설치 창을 띄우므로 실제 git 이 있을 때만 쓴다.
    static let executable: String? = {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git",
                     "/Library/Developer/CommandLineTools/usr/bin/git",
                     "/Applications/Xcode.app/Contents/Developer/usr/bin/git"] where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }()

    /// nil = git 없음·저장소 아님·실패
    static func status(root: String, timeout: TimeInterval = 10) -> GitStatusSnapshot? {
        guard let git = executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignored=matching"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0" // 색인을 고쳐 쓰지 않는다(사용자의 git 명령과 잠금 다툼 없음)
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return GitStatusParser.parse(data)
    }
}
