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
    /// 데몬이 꺼져 사라진 화면(탭을 열면 되살린다)
    var dormant = false

    var id: String { pane.id }
    var isClaude: Bool { session != nil || pane.foreground == "claude" || dormantClaude }
    /// 꺼진 화면에서 claude 가 돌고 있었는지
    var dormantClaude = false
    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "ksh", "dash", "nu"]
    /// 앞에 셸만 떠 있는지("zsh (kiro-cli-term)" 처럼 감싼 셸도 셸로 본다). claude 가 짝지어졌으면 셸이 아니다.
    var isShell: Bool {
        guard session == nil, let name = pane.foreground?.split(separator: " ").first else { return false }
        return Self.shellNames.contains(String(name))
    }
    /// 목록에 보일 프로그램 이름
    var program: String {
        if isClaude { return "claude" }
        return pane.foreground.flatMap { $0.split(separator: " ").first.map(String.init) } ?? "셸"
    }

    var title: String { name }

    /// 이름을 바꿀 때 쓰는 열쇠: claude 세션이면 세션에, 아니면 화면에 붙인다
    var nameKey: String {
        session.map { SessionNames.sessionKey($0.sessionId) } ?? SessionNames.paneKey(pane.id)
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

    let client = DaemonClient()
    /// 오른쪽 터미널이 붙을 곳(TerminalHostController)
    weak var host: TerminalHostController?
    private var timer: Timer?
    private var titles: [String: (path: String, cursor: TranscriptCursor)] = [:]
    /// 세션별 첫 질문(찾으면 고정). 못 찾았으면 그때 파일 크기를 적어 두고 커질 때만 다시 본다.
    private var firstPrompts: [String: (prompt: String?, size: UInt64)] = [:]
    let names = SessionNames()
    /// 되살린 시각(그 직후 잠깐은 세션 정보를 지키려고)
    private var revivedAt: [String: Date] = [:]
    /// 만들라고 보냈지만 아직 목록에 안 나타난 화면(그 사이 온 목록 때문에 배치에서 빠지지 않게)
    private var awaiting: Set<String> = []
    /// 닫으라고 보냈지만 아직 목록에 남은 화면(새 탭으로 다시 붙지 않게)
    private var closing: Set<String> = []
    /// 데몬 목록을 한 번이라도 받았는지(받기 전엔 저장된 배치를 맞춰 볼 수 없다)
    private var reconciled = false

    private static var layoutURL: URL { TermPaths.home.appendingPathComponent("layout.json") }

    /// 목록에서 고른 줄 = 지금 탭의 포커스 화면
    var selectedId: String? { workspace.selectedTab?.focused }

    func start() {
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
        if connected { client.list() } else { lastError = "데몬에 연결하지 못했습니다" }
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
        let dormant = workspace.allPanes.filter { workspace.dormant.contains($0) }.compactMap { id in
            workspace.recipes[id].map { (id, $0) }
        }
        worker.async { [weak self] in
            guard let self else { return }
            let newRows = self.makeRows(state.panes) + dormant.map { self.dormantRow(id: $0.0, recipe: $0.1) }
            let newGroups = Self.makeGroups(newRows)
            DispatchQueue.main.async { self.show(newRows, newGroups, daemonPid: state.pid) }
        }
    }

    /// worker 에서만 부른다(titles 도 worker 에서만 쓴다)
    private func makeRows(_ panes: [PaneInfo]) -> [PaneRow] {
        // hook 기록 중 실행 중인 세션을 화면에 짝짓는다. claude 에서 부모 프로세스를 따라 올라가 화면의 셸을 만나면 그 화면이다.
        // (Kiro CLI 처럼 셸을 자기 가상 터미널로 한 겹 감싸는 도구가 있으면 claude 의 tty 가 화면의 tty 와 다르다.)
        // 계보로 못 찾으면 tty 로 짝짓는다.
        let running = SessionStore().all().filter(\.isRunning)
        func device(_ tty: String?) -> String? { tty.map { ($0 as NSString).lastPathComponent } } // "/dev/ttys002" ↔ "ttys002"
        let shells = Dictionary(panes.map { ($0.pid, $0.id) }, uniquingKeysWith: { first, _ in first })
        var sessionByPane: [String: SessionRecord] = [:]
        for record in running {
            var pid = record.pid
            for _ in 0..<32 {
                guard pid > 1, let info = ProcessUtil.info(pid) else { break }
                if let pane = shells[pid] {
                    if sessionByPane[pane] == nil { sessionByPane[pane] = record }
                    break
                }
                pid = info.ppid
            }
        }
        // 감싼 셸이 있는 화면은 안쪽 셸의 폴더를 읽어야 cd 를 따라간다(자식 목록은 그런 화면이 있을 때만 만든다)
        let wrapped = panes.contains { ($0.foreground ?? "").contains(" (") }
        var children: [pid_t: [ProcInfo]] = [:]
        if wrapped {
            for pid in ProcessUtil.allPids() {
                if let info = ProcessUtil.info(pid) { children[info.ppid, default: []].append(info) }
            }
        }
        func innermostShell(_ pid: pid_t) -> pid_t {
            var current = pid
            for _ in 0..<8 {
                guard let next = children[current]?.first(where: { PaneRow.shellNames.contains($0.command) }) else { break }
                current = next.pid
            }
            return current
        }
        return panes.map { pane -> PaneRow in
            let session = sessionByPane[pane.id]
                ?? device(pane.tty).flatMap { tty in running.first { device($0.tty) == tty } }
            let shell = wrapped ? innermostShell(pane.pid) : pane.pid
            let cwd = session.flatMap { ProcessUtil.cwd($0.pid) ?? $0.cwd } ?? ProcessUtil.cwd(shell) ?? pane.cwd
            return PaneRow(pane: pane, session: session, name: name(pane: pane, session: session, cwd: cwd),
                           cwd: cwd, git: GitWorktrees.locate(cwd),
                           claudeArgs: session.flatMap { ProcessUtil.arguments($0.pid) }.map(PaneRecipe.keptArgs))
        }
    }

    /// 폴더(저장소)별로 묶는다. 처음 나온 순서를 지키고, 저장소는 작업 트리 목록을 함께 보여 준다.
    static func makeGroups(_ rows: [PaneRow]) -> [FolderGroup] {
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
                                })
            }
            return FolderGroup(path: key, isGit: true, sections: sections)
        }
    }

    private func show(_ newRows: [PaneRow], _ newGroups: [FolderGroup], daemonPid: Int32) {
        if newRows != rows {
            rows = newRows
            host?.refreshTitles()
        }
        if newGroups != groups { groups = newGroups }
        let live = newRows.filter { !$0.dormant }.map(\.id)
        awaiting.subtract(live)
        closing.formIntersection(live)
        var next = workspace
        var changed = next.reconcile(live: live, keep: awaiting, ignore: closing, daemonPid: daemonPid)
        // 되살리기 정보: 지금 폴더, claude 세션, 실행 옵션
        for row in newRows where !row.dormant && next.allPanes.contains(row.id) {
            var recipe = PaneRecipe(cwd: row.cwd, sessionId: row.session?.sessionId, claudeArgs: row.claudeArgs)
            // 되살린 직후 claude 가 아직 안 떴으면(세션 기록 전) 원래 세션을 지우지 않는다
            if recipe.sessionId == nil, let old = next.recipes[row.id], old.sessionId != nil,
               let revived = revivedAt[row.id], Date().timeIntervalSince(revived) < 60 {
                recipe.sessionId = old.sessionId
                recipe.claudeArgs = old.claudeArgs
            }
            if row.session != nil { revivedAt[row.id] = nil }
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

    /// 꺼진 화면의 목록 줄(worker 에서)
    private func dormantRow(id: String, recipe: PaneRecipe) -> PaneRow {
        let pane = PaneInfo(id: id, title: "", cwd: recipe.cwd, pid: 0, tty: nil, foreground: nil, cols: 0, rows: 0,
                            bufferedBytes: 0, createdAt: Date(timeIntervalSince1970: 0))
        var name = (recipe.cwd as NSString).lastPathComponent
        if let sid = recipe.sessionId {
            if let titled = names.userTitle(SessionNames.sessionKey(sid)) ?? names.savedAutoTitle(session: sid) {
                name = titled
            } else if let path = TranscriptReader.locate(sessionId: sid) {
                let summary = TranscriptReader.read(path: path)
                if let custom = summary.customTitle, !SessionNaming.isAutomatic(custom, cwd: recipe.cwd) { name = custom }
                else if let ai = summary.aiTitle { name = ai }
            }
        } else if let user = names.userTitle(SessionNames.paneKey(id)) {
            name = user
        }
        return PaneRow(pane: pane, session: nil, name: name, cwd: recipe.cwd, git: GitWorktrees.locate(recipe.cwd),
                       claudeArgs: recipe.claudeArgs, dormant: true, dormantClaude: recipe.sessionId != nil)
    }

    /// 꺼진 화면을 같은 자리(같은 ID)에 되살린다. 탭을 열어 화면이 보이게 될 때 부른다(한꺼번에 다 띄우지 않게).
    /// claude 세션이 있었으면 그 셸에서 `claude --resume <세션>` 을 원래 옵션으로 실행한다.
    func revive(_ ids: [String]) {
        let targets = ids.filter { workspace.dormant.contains($0) }
        guard !targets.isEmpty, client.isConnected else { return }
        let size = host?.estimatedSize(splitting: nil) ?? (cols: 120, rows: 36)
        var next = workspace
        for id in targets {
            guard let recipe = next.recipes[id] else { continue }
            // 대화를 한 번도 안 한 세션은 대화 파일이 없어 이어 열 수 없다 → 셸만
            // 시험용: CLAUDE_TERM_RESUME_PREFIX="echo" 면 실제 claude 대신 명령만 찍는다(대화 파일 확인도 건너뜀)
            let testPrefix = ProcessInfo.processInfo.environment["CLAUDE_TERM_RESUME_PREFIX"]
            let resumable = testPrefix != nil || (recipe.sessionId.map { TranscriptReader.locate(sessionId: $0) != nil } ?? false)
            let command = recipe.resumeCommand.map { (testPrefix.map { $0 + " " } ?? "") + $0 + "\n" }
            let cwd = FileManager.default.fileExists(atPath: recipe.cwd) ? recipe.cwd : NSHomeDirectory()
            awaiting.insert(id)
            revivedAt[id] = Date()
            client.create(CreateRequest(id: id, cwd: cwd, cols: size.cols, rows: size.rows,
                                        input: resumable ? command : nil))
            next.dormant.remove(id)
        }
        workspace = next // 그리는 중에 불리므로 다시 그리기는 하지 않는다
        saveLayout()
        client.list()
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
        row(tab.focused)?.title ?? "…"
    }

    /// 분할 테두리 제목(탭·목록과 같은 이름)
    func paneLabel(_ id: String) -> String {
        row(id)?.title ?? "…"
    }

    /// 이름 바꾸기(빈 칸이면 자동 이름으로 돌아간다)
    func rename(pane id: String) {
        guard let row = row(id) else { return }
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
        let cwd = cwd ?? focusedRow?.cwd ?? NSHomeDirectory()
        let size = host?.estimatedSize(splitting: axis) ?? (cols: 120, rows: 36)
        let id = UUID().uuidString
        awaiting.insert(id)
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

    /// 화면 닫기(셸·claude 종료). 셸이 아닌 프로그램이 돌고 있으면 묻는다(Ghostty 처럼).
    func close(pane id: String, confirm: Bool = true) {
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

    func moveTab(from: Int, to: Int) {
        guard workspace.tabs.indices.contains(from), workspace.tabs.indices.contains(to), from != to else { return }
        var next = workspace
        next.tabs.insert(next.tabs.remove(at: from), at: to)
        setWorkspace(next, render: false)
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
        case "focus": if let direction = parts.dropFirst().first.flatMap({ Direction(rawValue: $0) }) { moveFocus(direction) }
        case "next-split": cycleFocus(1)
        case "previous-split": cycleFocus(-1)
        case "zoom": toggleZoom()
        case "equalize": equalize()
        case "resize": if let direction = parts.dropFirst().first.flatMap({ Direction(rawValue: $0) }) { resizeSplit(direction) }
        case "next-tab": selectTab(offset: 1)
        case "previous-tab": selectTab(offset: -1)
        case "tab":
            if parts.count > 1, let number = Int(parts[1]) {
                selectTab(number >= 9 ? workspace.tabs.count - 1 : number - 1)
            }
        default: break
        }
    }
}
