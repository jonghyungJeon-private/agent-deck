import AppKit
import Combine
import TermLayout
import TermWire

/// 파일 트리의 한 줄(폴더·파일). NSOutlineView 는 항목을 객체 정체성으로 기억하므로 클래스.
final class FileNode {
    let path: String
    /// 루트 기준 상대 경로(루트는 "")
    let rel: String
    let name: String
    let isDirectory: Bool
    /// nil = 아직 안 읽음(펼칠 때 읽는다)
    var children: [FileNode]?
    var loading = false

    init(path: String, rel: String, name: String, isDirectory: Bool) {
        self.path = path
        self.rel = rel
        self.name = name
        self.isDirectory = isDirectory
    }

    var isHidden: Bool { name.hasPrefix(".") }

    func child(rel: String, entry: DirectoryEntry) -> FileNode {
        FileNode(path: (path as NSString).appendingPathComponent(entry.name),
                 rel: rel.isEmpty ? entry.name : rel + "/" + entry.name,
                 name: entry.name, isDirectory: entry.isDirectory)
    }

    /// 다시 읽은 내용으로 바꾸되, 이름·종류가 같은 것은 그 객체를 그대로 둔다(펼침·읽어 둔 하위 유지)
    func merge(_ entries: [DirectoryEntry]) {
        let old = Dictionary((children ?? []).map { ($0.name + ($0.isDirectory ? "/" : ""), $0) },
                             uniquingKeysWith: { first, _ in first })
        children = entries.map { entry in old[entry.name + (entry.isDirectory ? "/" : "")] ?? child(rel: rel, entry: entry) }
    }

    func find(rel target: String) -> FileNode? {
        if target == rel { return self }
        guard let children, target.hasPrefix(rel.isEmpty ? "" : rel + "/") else { return nil }
        for child in children where target == child.rel || target.hasPrefix(child.rel + "/") {
            return child.find(rel: target)
        }
        return nil
    }

    /// 읽어 둔 폴더(절대 경로)
    func loadedDirectories(into set: inout Set<String>) {
        guard let children else { return }
        set.insert(path)
        for child in children where child.isDirectory { child.loadedDirectories(into: &set) }
    }

    var loadedCount: Int { 1 + (children ?? []).reduce(0) { $0 + $1.loadedCount } }
}

/// git 상태 색(IntelliJ Darcula 계열, 이 앱의 어두운 바탕 #21252b 에서 읽히게 밝기를 맞춤)
enum FileStatusColors {
    static let modified = NSColor(srgbHex: 0x6ca0dc)
    static let added = NSColor(srgbHex: 0x8cc47a)
    static let untracked = NSColor(srgbHex: 0xd2826a)
    static let ignored = NSColor(srgbHex: 0x8b8b64)
    static let conflicted = NSColor(srgbHex: 0xf0605a)
    /// 안에 바뀐 것이 있는 폴더(접혀 있어도 보이게, 은은한 파랑)
    static let changedFolder = NSColor(srgbHex: 0xa9c3e3)
    static let folderIcon = NSColor(srgbHex: 0x8a9bb0)

    static func color(_ status: GitFileStatus?) -> NSColor? {
        switch status {
        case .modified, .renamed: return modified
        case .added: return added
        case .untracked: return untracked
        case .ignored: return ignored
        case .conflicted: return conflicted
        case .deleted, .none: return nil
        }
    }
}

/// 보이는 동안만 일하는 도구(보임·숨김을 도구 창 관리자가 알려 준다)
protocol ToolContent: AnyObject {
    func setToolVisible(_ visible: Bool)
}

/// files 도구: 포커스 화면의 프로젝트(작업 트리 맨 위, 없으면 화면 폴더) 파일 트리.
/// 폴더는 펼칠 때 읽고, git 상태는 보이는 동안만 FSEvents 로 바뀔 때 다시 읽는다.
final class FilesToolController: NSViewController, ToolContent, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let model: TermModel
    /// 파일 하나를 두 번 누르거나 Enter: 지금 화면 옆 미리보기로. 없으면 안내만 띄운다.
    var onOpenFile: ((String) -> Void)?
    /// 여러 줄을 골라 Enter·두 번 클릭·"열기": 고정 화면으로 한꺼번에
    var onOpenFiles: (([String]) -> Void)?
    /// ⌘두 번 클릭·"새 탭으로 열기"
    var onOpenFileInTab: ((String) -> Void)?
    /// 오른쪽 클릭 "오른쪽에 분할로 열기"(horizontal)·"아래로 분할로 열기"(vertical)
    var onOpenFileSplit: ((String, SplitAxis) -> Void)?
    /// 머리 줄 오른쪽 클릭 메뉴(옮기기·숨기기, 도구 창 관리자가 채운다)
    var dockMenu: (() -> NSMenu)?

    private let header = FilesHeaderView()
    private let outline = FilesOutlineView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private let toast = NSTextField(labelWithString: "")
    private var toastWork: DispatchWorkItem?
    private var toastHeight: NSLayoutConstraint?

    private let watcher = FilesWatcher()
    /// 루트별 펼친 폴더·보던 자리(스크롤 맨 위 줄·고른 줄)
    private var memory = ExpansionMemory()
    /// 마지막으로 트리에 드러낸 편집기 파일(목록이 2초마다 와도 다시 하지 않게)
    private var revealed: String?
    /// 루트를 읽는 중이라 미뤄 둔 드러내기(절대 경로)
    private var pendingReveal: String?
    private var headerHeight: NSLayoutConstraint!
    /// 숨기기 전에 보던 루트(다시 보일 때 편집기 화면이면 이 루트를 그대로 쓴다 — 도구를 오가도 루트가 바뀌지 않게)
    private var lastShown: FilesRoot?
    /// 최근 루트 몇 개의 git 상태(루트를 오갈 때 색을 바로 보이려고, 4개까지)
    private var recentStatus: [(root: String, status: GitStatusSnapshot)] = []
    private var rootNode: FileNode?
    private(set) var root: String?
    private(set) var isGit = false
    private(set) var branch: String?
    private(set) var status: GitStatusSnapshot?
    private var toolVisible = false
    private var occluded = false
    private var generation = 0
    /// 펼침을 되살리는 중(펼침 기록·지연 읽기를 건너뛴다)
    private var restoring = false
    private var subscriptions: Set<AnyCancellable> = []
    private let io = DispatchQueue(label: "AgentDeck.files.io", qos: .userInitiated)
    /// 시험용(AGENTDECK_SNAPSHOT·AGENTDECK_NO_ACTIVATE): 창을 뒤에 두고 시험하므로 가려져도 감시를 멈추지 않는다
    private let ignoreOcclusion: Bool = {
        let env = ProcessInfo.processInfo.environment
        return AgentDeckEnv.nonEmpty("SNAPSHOT", in: env) != nil || AgentDeckEnv.isOn("NO_ACTIVATE", in: env)
    }()

    init(model: TermModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        watcher.onStatus = { [weak self] snapshot in self?.apply(status: snapshot) }
        watcher.onDirectoriesChanged = { [weak self] dirs in self?.reload(directories: dirs) }
        // 포커스 화면·화면 폴더가 바뀌면 루트를 다시 정한다(보일 때만)
        Publishers.CombineLatest(model.$workspace, model.$rows)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRoot() }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = BackgroundView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        root.color = TermAppearance.chrome

        header.onCollapseAll = { [weak self] in self?.collapseAll() }
        header.menuProvider = { [weak self] in self?.dockMenu?() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = TermAppearance.chrome
        outline.rowHeight = TermAppearance.scaled(22)
        outline.indentationPerLevel = TermAppearance.scaled(14)
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsMultipleSelection = true // ⌘·⇧ 누르기로 여러 파일을 골라 한꺼번에 연다
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.onEnter = { [weak self] in self?.openSelected() }
        outline.onEscape = { [weak self] in self?.focusTerminal() }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = TermAppearance.chrome
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        empty.font = TermAppearance.scaledUIFont(11)
        empty.textColor = TermAppearance.textDim
        empty.alignment = .center
        empty.maximumNumberOfLines = 3
        empty.lineBreakMode = .byWordWrapping

        toast.font = TermAppearance.scaledUIFont(10)
        toast.textColor = TermAppearance.textPrimary
        toast.drawsBackground = true
        toast.backgroundColor = TermAppearance.chromeRaised
        toast.alignment = .center
        toast.isHidden = true
        toast.lineBreakMode = .byTruncatingMiddle

        for view in [header, scroll, empty, toast] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        headerHeight = header.heightAnchor.constraint(equalToConstant: TerminalHostController.tabBarHeight)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerHeight,
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -40),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            toast.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toast.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toast.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        toastHeight = toast.heightAnchor.constraint(equalToConstant: TermAppearance.scaled(24))
        toastHeight?.isActive = true
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let window = view.window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    // MARK: - 보임·숨김

    func setToolVisible(_ visible: Bool) {
        guard visible != toolVisible else { return }
        toolVisible = visible
        if visible {
            updateRoot(force: true)
        } else {
            // 숨기면 트리·감시를 놓는다(펼침·보던 자리만 기억). 다시 보이면 새로 읽는다.
            savePlace()
            lastShown = current ?? lastShown
            revealed = nil
            watcher.stop()
            generation += 1
            rootNode = nil
            root = nil
            status = nil
            recentStatus.removeAll()
            if isViewLoaded { outline.reloadData() }
        }
    }

    var isActive: Bool { toolVisible && (ignoreOcclusion || !occluded) }

    @objc private func occlusionChanged() {
        guard let window = view.window else { return }
        let hidden = !window.occlusionState.contains(.visible)
        guard hidden != occluded else { return }
        occluded = hidden
        guard toolVisible, !ignoreOcclusion else { return }
        // 창이 가려지거나 최소화되면 감시만 멈추고, 다시 보이면 이어서(그 사이 바뀐 것은 다시 읽는다)
        if hidden {
            watcher.stop()
        } else if let root {
            watcher.loadedDirectories = loadedDirectories()
            watcher.start(root: root, isGit: isGit)
            reload(directories: loadedDirectories())
        }
    }

    // MARK: - 루트

    /// 포커스 화면의 작업 트리 맨 위(없으면 화면 폴더)
    static func root(for row: PaneRow?) -> FilesRoot? {
        row.map { FilesRoot.folder($0.cwd, git: $0.git) }
    }

    private var current: FilesRoot? { root.map { FilesRoot(path: $0, isGit: isGit) } }

    /// 포커스 화면에 맞춰 루트를 정한다. 같은 루트면 아무것도 다시 만들지 않는다(펼침·스크롤·고른 줄 그대로).
    private func updateRoot(force: Bool = false) {
        guard toolVisible, isViewLoaded else { return }
        let target: FilesRoot?
        var editorFile: String?
        if let id = model.selectedId, let path = model.workspace.editors[id]?.path {
            // 편집기 화면: 지금 루트 안의 파일이면 그대로, 아니면 터미널 화면과 같은 규칙(작업 트리 맨 위)
            editorFile = path
            target = FilesRoot.editor(file: path, current: current ?? lastShown, locate: GitWorktrees.locate)
        } else {
            // 막 만든 화면은 목록(2초마다)에 오기 전까지 줄이 없다 — 그동안은 지금 루트를 그대로 둔다
            if !force, root != nil, model.selectedId != nil, model.focusedRow == nil { return }
            target = Self.root(for: model.focusedRow)
        }
        if force || target != current {
            load(root: target)
        }
        // 편집기로 포커스가 오면 그 파일을 트리에 드러낸다(다른 폴더는 접지 않는다)
        if let editorFile, editorFile != revealed {
            revealed = editorFile
            reveal(editorFile)
        } else if editorFile == nil {
            revealed = nil
        }
    }

    private func load(root target: FilesRoot?) {
        savePlace()
        generation += 1
        let generation = self.generation
        watcher.stop()
        root = target?.path
        isGit = target?.isGit ?? false
        // 최근에 본 루트면 지난 git 상태를 먼저 보이고(색이 깜빡이지 않게) 새 결과로 바꾼다
        status = target.flatMap { target in recentStatus.first { $0.root == target.path }?.status }
        branch = nil
        rootNode = nil
        outline.reloadData()
        guard let target else {
            header.update(name: nil, branch: nil, changes: 0, isGit: false)
            showEmpty("열린 화면이 없습니다.\n화면을 고르면 그 프로젝트 파일이 보입니다.")
            return
        }
        header.update(name: (target.path as NSString).lastPathComponent, branch: nil, changes: 0, isGit: target.isGit)
        showEmpty(nil)
        let expanded = memory.paths(for: target.path)
        io.async { [weak self] in
            // 루트와 펼쳐 두었던 폴더를 한 번에 읽어 온다(메인 스레드는 디스크를 기다리지 않는다)
            let node = FileNode(path: target.path, rel: "", name: (target.path as NSString).lastPathComponent, isDirectory: true)
            var exists: ObjCBool = false
            let readable = FileManager.default.fileExists(atPath: target.path, isDirectory: &exists) && exists.boolValue
            node.children = DirectoryListing.read(target.path).map { node.child(rel: "", entry: $0) }
            var restored: [String] = []
            for rel in expanded {
                let parentRel = (rel as NSString).deletingLastPathComponent
                guard parentRel.isEmpty || restored.contains(parentRel),
                      let folder = node.find(rel: rel), folder.isDirectory, folder.children == nil else { continue }
                folder.children = DirectoryListing.read(folder.path).map { folder.child(rel: rel, entry: $0) }
                restored.append(rel)
            }
            let branch = target.isGit ? GitWorktrees.branch(worktreeRoot: target.path) : nil
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                self.rootNode = node
                self.branch = branch
                self.header.update(name: node.name, branch: branch, changes: self.status?.changeCount ?? 0, isGit: target.isGit)
                self.restoring = true
                self.outline.reloadData()
                for rel in restored { if let folder = node.find(rel: rel) { self.outline.expandItem(folder) } }
                self.restoring = false
                self.restorePlace(target.path)
                if let path = self.pendingReveal {
                    self.pendingReveal = nil
                    self.reveal(path)
                }
                self.showEmpty(readable ? (node.children?.isEmpty == true ? "빈 폴더입니다." : nil) : "폴더를 읽을 수 없습니다.\n\(target.path)")
                if self.isActive {
                    self.watcher.loadedDirectories = self.loadedDirectories()
                    self.watcher.start(root: target.path, isGit: target.isGit)
                }
            }
        }
    }

    // MARK: - 보던 자리

    private func rel(ofRow row: Int) -> String? { (outline.item(atRow: row) as? FileNode)?.rel }

    /// 맨 위에 보이는 줄
    private var topRow: Int { outline.row(at: NSPoint(x: 1, y: scroll.contentView.bounds.minY + 1)) }

    /// 떠나기 전 이 루트의 스크롤(맨 위 줄)·고른 줄을 기억한다
    private func savePlace() {
        guard let root, rootNode != nil else { return }
        memory.setPlace(TreePlace(topRow: rel(ofRow: topRow), selected: rel(ofRow: outline.selectedRow)), root: root)
    }

    private func restorePlace(_ root: String) {
        guard let place = memory.place(for: root), let rootNode else { return }
        if let rel = place.topRow { scroll(toTop: rel) }
        if let rel = place.selected, let node = rootNode.find(rel: rel) {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
    }

    /// 그 줄이 맨 위에 오게 스크롤
    private func scroll(toTop rel: String) {
        guard let node = rootNode?.find(rel: rel) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: outline.rect(ofRow: row).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 파일을 트리에 드러낸다: 위 폴더를 차례로 펼치고(읽기를 기다리며) 고른 뒤 보이게 스크롤. 다른 폴더는 그대로.
    /// 이미 여러 줄을 골라 둔 가운데 하나면 고른 것을 바꾸지 않는다.
    private func reveal(_ path: String) {
        guard let rel = current?.relative(path), !rel.isEmpty else { return }
        guard let rootNode else {
            pendingReveal = path
            return
        }
        let generation = self.generation
        let folders = ExpansionMemory.ancestors(of: rel)
        func step(_ index: Int) {
            guard generation == self.generation else { return }
            guard index < folders.count else {
                guard let node = rootNode.find(rel: rel) else { return }
                let row = outline.row(forItem: node)
                guard row >= 0 else { return }
                if !outline.selectedRowIndexes.contains(row) {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                outline.scrollRowToVisible(row)
                return
            }
            guard let folder = rootNode.find(rel: folders[index]), folder.isDirectory else { return }
            if folder.children == nil {
                loadChildren(folder, expand: true) { step(index + 1) }
            } else {
                if !outline.isItemExpanded(folder) { outline.expandItem(folder) }
                step(index + 1)
            }
        }
        step(0)
    }

    // MARK: - 배율

    /// 글꼴 크기 배율이 바뀜: 줄 높이·들여쓰기·글꼴을 바꾸되 펼침·고른 줄·맨 위 줄은 그대로
    func scaleChanged() {
        guard isViewLoaded else { return }
        let top = rel(ofRow: topRow)
        headerHeight.constant = TerminalHostController.tabBarHeight
        header.applyScale()
        empty.font = TermAppearance.scaledUIFont(11)
        toast.font = TermAppearance.scaledUIFont(10)
        toastHeight?.constant = TermAppearance.scaled(24)
        outline.rowHeight = TermAppearance.scaled(22)
        outline.indentationPerLevel = TermAppearance.scaled(14)
        // 들여쓰기는 칸을 다시 만들어야 맞는다 — 펼침·고른 줄·맨 위 줄을 지키며 다시 읽는다(디스크는 다시 읽지 않음)
        reloadKeepingState(top: top)
    }

    /// 트리를 다시 그리되 펼친 폴더·고른 줄·맨 위 줄은 그대로
    private func reloadKeepingState(top: String?) {
        guard let root, let rootNode else { return outline.reloadData() }
        let selected = outline.selectedRowIndexes.compactMap { rel(ofRow: $0) }
        outline.reloadData()
        restoring = true
        for rel in memory.paths(for: root) {
            if let folder = rootNode.find(rel: rel), folder.children != nil { outline.expandItem(folder) }
        }
        restoring = false
        let rows = selected.compactMap { rootNode.find(rel: $0) }.map { outline.row(forItem: $0) }.filter { $0 >= 0 }
        outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        if let top { scroll(toTop: top) }
    }

    private func showEmpty(_ text: String?) {
        empty.stringValue = text ?? ""
        empty.isHidden = text == nil
    }

    private func loadedDirectories() -> Set<String> {
        var set: Set<String> = []
        rootNode?.loadedDirectories(into: &set)
        return set
    }

    // MARK: - 폴더 읽기

    private func loadChildren(_ node: FileNode, expand: Bool, then done: (() -> Void)? = nil) {
        guard node.isDirectory, node.children == nil, !node.loading else { return }
        node.loading = true
        let generation = self.generation
        io.async { [weak self] in
            let entries = DirectoryListing.read(node.path)
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                node.loading = false
                node.children = entries.map { node.child(rel: node.rel, entry: $0) }
                self.outline.reloadItem(node, reloadChildren: true)
                if expand { self.outline.expandItem(node) }
                self.watcher.loadedDirectories = self.loadedDirectories()
                done?()
            }
        }
    }

    /// FSEvents 로 바뀐 폴더를 다시 읽는다(읽어 둔 것만)
    private func reload(directories: Set<String>) {
        guard let rootNode, let root else { return }
        let targets: [FileNode] = directories.compactMap { path in
            guard path == root || path.hasPrefix(root + "/") else { return nil }
            let rel = path == root ? "" : String(path.dropFirst(root.count + 1))
            return rootNode.find(rel: rel).flatMap { $0.children == nil ? nil : $0 }
        }
        guard !targets.isEmpty else { return }
        let generation = self.generation
        io.async { [weak self] in
            let listings = targets.map { ($0, DirectoryListing.read($0.path)) }
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                for (node, entries) in listings {
                    let before = node.children?.map { $0.name + ($0.isDirectory ? "/" : "") }
                    node.merge(entries)
                    guard before != node.children?.map({ $0.name + ($0.isDirectory ? "/" : "") }) else { continue }
                    self.outline.reloadItem(node === rootNode ? nil : node, reloadChildren: true)
                }
                self.watcher.loadedDirectories = self.loadedDirectories()
                self.showEmpty(rootNode.children?.isEmpty == true ? "빈 폴더입니다." : nil)
            }
        }
    }

    // MARK: - git 상태

    private func apply(status snapshot: GitStatusSnapshot?) {
        if let root {
            recentStatus.removeAll { $0.root == root }
            if let snapshot { recentStatus.append((root, snapshot)) }
            if recentStatus.count > 4 { recentStatus.removeFirst() }
        }
        guard snapshot != status else { return }
        status = snapshot
        header.update(name: rootNode?.name ?? (root as NSString?)?.lastPathComponent, branch: branch,
                      changes: snapshot?.changeCount ?? 0, isGit: isGit)
        // 보이는 줄만 다시 칠한다(나머지는 보일 때 칠해진다)
        let range = outline.rows(in: outline.visibleRect)
        for row in range.location..<(range.location + range.length) {
            guard let node = outline.item(atRow: row) as? FileNode,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView else { continue }
            configure(cell, node)
        }
    }

    // MARK: - 데이터

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileNode) ?? rootNode else { return 0 }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? FileNode) ?? rootNode!
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: FileCellView.identifier, owner: nil) as? FileCellView ?? FileCellView()
        configure(cell, node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        outlineView.makeView(withIdentifier: FileRowView.identifier, owner: nil) as? FileRowView ?? FileRowView()
    }

    private func configure(_ cell: FileCellView, _ node: FileNode) {
        let state = isGit ? status?.status(of: node.rel) : nil
        var color = FileStatusColors.color(state) ?? TermAppearance.textPrimary
        if state == nil, node.isDirectory, status?.containsChanges(node.rel) == true { color = FileStatusColors.changedFolder }
        cell.configure(name: node.name, isDirectory: node.isDirectory, color: color,
                       dim: node.isHidden || state == .ignored, status: state)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        if node.children == nil { loadChildren(node, expand: true) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode, let root else { return }
        memory.setExpanded(node.rel, true, root: root)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? FileNode, let root else { return }
        memory.setExpanded(node.rel, false, root: root)
    }

    // MARK: - 동작

    private var selectedNode: FileNode? { outline.item(atRow: outline.selectedRow) as? FileNode }

    /// 고른 파일들(줄 순서, 폴더는 뺀다)
    private var selectedFiles: [FileNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }.filter { !$0.isDirectory }
    }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard let node = outline.item(atRow: row) as? FileNode else { return }
        // ⌘두 번 클릭 = 새 탭
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true, !node.isDirectory, let onOpenFileInTab {
            onOpenFileInTab(node.path)
            return
        }
        // 여러 줄을 고른 가운데를 두 번 누르면 고른 파일을 모두 연다
        if outline.selectedRowIndexes.count > 1, outline.selectedRowIndexes.contains(row) {
            openSelected()
        } else {
            open(node)
        }
    }

    /// Enter: 하나면 그 줄(폴더는 펼치기·접기), 여러 줄이면 고른 파일을 모두
    private func openSelected() {
        guard outline.selectedRowIndexes.count > 1 else {
            if let node = selectedNode { open(node) }
            return
        }
        open(files: selectedFiles.map(\.path))
    }

    private func open(files: [String]) {
        if files.count == 1 {
            onOpenFile?(files[0])
        } else if files.count > 1 {
            onOpenFiles?(files)
        }
    }

    func open(_ node: FileNode) {
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
            return
        }
        if let onOpenFile {
            onOpenFile(node.path)
        } else {
            showToast("편집기는 다음 단계에서 지원합니다 · \(node.name)")
        }
    }

    private func showToast(_ text: String) {
        toastWork?.cancel()
        toast.stringValue = text
        toast.isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.toast.isHidden = true }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func focusTerminal() {
        if let target = model.host?.focusedPaneView { view.window?.makeFirstResponder(target) }
    }

    func focusTree() {
        view.window?.makeFirstResponder(outline)
        if outline.selectedRow < 0, outline.numberOfRows > 0 {
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func collapseAll() {
        if let root { memory.collapseAll(root: root) }
        restoring = true
        outline.collapseItem(nil, collapseChildren: true)
        restoring = false
    }

    // MARK: - 오른쪽 클릭

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // 오른쪽 클릭한 줄(키보드로 연 메뉴면 고른 줄)
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = outline.item(atRow: row) as? FileNode else { return }
        // 여러 줄을 고른 가운데를 오른쪽 클릭: 고른 파일을 한꺼번에
        if outline.selectedRowIndexes.count > 1, outline.selectedRowIndexes.contains(row) {
            let files = selectedFiles.map(\.path)
            if !files.isEmpty {
                add(menu, "열기 (파일 \(files.count)개)") { [weak self] in self?.open(files: files) }
                menu.addItem(.separator())
            }
            let paths = outline.selectedRowIndexes.compactMap { (self.outline.item(atRow: $0) as? FileNode)?.path }
            add(menu, "경로 복사 (\(paths.count)개)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
            }
            return
        }
        let folder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
        if !node.isDirectory {
            add(menu, "열기") { [weak self] in self?.onOpenFile?(node.path) }
            if let inTab = onOpenFileInTab { add(menu, "새 탭으로 열기") { inTab(node.path) } }
            if let split = onOpenFileSplit {
                add(menu, "오른쪽에 분할로 열기") { split(node.path, .horizontal) }
                add(menu, "아래로 분할로 열기") { split(node.path, .vertical) }
            }
            menu.addItem(.separator())
        }
        add(menu, "Finder 에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)]) }
        add(menu, "경로 복사") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
        if !node.rel.isEmpty {
            add(menu, "상대 경로 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.rel, forType: .string)
            }
        }
        menu.addItem(.separator())
        add(menu, "여기서 셸 열기(새 탭)") { [weak self] in self?.model.newPane(cwd: folder) }
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: @escaping () -> Void) {
        menu.addItem(ClosureMenuItem(title: title, action: action))
    }

    // MARK: - 시험용

    /// 상대 경로까지 차례로 펼친다(읽기가 끝나기를 기다리며)
    func debugExpand(_ rel: String, attempt: Int = 0) {
        guard let rootNode else { return }
        let parts = rel.split(separator: "/").map(String.init)
        var current = rootNode
        for (index, part) in parts.enumerated() {
            guard let next = current.children?.first(where: { $0.name == part }) else {
                if attempt < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.debugExpand(rel, attempt: attempt + 1) } }
                return
            }
            if next.isDirectory, !outline.isItemExpanded(next) { outline.expandItem(next) }
            if next.isDirectory, next.children == nil {
                if attempt < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.debugExpand(rel, attempt: attempt + 1) } }
                return
            }
            current = next
            if index == parts.count - 1 {
                let row = outline.row(forItem: next)
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
        }
    }

    /// filesmenu <상대 경로>[|<항목 제목>]: 그 줄의 오른쪽 클릭 메뉴 항목을 출력하고, 제목을 주면 그 항목을 실행한다
    func debugMenu(_ argument: String) {
        let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
        guard let node = rootNode?.find(rel: parts[0]) else { print("filesmenu: 없음 \(parts[0])"); fflush(stdout); return }
        let row = outline.row(forItem: node)
        if row >= 0, !outline.selectedRowIndexes.contains(row) {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        print("filesmenu \(node.rel): " + menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " / "))
        fflush(stdout)
        if parts.count > 1, let item = menu.items.first(where: { $0.title == parts[1] }) as? ClosureMenuItem { item.perform() }
    }

    func debugOpen(_ rel: String) {
        if let node = rootNode?.find(rel: rel) { open(node) }
    }

    /// files-select a|b|c: 그 줄들을 고른다(펼쳐져 있어야 한다)
    func debugSelect(_ argument: String) {
        let rows = argument.split(separator: "|").compactMap { rootNode?.find(rel: String($0)) }.map { outline.row(forItem: $0) }
        outline.selectRowIndexes(IndexSet(rows.filter { $0 >= 0 }), byExtendingSelection: false)
    }

    /// files-enter: Enter 와 같다
    func debugEnter() { openSelected() }

    /// files-scroll <줄>: 그 줄을 맨 위로
    func debugScroll(_ rel: String) { scroll(toTop: rel) }

    var debugSummary: String {
        let changes = status.map { "\($0.changeCount) (files \($0.files.count), folders \($0.folders.count))" } ?? "none"
        return "filesroot root=\(root ?? "-") git=\(isGit) branch=\(branch ?? "-") visible=\(toolVisible) active=\(isActive) "
            + "watching=\(watcher.isRunning) gitRuns=\(watcher.runs) lastGit=\(String(format: "%.0fms", watcher.lastDuration * 1000)) "
            + "changes=\(changes) loadedNodes=\(rootNode?.loadedCount ?? 0) rows=\(outline.numberOfRows) "
            + "selected=[\(outline.selectedRowIndexes.compactMap { rel(ofRow: $0) }.joined(separator: ","))] top=\(rel(ofRow: topRow) ?? "-") "
            + "rowHeight=\(outline.rowHeight) "
            + "rootsRemembered=\(memory.rootCount) toast=\(toast.isHidden ? "-" : toast.stringValue) toastFrame=\(toast.frame)"
    }
}

// MARK: - 뷰

/// 오른쪽 클릭 메뉴 항목(닫힘으로 동작)
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }

    func perform() { handler() }
}

final class FilesOutlineView: NSOutlineView {
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onEnter?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }

    // 오른쪽 클릭한 줄을 고른 줄로 보이게(IntelliJ 처럼)
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

/// 고른 줄: 포커스가 있으면 강조색을 옅게, 없으면 한 단계 밝은 바탕
final class FileRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("FileRow")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError() }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds
        if isEmphasized {
            TermAppearance.accent.withAlphaComponent(0.22).setFill()
            rect.fill()
            TermAppearance.accent.setFill()
            NSRect(x: 0, y: 0, width: 2, height: rect.height).fill()
        } else {
            TermAppearance.chromeRaised.setFill()
            rect.fill()
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        TermAppearance.chrome.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

final class FileCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    /// 아이콘(배율별로 한 번만 만든다)
    private static var images: [CGFloat: (folder: NSImage?, file: NSImage?)] = [:]
    private static func icons(_ pointSize: CGFloat) -> (folder: NSImage?, file: NSImage?) {
        if let cached = images[pointSize] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let made = (NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "폴더")?.withSymbolConfiguration(config),
                    NSImage(systemSymbolName: "doc", accessibilityDescription: "파일")?.withSymbolConfiguration(config))
        images[pointSize] = made
        return made
    }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    /// 이 칸에 맞춘 배율(재사용된 칸이 예전 배율이면 configure 에서 맞춘다)
    private var scale: UIScale?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        badge.alignment = .right
        icon.imageScaling = .scaleProportionallyDown
        for view in [icon, label, badge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 16)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: 14)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconHeight,
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = icon
        textField = label
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 상태 글자(색만으로 구분하지 않게 IntelliJ·VS Code 처럼 한 글자를 오른쪽에)
    private static func letter(_ status: GitFileStatus?) -> String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .renamed: return "R"
        case .untracked: return "U"
        case .conflicted: return "!"
        default: return ""
        }
    }

    private func applyScale() {
        let ui = TermAppearance.uiScale
        guard ui != scale else { return }
        scale = ui
        label.font = TermAppearance.uiFont(ui(12))
        badge.font = TermAppearance.uiFont(ui(10))
        iconWidth.constant = ui(16)
        iconHeight.constant = ui(14)
    }

    func configure(name: String, isDirectory: Bool, color: NSColor, dim: Bool, status: GitFileStatus?) {
        applyScale()
        let alpha: CGFloat = dim ? 0.55 : 1
        label.stringValue = name
        label.textColor = color.withAlphaComponent(alpha)
        let icons = Self.icons(TermAppearance.scaled(11))
        icon.image = isDirectory ? icons.folder : icons.file
        icon.contentTintColor = (isDirectory ? FileStatusColors.folderIcon : TermAppearance.textDim).withAlphaComponent(alpha)
        let letter = isDirectory ? "" : Self.letter(status)
        badge.stringValue = letter
        badge.textColor = color.withAlphaComponent(0.85)
        badge.isHidden = letter.isEmpty
        toolTip = nil
    }
}

/// files 머리 줄: 루트 폴더 이름 · 브랜치 · 바뀐 수, 오른쪽에 모두 접기. 오른쪽 클릭 = 옮기기·숨기기.
final class FilesHeaderView: NSView {
    var onCollapseAll: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let title = NSTextField(labelWithString: "files")
    private let branch = NSTextField(labelWithString: "")
    private let changes = NSTextField(labelWithString: "")
    private let collapse = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.textColor = TermAppearance.textPrimary
        title.lineBreakMode = .byTruncatingTail
        branch.textColor = TermAppearance.cyan
        branch.lineBreakMode = .byTruncatingMiddle
        changes.textColor = FileStatusColors.modified
        applyScale()
        collapse.isBordered = false
        collapse.contentTintColor = TermAppearance.textDim
        collapse.toolTip = "모두 접기"
        collapse.target = self
        collapse.action = #selector(collapseAll)
        for view in [title, branch, changes, collapse] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // 폴더 이름이 길어도 브랜치가 보이게: 이름은 머리 줄의 60% 까지만, 나머지는 브랜치(가운데 줄임)
        title.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        branch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6).isActive = true
        changes.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            branch.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            branch.centerYAnchor.constraint(equalTo: centerYAnchor),
            changes.leadingAnchor.constraint(greaterThanOrEqualTo: branch.trailingAnchor, constant: 8),
            changes.centerYAnchor.constraint(equalTo: centerYAnchor),
            collapse.leadingAnchor.constraint(equalTo: changes.trailingAnchor, constant: 8),
            collapse.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            collapse.centerYAnchor.constraint(equalTo: centerYAnchor),
            collapse.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.chrome.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    /// 글꼴 크기 배율
    func applyScale() {
        title.font = TermAppearance.scaledUIFont(12, bold: true)
        branch.font = TermAppearance.scaledUIFont(11)
        changes.font = TermAppearance.scaledUIFont(10)
        collapse.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: "모두 접기")?
            .withSymbolConfiguration(.init(pointSize: TermAppearance.scaled(10), weight: .medium))
    }

    func update(name: String?, branch value: String?, changes count: Int, isGit: Bool) {
        title.stringValue = name ?? "files"
        toolTip = [name, value.map { "브랜치 \($0)" }].compactMap { $0 }.joined(separator: " · ")
        branch.stringValue = value.map { "⎇ \($0)" } ?? ""
        branch.isHidden = value == nil
        changes.stringValue = count > 0 ? "● \(count)" : ""
        changes.toolTip = count > 0 ? "바뀐 파일 \(count)개" : nil
        changes.isHidden = count == 0
        collapse.isHidden = name == nil
    }

    @objc private func collapseAll() { onCollapseAll?() }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
