import AppKit
import SwiftUI
import TermLayout
import TermWire

/// IntelliJ 식 도구 창: 창 = [왼쪽 도크 | 터미널 | 오른쪽 도크]. 도구(spaces·files)는 왼쪽·오른쪽·숨김 중 한 곳에 붙고,
/// 도구가 둘 붙은 도크는 위에 도구 버튼 줄이 생긴다. 보이는 도구가 없는 도크는 접힌다.
/// 배치·도크 폭은 `term/ui.json` 에 저장한다.
final class ToolWindowsController: NSObject {
    let split = NSSplitViewController()
    private(set) var layout: ToolLayout
    let files: FilesToolController
    private let model: TermModel
    private let sidebar: NSHostingController<SidebarView>
    private let docks: [DockSide: DockViewController]
    private let browserButton = BrowserToggleButton()
    /// 세션 창 안에 떠 있는 작은 브라우저 창(host.view 위, 🌐 버튼 아래)
    private let floatPanel = BrowserFloatPanel()
    /// 작은 창을 끄는 동안 그 칸(끝에서 같은 칸에 알린다 — 그사이 도크가 다른 세션으로 바뀌어도)
    private var gesturePane: BrowserPaneView?
    private let host: TerminalHostController
    private var items: [DockSide: NSSplitViewItem] = [:]
    /// 배치를 바꾸는 중에는 폭 변화를 기록하지 않는다
    private var applying = false
    private var widthsRestored = false
    private var saveWork: DispatchWorkItem?

    static var url: URL { TermPaths.home.appendingPathComponent("ui.json") }

    init(model: TermModel, host: TerminalHostController) {
        self.model = model
        self.host = host
        layout = ToolLayout.load(from: Self.url)
        files = FilesToolController(model: model)
        sidebar = NSHostingController(rootView: SidebarView(model: model))
        docks = [.left: DockViewController(side: .left, model: model), .right: DockViewController(side: .right, model: model)]
        super.init()

        files.dockMenu = { [weak self] in self?.menu(for: .files) ?? NSMenu() }
        // 파일 열기: 두 번 클릭·Enter = 지금 화면 옆 미리보기(여러 개면 고정 화면으로 쌓기), ⌘두 번 클릭·메뉴 = 새 탭, 메뉴 = 나눠 열기
        files.onOpenFile = { [weak model] path in model?.openFromTree(path) }
        files.onOpenFiles = { [weak model] paths in model?.openFromTree(paths: paths) }
        files.onOpenFileInTab = { [weak model] path in model?.openFile(path) }
        files.onOpenFileSplit = { [weak model] path, axis in model?.openFile(path, split: axis) }
        // browser 도구: 고른 세션의 브라우저(보는 곳이 "세션 창 안"인 세션) — 칸은 BrowserWindows 가 들고 있다
        model.browserWindows.revealDock = { [weak self] in self?.reveal(.browser) }
        model.browserWindows.dockVisible = { [weak self] in self?.layout.isBrowserShown == true }
        model.browserWindows.dockFloating = { [weak self] in self?.layout.browserFloat.shown == true }
        model.browserWindows.floatDock = { [weak self] in self?.showBrowserFloat() }
        model.browserWindows.moveDock = { [weak self] side in self?.move(.browser, to: side) }
        model.browserWindows.titleFor = { [weak model] owner in model?.row(owner)?.title }
        for (_, dock) in docks {
            dock.onSelect = { [weak self] tool in self?.select(tool) }
            dock.menuFor = { [weak self] tool in self?.menu(for: tool) ?? NSMenu() }
        }

        // 도크는 창 크기가 바뀌어도 폭을 지키고(터미널이 늘고 준다), 접을 수 있다
        let left = NSSplitViewItem(viewController: docks[.left]!)
        let content = NSSplitViewItem(viewController: host)
        let right = NSSplitViewItem(viewController: docks[.right]!)
        for item in [left, right] {
            item.canCollapse = true
            item.minimumThickness = 220
            // 브라우저 도크는 페이지가 칸 그대로(1:1) 보일 만큼 넓힐 수 있게(터미널은 400pt 남는다). 도구마다 상한을 바꾸면
            // 같은 도크에서 도구를 바꿀 때 넓힌 폭이 줄어들어 한 상한을 쓴다
            item.maximumThickness = CGFloat(ToolLayout.maxWidth)
            item.holdingPriority = NSLayoutConstraint.Priority(260)
        }
        content.minimumThickness = 400
        content.holdingPriority = NSLayoutConstraint.Priority(250)
        split.addSplitViewItem(left)
        split.addSplitViewItem(content)
        split.addSplitViewItem(right)
        // 세션 창 오른쪽 아래 🌐: 세션 창 안 브라우저 칸 켜고 끄기 + 브라우저 상태(터미널 위에 떠 있다 — 터미널 칸 자식들은 그대로라 맨 위에 남는다).
        // 크기는 버튼이 정한다(동그라미 ↔ 상태 알약, 오른쪽 아래 고정)
        browserButton.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(browserButton)
        NSLayoutConstraint.activate([
            browserButton.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -14),
            browserButton.bottomAnchor.constraint(equalTo: host.view.bottomAnchor, constant: -12),
        ])
        browserButton.onClick = { [weak self] in self?.toggleBrowserFromButton() }
        floatPanel.onClose = { [weak self] in self?.move(.browser, to: .hidden) }
        floatPanel.onToggleSize = { [weak self] in self?.toggleFloatSize() }
        floatPanel.onFrameChanged = { [weak self] frame in self?.floatFrameChanged(frame) }
        // 끌어 옮기거나 크기를 바꾸는 동안은 브라우저 페이지 크기를 맞추지 않고(그림만 줄이고 늘림) 끝나면 한 번 맞춘다
        floatPanel.onGestureBegan = { [weak self] in
            self?.gesturePane = self?.model.browserWindows.dock.hosted
            self?.gesturePane?.beginResizeGesture()
        }
        floatPanel.onGestureEnded = { [weak self] in
            self?.gesturePane?.endResizeGesture()
            self?.gesturePane = nil
        }
        host.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(hostResized), name: NSView.frameDidChangeNotification,
                                               object: host.view)
        // 세션·상태가 바뀜: 🌐 버튼과 작은 창 제목(세션 이름)
        model.browserWindows.onDockOwnerOrState = { [weak self] in
            guard let self else { return }
            self.refreshBrowserButton()
            // 제목만 — 자리는 건드리지 않는다(끄는 도중 상태가 바뀌어도 저장된 자리로 튀지 않게)
            self.floatPanel.setTitle(self.floatTitle())
        }
        items = [.left: left, .right: right]
        apply()
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged),
                                               name: TermAppearance.fontSizeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized),
                                               name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
    }

    private func controller(_ tool: ToolID) -> NSViewController {
        switch tool {
        case .spaces: return sidebar
        case .files: return files
        case .browser: return model.browserWindows.dock
        }
    }

    // MARK: - 배치 적용

    private func apply() {
        applying = true
        defer { applying = false }
        defer { refreshBrowserButton() }
        var opened: [DockSide] = []
        // 상태 줄은 도크 하나에만: 왼쪽이 보이면 왼쪽, 아니면 오른쪽
        let footerSide: DockSide = layout.visibleTool(in: .left) != nil ? .left : .right
        for side in [DockSide.left, .right] {
            guard let dock = docks[side], let item = items[side] else { continue }
            let visible = layout.visibleTool(in: side)
            dock.show(tools: layout.tools(in: side), selected: visible, content: visible.map(controller))
            dock.showsFooter = side == footerSide && visible != nil
            let collapse = visible == nil
            if item.isCollapsed != collapse {
                item.isCollapsed = collapse
                if !collapse { opened.append(side) }
            }
        }
        // spaces 가 다른 도구와 같은 도크에 있으면 위 버튼 줄이 이름을 보이므로 자기 제목은 뺀다
        let spacesShared = layout.tools(in: layout.side(of: .spaces)).count > 1
        sidebar.rootView = SidebarView(model: model, showsTitle: !spacesShared,
                                       onDock: { [weak self] side in self?.move(.spaces, to: side) },
                                       currentSide: layout.side(of: .spaces))
        if widthsRestored, !opened.isEmpty {
            split.splitView.layoutSubtreeIfNeeded()
            for side in opened { setWidth(side) }
        }
        files.setToolVisible(layout.isVisible(.files))
        // 작은 창은 도크 쪽 정리(위 반복문이 browser 를 도크에서 뗀 뒤)에 내용을 달고, 도크로 돌아갈 때는 도크가 먼저 가져간다
        applyFloat()
        model.browserWindows.dock.setToolVisible(layout.isBrowserShown)
    }

    // MARK: - 작은 창(세션 창 안에 떠 있는 브라우저)

    /// 🌐 버튼 윗선 + 14pt (작은 창의 기본 아래 위치)
    private var floatBottomInset: Double { 12 + Double(BrowserToggleButton.size) + BrowserFloatFrame.margin }

    /// host.view 좌표(위·아래가 뒤집혔을 수 있다)와 아래-왼쪽 원점 사각형을 오간다
    private func flipped(_ rect: NSRect) -> NSRect {
        guard host.view.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: host.view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 지금 있어야 할 작은 창 자리(저장된 자리 또는 기본, 호스트 안으로 맞춘 것)
    private func floatRect() -> NSRect {
        let size = host.view.bounds.size
        let rect = layout.browserFloat.frame?.rect(in: size)
            ?? BrowserFloatFrame.defaultRect(in: size, bottomInset: floatBottomInset)
        return flipped(rect)
    }

    private func applyFloat() {
        let shown = layout.browserFloat.shown
        if shown {
            if floatPanel.superview !== host.view {
                host.view.addSubview(floatPanel, positioned: .below, relativeTo: browserButton)
            }
            floatPanel.setContent(model.browserWindows.dock.view)
            layoutFloat()
        } else {
            floatPanel.setContent(nil)
            floatPanel.removeFromSuperview()
        }
    }

    private func layoutFloat() {
        guard layout.browserFloat.shown, floatPanel.superview === host.view else { return }
        let rect = floatRect()
        if floatPanel.frame != rect { floatPanel.frame = rect }
        floatPanel.setLarge(isFloatLarge())
        floatPanel.setTitle(floatTitle())
    }

    private func floatTitle() -> String {
        let name = model.browserWindows.dock.owner.flatMap { model.row($0)?.title }
        return "🌐 브라우저" + (name.map { " · \($0)" } ?? "")
    }

    @objc private func hostResized() { layoutFloat() }

    /// 사람이 끌어 옮기거나 크기를 바꿈: 호스트 대비 비율로 저장
    private func floatFrameChanged(_ frame: NSRect) {
        let rect = BrowserFloatFrame.clamp(flipped(frame), in: host.view.bounds.size)
        layout.browserFloat.frame = BrowserFloatFrame(rect: rect, in: host.view.bounds.size)
        layoutFloat()
        save()
    }

    /// 지금 "크게" 크기인가: 비율로 짐작하지 않고 크게 자리와 견준다(좁은 창에서는 기본 자리도 최소 폭에 걸려 넓어 보여서)
    private func isFloatLarge() -> Bool {
        let large = BrowserFloatFrame.clamp(BrowserFloatFrame.largeRect(in: host.view.bounds.size, bottomInset: floatBottomInset),
                                            in: host.view.bounds.size)
        let now = floatRect()
        return abs(now.width - large.width) < 2 && abs(now.height - large.height) < 2
    }

    /// "크게"/"작게": 크게 ↔ 기본 자리
    private func toggleFloatSize() {
        let size = host.view.bounds.size
        let large = isFloatLarge()
        let rect = large ? nil : BrowserFloatFrame(rect: BrowserFloatFrame.largeRect(in: size, bottomInset: floatBottomInset), in: size)
        layout.browserFloat.frame = rect
        layoutFloat()
        save()
    }

    /// 작은 창으로 보이기(메뉴 "작은 창으로"·`dock browser float`): 도크에 있었으면 내리고, 이미 작은 창이면 그대로
    func showBrowserFloat() {
        guard !layout.browserFloat.shown else { return }
        change { $0.showBrowserFloat() }
    }

    /// 시험 명령 `browsers`·`uilayout`: 작은 창 상태와 실제 자리(창 좌표, 원점 왼쪽 아래 — `mouse down x y` 에 그대로 쓴다)
    var debugFloat: String {
        let f = layout.browserFloat
        let place = f.shown ? "float" : (layout.side(of: .browser) == .hidden ? "hidden" : layout.side(of: .browser).rawValue)
        var text = "browser-float presentation=\(place) shown=\(f.shown) "
        text += "saved=" + (f.frame.map { String(format: "right=%.3f bottom=%.3f w=%.3f h=%.3f", $0.right, $0.bottom, $0.width, $0.height) } ?? "default")
        text += " host=\(Int(host.view.bounds.width))x\(Int(host.view.bounds.height))"
        if f.shown, floatPanel.superview === host.view {
            let r = floatPanel.convert(floatPanel.bounds, to: nil)
            text += String(format: " panel(window)=x=%.0f y=%.0f w=%.0f h=%.0f content=%@", r.minX, r.minY, r.width, r.height,
                           floatPanel.hasContent ? "yes" : "no")
            let b = browserButton.convert(browserButton.bounds, to: nil)
            text += String(format: " button(window)=x=%.0f y=%.0f w=%.0f h=%.0f", b.minX, b.minY, b.width, b.height)
        }
        return text
    }

    /// 창을 띄운 뒤 한 번: 저장된 도크 폭으로
    func restoreWidths() {
        split.splitView.layoutSubtreeIfNeeded()
        applying = true
        for side in [DockSide.left, .right] where items[side]?.isCollapsed == false { setWidth(side) }
        applying = false
        widthsRestored = true
        layoutFloat() // 저장된 작은 창은 창이 뜬 뒤 크기가 정해진 다음에 자리를 잡는다
    }

    private func setWidth(_ side: DockSide) {
        let view = split.splitView
        let width = CGFloat(layout.width(side))
        switch side {
        case .left: view.setPosition(width, ofDividerAt: 0)
        case .right: view.setPosition(view.bounds.width - width - view.dividerThickness, ofDividerAt: 1)
        case .hidden: break
        }
    }

    @objc private func splitResized() {
        guard widthsRestored, !applying else { return }
        var changed = false
        for side in [DockSide.left, .right] {
            guard let item = items[side], !item.isCollapsed, let view = docks[side]?.view, view.frame.width >= 100 else { continue }
            let width = Double(view.frame.width.rounded())
            if abs(width - layout.width(side)) >= 1 {
                layout.widths[side] = width
                changed = true
            }
        }
        if changed { save() }
    }

    /// 글꼴 크기는 같은 `ui.json` 에 저장한다(기본 크기면 비운다)
    @objc private func fontSizeChanged() {
        let size = TermAppearance.fontSize
        layout.fontSize = size == TermAppearance.defaultFontSize ? nil : Double(size)
        save()
        // 도구 창도 배율을 따른다(spaces·상태 줄은 SwiftUI 라 UIScaleModel 로 스스로 다시 그린다)
        docks.values.forEach { $0.scaleChanged() }
        browserButton.scaleChanged()
        layoutFloat()
        files.scaleChanged()
    }

    private func save() {
        saveWork?.cancel()
        let data = layout.data()
        let work = DispatchWorkItem { [url = Self.url] in try? data?.write(to: url, options: .atomic) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func change(_ update: (inout ToolLayout) -> Void) {
        var next = layout
        update(&next)
        widenBrowserDock(&next)
        guard next != layout else { return }
        let old = layout
        layout = next
        apply()
        // 이미 펼쳐진 도크의 폭이 바뀌었으면(브라우저를 처음 꺼내 넓힘) 바로 그 폭으로 — 새로 펼친 도크는 apply 가 맞춘다
        if widthsRestored {
            for side in [DockSide.left, .right] where old.width(side) != next.width(side) && items[side]?.isCollapsed == false {
                applying = true
                split.splitView.layoutSubtreeIfNeeded()
                setWidth(side)
                applying = false
            }
        }
        save()
    }

    /// 브라우저를 처음 꺼낸 도크(기본 폭 640 그대로)는 창 폭의 45% 까지 넓힌다: 넓은 창에서 640pt 칸은 페이지를 작게 줄여 보여서.
    /// 도크 폭이 1024 이상이면 페이지가 칸 그대로(1:1) 그려진다(BrowserViewOptions.pageSize(for:docked:)). 터미널 쪽은 560pt 남긴다.
    /// 사람이 정한 폭은 건드리지 않는다.
    private func widenBrowserDock(_ next: inout ToolLayout) {
        let side = next.side(of: .browser)
        guard side != .hidden, !layout.isVisible(.browser), next.isVisible(.browser),
              next.width(side) == ToolLayout.browserWidth, let window = split.view.window else { return }
        let other: DockSide = side == .left ? .right : .left
        let otherWidth = next.visibleTool(in: other) != nil ? next.width(other) : 0
        let room = Double(window.contentLayoutRect.width) - otherWidth - 560
        let target = min((Double(window.contentLayoutRect.width) * 0.45).rounded(), room)
        if target > ToolLayout.browserWidth { next.widths[side] = target }
    }

    /// 🌐 버튼: 브라우저 칸이 열려 있으면 닫고, 아니면 고른 세션의 브라우저를 세션 창 안에 연다
    /// (그 세션을 별도 창으로 보고 있었으면 세션 창 안으로 옮긴다 — 한 세션의 브라우저는 한 곳에만)
    private func toggleBrowserFromButton() {
        if layout.isBrowserShown { move(.browser, to: .hidden); return }
        let windows = model.browserWindows
        if let owner = windows.dock.owner { windows.move(owner, to: .dock) } else { reveal(.browser) }
    }

    private func refreshBrowserButton() {
        let owner = model.browserWindows.dock.owner
        browserButton.indicator = owner.flatMap { model.browserStates[$0] }.flatMap(BrowserIndicator.init)
        browserButton.isOn = layout.isBrowserShown
        if layout.browserFloat.shown { floatPanel.setTitle(floatTitle()) }
    }

    // MARK: - 동작

    func select(_ tool: ToolID) {
        let side = layout.side(of: tool)
        guard side != .hidden else { return }
        change { $0.selected[side] = tool }
    }

    func move(_ tool: ToolID, to side: DockSide) {
        let hadFocus = ownsFirstResponder(tool)
        change { $0.move(tool, to: side) }
        if side == .hidden, hadFocus { focusTerminal() }
    }

    /// 안 보이면 보이게(숨김이면 마지막 쪽에, 같은 도크의 다른 도구가 보이면 이것으로). 이미 보이면 그대로.
    func reveal(_ tool: ToolID) {
        guard !(tool == .browser ? layout.isBrowserShown : layout.isVisible(tool)) else { return }
        change { $0.toggle(tool) }
    }

    /// ⌘⇧E·⌘⇧S
    func toggle(_ tool: ToolID) {
        let hadFocus = ownsFirstResponder(tool)
        change { $0.toggle(tool) }
        if tool == .browser ? layout.isBrowserShown : layout.isVisible(tool) {
            if tool == .files { files.focusTree() }
        } else if hadFocus {
            focusTerminal()
        }
    }

    private func ownsFirstResponder(_ tool: ToolID) -> Bool {
        guard let responder = split.view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: controller(tool).view)
    }

    private func focusTerminal() {
        if let target = model.host?.focusedPaneView { split.view.window?.makeFirstResponder(target) }
    }

    /// 메뉴·단축키 이름: tool-toggle:<도구>, tool-move:<도구>:<left|right|hidden>(browser 는 float 도), tool-select:<도구>
    @discardableResult
    func perform(_ action: String) -> Bool {
        let parts = action.split(separator: ":").map(String.init)
        guard parts.count >= 2, let tool = ToolID(rawValue: parts[1]) else { return false }
        switch parts[0] {
        case "tool-toggle": toggle(tool)
        case "tool-select": select(tool)
        case "tool-move":
            if tool == .browser, parts.count >= 3, parts[2] == "float" { showBrowserFloat(); return true }
            guard parts.count >= 3, let side = DockSide(rawValue: parts[2]) else { return false }
            move(tool, to: side)
        default: return false
        }
        return true
    }

    /// 도구 버튼·머리 줄 오른쪽 클릭 메뉴
    func menu(for tool: ToolID) -> NSMenu {
        let menu = NSMenu()
        let side = layout.side(of: tool)
        let left = ClosureMenuItem(title: "왼쪽으로 옮기기") { [weak self] in self?.move(tool, to: .left) }
        left.state = side == .left ? .on : .off
        let right = ClosureMenuItem(title: "오른쪽으로 옮기기") { [weak self] in self?.move(tool, to: .right) }
        right.state = side == .right ? .on : .off
        var floatItem: NSMenuItem?
        if tool == .browser {
            let item = ClosureMenuItem(title: "작은 창으로") { [weak self] in self?.showBrowserFloat() }
            item.state = layout.browserFloat.shown ? .on : .off
            floatItem = item
        }
        let hide = ClosureMenuItem(title: "숨기기") { [weak self] in self?.move(tool, to: .hidden) }
        // ⌘⇧B 는 "브라우저 보기"(보는 곳에 열기) — 숨기기 단축키로 쓰지 않는다
        if tool != .browser {
            hide.keyEquivalent = tool == .files ? "e" : "s"
            hide.keyEquivalentModifierMask = [.command, .shift]
        }
        // 브라우저는 옆으로 옮기는 항목 없이 작은 창 + 숨기기만
        let moves = tool == .browser ? [] : [left, right]
        for item in [floatItem] + moves + [NSMenuItem.separator(), hide] { if let item { menu.addItem(item) } }
        return menu
    }

    static func shortcutLabel(_ tool: ToolID) -> String {
        switch tool {
        case .files: return "⌘⇧E"
        case .spaces: return "⌘⇧S"
        case .browser: return "⌘⇧B"
        }
    }
}

/// 도크 하나: (도구가 둘 이상이면) 위에 도구 버튼 줄 + 고른 도구 + (붙었으면) 아래 상태 줄
final class DockViewController: NSViewController {
    let side: DockSide
    private let model: TermModel
    private lazy var footer: NSHostingView<StatusFooterView> = {
        let host = NSHostingView(rootView: StatusFooterView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.setContentHuggingPriority(.required, for: .vertical)
        return host
    }()
    private var containerBottom: NSLayoutConstraint!
    var onSelect: ((ToolID) -> Void)?
    var menuFor: ((ToolID) -> NSMenu)?

    private let strip = DockStripView()
    private let container = NSView()
    private var stripHeight: NSLayoutConstraint!
    private(set) var current: NSViewController?

    init(side: DockSide, model: TermModel) {
        self.side = side
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = BackgroundView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        root.color = TermAppearance.chrome
        strip.onSelect = { [weak self] tool in self?.onSelect?(tool) }
        strip.menuFor = { [weak self] tool in self?.menuFor?(tool) }
        for view in [strip, container] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        stripHeight = strip.heightAnchor.constraint(equalToConstant: 0)
        containerBottom = container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: root.topAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripHeight,
            container.topAnchor.constraint(equalTo: strip.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            containerBottom,
        ])
        view = root
    }

    /// 이 도크 맨 아래에 상태 줄을 붙이거나 뗀다
    var showsFooter = false {
        didSet {
            guard showsFooter != oldValue else { return }
            _ = view
            if showsFooter {
                view.addSubview(footer)
                containerBottom.isActive = false
                NSLayoutConstraint.activate([
                    footer.topAnchor.constraint(equalTo: container.bottomAnchor),
                    footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                ])
            } else {
                footer.removeFromSuperview() // 붙어 있던 제약도 함께 사라진다
                containerBottom.isActive = true
            }
        }
    }

    /// 글꼴 크기 배율이 바뀜: 도구 버튼 줄 높이·글꼴
    func scaleChanged() {
        guard isViewLoaded else { return }
        if stripHeight.constant > 0 { stripHeight.constant = DockStripView.height }
        strip.scaleChanged()
    }

    func show(tools: [ToolID], selected: ToolID?, content: NSViewController?) {
        _ = view
        strip.update(tools: tools, selected: selected)
        let shared = tools.count > 1
        stripHeight.constant = shared ? DockStripView.height : 0
        strip.isHidden = !shared
        guard content !== current else { return }
        // 다른 도크로 옮겨 간 도구는 이미 그쪽에 붙어 있을 수 있다 — 내 것일 때만 뗀다
        if let current, current.parent === self {
            if current.view.superview === container { current.view.removeFromSuperview() }
            current.removeFromParent()
        }
        current = content
        guard let content else { return }
        addChild(content)
        let view = content.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// 도크 위 도구 버튼 줄(탭 줄과 같은 모양: 고른 것은 강조색 바탕). 오른쪽 클릭 = 옮기기·숨기기.
final class DockStripView: NSView {
    /// 터미널 탭 줄과 같은 높이(양쪽 줄이 한 선에 맞게)
    static var height: CGFloat { TerminalHostController.tabBarHeight }

    var onSelect: ((ToolID) -> Void)?
    var menuFor: ((ToolID) -> NSMenu?)?

    private var tools: [ToolID] = []
    private var selected: ToolID?
    private var hovered: ToolID?
    private var rects: [(ToolID, CGRect)] = []

    override var isFlipped: Bool { true }

    func scaleChanged() {
        layoutButtons()
        needsDisplay = true
    }

    func update(tools: [ToolID], selected: ToolID?) {
        guard tools != self.tools || selected != self.selected else { return }
        self.tools = tools
        self.selected = selected
        layoutButtons()
        needsDisplay = true
    }

    private func attributes(_ tool: ToolID) -> [NSAttributedString.Key: Any] {
        let isSelected = tool == selected
        let color = isSelected ? TermAppearance.chrome : tool == hovered ? TermAppearance.textPrimary : TermAppearance.textDim
        return [.font: TermAppearance.scaledUIFont(11, bold: isSelected), .foregroundColor: color]
    }

    private func hintAttributes(_ tool: ToolID) -> [NSAttributedString.Key: Any] {
        let color = tool == selected ? TermAppearance.chrome.withAlphaComponent(0.7) : TermAppearance.textDim.withAlphaComponent(0.7)
        return [.font: TermAppearance.scaledUIFont(9), .foregroundColor: color]
    }

    private func layoutButtons() {
        rects = []
        var x: CGFloat = 0
        for tool in tools {
            let label = (tool.rawValue as NSString).size(withAttributes: attributes(tool)).width
            let hint = (ToolWindowsController.shortcutLabel(tool) as NSString).size(withAttributes: hintAttributes(tool)).width
            let pad = TermAppearance.scaled(12), gap = TermAppearance.scaled(6)
            let rect = CGRect(x: x, y: 0, width: ceil(pad + label + gap + hint + pad), height: bounds.height)
            rects.append((tool, rect))
            x = rect.maxX
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutButtons()
        needsDisplay = true // 층 뷰는 크기만 바뀌면 다시 그리지 않는다(숨김 → 보임에서 빈 줄로 남았다)
    }

    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.chrome.setFill()
        bounds.fill()
        for (tool, rect) in rects {
            if tool == selected {
                TermAppearance.accent.setFill()
                rect.fill()
            } else if tool == hovered {
                TermAppearance.chromeRaised.setFill()
                rect.fill()
            }
            let label = tool.rawValue as NSString
            let size = label.size(withAttributes: attributes(tool))
            let pad = TermAppearance.scaled(12), gap = TermAppearance.scaled(6)
            label.draw(at: CGPoint(x: rect.minX + pad, y: rect.midY - size.height / 2), withAttributes: attributes(tool))
            let hint = ToolWindowsController.shortcutLabel(tool) as NSString
            let hintSize = hint.size(withAttributes: hintAttributes(tool))
            hint.draw(at: CGPoint(x: rect.minX + pad + size.width + gap, y: rect.midY - hintSize.height / 2 + 0.5),
                      withAttributes: hintAttributes(tool))
        }
        // 아래 경계(도구 내용과 나눔)
        TermAppearance.border.withAlphaComponent(0.6).setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func tool(at event: NSEvent) -> ToolID? {
        let point = convert(event.locationInWindow, from: nil)
        return rects.first { $0.1.contains(point) }?.0
    }

    override func mouseDown(with event: NSEvent) {
        if let tool = tool(at: event) { onSelect?(tool) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tool = tool(at: event) ?? selected else { return nil }
        return menuFor?(tool)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let tool = tool(at: event)
        guard tool != hovered else { return }
        hovered = tool
        layoutButtons()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        layoutButtons()
        needsDisplay = true
    }
}
