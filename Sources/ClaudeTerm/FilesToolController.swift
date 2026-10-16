import AppKit
import Combine
import TermLayout

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
    /// 2단계(편집기) 연결점: 파일을 두 번 누르거나 Enter. 없으면 안내만 띄운다.
    var onOpenFile: ((String) -> Void)?
    /// 머리 줄 오른쪽 클릭 메뉴(옮기기·숨기기, 도구 창 관리자가 채운다)
    var dockMenu: (() -> NSMenu)?

    private let header = FilesHeaderView()
    private let outline = FilesOutlineView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private let toast = NSTextField(labelWithString: "")
    private var toastWork: DispatchWorkItem?

    private let watcher = FilesWatcher()
    private var memory = ExpansionMemory()
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
    private let io = DispatchQueue(label: "ClaudeTerm.files.io", qos: .userInitiated)
    /// 시험용(CLAUDE_TERM_SNAPSHOT·CLAUDE_TERM_NO_ACTIVATE): 창을 뒤에 두고 시험하므로 가려져도 감시를 멈추지 않는다
    private let ignoreOcclusion: Bool = {
        let env = ProcessInfo.processInfo.environment
        return !(env["CLAUDE_TERM_SNAPSHOT"] ?? "").isEmpty || env["CLAUDE_TERM_NO_ACTIVATE"] == "1"
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
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsMultipleSelection = false
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

        empty.font = TermAppearance.uiFont(11)
        empty.textColor = TermAppearance.textDim
        empty.alignment = .center
        empty.maximumNumberOfLines = 3
        empty.lineBreakMode = .byWordWrapping

        toast.font = TermAppearance.uiFont(10)
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
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: TerminalHostController.tabBarHeight),
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
            toast.heightAnchor.constraint(equalToConstant: 24),
        ])
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
            // 숨기면 트리·감시를 놓는다(펼침만 기억). 다시 보이면 새로 읽는다.
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
    static func root(for row: PaneRow?) -> (path: String, isGit: Bool)? {
        guard let row else { return nil }
        if let git = row.git { return (git.worktreeRoot, true) }
        return ((row.cwd as NSString).standardizingPath, false)
    }

    private func updateRoot(force: Bool = false) {
        guard toolVisible, isViewLoaded else { return }
        // 막 만든 화면은 목록(2초마다)에 오기 전까지 줄이 없다 — 그동안은 지금 루트를 그대로 둔다
        if !force, root != nil, model.selectedId != nil, model.focusedRow == nil { return }
        let target = Self.root(for: model.focusedRow)
        guard force || target?.path != root || target?.isGit != isGit else { return }
        load(root: target)
    }

    private func load(root target: (path: String, isGit: Bool)?) {
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
                self.showEmpty(readable ? (node.children?.isEmpty == true ? "빈 폴더입니다." : nil) : "폴더를 읽을 수 없습니다.\n\(target.path)")
                if self.isActive {
                    self.watcher.loadedDirectories = self.loadedDirectories()
                    self.watcher.start(root: target.path, isGit: target.isGit)
                }
            }
        }
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

    private func loadChildren(_ node: FileNode, expand: Bool) {
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

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        open(node)
    }

    private func openSelected() {
        if let node = selectedNode { open(node) }
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
        if let terminal = model.host?.focusedTerminal?.view { view.window?.makeFirstResponder(terminal) }
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
        let folder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
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
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        print("filesmenu \(node.rel): " + menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " / "))
        fflush(stdout)
        if parts.count > 1, let item = menu.items.first(where: { $0.title == parts[1] }) as? ClosureMenuItem { item.perform() }
    }

    func debugOpen(_ rel: String) {
        if let node = rootNode?.find(rel: rel) { open(node) }
    }

    var debugSummary: String {
        let changes = status.map { "\($0.changeCount) (files \($0.files.count), folders \($0.folders.count))" } ?? "none"
        return "filesroot root=\(root ?? "-") git=\(isGit) branch=\(branch ?? "-") visible=\(toolVisible) active=\(isActive) "
            + "watching=\(watcher.isRunning) gitRuns=\(watcher.runs) lastGit=\(String(format: "%.0fms", watcher.lastDuration * 1000)) "
            + "changes=\(changes) loadedNodes=\(rootNode?.loadedCount ?? 0) rows=\(outline.numberOfRows) "
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
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    private static let folderImage = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "폴더")?
        .withSymbolConfiguration(symbolConfig)
    private static let fileImage = NSImage(systemSymbolName: "doc", accessibilityDescription: "파일")?
        .withSymbolConfiguration(symbolConfig)

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.font = TermAppearance.uiFont(12)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        badge.font = TermAppearance.uiFont(10)
        badge.alignment = .right
        icon.imageScaling = .scaleProportionallyDown
        for view in [icon, label, badge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 14),
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

    func configure(name: String, isDirectory: Bool, color: NSColor, dim: Bool, status: GitFileStatus?) {
        let alpha: CGFloat = dim ? 0.55 : 1
        label.stringValue = name
        label.textColor = color.withAlphaComponent(alpha)
        icon.image = isDirectory ? Self.folderImage : Self.fileImage
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
        title.font = TermAppearance.uiFont(12, bold: true)
        title.textColor = TermAppearance.textPrimary
        title.lineBreakMode = .byTruncatingTail
        branch.font = TermAppearance.uiFont(11)
        branch.textColor = TermAppearance.cyan
        branch.lineBreakMode = .byTruncatingMiddle
        changes.font = TermAppearance.uiFont(10)
        changes.textColor = FileStatusColors.modified
        collapse.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: "모두 접기")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
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
