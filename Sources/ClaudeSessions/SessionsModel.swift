import Foundation
import ServiceManagement
import SessionCore
import SwiftUI

struct SessionItem: Identifiable, Equatable {
    var record: SessionRecord
    var summary: TranscriptSummary
    var branch: String?
    /// git 저장소 최상위 폴더(저장소가 아니면 nil)
    var repoRoot: String?
    var isRunning: Bool
    /// 방금 열라고 보냈고 claude 가 뜨기를 기다리는 중
    var isOpening = false

    var id: String { record.sessionId }
    var folderName: String { (record.cwd as NSString).lastPathComponent }

    /// 목록을 묶는 프로젝트: git 저장소 최상위, 저장소가 아니면 세션 폴더
    var projectPath: String { repoRoot ?? record.cwd }
    var projectName: String { (projectPath as NSString).lastPathComponent }

    /// 저장소 안 하위 폴더에서 연 세션이면 그 상대 경로(예: "apps/web")
    var subpath: String? {
        guard let root = repoRoot, record.cwd.hasPrefix(root + "/") else { return nil }
        return String(record.cwd.dropFirst(root.count + 1))
    }

    /// 세션이 돌고 있는(돌던) 터미널
    var terminalName: String {
        switch record.termProgram {
        case "ghostty": return "Ghostty"
        case "iTerm.app": return "iTerm2"
        case "Apple_Terminal": return "터미널"
        case "vscode": return "VS Code"
        case "WarpTerminal": return "Warp"
        case let other?: return other
        case nil: return "알 수 없는 터미널"
        }
    }

    var title: String {
        summary.aiTitle ?? summary.customTitle ?? summary.lastPrompt.map(Self.firstLine) ?? "새 세션 (아직 대화 없음)"
    }

    /// 실행 명령의 {name} 과 탭 찾기에 쓰는 이름
    var name: String { summary.customTitle ?? summary.aiTitle ?? folderName }

    var location: String {
        branch.map { "\(folderName) @ \($0)" } ?? folderName
    }

    var lastPrompt: String? { summary.lastPrompt.map(Self.firstLine) }

    var lastActivity: Date {
        [summary.modifiedAt, record.endedAt, record.startedAt].compactMap { $0 }.max() ?? record.startedAt
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}

enum SettingsKey {
    static let terminal = "terminal"
    static let commandTemplate = "commandTemplate"
    static let retentionDays = "retentionDays"
    static let skipPermissions = "skipPermissions"
    static let showInDock = "showInDock"
    static let splitDirection = "splitDirection"
    /// 꺼진 세션을 다시 열 곳: original(세션이 돌던 터미널) / configured(설정된 터미널)
    static let reopenTarget = "reopenTarget"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            terminal: "ghostty",
            commandTemplate: CommandTemplate.defaultTemplate,
            retentionDays: 14,
            skipPermissions: false,
            showInDock: true,
            splitDirection: "right",
            reopenTarget: "original",
        ])
    }
}

/// 목록 만들기(파일·프로세스 조사). 메인 스레드를 막지 않도록 전용 큐에서만 쓴다.
final class SessionScanner {
    private let store: SessionStore
    private let reservations: LaunchReservations
    private var summaryCache: [String: (Date?, TranscriptCursor)] = [:]
    /// 대화 파일을 아직 못 찾은 세션: 다음 탐색 시각(매번 ~/.claude/projects 전체를 뒤지지 않게)
    private var locateRetryAt: [String: Date] = [:]

    init(store: SessionStore, reservations: LaunchReservations) {
        self.store = store
        self.reservations = reservations
    }

    struct Result {
        var running: [SessionItem]
        var stopped: [SessionItem]
    }

    func scan(retention: TimeInterval, now: Date = Date()) -> Result {
        let processes = LiveSessions.systemProcesses()
        let records: [SessionRecord] = store.withLock {
            store.removeSupersededSessions()
            // 같은 세션을 연 다른 claude 가 남아 있으면 그쪽으로 기록을 넘긴다(두 화면 중 하나만 닫은 경우 등)
            let adopted = LiveSessions.adopt(into: store, processes: processes)
            if !adopted.isEmpty { AppLog.write("남아 있는 claude 로 기록을 옮김: \(adopted.map { String($0.prefix(8)) })") }
            for record in store.all() where record.transcriptPath == nil
                && (locateRetryAt[record.sessionId] ?? .distantPast) <= now {
                if let path = TranscriptReader.locate(sessionId: record.sessionId) {
                    store.update(record.sessionId) { $0.transcriptPath = $0.transcriptPath ?? path }
                } else {
                    locateRetryAt[record.sessionId] = now.addingTimeInterval(30)
                }
            }
            // 꺼졌는데 대화 파일이 없으면 이어 열 수 없다(대화 없이 닫은 세션). 오래된 꺼진 세션도 정리한다.
            for record in store.all() where !record.isRunning {
                let missing = record.transcriptPath.map { !FileManager.default.fileExists(atPath: $0) } ?? true
                let last = [record.endedAt, record.activeSince, record.startedAt].compactMap { $0 }.max() ?? record.startedAt
                let modified = record.transcriptPath.flatMap {
                    (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
                }
                if missing || now.timeIntervalSince(max(last, modified ?? last)) > retention {
                    store.remove(record.sessionId)
                }
            }
            return store.all()
        }
        let opening = Set(reservations.active(now: now).keys)
        var items = records.map { record in
            SessionItem(
                record: record,
                summary: summary(for: record),
                branch: GitInfo.branch(at: record.cwd),
                repoRoot: GitInfo.repoRoot(at: record.cwd),
                isRunning: record.isRunning
            )
        }
        for index in items.indices where !items[index].isRunning && opening.contains(items[index].id) {
            items[index].isOpening = true
        }
        items.sort { $0.lastActivity > $1.lastActivity }
        return Result(running: items.filter(\.isRunning), stopped: items.filter { !$0.isRunning })
    }

    private func summary(for record: SessionRecord) -> TranscriptSummary {
        guard let path = record.transcriptPath else { return TranscriptSummary() }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let cached = summaryCache[path], cached.0 == modified { return cached.1.summary }
        // 바뀐 파일은 지난번에 읽은 뒤에 덧붙은 부분만 읽는다
        let cursor = TranscriptReader.update(path: path, cursor: summaryCache[path]?.1)
        summaryCache[path] = (modified, cursor)
        return cursor.summary
    }
}

@MainActor
final class SessionsModel: ObservableObject {
    static let shared = SessionsModel()

    @Published private(set) var running: [SessionItem] = []
    @Published private(set) var stopped: [SessionItem] = []
    @Published private(set) var hookStatus: HookInstaller.Status = .notInstalled
    @Published var message: String?
    /// 터미널별로 마지막에 기록한 배치(창·탭·분할)
    @Published private(set) var layouts: [String: LayoutSnapshot] = [:]
    /// 마지막으로 새로 고친 시각("n분 전" 기준). 5초마다 바뀌어 목록의 시각도 그때 갱신된다.
    @Published private(set) var lastRefresh = Date()
    /// "모두 열기"가 도는 중
    @Published private(set) var isRestoring = false

    private let store = SessionStore()
    private let reservations = LaunchReservations()
    private let scanner: SessionScanner
    /// 파일·프로세스 조사(목록)는 이 큐에서
    private let refreshQueue = DispatchQueue(label: "ClaudeSessions.refresh")
    /// 터미널 제어(osascript)는 수 초 걸릴 수 있어 메인 스레드 밖에서 순서대로 돌린다.
    private let launchQueue = DispatchQueue(label: "ClaudeSessions.launch")
    private var refreshGeneration = 0
    private var tick = 0
    private var timer: Timer?

    init() {
        SettingsKey.registerDefaults()
        scanner = SessionScanner(store: store, reservations: reservations)
        refreshHookStatus()
        // 앱을 다른 위치로 옮겨 기존 hook 이 가리키는 파일이 없어졌을 때만 조용히 고친다(이미 연결에 동의한 사용자).
        // 개발용 실행(CLAUDE_SESSIONS_HOME)은 settings.json 을 절대 건드리지 않는다.
        if ProcessInfo.processInfo.environment["CLAUDE_SESSIONS_HOME"] == nil, (try? installer.needsRepair()) == true {
            connectClaude(silently: true)
        }
        LayoutStore.migrateLegacy(toTerminal: launcher.id)
        layouts = SessionActions.loadLayouts()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.tick += 1
                if self.tick % 3 == 0 { self.captureLayout() }
            }
        }
    }

    var installer: HookInstaller {
        HookInstaller(executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    }

    var launcher: TerminalLauncher { SessionActions.configuredLauncher }

    // MARK: - 목록

    func refresh(then completion: (@MainActor () -> Void)? = nil) {
        let retention = TimeInterval(max(1, UserDefaults.standard.integer(forKey: SettingsKey.retentionDays)) * 86_400)
        refreshGeneration += 1
        let generation = refreshGeneration
        let scanner = scanner
        refreshQueue.async {
            let result = scanner.scan(retention: retention)
            Task { @MainActor in
                // 그 사이 더 새로운 새로 고침을 시작했으면 이 결과는 버린다
                guard generation == self.refreshGeneration else { return }
                self.lastRefresh = Date()
                if result.running != self.running { self.running = result.running }
                if result.stopped != self.stopped { self.stopped = result.stopped }
                completion?()
            }
        }
    }

    // MARK: - 동작

    /// 목록 행 클릭. 화면에 보이는 상태는 최대 5초 늦을 수 있어 누른 순간의 상태로 다시 판단한다.
    func activate(_ item: SessionItem) {
        let id = item.id
        let store = store
        launchQueue.async {
            let record = store.load(id)
            let processes = LiveSessions.systemProcesses()
            let isOpen = record.map { LiveSessions.openIds(records: [$0], processes: processes).contains(id) } ?? false
            Task { @MainActor in
                if isOpen, let record {
                    self.focus(record: record, summary: item.summary)
                } else if record != nil {
                    self.resume(item)
                } else {
                    self.message = "기록이 없어진 세션입니다(직접 종료함)."
                    self.refresh()
                }
            }
        }
    }

    /// skipPermissions 를 주면 이번 한 번만 설정값 대신 쓴다(우클릭 메뉴).
    func resume(_ item: SessionItem, skipPermissions: Bool? = nil) {
        guard FileManager.default.fileExists(atPath: item.record.cwd) else {
            message = "폴더가 없습니다: \(item.record.cwd)"
            return
        }
        let request = SessionActions.request(for: item.record, summary: item.summary, skipPermissions: skipPermissions)
        let store = store, reservations = reservations
        perform {
            guard let record = store.load(item.id) else { throw LaunchError.script("기록이 없어진 세션입니다.") }
            if try SessionActions.open(record, request: request, store: store, reservations: reservations) == .alreadyOpen {
                throw LaunchError.script("이미 열려 있거나 여는 중인 세션입니다.")
            }
        }
    }

    /// 꺼진 세션을 모두 연다. 터미널별로 기록된 배치(창·탭·분할)가 있으면 그대로 되살리고, 나머지는 새 탭으로 연다.
    func resumeAllStopped() {
        guard !isRestoring else { return }
        let items = stopped.filter { !$0.isOpening && FileManager.default.fileExists(atPath: $0.record.cwd) }
        guard !items.isEmpty else { return }
        let prepared = items.map { ($0.id, SessionActions.request(for: $0.record, summary: $0.summary)) }
        let direction = UserDefaults.standard.string(forKey: SettingsKey.splitDirection) ?? "right"
        let store = store, reservations = reservations
        isRestoring = true
        perform(finally: { self.isRestoring = false }) {
            // 누른 순간의 최신 기록으로(목록은 최대 5초 늦을 수 있다)
            let work = prepared.compactMap { id, request in store.load(id).map { (record: $0, request: request) } }
            let started = try SessionActions.restoreAll(work, splitDirection: direction, store: store,
                                                        reservations: reservations)
            if started < prepared.count {
                AppLog.write("모두 열기: \(prepared.count)개 중 \(prepared.count - started)개는 이미 열려 있거나 여는 중이라 건너뜀")
            }
        }
    }

    /// 지금 터미널 배치에서 실행 중 세션의 위치를 기록한다(재부팅에 대비해 15초마다).
    func captureLayout() {
        guard !running.isEmpty else { return }
        let running = running.map { item in
            (record: item.record, titles: [
                item.summary.aiTitle, item.summary.customTitle,
                ProcessUtil.arguments(item.record.pid).flatMap(RunningSessionScanner.nameArgument),
            ].compactMap { $0 })
        }
        let knownIds = Set((self.running + stopped).map(\.id))
        launchQueue.async {
            let changed = SessionActions.captureLayouts(running: running, knownIds: knownIds)
            guard !changed.isEmpty else { return }
            Task { @MainActor in self.layouts.merge(changed) { $1 } }
        }
    }

    private func focus(record: SessionRecord, summary: TranscriptSummary) {
        // 새 세션은 아직 제목이 없으므로 `claude -n <이름>` 으로 준 이름도 탭 제목 후보로 쓴다.
        let launchName = ProcessUtil.arguments(record.pid).flatMap(RunningSessionScanner.nameArgument)
        let titles = [summary.aiTitle, summary.customTitle, launchName].compactMap { $0 }
        let cwd = record.cwd
        let tty = ProcessUtil.info(record.pid)?.tty ?? record.tty
        // 탭 이동은 설정된 터미널이 아니라 세션이 실제로 돌고 있는 터미널에서 한다.
        let launcher = SessionActions.sourceTerminal(of: record)
        perform {
            if try !launcher.focus(titles: titles, cwd: cwd, tty: tty) {
                AppLog.write("탭 이동 실패(\(launcher.displayName)): tty=\(tty ?? "-") 제목=\(titles) 폴더=\(cwd)")
                throw LaunchError.script("열려 있는 탭을 찾지 못했습니다.")
            }
        }
    }

    func forget(_ item: SessionItem) {
        store.remove(item.id)
        refresh()
    }

    func forgetAllStopped() {
        stopped.forEach { store.remove($0.id) }
        refresh()
    }

    private func perform(finally: (@MainActor () -> Void)? = nil, _ action: @escaping () throws -> Void) {
        launchQueue.async {
            var failure: String?
            do {
                try action()
            } catch {
                failure = error.localizedDescription
            }
            Task { @MainActor in
                if let failure { self.message = failure }
                finally?()
                self.refresh() // "여는 중" 표시를 바로 반영
            }
        }
    }

    // MARK: - Claude Code 연결

    func refreshHookStatus() {
        do {
            hookStatus = try installer.status()
        } catch {
            hookStatus = .notInstalled
            message = error.localizedDescription
        }
    }

    func connectClaude(silently: Bool = false) {
        do {
            try installer.install()
            let imported = store.withLock { RunningSessionScanner.importRunning(into: store) }
            if !silently {
                message = imported > 0
                    ? "연결했습니다. 이미 열려 있던 세션 \(imported)개를 가져왔습니다."
                    : "연결했습니다. 이제부터 여는 Claude 세션이 기록됩니다."
            }
        } catch {
            message = error.localizedDescription
        }
        refreshHookStatus()
        refresh()
    }

    func disconnectClaude() {
        do {
            try installer.uninstall()
            message = "연결을 해제했습니다. 기존 기록은 남아 있습니다."
        } catch {
            message = error.localizedDescription
        }
        refreshHookStatus()
    }

    // MARK: - 로그인 시 실행

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                message = "로그인 항목 설정 실패: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}
