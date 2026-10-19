import EditorCore
import Foundation
import TermLayout
import TermWire

/// 프로젝트 하나의 선언 색인(LSP 아님 — 이름 → 파일·줄·종류만).
/// 처음 이동 요청 때 낮은 우선순위로 만들고, 편집기에서 저장한 파일은 바로, 그 밖의 디스크 변경은
/// 다음 요청 때(10초에 한 번까지) 파일 목록·수정 시각으로 확인한다. 타이머·감시 없음.
final class ProjectIndex {
    enum State { case idle, building, ready }

    struct Stats {
        var files = 0
        var symbols = 0
        var names = 0
        var scanned = 0
        var listSeconds: TimeInterval = 0
        var totalSeconds: TimeInterval = 0
        var refreshes = 0
        var truncated = false
    }

    struct UsageHit {
        /// 루트 기준 상대 경로
        var path: String
        var usage: Usage
    }

    static let maxFiles = 50_000
    static let maxFileBytes = 1_000_000
    static let refreshInterval: TimeInterval = 10
    static let maxUsages = 500
    /// 늘 빼는 폴더(빌드 결과·의존성·도구 설정)
    static let skippedDirectories: Set<String> = [
        ".git", "build", "out", "target", "node_modules", ".gradle", ".idea", "dist", "vendor", ".build", "DerivedData",
        "Pods", ".next", ".nuxt", ".venv", "venv", "__pycache__", ".tox", ".mypy_cache", "coverage", ".dart_tool",
    ]

    let root: String
    let isGit: Bool
    var name: String { (root as NSString).lastPathComponent }

    /// 색인(queue 에서만)
    private var table = SymbolTable()
    private var files: [(path: String, language: SyntaxLanguage)] = []
    private let queue: DispatchQueue
    /// 사용 위치 찾기(파일을 다 읽으므로 색인 질의를 막지 않게 따로)
    private let searchQueue: DispatchQueue

    // 메인 스레드
    private(set) var state: State = .idle
    private(set) var stats = Stats()
    private var waiters: [() -> Void] = []
    private var lastRefresh = Date.distantPast
    private var refreshing = false

    /// 파일 읽기 버퍼(queue 에서만 — 파일마다 메모리를 새로 잡지 않게)
    private var buffer = FileBuffer()
    private let lock = NSLock()
    private var _progress = 0
    private var _generation = 0
    /// 만드는 동안 읽은 파일 수(안내용)
    var progress: Int { lock.withLock { _progress } }

    init(root: String, isGit: Bool) {
        self.root = root
        self.isGit = isGit
        queue = DispatchQueue(label: "AgentDeck.index", qos: .utility)
        searchQueue = DispatchQueue(label: "AgentDeck.index.usages", qos: .userInitiated)
    }

    var isReady: Bool { state == .ready }

    /// 쓸 준비가 되면 ready(메인). 만드는 중이면 끝난 뒤, 처음이면 만들기 시작. 준비된 색인이 오래됐으면 뒤에서 다시 확인한다
    /// (그 확인이 질의보다 먼저 줄을 서므로 결과는 새것으로 나온다).
    func whenReady(_ ready: @escaping () -> Void) {
        switch state {
        case .ready:
            if !refreshing, Date().timeIntervalSince(lastRefresh) > Self.refreshInterval { refresh() }
            ready()
        case .building:
            waiters.append(ready)
        case .idle:
            waiters.append(ready)
            state = .building
            refresh()
        }
    }

    private func refresh() {
        refreshing = true
        lastRefresh = Date()
        queue.async { [weak self] in
            guard let self else { return }
            FileBuffer.applyIOPolicy()
            let started = Date()
            let (list, truncated) = self.listFiles()
            let listed = Date()
            let scanned = self.sync(list)
            var stats = Stats(files: self.table.fileCount, symbols: self.table.symbolCount, names: self.table.names.count,
                              scanned: scanned, listSeconds: listed.timeIntervalSince(started),
                              totalSeconds: Date().timeIntervalSince(started), refreshes: 0, truncated: truncated)
            DispatchQueue.main.async {
                stats.refreshes = self.stats.refreshes + 1
                self.stats = stats
                self.refreshing = false
                self.lastRefresh = Date()
                self.state = .ready
                let waiting = self.waiters
                self.waiters = []
                waiting.forEach { $0() }
            }
        }
    }

    // MARK: - 파일 목록

    /// git 저장소면 `git ls-files -co --exclude-standard`(.gitignore 를 따른다, 빠름), 아니면 폴더를 걷는다
    private func listFiles() -> ([(path: String, language: SyntaxLanguage)], Bool) {
        var result: [(path: String, language: SyntaxLanguage)] = []
        var truncated = false
        func consider(_ rel: String) -> Bool {
            guard let language = SymbolLanguages.language(path: rel) else { return true }
            if rel.split(separator: "/").dropLast().contains(where: { Self.skippedDirectories.contains(String($0)) }) { return true }
            result.append((rel, language))
            if result.count >= Self.maxFiles { truncated = true; return false }
            return true
        }
        if isGit, let listed = GitRunner.run(["-C", root, "ls-files", "-co", "--exclude-standard", "-z"], timeout: 30, limit: 64 << 20),
           listed.status == 0 {
            var seen = Set<String>()
            for piece in listed.output.split(separator: 0) {
                let rel = String(decoding: piece, as: UTF8.self)
                guard seen.insert(rel).inserted else { continue }
                if !consider(rel) { break }
            }
            return (result, truncated)
        }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], false)
        }
        let prefix = rootURL.path.count + 1
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 200_000 { truncated = true; break }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if Self.skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard url.path.count > prefix else { continue }
            if !consider(String(url.path.dropFirst(prefix))) { break }
        }
        return (result, truncated)
    }

    /// 목록과 색인을 맞춘다(바뀐 파일만 다시 읽음). 읽은 파일 수.
    private func sync(_ list: [(path: String, language: SyntaxLanguage)]) -> Int {
        var scanned = 0
        var present = Set<String>()
        present.reserveCapacity(list.count)
        for (index, item) in list.enumerated() {
            present.insert(item.path)
            if scan(item.path, item.language) { scanned += 1 }
            if index & 63 == 0 { lock.withLock { _progress = index } }
        }
        lock.withLock { _progress = list.count }
        for path in table.paths where !present.contains(path) { table.remove(path) }
        files = list
        return scanned
    }

    /// 파일 하나: 수정 시각·크기가 같으면 그대로, 다르면 다시 읽는다. 읽었으면 true.
    @discardableResult
    private func scan(_ rel: String, _ language: SyntaxLanguage) -> Bool {
        let path = root + "/" + rel
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            table.remove(rel)
            return false
        }
        guard info.st_size <= Self.maxFileBytes else {
            table.remove(rel)
            return false
        }
        let stamp = SymbolTable.FileStamp(modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                                          size: Int(info.st_size))
        if table.stamp(rel) == stamp { return false }
        guard let declarations = buffer.read(path, size: Int(info.st_size), { SymbolScanner.scan($0, language: language) }) else {
            table.remove(rel)
            return false
        }
        table.set(rel, stamp: stamp, declarations: declarations)
        return true
    }

    // MARK: - 질의(결과는 메인에서)

    func relative(_ path: String) -> String? {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    func absolute(_ rel: String) -> String { root + "/" + rel }

    /// 편집기에서 저장한 파일을 바로 다시 읽는다
    func fileSaved(_ path: String) {
        guard let rel = relative(path), let language = SymbolLanguages.language(path: rel) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.scan(rel, language)
            if !self.files.contains(where: { $0.path == rel }) { self.files.append((rel, language)) }
            let counts = (self.table.fileCount, self.table.symbolCount, self.table.names.count)
            DispatchQueue.main.async {
                self.stats.files = counts.0
                self.stats.symbols = counts.1
                self.stats.names = counts.2
            }
        }
    }

    /// 이 파일만 다시 확인(건너뛴 줄이 맞지 않을 때)
    func recheck(_ path: String) { fileSaved(path) }

    func lookup(_ name: String, _ completion: @escaping ([SymbolTable.Hit]) -> Void) {
        queue.async { [weak self] in
            let hits = self?.table.lookup(name) ?? []
            DispatchQueue.main.async { completion(hits) }
        }
    }

    private func nextGeneration() -> Int { lock.withLock { _generation += 1; return _generation } }
    private func isCurrent(_ generation: Int) -> Bool { lock.withLock { _generation == generation } }

    /// ⌘O 이름 찾기. 새 질의가 오면 앞의 것은 그만둔다.
    func search(_ pattern: String, _ completion: @escaping ([(hit: SymbolTable.Hit, score: Int, matched: [Int])]) -> Void) {
        let generation = nextGeneration()
        queue.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            let results = self.table.search(pattern, limit: 200) { !self.isCurrent(generation) }
            DispatchQueue.main.async {
                guard self.isCurrent(generation) else { return }
                completion(results)
            }
        }
    }

    /// ⌥F7: 이름이 통째로 나오는 곳(주석·문자열 밖). 지금 파일은 편집 중인 글로 찾는다. 가까운 파일부터, 500개까지.
    func usages(_ name: String, current: (path: String, text: String)?,
                _ completion: @escaping (_ hits: [UsageHit], _ capped: Bool, _ seconds: TimeInterval) -> Void) {
        let generation = nextGeneration()
        queue.async { [weak self] in
            guard let self else { return }
            let list = self.files
            let currentRel = current.flatMap { self.relative($0.path) }
            self.searchQueue.async {
                var buffer = FileBuffer()
                let started = Date()
                let currentDir = currentRel.map { ($0 as NSString).deletingLastPathComponent } ?? ""
                func closeness(_ rel: String) -> Int {
                    let a = (rel as NSString).deletingLastPathComponent.split(separator: "/"), b = currentDir.split(separator: "/")
                    var n = 0
                    while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
                    return n
                }
                var ordered = list.filter { $0.path != currentRel }
                ordered.sort { a, b in
                    let ca = closeness(a.path), cb = closeness(b.path)
                    return ca != cb ? ca > cb : a.path < b.path
                }
                var hits: [UsageHit] = []
                var capped = false
                if let current, let rel = currentRel ?? Optional((current.path as NSString).lastPathComponent),
                   let language = SymbolLanguages.language(path: current.path) {
                    var text = current.text
                    let found = text.withUTF8 { UsageFinder.find(name, in: $0, language: language, limit: Self.maxUsages) }
                    hits += found.map { UsageHit(path: rel, usage: $0) }
                }
                for (index, item) in ordered.enumerated() {
                    if hits.count >= Self.maxUsages { capped = true; break }
                    if index & 63 == 0, !self.isCurrent(generation) { return }
                    let path = self.root + "/" + item.path
                    let remaining = Self.maxUsages - hits.count
                    guard let found = buffer.read(path, size: nil, {
                        UsageFinder.find(name, in: $0, language: item.language, limit: remaining)
                    }) else { continue }
                    hits += found.map { UsageHit(path: item.path, usage: $0) }
                }
                let seconds = Date().timeIntervalSince(started)
                DispatchQueue.main.async {
                    guard self.isCurrent(generation) else { return }
                    completion(hits, capped, seconds)
                }
            }
        }
    }
}

/// 파일을 한 번의 read 로 다시 쓰는 버퍼에 읽는다(작은 파일 수천 개를 mmap·Data 로 읽는 것보다 가볍다)
struct FileBuffer {
    private var storage = [UInt8](repeating: 0, count: 64 << 10)

    /// size 를 모르면 fstat 으로. 1MB 넘거나 읽지 못하면 nil.
    mutating func read<T>(_ path: String, size: Int?, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var length = size ?? -1
        if length < 0 {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            length = Int(info.st_size)
        }
        guard length <= ProjectIndex.maxFileBytes else { return nil }
        if storage.count < length + 1 { storage = [UInt8](repeating: 0, count: length + 1) }
        return storage.withUnsafeMutableBufferPointer { pointer -> T? in
            var total = 0
            while total < length {
                let n = Darwin.read(fd, pointer.baseAddress! + total, length - total)
                if n <= 0 { break }
                total += n
            }
            return body(UnsafeBufferPointer(start: pointer.baseAddress, count: total))
        }
    }

    /// 시험용: AGENTDECK_INDEX_IO=standard 면 색인 스레드의 디스크 읽기를 늦추지 않는다(CPU 우선순위는 그대로 낮게)
    static func applyIOPolicy() {
        if AgentDeckEnv.value("INDEX_IO") == "standard" {
            setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_STANDARD)
        }
    }
}

/// 열린 프로젝트 색인들(최근 3개만 — 오래된 것은 놓는다)
final class IndexStore {
    private(set) var indexes: [ProjectIndex] = []
    static let capacity = 3

    func index(root: String, isGit: Bool) -> ProjectIndex {
        if let found = indexes.firstIndex(where: { $0.root == root }) {
            let index = indexes.remove(at: found)
            indexes.append(index)
            return index
        }
        let index = ProjectIndex(root: root, isGit: isGit)
        indexes.append(index)
        if indexes.count > Self.capacity { indexes.removeFirst(indexes.count - Self.capacity) }
        return index
    }

    /// 시험용: 색인을 놓는다(다시 만들어 시간을 잰다)
    func forget(root: String) { indexes.removeAll { $0.root == root } }

    /// 이미 만든 색인 중 이 파일을 담은 것
    func existing(containing path: String) -> [ProjectIndex] {
        indexes.filter { path.hasPrefix($0.root + "/") }
    }

    /// 파일의 프로젝트(작업 트리 맨 위, 저장소가 아니면 파일 폴더)
    static func root(forFile path: String) -> (path: String, isGit: Bool) {
        let directory = (path as NSString).deletingLastPathComponent
        if let location = GitWorktrees.locate(directory) { return (location.worktreeRoot, true) }
        return (directory, false)
    }

    /// 색인하기엔 너무 넓은 폴더(/, 홈, 그 위)
    static func isTooBroad(_ root: String) -> Bool {
        let home = NSHomeDirectory()
        return root == "/" || root == home || home.hasPrefix(root + "/") || root == "/Users" || root == "/tmp" || root == "/private/tmp"
    }
}
