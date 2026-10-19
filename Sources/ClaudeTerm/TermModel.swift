import AppKit
import Foundation
import SessionCore
import TermLayout
import TermWire

/// 왼쪽 목록 한 줄(화면 하나)
struct PaneRow: Identifiable, Equatable {
    var pane: PaneInfo
    /// 이 화면에서 도는 Claude 세션(hook 기록의 tty 로 찾음)
    var session: SessionRecord?
    /// 탭·목록·분할 테두리가 함께 쓰는 이름(TermModel.name 규칙)
    var name: String
    /// 지금 작업 폴더(claude 가 돌면 claude 의, 아니면 셸의). 작업 트리로 옮겨 가면 따라간다.
    var cwd: String
    var git: GitLocation?
    /// claude 를 띄웠던 실행 인자(세션 지정 인자 뺀 것). 되살릴 때 같은 옵션으로 띄운다.
    var claudeArgs: [String]? = nil
    var codex: CodexSession?
    var codexArgs: [String]?
    var codexHome: String?
    var dormantCodex = false
    var dormantCodexSessionId: String?
    /// 작업 상태와 그 상태가 된 시각(hook 기록)
    var status: WorkStatus = .none
    var statusAt: Date?
    /// 상태 번호(hook 이 상태를 적을 때마다 오름, 예전 기록엔 없음) — 같은 초의 상태 변화를 구분한다
    var statusSeq: Int?
    /// 이 claude 가 띄운 하위 에이전트 중 작업 트리를 특정하지 못한 것(목록에서 이 줄 아래에 보인다)
    var agents: [SubagentActivity] = []
    /// 데몬이 꺼져 사라진 화면(탭을 열면 되살린다)
    var dormant = false

    var id: String { pane.id }
    var isCodex: Bool { codex != nil || pane.foreground == "codex" || dormantCodex || codexArgs != nil }
    var agentColor: NSColor { isCodex ? TermAppearance.codexColor : isClaude ? TermAppearance.claudeColor : TermAppearance.textDim }
    var statusSessionId: String? { codex.map { "codex:" + $0.id } ?? session?.sessionId }
    var isClaude: Bool { session != nil || pane.foreground == "claude" || dormantClaude }
    /// 꺼진 화면에서 claude 가 돌고 있었는지
    var dormantClaude = false
    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "ksh", "dash", "nu"]
    /// 앞에 셸만 떠 있는지("zsh (kiro-cli-term)" 처럼 감싼 셸도 셸로 본다). claude 가 짝지어졌으면 셸이 아니다.
    var isShell: Bool {
        guard session == nil, !isCodex, let name = pane.foreground?.split(separator: " ").first else { return false }
        return Self.shellNames.contains(String(name))
    }
    /// 목록에 보일 프로그램 이름
    var program: String {
        if isCodex { return "codex" }
        if isClaude { return "claude" }
        return pane.foreground.flatMap { $0.split(separator: " ").first.map(String.init) } ?? "셸"
    }

    var title: String { name }

    /// 이름을 바꿀 때 쓰는 열쇠: claude 세션이면 세션에, 아니면 화면에 붙인다
    var nameKey: String {
        if let id = codex?.id ?? dormantCodexSessionId { return "codex:" + id }
        return session.map { SessionNames.sessionKey($0.sessionId) } ?? SessionNames.paneKey(pane.id)
    }

    var folder: String { (cwd as NSString).lastPathComponent }
}

/// 목록의 작업 트리 칸(git 이 아니면 폴더 하나)
struct WorktreeSection: Identifiable, Equatable {
    var path: String
    var name: String
    var branch: String?
    var isMain: Bool
    var isClaude: Bool
    var rows: [PaneRow]
    /// 이 작업 트리에서 일하는 하위 에이전트(다른 폴더의 claude 가 띄운 것)
    var agents: [SubagentActivity] = []

    var id: String { path }
}

/// 목록의 폴더 묶음(git 저장소면 저장소 단위로, 작업 트리를 아래에 펼친다)
struct FolderGroup: Identifiable, Equatable {
    var path: String
    var isGit: Bool
    var sections: [WorktreeSection]

    var id: String { path }
    var name: String {
        path == NSHomeDirectory() ? "~" : (path as NSString).lastPathComponent
    }
    var branch: String? { sections.first { $0.isMain }?.branch }
}

final class TermModel: ObservableObject {
    @Published var rows: [PaneRow] = []
    @Published var groups: [FolderGroup] = []
    @Published private(set) var workspace = Workspace()
    @Published var connected = false
    @Published var daemonFootprint: UInt64 = 0
    @Published var appFootprint: UInt64 = 0
    @Published var lastError: String?
    /// Claude Code hook 연결 상태(세션 짝짓기·이름·되살리기·상태 표시의 바탕)
    @Published var hookState: HookState = .unknown
    @Published var codexHookState: HookState = .unknown
    @Published var notice: String?

    enum HookState: Equatable {
        case unknown
        case ok
        /// 연결 안 됨(또는 앱을 옮겨 경로가 바뀜)
        case missing
        /// 예전 ClaudeSessions 앱의 hook 으로 기록 중(그 앱을 지우면 끊긴다)
        case legacy
        /// 이 앱 hook 이 있지만 예전 것(상태 표시 이벤트가 빠짐, 또는 앱을 옮김)
        case update
        case error(String)
    }

    let client = DaemonClient()
    /// 편집기 문서(편집기 화면은 데몬과 상관없이 앱 안에만 있다)
    let editors = EditorManager()
    /// 오른쪽 터미널이 붙을 곳(TerminalHostController)
    weak var host: TerminalHostController?
    private var timer: Timer?
    private var titles: [String: (path: String, cursor: TranscriptCursor)] = [:]
    /// 세션별 첫 질문(찾으면 고정). 못 찾았으면 그때 파일 크기를 적어 두고 커질 때만 다시 본다.
    private var firstPrompts: [String: (prompt: String?, size: UInt64)] = [:]
    let names = SessionNames()
    /// spaces 의 접기·보이는 순서(탭 순서와 따로)
    let spaces = SpacesStore()
    private let codexScanner = CodexScanner()
    /// 하위 에이전트 훑기(worker 전용). 10초에 한 번만.
    private let subagents = SubagentScanner()
    private var lastAgentScan = Date.distantPast
    private var lastAgents: [SubagentActivity] = []
    /// 되살린 시각(그 직후 잠깐은 세션 정보를 지키려고)
    private var revivedAt: [String: Date] = [:]
    /// 만들라고 보냈지만 아직 목록에 안 나타난 화면(그 사이 온 목록 때문에 배치에서 빠지지 않게)
    private var awaiting: [String: Date] = [:]
    /// 만들기를 보냈는데 이만큼 지나도 데몬 목록에 안 나타나면 실패로 본다(연결이 끊겼거나 데몬이 만들지 못함)
    static let createTimeout: TimeInterval = 15
    /// 되살리기에 실패한 시각(바로 다시 시도해 같은 실패를 되풀이하지 않게)
    private var reviveFailedAt: [String: Date] = [:]
    /// 닫으라고 보냈지만 아직 목록에 남은 화면(새 탭으로 다시 붙지 않게)
    private var closing: Set<String> = []
    /// 데몬 목록을 한 번이라도 받았는지(받기 전엔 저장된 배치를 맞춰 볼 수 없다)
    private var reconciled = false

    private static var layoutURL: URL { TermPaths.home.appendingPathComponent("layout.json") }

    /// 목록에서 고른 줄 = 지금 탭의 포커스 화면
    var selectedId: String? { workspace.selectedTab?.focused }

    private var daemonPath: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("ClaudeTermDaemon").path
    }
    /// hook 은 데몬 실행 파일이 맡는다(AppKit 을 띄우지 않아 가볍다)
    private var hookInstaller: HookInstaller { .claude(daemonPath: daemonPath) }
    private var codexHookInstaller: HookInstaller { .codex(daemonPath: daemonPath) }

    func connectCodexHooks() {
        do {
            _ = try codexHookInstaller.install()
            notice = "Codex 상태 연결을 추가했습니다. Codex의 /hooks 에서 ClaudeTermDaemon 훅을 검토·신뢰한 뒤 사용하세요(갱신했으면 다시 신뢰)."
        } catch { notice = "Codex 연결 실패: \(error.localizedDescription)" }
        checkHooks()
    }

    /// 메뉴 "Claude Code 연결 해제…": 무엇을 빼는지 보여 주고 확인받은 뒤 이 앱의 hook 만 뺀다
    func disconnectHooks() {
        disconnect(hookInstaller, label: "Claude Code", effect: "새로 시작하는 claude 세션의 이름·되살리기·작업 상태·알림이 동작하지 않습니다.")
    }

    func disconnectCodexHooks() {
        disconnect(codexHookInstaller, label: "Codex", effect: "Codex 세션의 권한 요청·질문 대기·완료 상태와 알림이 더 이상 오지 않습니다.")
    }

    private func disconnect(_ installer: HookInstaller, label: String, effect: String) {
        let file = (installer.settingsURL.path as NSString).abbreviatingWithTildeInPath
        let alert = NSAlert()
        alert.messageText = "\(label) 연결을 해제할까요?"
        alert.informativeText = """
            \(file) 에서 이 앱이 넣은 hook(ClaudeTermDaemon, \(installer.eventNames.count)개 이벤트)만 뺍니다. \
            다른 hook·설정은 그대로이고, 바꾸기 전에 백업을 남깁니다.

            \(effect) 이미 열린 세션은 계속 돌고, 언제든 다시 연결할 수 있습니다.
            """
        alert.addButton(withTitle: "연결 해제")
        alert.addButton(withTitle: "취소")
        guard AppAlert.run(alert) == .alertFirstButtonReturn else { return }
        do {
            let result = try installer.uninstall()
            notice = result.removed == 0 ? "\(label): 뺄 hook 이 없습니다."
                : "\(label) 연결을 해제했습니다(hook \(result.removed)개)."
                    + (result.backup.map { "\n이전 설정 백업: \(($0.path as NSString).abbreviatingWithTildeInPath)" } ?? "")
        } catch {
            notice = "\(label) 연결을 해제하지 못했습니다: \(error.localizedDescription)"
        }
        checkHooks()
    }

    func checkHooks() {
        let installer = hookInstaller
        let codexInstaller = codexHookInstaller
        worker.async { [weak self] in
            let state: HookState
            do {
                let status = try installer.status()
                let legacy = try installer.hasLegacyHooks()
                switch status {
                case .installed: state = .ok
                case .outdated: state = .update
                case .notInstalled: state = legacy ? .legacy : .missing
                }
            } catch {
                state = .error(error.localizedDescription)
            }
            let codexState: HookState
            do {
                switch try codexInstaller.status() {
                case .installed: codexState = .ok
                case .outdated: codexState = .update
                case .notInstalled: codexState = .missing
                }
            } catch { codexState = .error(error.localizedDescription) }
            DispatchQueue.main.async { self?.hookState = state; self?.codexHookState = codexState }
        }
    }

    /// ~/.claude/settings.json 에 hook 을 넣는다(사용자가 누를 때만). 예전 ClaudeSessions hook 은 같이 뺀다.
    func connectHooks() {
        do {
            let backup = try hookInstaller.install(replacingLegacy: true)
            notice = "Claude Code 에 연결했습니다. 새로 시작하는 claude 세션부터 적용됩니다."
                + (backup.map { "\n이전 설정 백업: \(($0.path as NSString).abbreviatingWithTildeInPath)" } ?? "")
        } catch {
            notice = "연결하지 못했습니다: \(error.localizedDescription)"
        }
        checkHooks()
    }

    let notifier = Notifier()
    /// 새 버전 알림(하루 한 번까지, 켤 때·앞으로 나올 때만)
    let updates = UpdateNotifier()
    /// 알림을 보낸 상태(세션별 "세션#상태 번호", 번호 없는 예전 기록은 "상태@시각") — 같은 상태로 두 번 보내지 않는다
    private var notified: [String: String] = [:]
    private var notifyPrimed = false

    func start() {
        checkHooks()
        updates.start()
        editors.onTitleChange = { [weak self] in
            self?.pinDirtyPreviews() // 고치면(●) 미리보기가 아니다
            self?.host?.refreshTitles()
        }
        notifier.onOpen = { [weak self] pane in self?.focus(pane: pane) }
        notifier.start()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.markSeen() }
        if let data = try? Data(contentsOf: Self.layoutURL),
           let saved = try? JSONDecoder().decode(Workspace.self, from: data) {
            workspace = saved
        }
        names.onChange = { [weak self] in self?.client.list() }
        client.onState = { [weak self] state in self?.apply(state) }
        client.onOutput = { [weak self] id, bytes, replay in self?.host?.receive(id: id, bytes: bytes, replay: replay) }
        client.onExited = { [weak self] id in self?.host?.paneExited(id) }
        client.onError = { [weak self] message in self?.lastError = message }
        client.onDisconnect = { [weak self] in
            self?.connected = false
            self?.host?.render()
        }
        reconnect()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reconnect() {
        connected = client.connect()
        if connected {
            // 다시 붙었으면 배치가 그대로여도 화면을 새로 만들어 붙인다(끊길 때 화면을 모두 버렸으므로)
            reconciled = false
            client.list()
        } else {
            lastError = "데몬에 연결하지 못했습니다"
        }
    }

    private func tick() {
        appFootprint = Memory.footprint()
        if client.isConnected { client.list() } else { reconnect() }
    }

    // MARK: - 데몬 목록 → 목록·배치

    /// 기록 읽기·대화 제목 읽기·폴더 확인은 파일을 읽으므로 메인 스레드 밖에서 한다(입력·화면 그리기가 끊기지 않게).
    private let worker = DispatchQueue(label: "ClaudeTerm.rows", qos: .utility)

    private func apply(_ state: DaemonState) {
        daemonFootprint = state.footprint
        appFootprint = Memory.footprint()
        let seen = seenDone
        let dormant = workspace.allPanes.filter { workspace.dormant.contains($0) }.compactMap { id in
            workspace.recipes[id].map { (id, $0) }
        }
        worker.async { [weak self] in
            guard let self else { return }
            let newRows = self.makeRows(state.panes, seen: seen) + dormant.map { self.dormantRow(id: $0.0, recipe: $0.1) }
            let newGroups = Self.makeGroups(newRows, agents: self.scanAgents(newRows))
            DispatchQueue.main.async { self.show(newRows, newGroups, daemonPid: state.pid, instance: state.instance) }
        }
    }

    /// worker 에서만 부른다(titles 도 worker 에서만 쓴다)
    private func makeRows(_ panes: [PaneInfo], seen: [String: WorkStateRules.Seen] = [:]) -> [PaneRow] {
        // hook 기록 중 실행 중인 세션을 화면에 짝짓는다. claude 에서 부모 프로세스를 따라 올라가 화면의 셸을 만나면 그 화면이다.
        // (Kiro CLI 처럼 셸을 자기 가상 터미널로 한 겹 감싸는 도구가 있으면 claude 의 tty 가 화면의 tty 와 다르다.)
        // 계보로 못 찾으면 tty 로 짝짓는다.
        // 프로세스 목록은 sysctl 한 번으로 찍어 아래 계보 찾기들이 같이 쓴다
        let snapshot = ProcessUtil.snapshot()
        let codexMatches = codexScanner.scan(panes, snapshot: snapshot)
        let running = SessionStore().all().filter(\.isRunning)
        func device(_ tty: String?) -> String? { tty.map { ($0 as NSString).lastPathComponent } } // "/dev/ttys002" ↔ "ttys002"
        let shells = Dictionary(panes.map { ($0.pid, $0.id) }, uniquingKeysWith: { first, _ in first })
        var sessionByPane: [String: SessionRecord] = [:]
        // hook 이 남긴 화면 ID 가 맞으면 그대로(가장 정확). 같은 화면에 여럿이면 최근 것.
        let paneIds = Set(panes.map(\.id))
        for record in running.sorted(by: { ($0.activeSince ?? $0.startedAt) < ($1.activeSince ?? $1.startedAt) }) {
            if let pane = record.pane, paneIds.contains(pane) { sessionByPane[pane] = record }
        }
        for record in running where !sessionByPane.values.contains(where: { $0.sessionId == record.sessionId }) {
            if let pane = snapshot.pane(of: record.pid, shells: shells, maxHops: 32), sessionByPane[pane] == nil {
                sessionByPane[pane] = record
            }
        }
        // 감싼 셸이 있는 화면은 안쪽 셸의 폴더를 읽어야 cd 를 따라간다
        let wrapped = panes.contains { ($0.foreground ?? "").contains(" (") }
        func innermostShell(_ pid: pid_t) -> pid_t { snapshot.innermostShell(from: pid, names: PaneRow.shellNames) }
        return panes.map { pane -> PaneRow in
            let codexMatch = codexMatches[pane.id]
            let session = codexMatch == nil ? (sessionByPane[pane.id]
                ?? device(pane.tty).flatMap { tty in running.first { device($0.tty) == tty } }) : nil
            let shell = wrapped ? innermostShell(pane.pid) : pane.pid
            let codexSessionCwd: String? = codexMatch?.session?.cwd
            let codexProcessCwd: String? = codexMatch.flatMap { ProcessUtil.cwd($0.process.pid) }
            let claudeCwd: String? = session.flatMap { ProcessUtil.cwd($0.pid) ?? $0.cwd }
            let agentCwd: String? = codexSessionCwd.flatMap { $0.isEmpty ? nil : $0 } ?? codexProcessCwd ?? claudeCwd
            let cwd: String = agentCwd ?? ProcessUtil.cwd(shell) ?? pane.cwd
            var row = PaneRow(pane: pane, session: session, name: name(pane: pane, session: session, cwd: cwd),
                              cwd: cwd, git: GitWorktrees.locate(cwd),
                              claudeArgs: session.flatMap { ProcessUtil.arguments($0.pid) }.map(PaneRecipe.keptArgs))
            if let match = codexMatch {
                row.codex = match.session
                row.codexArgs = CodexArguments.keptArgs(match.args)
                row.codexHome = match.home.path
                if let codex = match.session {
                    row.name = names.userTitle("codex:" + codex.id) ?? names.userTitle(SessionNames.paneKey(pane.id))
                        ?? (codex.title.isEmpty ? (cwd as NSString).lastPathComponent : SessionNaming.preview(of: codex.title))
                    let state = WorkStateRules.effective(state: codex.state, at: codex.stateAt, seq: codex.stateSeq,
                        transcriptModifiedAt: nil, seen: seen["codex:" + codex.id])
                    row.status = WorkStatus(state: state, message: codex.message)
                    if row.status == .unknown { row.status = .codexUnknown }
                    row.statusAt = codex.stateAt
                    row.statusSeq = codex.stateSeq
                } else { row.status = .codexUnknown }
            } else {
                (row.status, row.statusAt, row.statusSeq) = workStatus(session, isClaude: row.isClaude, seen: seen)
            }
            return row
        }
    }

    /// 실행 중인 claude 의 하위 에이전트를 10초에 한 번 훑는다(worker 에서)
    private func scanAgents(_ rows: [PaneRow]) -> [SubagentActivity] {
        guard Date().timeIntervalSince(lastAgentScan) >= 10 else { return lastAgents }
        lastAgentScan = Date()
        let sessions = rows.compactMap { row -> (paneId: String, sessionId: String, transcript: String, worktrees: [String])? in
            guard !row.dormant, let session = row.session,
                  let path = session.transcriptPath ?? TranscriptReader.locate(sessionId: session.sessionId)
            else { return nil }
            let worktrees = row.git.map { GitWorktrees.list($0).filter { !$0.isMain }.map(\.path) } ?? []
            return (row.id, session.sessionId, path, worktrees)
        }
        lastAgents = subagents.scan(sessions)
        for row in rows where !row.dormant {
            guard let codex = row.codex else { continue }
            let home = URL(fileURLWithPath: row.codexHome ?? CodexSessions.defaultHome.path)
            for (child, status) in codexScanner.reader(home).children(of: codex.id) {
                let at = child.stateAt ?? .distantPast
                guard Date().timeIntervalSince(at) < 15 * 60 else { continue }
                let worktrees = row.git.map { GitWorktrees.list($0).filter { !$0.isMain }.map(\.path) } ?? []
                let tree = worktrees.first { child.cwd == $0 || child.cwd.hasPrefix($0 + "/") }
                lastAgents.append(SubagentActivity(id: child.id, sessionId: "codex:" + codex.id, paneId: row.id,
                    description: child.title.isEmpty ? "Codex 하위 에이전트" : SessionNaming.preview(of: child.title),
                    agentType: "codex", worktreePath: tree, lastActive: at, lastText: child.lastText,
                    running: child.state == "working" && status != "closed"))
            }
        }
        return lastAgents
    }

    /// 폴더(저장소)별로 묶는다. 처음 나온 순서를 지키고, 저장소는 작업 트리 목록을 함께 보여 준다.
    /// 하위 에이전트는 일하는 작업 트리 아래에, 작업 트리를 모르면 띄운 claude 줄 아래에 붙인다.
    static func makeGroups(_ rows: [PaneRow], agents: [SubagentActivity] = []) -> [FolderGroup] {
        let rows = rows.map { row -> PaneRow in
            var row = row
            row.agents = agents.filter { $0.paneId == row.id && $0.worktreePath == nil }
            return row
        }
        var order: [String] = []
        var byKey: [String: [PaneRow]] = [:]
        var locations: [String: GitLocation] = [:]
        for row in rows {
            let key = row.git?.repoRoot ?? (row.cwd as NSString).standardizingPath
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(row)
            if let git = row.git, locations[key] == nil { locations[key] = git }
        }
        return order.map { key in
            let members = byKey[key] ?? []
            guard let location = locations[key] else {
                return FolderGroup(path: key, isGit: false, sections: [
                    WorktreeSection(path: key, name: (key as NSString).lastPathComponent, branch: nil, isMain: true,
                                    isClaude: false, rows: members),
                ])
            }
            let worktrees = GitWorktrees.list(location)
            let known = Set(worktrees.map(\.path))
            let sections = worktrees.map { tree in
                WorktreeSection(path: tree.path, name: tree.name, branch: tree.branch, isMain: tree.isMain,
                                isClaude: tree.isClaude, rows: members.filter {
                                    let root = $0.git?.worktreeRoot ?? key
                                    return root == tree.path || (tree.isMain && !known.contains(root))
                                }, agents: tree.isMain ? [] : agents.filter { $0.worktreePath == tree.path })
            }
            return FolderGroup(path: key, isGit: true, sections: sections)
        }
    }

    private func show(_ newRows: [PaneRow], _ newGroups: [FolderGroup], daemonPid: Int32, instance: String?) {
        if newRows != rows {
            rows = newRows
            host?.refreshTitles()
        }
        notifyAttention(newRows)
        markSeen()
        updateDockBadge()
        if newGroups != groups { groups = newGroups }
        let live = newRows.filter { !$0.dormant }.map(\.id)
        if live.contains(where: { reviveFailedAt[$0] != nil }) { lastError = nil } // 다시 시도해 되살아났다
        live.forEach { awaiting[$0] = nil; reviveFailedAt[$0] = nil }
        let failed = awaiting.filter { Date().timeIntervalSince($0.value) > Self.createTimeout }.map(\.key)
        failed.forEach { awaiting[$0] = nil }
        closing.formIntersection(live)
        var next = workspace
        // 만들지 못한 화면: 되살리던 것은 다시 "꺼짐"으로(탭을 다시 열면 재시도), 새로 만들던 것은 뺀다
        for id in failed where next.allPanes.contains(id) {
            if next.recipes[id] != nil {
                next.dormant.insert(id)
                reviveFailedAt[id] = Date()
                lastError = "화면을 되살리지 못했습니다. 잠시 뒤 탭을 다시 열면 다시 시도합니다."
            } else {
                next.forget(pane: id)
                lastError = "새 화면을 만들지 못했습니다."
            }
        }
        var changed = next.reconcile(live: live, keep: Set(awaiting.keys), ignore: closing,
                                     daemonPid: daemonPid, daemonInstance: instance) || !failed.isEmpty
        // 되살리기 정보: 지금 폴더, claude 세션, 실행 옵션
        for row in newRows where !row.dormant && next.allPanes.contains(row.id) {
            var recipe = PaneRecipe(cwd: row.cwd, sessionId: row.session?.sessionId, claudeArgs: row.claudeArgs,
                                    codexSessionId: row.codex?.id, codexArgs: row.codexArgs, codexHome: row.codexHome)
            // 되살린 직후 claude 가 아직 안 떴으면(세션 기록 전) 원래 세션을 지우지 않는다
            if recipe.sessionId == nil, recipe.codexSessionId == nil, let old = next.recipes[row.id],
               old.sessionId != nil || old.codexSessionId != nil,
               (row.isCodex && old.codexSessionId != nil) || revivedAt[row.id].map({ Date().timeIntervalSince($0) < 60 }) == true {
                recipe.sessionId = old.sessionId
                recipe.claudeArgs = old.claudeArgs
                recipe.codexSessionId = old.codexSessionId
                recipe.codexArgs = old.codexArgs
                recipe.codexHome = old.codexHome
            }
            if row.session != nil || row.codex != nil { revivedAt[row.id] = nil }
            if next.recipes[row.id] != recipe {
                next.recipes[row.id] = recipe
                changed = true
            }
        }
        let first = !reconciled
        reconciled = true
        let newlyDormant = next.dormant != workspace.dormant
        if changed || first { setWorkspace(next, render: true) }
        if newlyDormant { client.list() } // 꺼진 화면을 목록에 바로 보이게
    }

    /// 화면에서 확인한 "완료"의 시각(세션별). 이보다 늦은 완료만 "완료"로, 아니면 "쉬는 중"으로 보인다.
    private var seenDone: [String: WorkStateRules.Seen] = [:]

    /// 작업 상태(worker 에서). hook 이 없는 때는 가볍게 보완한다(WorkStateRules.effective):
    /// 입력 대기 뒤에 대화 파일이 다시 늘면(권한을 허락해 이어서 일함) 작업 중으로 본다.
    /// 대화 파일 수정 시각은 이름 정하기(titles)와 따로, 입력 대기일 때만 stat 한 번으로 읽는다
    /// (이 앱에서 이름을 바꾼 세션은 이름 정하기가 대화 파일을 읽지 않아 titles 가 비거나 낡는다).
    private func workStatus(_ session: SessionRecord?, isClaude: Bool,
                            seen: [String: WorkStateRules.Seen]) -> (WorkStatus, Date?, Int?) {
        guard let session else { return (isClaude ? .unknown : .none, nil, nil) }
        let at = session.stateAt
        let modified = session.state == "waiting"
            ? WorkStateRules.transcriptModifiedAt(session.transcriptPath ?? titles[session.sessionId]?.path)
            : nil
        let state = WorkStateRules.effective(state: session.state, at: at, seq: session.stateSeq,
                                             transcriptModifiedAt: modified, seen: seen[session.sessionId])
        return (WorkStatus(state: state, message: session.stateMessage), at, session.stateSeq)
    }

    /// 꺼진 화면 대화 파일에서 읽은 제목(세션당 한 번만 읽는다 — 매번 읽으면 2초마다 최대 16MB 를 읽게 된다). worker 전용.
    private var dormantTitles: [String: String?] = [:]

    /// 지금 보고 있는 화면의 "완료"는 확인한 것으로 친다(앱이 앞에 있을 때만)
    func markSeen() {
        guard NSApp.isActive, let id = selectedId, let row = row(id), row.status == .done,
              let sid = row.statusSessionId, let at = row.statusAt,
              !WorkStateRules.isSeen(seenDone[sid], seq: row.statusSeq, at: at)
        else { return }
        seenDone[sid] = WorkStateRules.Seen(seq: row.statusSeq, at: at)
        notifier.clear(paneId: id)
        client.list() // 바로 "쉬는 중"으로 다시 그린다
    }

    /// 입력 대기·완료·오류로 바뀐 화면을 알린다. 지금 보고 있는 화면은 알리지 않는다.
    /// 앱을 켠 직후의 첫 목록은 지금 상태로 기억만 하고 알리지 않는다(켤 때마다 알림이 쏟아지지 않게).
    private func notifyAttention(_ rows: [PaneRow]) {
        for row in rows where !row.dormant {
            guard let sid = row.statusSessionId, let at = row.statusAt, row.status.needsAttention else { continue }
            // 시각만 보면(초 단위 저장) 같은 초에 입력 대기 → 완료가 이어질 때 완료 알림이 빠진다 → 상태 번호로
            let key = WorkStateRules.notificationKey(sessionId: sid, seq: row.statusSeq, state: row.status.debugName, at: at)
            guard notified[sid] != key else { continue }
            notified[sid] = key
            guard notifyPrimed else { continue }
            let watching = NSApp.isActive && row.id == selectedId
            guard !watching, let label = row.status.label else { continue }
            notifier.post(title: "\(label) · \(row.name)", body: row.status.detail ?? row.cwd,
                          paneId: row.id, key: key)
        }
        notifyPrimed = true
    }

    /// Dock 아이콘에 확인이 필요한 화면 수
    private func updateDockBadge() {
        let count = rows.filter { !$0.dormant && $0.status.needsAttention }.count
        let label = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// 꺼진 화면의 목록 줄(worker 에서)
    private func dormantRow(id: String, recipe: PaneRecipe) -> PaneRow {
        let pane = PaneInfo(id: id, title: "", cwd: recipe.cwd, pid: 0, tty: nil, foreground: nil, cols: 0, rows: 0,
                            bufferedBytes: 0, createdAt: Date(timeIntervalSince1970: 0))
        var name = (recipe.cwd as NSString).lastPathComponent
        if let sid = recipe.codexSessionId {
            let reader = codexScanner.reader(URL(fileURLWithPath: recipe.codexHome ?? CodexSessions.defaultHome.path))
            name = names.userTitle("codex:" + sid) ?? reader.session(sid).map {
                $0.title.isEmpty ? name : SessionNaming.preview(of: $0.title)
            } ?? name
        } else if let sid = recipe.sessionId {
            if let titled = names.userTitle(SessionNames.sessionKey(sid)) ?? names.savedAutoTitle(session: sid) {
                name = titled
            } else {
                if dormantTitles[sid] == nil {
                    var title: String?
                    if let path = TranscriptReader.locate(sessionId: sid) {
                        let summary = TranscriptReader.read(path: path)
                        if let custom = summary.customTitle, !SessionNaming.isAutomatic(custom, cwd: recipe.cwd) { title = custom }
                        else { title = summary.aiTitle }
                    }
                    dormantTitles[sid] = .some(title)
                }
                if let title = dormantTitles[sid] ?? nil { name = title }
            }
        } else if let user = names.userTitle(SessionNames.paneKey(id)) {
            name = user
        }
        return PaneRow(pane: pane, session: nil, name: name, cwd: recipe.cwd, git: GitWorktrees.locate(recipe.cwd),
                       claudeArgs: recipe.claudeArgs, codexArgs: recipe.codexArgs, codexHome: recipe.codexHome,
                       dormantCodex: recipe.codexSessionId != nil, dormantCodexSessionId: recipe.codexSessionId, dormant: true, dormantClaude: recipe.sessionId != nil)
    }

    /// 꺼진 화면을 같은 자리(같은 ID)에 되살린다. 탭을 열어 화면이 보이게 될 때 부른다(한꺼번에 다 띄우지 않게).
    /// claude 세션이 있었으면 그 셸에서 `claude --resume <세션>` 을 원래 옵션으로 실행한다.
    @discardableResult
    func revive(_ ids: [String]) -> [String] {
        let targets = ids.filter { id in
            workspace.dormant.contains(id) && (reviveFailedAt[id].map { Date().timeIntervalSince($0) > 30 } ?? true)
        }
        guard !targets.isEmpty, client.isConnected else { return [] }
        let size = host?.estimatedSize(splitting: nil) ?? (cols: 120, rows: 36)
        var next = workspace
        for id in targets {
            guard let recipe = next.recipes[id] else { continue }
            // 대화를 한 번도 안 한 세션은 대화 파일이 없어 이어 열 수 없다 → 셸만
            // 시험용: CLAUDE_TERM_RESUME_PREFIX="echo" 면 실제 claude 대신 명령만 찍는다(대화 파일 확인도 건너뜀)
            let testPrefix = ProcessInfo.processInfo.environment["CLAUDE_TERM_RESUME_PREFIX"]
            let codexExists = recipe.codexSessionId.flatMap { sid in
                CodexSessions(home: URL(fileURLWithPath: recipe.codexHome ?? CodexSessions.defaultHome.path)).session(sid)
            } != nil
            let resumable = testPrefix != nil || codexExists || (recipe.sessionId.map { TranscriptReader.locate(sessionId: $0) != nil } ?? false)
            let command = recipe.resumeCommand.map { (testPrefix.map { $0 + " " } ?? "") + $0 + "\n" }
            let cwd = FileManager.default.fileExists(atPath: recipe.cwd) ? recipe.cwd : NSHomeDirectory()
            awaiting[id] = Date()
            revivedAt[id] = Date()
            client.create(CreateRequest(id: id, cwd: cwd, cols: size.cols, rows: size.rows,
                                        input: resumable ? command : nil))
            next.dormant.remove(id)
        }
        workspace = next // 그리는 중에 불리므로 다시 그리기는 하지 않는다
        saveLayout()
        client.list()
        return targets
    }

    /// 화면 이름 하나로 정하기(worker 에서). 앞의 것이 있으면 그것을 쓴다:
    /// 1. 이 앱에서 직접 바꾼 이름
    /// 2. 사람이 붙인 claude 세션 이름(/rename, `claude -n`) — claudec 처럼 "<폴더>@<브랜치>" 로 기계적으로 붙인 이름은 빼고
    /// 3. claude 가 스스로 붙인 제목(ai-title)
    /// 4. 첫 질문으로 지은 제목(Orca 처럼). 짓는 동안은 첫 질문 앞부분
    /// 5. 기계적으로 붙은 이름, 그것도 없으면 폴더 이름
    private func name(pane: PaneInfo, session: SessionRecord?, cwd: String) -> String {
        let folder = (cwd as NSString).lastPathComponent
        guard let session else { return names.userTitle(SessionNames.paneKey(pane.id)) ?? folder }
        if let user = names.userTitle(SessionNames.sessionKey(session.sessionId)) { return user }
        let path = session.transcriptPath ?? TranscriptReader.locate(sessionId: session.sessionId)
        var summary = TranscriptSummary()
        if let path {
            let previous = titles[session.sessionId].flatMap { $0.path == path ? $0.cursor : nil }
            let cursor = TranscriptReader.update(path: path, cursor: previous)
            titles[session.sessionId] = (path, cursor)
            summary = cursor.summary
        }
        let custom = summary.customTitle
        if let custom, !SessionNaming.isAutomatic(custom, cwd: session.cwd) { return custom }
        if let ai = summary.aiTitle { return ai }
        if let path, let prompt = firstPrompt(session: session.sessionId, path: path) {
            return names.autoTitle(session: session.sessionId, prompt: prompt) ?? SessionNaming.preview(of: prompt)
        }
        return custom ?? folder
    }

    private func firstPrompt(session id: String, path: String) -> String? {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value ?? 0
        if let known = firstPrompts[id], known.prompt != nil || known.size == size { return known.prompt }
        // 앞 2MB 안에 질문이 없던 큰 파일(이어 하기 요약으로 시작하는 세션 등)은 다시 읽지 않는다
        if let known = firstPrompts[id], known.size >= 2 << 20 { return nil }
        let prompt = TranscriptReader.firstPrompt(path: path)
        firstPrompts[id] = (prompt, size)
        return prompt
    }

    func row(_ id: String) -> PaneRow? { rows.first { $0.id == id } }

    func tabTitle(_ tab: TabState) -> String {
        paneLabel(tab.focused)
    }

    /// 분할 테두리 제목(탭·목록과 같은 이름). 편집기는 파일 이름, 저장 안 했으면 뒤에 ●.
    func paneLabel(_ id: String) -> String {
        if EditorPane.isEditor(id) {
            let name = workspace.editors[id].map { ($0.path as NSString).lastPathComponent } ?? "…"
            return editors.isDirty(id) ? name + " ●" : name
        }
        return row(id)?.title ?? "…"
    }

    /// 이름 바꾸기(빈 칸이면 자동 이름으로 돌아간다)
    func rename(pane id: String) {
        guard !EditorPane.isEditor(id), let row = row(id) else { return }
        let alert = NSAlert()
        alert.messageText = "이름 바꾸기"
        alert.informativeText = "탭·목록·분할 테두리에 함께 보입니다. 비우면 자동 이름(첫 질문으로 지은 제목)으로 돌아갑니다."
        let field = NSTextField(string: names.userTitle(row.nameKey) ?? row.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        names.setUserTitle(row.nameKey, field.stringValue)
        client.list() // 새 이름으로 목록을 다시 만든다
    }

    func renameFocused() {
        if let id = selectedId { rename(pane: id) }
    }

    // MARK: - 배치 바꾸기

    private var saveWork: DispatchWorkItem?

    /// render: 보일 화면이 바뀌었으면 true(뷰를 새로 만든다), 포커스·비율만 바뀌었으면 false
    private func setWorkspace(_ next: Workspace, render: Bool) {
        let before = workspace
        workspace = next
        if render || before.selectedTab?.visibleRoot != next.selectedTab?.visibleRoot
            || before.tabs.count != next.tabs.count {
            host?.render()
        } else {
            host?.focusChanged()
        }
        saveLayout()
        markSeen() // 탭·화면을 옮겨 "완료"를 보게 됐으면 확인 처리
    }

    /// 앱을 끌 때: 미뤄 둔 배치 저장을 바로 쓴다
    func saveLayoutNow() {
        saveWork?.cancel()
        saveWork = nil
        if let data = try? JSONEncoder().encode(workspace) { try? data.write(to: Self.layoutURL, options: .atomic) }
    }

    /// 끌어서 비율을 바꾸는 동안 매번 쓰지 않게 잠시 모았다 쓴다
    private func saveLayout() {
        saveWork?.cancel()
        let data = try? JSONEncoder().encode(workspace)
        let work = DispatchWorkItem { [url = Self.layoutURL] in try? data?.write(to: url, options: .atomic) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func updateSelectedTab(render: Bool = false, _ change: (inout TabState) -> Void) {
        guard let index = workspace.selectedIndex else { return }
        var next = workspace
        change(&next.tabs[index])
        setWorkspace(next, render: render)
    }

    /// 목록에서 고르거나 화면을 눌렀을 때: 그 화면이 있는 탭으로 가서 포커스
    func focus(pane id: String, fromClick: Bool = false) {
        guard let index = workspace.tabIndex(containing: id) else { return }
        var next = workspace
        next.selected = next.tabs[index].id
        if next.tabs[index].focused != id {
            next.tabs[index].focused = id
            // 크게 보던 중 다른 화면을 고르면 크게 보기를 푼다
            if !fromClick { next.tabs[index].zoomed = false }
        }
        guard next != workspace else { return }
        setWorkspace(next, render: false)
    }

    /// 새 화면. command 가 있으면 셸이 뜬 뒤 입력한다. split 이 있으면 지금 화면을 나눠 넣고, 없으면 새 탭.
    func newPane(cwd: String? = nil, command: String? = nil, split axis: SplitAxis? = nil) {
        guard client.isConnected || client.connect() else { return }
        connected = true
        let cwd = cwd ?? focusedCwd ?? NSHomeDirectory()
        let size = host?.estimatedSize(splitting: axis) ?? (cols: 120, rows: 36)
        let id = UUID().uuidString
        awaiting[id] = Date()
        client.create(CreateRequest(id: id, cwd: cwd, cols: size.cols, rows: size.rows,
                                    input: command.map { $0 + "\n" }))
        var next = workspace
        if let axis, let index = next.selectedIndex {
            var tab = next.tabs[index]
            tab.root = tab.root.splitting(tab.focused, with: id, axis: axis)
            tab.focused = id
            tab.zoomed = false
            next.tabs[index] = tab
        } else {
            let tab = TabState(root: .pane(id), focused: id)
            let at = next.selectedIndex.map { $0 + 1 } ?? next.tabs.count
            next.tabs.insert(tab, at: at)
            next.selected = tab.id
        }
        setWorkspace(next, render: true)
        client.list()
    }

    var focusedRow: PaneRow? { selectedId.flatMap(row) }

    /// 지금 화면의 폴더(편집기면 그 파일이 있는 폴더) — 새 탭·분할이 여기서 열린다
    var focusedCwd: String? {
        if let id = selectedId, let path = workspace.editors[id]?.path { return (path as NSString).deletingLastPathComponent }
        return focusedRow?.cwd
    }

    // MARK: - 편집기

    /// 파일 열기(files 도구 두 번 클릭·Enter·메뉴). 이미 열려 있으면 그 화면으로 간다.
    /// 아니면 지금 탭 바로 뒤 새 탭에(split 이 있으면 지금 화면을 나눠) 연다.
    func openFile(_ path: String, split axis: SplitAxis? = nil) {
        let path = (path as NSString).standardizingPath
        if let existing = workspace.editorPane(path: path) {
            focus(pane: existing)
            host?.focusPane()
            return
        }
        let id = EditorPane.newId()
        var next = workspace
        next.editors[id] = EditorRecipe(path: path)
        if let axis, let index = next.selectedIndex {
            var tab = next.tabs[index]
            tab.root = tab.root.splitting(tab.focused, with: id, axis: axis)
            tab.focused = id
            tab.zoomed = false
            next.tabs[index] = tab
        } else {
            let tab = TabState(root: .pane(id), focused: id)
            let at = next.selectedIndex.map { $0 + 1 } ?? next.tabs.count
            next.tabs.insert(tab, at: at)
            next.selected = tab.id
        }
        setWorkspace(next, render: true)
    }

    // MARK: 파일 트리에서 열기(배치 규칙은 TermLayout `Workspace.openPreview`·`openStacked`·`openGrid`)

    /// 두 번 클릭·Enter: 지금 화면 옆 미리보기 화면에(이미 열렸으면 그 화면으로)
    func openFromTree(_ path: String) {
        pinDirtyPreviews()
        var next = workspace
        let result = next.openPreview(path: (path as NSString).standardizingPath, newId: EditorPane.newId)
        applyOpen(next, result)
    }

    /// 여러 파일을 한꺼번에: 4개까지는 지금 화면 옆 칸에 위아래로, 더 많으면 물어보고 새 탭에 격자로(12개까지)
    func openFromTree(paths: [String]) {
        let paths = paths.map { ($0 as NSString).standardizingPath }
        guard paths.count > 1 else {
            if let path = paths.first { openFromTree(path) }
            return
        }
        pinDirtyPreviews()
        var next = workspace
        let result: FileOpenResult
        if paths.count <= Workspace.maxStackedFiles {
            result = next.openStacked(paths: paths, newId: EditorPane.newId)
        } else {
            let alert = NSAlert()
            alert.messageText = "\(paths.count)개 파일을 새 탭에 열까요?"
            alert.informativeText = paths.count > Workspace.maxGridFiles
                ? "한 탭에 \(Workspace.maxGridFiles)개까지 나눠 엽니다. 앞의 \(Workspace.maxGridFiles)개만 열립니다."
                : "새 탭 하나에 나눠 엽니다."
            alert.addButton(withTitle: "새 탭에 열기")
            alert.addButton(withTitle: "취소")
            guard AppAlert.run(alert) == .alertFirstButtonReturn else { return }
            result = next.openGrid(paths: paths, newId: EditorPane.newId)
        }
        applyOpen(next, result)
    }

    private func applyOpen(_ next: Workspace, _ result: FileOpenResult) {
        guard next != workspace else { return }
        setWorkspace(next, render: true) // 뷰를 먼저 떼고
        result.closed.forEach(editors.remove) // 바꿔 쓴 미리보기 문서를 닫는다
        host?.focusPane()
    }

    /// 미리보기를 보통 화면으로(제목 두 번 누르기·"고정")
    func pin(editor id: String) {
        var next = workspace
        guard next.pin(editor: id) else { return }
        setWorkspace(next, render: false)
        host?.refreshTitles()
    }

    /// 고친 미리보기는 고정한다(다음 파일이 그 자리를 덮지 않게)
    private func pinDirtyPreviews() {
        var next = workspace
        var changed = false
        for (id, recipe) in workspace.editors where recipe.isPreview && editors.isDirty(id) {
            changed = next.pin(editor: id) || changed
        }
        if changed { setWorkspace(next, render: false) }
    }

    /// ⌘S: 지금 화면이 편집기면 저장
    @discardableResult
    func saveFocused() -> Bool {
        guard let id = selectedId, EditorPane.isEditor(id), let document = editors.documents[id] else { return false }
        return document.save()
    }

    var focusedIsEditor: Bool { selectedId.map(EditorPane.isEditor) ?? false }

    /// 편집기 커서를 배치 파일에 기억한다(다시 켜도 그 자리로). 그리기 중에 불릴 수 있어 다음 차례에.
    func rememberEditorCursor(_ id: String, _ cursor: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.workspace.editors[id] != nil, self.workspace.editors[id]?.cursor != cursor else { return }
            self.workspace.editors[id]?.cursor = cursor
            self.saveLayout()
        }
    }

    /// 편집기 화면 닫기: 저장 안 한 내용이 있으면 저장 / 저장 안 함 / 취소를 묻는다
    private func closeEditor(_ id: String, confirm: Bool) {
        if confirm, let document = editors.documents[id], !editors.confirmClose([document]) { return }
        var next = workspace
        next.forget(pane: id)
        setWorkspace(next, render: true) // 뷰를 먼저 떼고
        editors.remove(id)               // 문서를 닫는다
    }

    /// 앱을 끄기 전: 저장 안 한 편집기가 있으면 묻는다. 꺼도 되면 true.
    func confirmQuit() -> Bool {
        editors.confirmClose(editors.dirtyDocuments)
    }

    /// 화면 닫기(셸·claude 종료). 셸이 아닌 프로그램이 돌고 있으면 묻는다(Ghostty 처럼).
    func close(pane id: String, confirm: Bool = true) {
        if EditorPane.isEditor(id) {
            closeEditor(id, confirm: confirm)
            return
        }
        let row = row(id)
        if confirm, let row, !row.isShell, !row.dormant {
            let alert = NSAlert()
            alert.messageText = "\(row.title) 화면을 닫을까요?"
            alert.informativeText = row.isClaude
                ? "이 화면의 claude 가 종료됩니다. 대화는 나중에 이어 열 수 있습니다."
                : "이 화면에서 \(row.pane.foreground ?? "프로그램")이(가) 실행 중입니다. 닫으면 종료됩니다."
            alert.addButton(withTitle: "닫기")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        closing.insert(id)
        client.kill(id)
        var next = workspace
        next.forget(pane: id)
        setWorkspace(next, render: true)
    }

    func closeFocused() {
        if let id = selectedId { close(pane: id) }
    }

    func closeTab() {
        guard let tab = workspace.selectedTab else { return }
        // 저장 안 한 편집기를 먼저 묻는다(취소하면 아무것도 닫지 않는다)
        let documents = tab.root.panes.filter(EditorPane.isEditor).compactMap { editors.documents[$0] }
        guard editors.confirmClose(documents) else { return }
        let rows = tab.root.panes.compactMap(row)
        let busy = rows.filter { !$0.isShell }
        if !busy.isEmpty {
            let alert = NSAlert()
            alert.messageText = "탭을 닫을까요? 화면 \(tab.root.panes.count)개가 종료됩니다."
            alert.informativeText = "실행 중: " + busy.map(\.title).joined(separator: ", ")
            alert.addButton(withTitle: "닫기")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for id in tab.root.panes { close(pane: id, confirm: false) }
    }

    func selectTab(_ index: Int) {
        guard workspace.tabs.indices.contains(index) else { return }
        var next = workspace
        next.selected = next.tabs[index].id
        setWorkspace(next, render: true)
    }

    func selectTab(offset: Int) {
        guard let index = workspace.selectedIndex, !workspace.tabs.isEmpty else { return }
        let count = workspace.tabs.count
        selectTab(((index + offset) % count + count) % count)
    }

    func moveFocus(_ direction: Direction) {
        guard let tab = workspace.selectedTab, !tab.zoomed,
              let target = tab.root.neighbor(of: tab.focused, toward: direction) else { return }
        focus(pane: target)
    }

    /// 분할 순서대로 다음/이전 화면(Ghostty goto_split previous/next)
    func cycleFocus(_ offset: Int) {
        guard let tab = workspace.selectedTab, !tab.zoomed else { return }
        let panes = tab.root.panes
        guard panes.count > 1, let index = panes.firstIndex(of: tab.focused) else { return }
        focus(pane: panes[((index + offset) % panes.count + panes.count) % panes.count])
    }

    func toggleZoom() {
        guard let tab = workspace.selectedTab, tab.root.panes.count > 1 else { return }
        updateSelectedTab(render: true) { $0.zoomed.toggle() }
    }

    func equalize() {
        updateSelectedTab { $0.root = $0.root.equalized() }
    }

    func resizeSplit(_ direction: Direction) {
        updateSelectedTab { $0.root = $0.root.resizing($0.focused, toward: direction, by: 0.05) }
    }

    func setRatio(path: [Bool], ratio: Double) {
        updateSelectedTab { $0.root = $0.root.settingRatio(at: path, to: ratio) }
    }

    // MARK: - 탭·화면 옮기기
    // 배치만 바꾼다. 데몬 화면(PTY)은 그대로라 셸·claude 가 다시 뜨지 않고, 계속 보이는 화면은 뷰도 그대로 옮겨 붙는다.

    /// 탭 줄에서 끌어 순서 바꾸기(to = 옮긴 뒤 자리). 옮긴 탭을 고른다.
    func moveTab(from: Int, to: Int) {
        guard workspace.tabs.indices.contains(from) else { return }
        move(tab: workspace.tabs[from].id, to: .tab(gap: to > from ? to + 1 : to))
    }

    /// 지금 탭을 왼쪽(-1)·오른쪽(+1)으로 한 칸
    func moveSelectedTab(by offset: Int) {
        guard let index = workspace.selectedIndex else { return }
        var next = workspace
        guard next.moveTab(from: index, to: index + offset) else { return }
        setWorkspace(next, render: false)
    }

    func move(tab id: String, to drop: PaneDrop) {
        var next = workspace
        guard next.move(tab: id, to: drop) else { return }
        setWorkspace(next, render: true)
    }

    func move(pane id: String, to drop: PaneDrop) {
        var next = workspace
        guard next.move(pane: id, to: drop) else { return }
        setWorkspace(next, render: true)
    }

    /// 지금 화면을 새 탭으로 꺼내 지금 탭 바로 뒤에 둔다(분할된 탭에서만)
    func extractPane(_ id: String? = nil) {
        guard let id = id ?? selectedId, let index = workspace.tabIndex(containing: id),
              workspace.tabs[index].root.panes.count > 1 else { return }
        move(pane: id, to: .tab(gap: index + 1))
    }

    /// 메뉴·단축키·시험 명령이 함께 쓰는 이름
    func perform(_ action: String) {
        let parts = action.split(separator: ":").map(String.init)
        switch parts.first {
        case "new-tab": newPane()
        case "split-right": newPane(split: .horizontal)
        case "split-down": newPane(split: .vertical)
        case "close": closeFocused()
        case "close-tab": closeTab()
        case "rename": renameFocused()
        case "save": saveFocused()
        case "markdown-preview": host?.focusedEditor?.togglePreview()
        case "goto-declaration": host?.navigator.gotoDeclaration()
        case "find-usages": host?.navigator.findUsages()
        case "goto-symbol": host?.navigator.gotoSymbol()
        case "nav-back": host?.navigator.back()
        case "nav-forward": host?.navigator.forward()
        case "focus": if let direction = parts.dropFirst().first.flatMap({ Direction(rawValue: $0) }) { moveFocus(direction) }
        case "next-split": cycleFocus(1)
        case "previous-split": cycleFocus(-1)
        case "zoom": toggleZoom()
        case "equalize": equalize()
        case "resize": if let direction = parts.dropFirst().first.flatMap({ Direction(rawValue: $0) }) { resizeSplit(direction) }
        case "move-tab": moveSelectedTab(by: parts.dropFirst().first == "left" ? -1 : 1)
        case "extract-pane": extractPane()
        case "next-tab": selectTab(offset: 1)
        case "previous-tab": selectTab(offset: -1)
        case "update-check": updates.checkNow()
        case "hooks-disconnect": disconnectHooks()
        case "codex-hooks-disconnect": disconnectCodexHooks()
        case "tab":
            if parts.count > 1, let number = Int(parts[1]) {
                selectTab(number >= 9 ? workspace.tabs.count - 1 : number - 1)
            }
        default: break
        }
    }
}
