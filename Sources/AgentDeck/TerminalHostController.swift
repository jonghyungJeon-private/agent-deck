import AppKit
import EditorCore
import SwiftTerm
import TermLayout
import TermWire

/// 오른쪽 터미널 영역: 위에 탭 줄, 아래에 지금 탭의 분할 화면.
/// 지금 탭에 보이는 화면만 터미널 뷰를 만든다(다른 탭은 데몬이 지난 출력만 들고 있다).
final class TerminalHostController: NSViewController {
    /// 탭 줄 높이(글꼴 크기 배율을 따른다). 도구 창 머리 줄·도구 버튼 줄도 같은 높이라 한 선에 맞는다.
    static var tabBarHeight: CGFloat { TermAppearance.scaled(32) }

    let model: TermModel
    private(set) var terminals: [String: PaneTerminal] = [:]
    /// 보이는 편집기 화면(터미널처럼 보일 때만 만든다)
    private(set) var editorViews: [String: EditorPaneView] = [:]
    private let container = SplitContainerView()
    /// 화면이 하나도 없을 때(또는 연결 중·끊김): 아이콘 + 한 줄 안내(안내 글만 — 버튼은 두지 않는다)
    private let placeholder = NSStackView()
    private let placeholderIcon = NSImageView()
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private let tabBar = TabBarView()
    /// 탭·화면을 끄는 동안 놓일 곳을 보이는 덮개
    private let dropOverlay = DropOverlayView()
    private var tabBarHeight: NSLayoutConstraint!
    /// 탭 줄 아래(탭 줄이 없으면 맨 위) — 떠 있는 버튼을 이 아래에 붙인다
    var belowTabBarAnchor: NSLayoutYAxisAnchor { tabBar.bottomAnchor }
    /// 탭 줄 세로 가운데(떠 있는 버튼을 탭 줄 오른쪽 끝에 앉힌다)
    var tabBarCenterYAnchor: NSLayoutYAxisAnchor { tabBar.centerYAnchor }
    /// 탭 줄 높이(없으면 0)
    var tabBarInset: CGFloat { tabBarHeight?.constant ?? 0 }
    /// 탭 줄 오른쪽에서 비울 폭(탭 줄 안에 앉은 🌐·⌨ 알약 폭 — 탭과 "+" 가 알약 아래로 들어가지 않게)
    func setTabBarTrailingReserve(_ width: CGFloat) { tabBar.trailingReserve = width }
    /// 탭 줄 왼쪽에서 비울 폭(창 제목 줄과 합쳐져 신호등이 탭 줄 위에 있을 때 그 폭)
    func setTabBarLeadingInset(_ width: CGFloat) { tabBar.leadingInset = width }
    /// 탭 줄 왼쪽 비움(시험·표시용)
    var tabBarLeadingInset: CGFloat { tabBar.leadingInset }
    /// 지금 보이는 탭 줄 ⌄ 메뉴에 든 탭 번호(시험·표시용)
    var tabBarHiddenTabs: [Int] { tabBar.debugHiddenTabs }
    /// 시험 명령: ⌄ 메뉴 항목·고르기·열기
    var tabBarOverflowTitles: [String] { tabBar.debugOverflowTitles }
    func debugPickOverflow(_ n: Int) { tabBar.debugPickOverflow(n) }
    func debugOpenOverflow(closeAfter: TimeInterval) { tabBar.debugOpenOverflow(closeAfter: closeAfter) }
    /// 고른 세션 이름·폴더가 바뀜(창 제목·부제 — 창 메뉴와 Mission Control 이 읽는다)
    var onWindowTitleChanged: ((_ title: String, _ subtitle: String) -> Void)?
    /// 탭 제목을 최소 폭까지 줄였을 때 탭 + "+" 가 차지하는 폭(알약이 탭 줄 안에 들어갈 수 있는지 가늠한다)
    var tabBarMinimumContentWidth: CGFloat { tabBar.minimumContentWidth }
    /// 탭이 생기고 사라지거나 제목·배율이 바뀌어 `tabBarMinimumContentWidth` 가 바뀜
    var onTabBarContentChanged: (() -> Void)?
    /// 시험용: 탭과 "+" 가 차지하는 오른쪽 끝(창 좌표 x)
    var debugTabRowMaxX: CGFloat { tabBar.convert(CGPoint(x: tabBar.debugContentMaxX, y: 0), to: nil).x }
    /// 탭 줄 높이가 바뀜(작은 창 자리를 다시 맞춘다)
    var onTabBarHeightChanged: (() -> Void)?
    private var monitors: [Any] = []
    /// 편집기 이동(⌘B·⌥F7·⌘O·뒤로·앞으로)
    private(set) lazy var navigator = CodeNavigator(host: self)

    private(set) lazy var sessionSwitcher = SessionSwitcher(host: self)

    init(model: TermModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged),
                                               name: TermAppearance.fontSizeChanged, object: nil)
        // Shift+Enter = 줄바꿈. claude 는 이 터미널에서 확장 키 입력(kitty)을 켜지 않으므로
        // ⌥+Enter 와 같은 ESC CR 을 보낸다(claude 는 이를 줄바꿈으로 받는다).
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 세션 화면이든 작은 터미널 창이든 키보드를 받고 있는 터미널
            guard let self, let pane = [self.focusedTerminal, self.model.scratch.current].lazy
                    .compactMap({ $0 }).first(where: { $0.view.window?.firstResponder === $0.view }),
                  event.window === pane.view.window,
                  event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.intersection([.shift, .command, .control, .option]) == .shift,
                  !pane.view.hasMarkedText(),
                  pane.view.getTerminal().keyboardEnhancementFlags.isEmpty
            else { return event }
            self.model.client.input(pane.id, [0x1b, 0x0d])
            return nil
        } as Any)
        // 화면을 누르면 그 화면으로 포커스(목록 선택·탭 제목도 따라온다)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // 작은 터미널 창을 누르면 그 터미널로 키보드(세션 화면의 포커스는 그대로)
            if let scratch = self?.model.scratch.current, event.window === scratch.view.window,
               let content = event.window?.contentView,
               let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
               hit === scratch.view || hit.isDescendant(of: scratch.view) {
                event.window?.makeFirstResponder(scratch.view)
                return event
            }
            // 화면 위에 떠 있는 것(작은 브라우저 창·🌐 버튼)을 누른 것은 아래 화면으로 포커스를 옮기지 않는다
            // (옮기면 브라우저가 그 화면의 세션으로 바뀐다)
            guard let self, event.window === self.view.window, let content = event.window?.contentView,
                  let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                  hit === self.container || hit.isDescendant(of: self.container),
                  let id = self.container.paneId(at: event.locationInWindow) else { return event }
            self.model.focus(pane: id, fromClick: true)
            if let pane = self.terminals[id], hit === pane.view || hit.isDescendant(of: pane.view) {
                event.window?.makeFirstResponder(pane.view)
            }
            return event
        } as Any)
    }

    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = BackgroundView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        root.color = TermAppearance.background // 칸에 안 맞는 아래 틈도 터미널과 같은 색

        tabBar.onSelect = { [weak self] index in self?.model.selectTab(index) }
        tabBar.onClose = { [weak self] index in
            self?.model.selectTab(index)
            self?.model.closeTab()
        }
        tabBar.onNew = { [weak self] in self?.model.newPane() }
        tabBar.onContentChanged = { [weak self] in self?.onTabBarContentChanged?() }
        tabBar.onRename = { [weak self] index in
            guard let self, self.model.workspace.tabs.indices.contains(index) else { return }
            self.model.selectTab(index)
            self.model.rename(pane: self.model.workspace.tabs[index].focused)
        }
        tabBar.onMove = { [weak self] from, to in self?.model.moveTab(from: from, to: to) }
        tabBar.onDragOutside = { [weak self] index, point in self?.dragTab(index, at: point, drop: false) }
        tabBar.onDropOutside = { [weak self] index, point in self?.dragTab(index, at: point, drop: true) }
        container.onPaneDrag = { [weak self] id, point, ended in self?.drag(.pane(id), at: point, drop: ended) }
        container.onExtract = { [weak self] id in self?.model.extractPane(id) }
        container.onPin = { [weak self] id in self?.model.pin(editor: id) }
        dropOverlay.isHidden = true
        for view in [container, placeholder, tabBar, dropOverlay] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = Space.sm
        placeholderIcon.contentTintColor = TermAppearance.textDim
        placeholderLabel.textColor = TermAppearance.textSecondary
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 0
        placeholderLabel.preferredMaxLayoutWidth = 320
        placeholder.addArrangedSubview(placeholderIcon)
        placeholder.addArrangedSubview(placeholderLabel)
        applyPlaceholderFonts()
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBarHeight,
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dropOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            dropOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.onRatioChange = { [weak self] path, ratio in self?.model.setRatio(path: path, ratio: ratio) }
        view = root
        render()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        sessionSwitcher.layout()
    }

    var focusedTerminal: PaneTerminal? {
        model.workspace.selectedTab.flatMap { terminals[$0.focused] }
    }

    var focusedEditor: EditorPaneView? {
        model.workspace.selectedTab.flatMap { editorViews[$0.focused] }
    }

    /// 앞에 있는 브라우저 창의 화면(시험 명령·편집 메뉴)
    var focusedBrowser: BrowserPaneView? { model.browserWindows.keyPane }

    /// 탭·분할 배치가 바뀌면 부른다. 보일 화면의 뷰만 남기고 나머지는 버린다.
    func render() {
        guard isViewLoaded else { return }
        model.browserWindows.follow(model.selectedId)
        let tab = model.connected ? model.workspace.selectedTab : nil
        let visible = tab?.visibleRoot
        // 꺼진 화면이 보이게 되면 이때 되살린다(attach 보다 먼저 만들어지도록 같은 연결로 먼저 보낸다)
        // 되살린 화면은 예전 뷰(실패해 비어 있을 수 있음)를 버리고 새로 붙는다
        for id in model.revive(visible?.panes ?? []) {
            terminals[id]?.detach()
            terminals[id] = nil
        }
        let ids = Set(visible?.panes ?? [])
        for (id, terminal) in terminals where !ids.contains(id) {
            terminal.detach()
            terminals[id] = nil
        }
        for (id, editor) in editorViews where !ids.contains(id) {
            model.rememberEditorCursor(id, editor.document.cursor)
            editor.detach()
            editorViews[id] = nil
        }
        var created: [PaneTerminal] = []
        for id in visible?.panes ?? [] {
            if BrowserPane.isBrowser(id) {
                continue // 주인 정보가 없는 잎(읽을 때 빼므로 생기지 않는다)
            } else if EditorPane.isEditor(id) {
                guard editorViews[id] == nil, let recipe = model.workspace.editors[id] else { continue }
                let editor = EditorPaneView(document: model.editors.document(id: id, recipe: recipe), frame: container.bounds)
                editor.onOpenFile = { [weak self] path in self?.openLinkedFile(path) }
                editor.onNavigate = { [weak self] index in self?.navigator.gotoDeclaration(at: index) }
                editorViews[id] = editor
            } else if terminals[id] == nil {
                let terminal = PaneTerminal(id: id, client: model.client, frame: container.bounds)
                terminals[id] = terminal
                created.append(terminal)
            }
        }
        var views: [String: NSView] = terminals.mapValues { $0.surface }
        for (id, editor) in editorViews { views[id] = editor }
        container.update(tree: visible, views: views, focused: tab?.focused, titles: paneTitles)
        // 크기가 정해진 뒤 붙어야 지난 출력이 맞는 크기로 그려진다
        created.forEach { $0.attach() }

        // 탭 줄은 창 제목 줄이기도 해서 탭이 없어도 높이를 둔다(신호등 자리·창 끌기). 탭이 없으면 줄만 그리고 "+" 는 안 그린다.
        tabBarHeight.constant = Self.tabBarHeight
        onTabBarHeightChanged?()
        updateTabBar()
        placeholder.isHidden = tab != nil
        placeholderLabel.stringValue = model.connectionStatusText ?? "왼쪽 위 버튼이나 ⌘T로 새 세션을 여세요"
        focusTerminal()
    }

    /// 포커스만 바뀌었을 때(뷰는 그대로)
    func focusChanged() {
        model.browserWindows.follow(model.selectedId) // 세션 창 안 브라우저는 고른 세션을 따라간다
        container.setFocused(model.workspace.selectedTab?.focused, titles: paneTitles)
        updateTabBar()
        focusTerminal()
    }

    /// 목록이 새로 왔을 때 테두리 제목만 고친다(포커스는 건드리지 않음)
    func refreshTitles() {
        container.setFocused(model.workspace.selectedTab?.focused, titles: paneTitles)
        updateTabBar()
    }

    private func updateTabBar() {
        let workspace = model.workspace
        // 탭마다 화면 상태를 찾으므로 줄을 한 번만 사전으로 만든다(탭·화면 수만큼 목록을 훑지 않게)
        let statuses = Dictionary(model.rows.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        let kinds: [String: SessionKind] = Dictionary(model.rows.map { row in
            (row.id, row.sessionKind)
        }, uniquingKeysWith: { first, _ in first })
        let warnings = Dictionary(model.rows.compactMap { row in row.launchWarning.map { (row.id, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        publishWindowTitle()
        tabBar.update(tabs: workspace.tabs.map { tab in
            TabBarView.Tab(title: model.tabTitle(tab), paneCount: tab.root.panes.count, zoomed: tab.zoomed,
                           status: WorkStatus.top(tab.root.panes.compactMap { statuses[$0] }),
                           warning: tab.root.panes.lazy.compactMap { warnings[$0] }.first,
                           kind: EditorPane.isEditor(tab.focused) ? .document : kinds[tab.focused] ?? .shell)
        }, selected: workspace.selectedIndex)
    }

    /// 창 제목 = 고른 탭의 이름, 부제 = 그 폴더(편집기는 파일이 든 폴더). 탭이 없으면 앱 이름만.
    private func publishWindowTitle() {
        let selected = model.connected ? model.workspace.selectedTab?.focused : nil
        var folder: String?
        if let selected {
            if EditorPane.isEditor(selected) {
                folder = model.workspace.editors[selected].map { ($0.path as NSString).deletingLastPathComponent }
            } else {
                folder = model.row(selected)?.cwd
            }
        }
        let text = WindowChrome.windowTitle(session: selected.map(model.paneLabel), folder: folder, home: NSHomeDirectory())
        onWindowTitleChanged?(text.title, text.subtitle)
    }

    /// 분할 테두리에 쓰는 화면 제목과 상태
    private var paneTitles: [String: PaneTitle] {
        Dictionary(uniqueKeysWithValues: (Array(terminals.keys) + Array(editorViews.keys)).map { id in
            (id, PaneTitle(name: model.paneLabel(id), status: model.row(id)?.status ?? .none,
                           preview: model.workspace.editors[id]?.isPreview == true))
        })
    }

    private func focusTerminal() {
        // 이동 목록 창이 키보드를 쥐고 있으면 그대로
        if navigator.popupHasFocus || sessionSwitcher.popup != nil { return }
        // 작은 터미널 창에 키보드가 있으면 그대로(세션을 바꿔도 거기 남는다)
        if model.scratch.hasFocus { return }
        if let editor = focusedEditor {
            // 편집기 안(찾기 막대 등)에 이미 포커스가 있으면 그대로
            if let responder = editor.window?.firstResponder as? NSView, responder.isDescendant(of: editor) { return }
            if let target = editor.focusTarget { editor.window?.makeFirstResponder(target) }
            return
        }
        guard let pane = focusedTerminal, let window = pane.view.window, window.firstResponder !== pane.view else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: pane.surface) { return }
        window.makeFirstResponder(pane.view)
    }

    /// 지금 화면(터미널·편집기)에 키보드 포커스
    func focusPane() { focusTerminal() }

    /// Markdown 미리보기에서 누른 로컬 파일 링크: 편집기로 연다(Markdown 이면 미리보기로)
    func openLinkedFile(_ path: String) {
        model.openFile(path)
        if MarkdownFile.isMarkdown(path: path) { focusedEditor?.setPreview(true) }
    }

    /// 지금 화면의 뷰(도구 창에서 Esc 로 돌아갈 곳)
    var focusedPaneView: NSView? { focusedEditor?.focusTarget ?? focusedTerminal?.view }

    /// 앱을 끌 때: 보이는 편집기 커서를 기억
    func rememberEditorCursors() {
        for (id, editor) in editorViews {
            model.rememberEditorCursor(id, editor.textView?.selectedRange().location ?? editor.document.cursor)
        }
    }

    func receive(id: String, bytes: ArraySlice<UInt8>, replay: Bool) {
        terminals[id]?.receive(bytes, replay: replay)
    }

    /// 글꼴 크기가 바뀌면 지금 있는 터미널에 적용한다(나중에 만들 화면은 만들 때 지금 크기를 쓴다).
    /// 탭 줄·분할 제목도 배율을 따라 높이가 바뀌므로 다시 배치한다(터미널 줄 수가 바뀌면 창 크기를 바꿀 때처럼 데몬에 알린다).
    @objc private func fontSizeChanged() {
        for terminal in terminals.values { terminal.applyFont() }
        guard isViewLoaded else { return }
        if tabBarHeight.constant > 0 { tabBarHeight.constant = Self.tabBarHeight; onTabBarHeightChanged?() }
        sessionSwitcher.scaleChanged()
        applyPlaceholderFonts()
        tabBar.scaleChanged()
        container.scaleChanged()
    }

    /// 빈 화면 안내 글꼴·아이콘 크기(글꼴 배율을 따른다)
    private func applyPlaceholderFonts() {
        placeholderLabel.font = TermAppearance.uiTextFont(TermAppearance.scaled(TypeSize.emphasis))
        let configuration = NSImage.SymbolConfiguration(pointSize: TermAppearance.scaled(28), weight: .light)
        placeholderIcon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    func paneExited(_ id: String) {
        terminals[id]?.exited()
    }

    /// 새 화면 크기 어림: 새 탭이면 영역 전체, 나누면 지금 화면의 반
    func estimatedSize(splitting axis: SplitAxis?) -> (cols: Int, rows: Int) {
        if let axis, let size = focusedTerminal?.size {
            return axis == .horizontal ? (max(size.cols / 2, 10), size.rows) : (size.cols, max(size.rows / 2, 4))
        }
        let probe = TerminalView(frame: container.bounds.isEmpty ? view.bounds : container.bounds, font: TermAppearance.font)
        let terminal = probe.getTerminal()
        return (terminal.cols, terminal.rows)
    }

    // MARK: - 탭·화면 끌어 옮기기
    // 탭: 탭 줄 안에서는 순서 바꾸기(탭 줄이 직접 그린다), 밖으로 끌어 지금 탭의 화면 위에 놓으면 그 화면을 나눠 탭째 넣는다.
    // 화면(분할 제목 줄): 다른 화면 위에 놓으면 그쪽으로 나눠 옮기고, 탭 줄에 놓으면 새 탭으로.

    private enum DragItem {
        case tab(String)
        case pane(String)
    }

    private func dragTab(_ index: Int, at point: NSPoint?, drop: Bool) {
        guard model.workspace.tabs.indices.contains(index) else { return dropOverlay.clear() }
        drag(.tab(model.workspace.tabs[index].id), at: point, drop: drop)
    }

    /// 끄는 중이면 놓일 곳을 보이고, 놓았으면 옮긴다. point 가 nil 이면 탭 줄 안(탭 줄이 순서 바꾸기를 직접 보인다).
    private func drag(_ item: DragItem, at point: NSPoint?, drop: Bool) {
        let target = point.flatMap { dropTarget(item, at: $0) }
        if case .tab(let gap)? = target?.drop, !drop { tabBar.setInsertion(gap) } else { tabBar.setInsertion(nil) }
        guard !drop, let point else {
            dropOverlay.clear()
            guard drop, let target else { return }
            switch item {
            case .tab(let id): model.move(tab: id, to: target.drop)
            case .pane(let id): model.move(pane: id, to: target.drop)
            }
            return
        }
        let title: String
        var source: CGRect?
        switch item {
        case .tab(let id):
            title = model.workspace.tabs.first { $0.id == id }.map(model.tabTitle) ?? ""
        case .pane(let id):
            title = model.paneLabel(id)
            source = container.paneFrame(id).map { dropOverlay.convert($0, from: container) }
        }
        dropOverlay.show(zone: target?.zone, source: source, chip: title, at: dropOverlay.convert(point, from: nil))
    }

    /// 놓을 곳. 끄는 탭·화면 자신 위는 없음.
    private func dropTarget(_ item: DragItem, at point: NSPoint) -> (drop: PaneDrop, zone: CGRect?)? {
        if case .pane = item, tabBar.isInBand(point) { return (.tab(gap: tabBar.gap(at: point)), nil) }
        guard let (pane, direction, rect) = container.dropZone(at: point) else { return nil }
        let own: [String]
        switch item {
        case .tab(let id): own = model.workspace.tabs.first { $0.id == id }?.root.panes ?? []
        case .pane(let id): own = [id]
        }
        guard !own.contains(pane) else { return nil }
        return (.split(target: pane, toward: direction), dropOverlay.convert(rect, from: container))
    }

    // MARK: - 시험용

    /// 끌기 시험용 좌표(창 좌표, 아래가 0): 탭 가운데, 화면 자리와 제목 줄 가운데
    func debugDragPoints() -> String {
        func point(_ p: CGPoint) -> String { "\(Int(p.x)),\(Int(p.y))" }
        var lines = tabBar.windowTabRects.enumerated().map { "tab \($0.offset) center=\(point(CGPoint(x: $0.element.midX, y: $0.element.midY)))" }
        for id in model.workspace.selectedTab?.visibleRoot.panes ?? [] {
            guard let frame = container.paneFrame(id) else { continue }
            let rect = container.convert(frame, to: nil)
            lines.append("pane \(id.prefix(8)) rect=\(point(rect.origin)) \(Int(rect.width))x\(Int(rect.height)) "
                + "title=\(point(container.convert(CGPoint(x: frame.midX, y: frame.minY + 8), to: nil)))")
        }
        return lines.joined(separator: "\n")
    }

    /// 한글 입력기(IME)가 하는 것과 같은 순서로 조합 중 글자 → 확정 글자를 넣는다.
    func simulateIME(composing: [String], commit: String) {
        if let browser = focusedBrowser?.focusTarget as? BrowserScreenView {
            for text in composing {
                browser.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            browser.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        guard let terminalView = focusedTerminal?.view else { return }
        for text in composing {
            terminalView.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        terminalView.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 조합 중 글자만 띄운다(아무것도 보내지 않음). 빈 글자면 지운다.
    func debugMark(_ text: String) {
        focusedTerminal?.view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                                            replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func debugCursor() {
        guard let terminal = focusedTerminal?.view.getTerminal() else { return }
        let buffer = terminal.buffer
        print("cursor x=\(buffer.x) y=\(buffer.y) rows=\(terminal.rows) panes=\(terminals.keys.sorted())")
        fflush(stdout)
    }

    /// 터미널 영역(탭 줄 포함)을 그림으로 남긴다. 터미널 배경은 층(layer) 색이라 render 결과에 안 담기므로 바탕을 먼저 칠한다.
    func snapshotTerminal(to url: URL) {
        guard let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        // 터미널 글자는 터미널 층을 따로 그려야 담긴다(층 render 는 하위 층 좌표를 위아래 뒤집어 그린다)
        for terminal in terminals.values {
            guard let sublayer = terminal.view.layer else { continue }
            let frame = terminal.view.convert(terminal.view.bounds, to: view)
            context.saveGState()
            context.translateBy(x: frame.minX, y: size.height - frame.maxY)
            context.clip(to: CGRect(origin: .zero, size: frame.size))
            sublayer.render(in: context)
            context.restoreGState()
        }
        guard let content = context.makeImage(),
              let final = CGContext(data: nil, width: content.width, height: content.height, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        let rect = CGRect(x: 0, y: 0, width: content.width, height: content.height)
        final.setFillColor(TermAppearance.background.cg(in: view))
        final.fill(rect)
        final.draw(content, in: rect)
        guard let image = final.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    /// 화면 하나만 따로(예전 방식) — 글자가 그려지는지 확인용
    func snapshotPanes(in dir: URL) {
        for (id, terminal) in terminals {
            guard let layer = terminal.view.layer else { continue }
            let size = terminal.view.bounds.size
            guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.setFillColor(TermAppearance.background.cg(in: terminal.view))
            context.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
            context.scaleBy(x: 2, y: 2)
            layer.render(in: context)
            guard let image = context.makeImage() else { continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("pane-\(id.prefix(4)).png"), options: .atomic)
        }
    }

    /// 탭 줄만 따로
    func snapshotTabBar(to url: URL) {
        guard !tabBar.bounds.isEmpty, let rep = tabBar.bitmapImageRepForCachingDisplay(in: tabBar.bounds) else { return }
        tabBar.cacheDisplay(in: tabBar.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    func typeText(_ text: String) {
        // 작은 터미널에 키보드가 있으면 거기로
        guard let id = (model.scratch.hasFocus ? model.scratch.current : focusedTerminal)?.id else { return }
        model.client.input(id, Array(text.utf8))
    }
}

/// 터미널과 같은 바탕색을 칠하는 영역(터미널 줄 높이에 안 맞아 남는 아래 틈이 튀지 않게)
final class BackgroundView: NSView {
    var color: NSColor = .textBackgroundColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        // macOS 14 부터 뷰가 경계 밖을 자르지 않아 dirtyRect 가 바깥까지 올 수 있다(옆 뷰를 덮지 않게 경계 안만)
        dirtyRect.intersection(bounds).fill()
    }
}
