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
    private var items: [DockSide: NSSplitViewItem] = [:]
    /// 배치를 바꾸는 중에는 폭 변화를 기록하지 않는다
    private var applying = false
    private var widthsRestored = false
    private var saveWork: DispatchWorkItem?

    static var url: URL { TermPaths.home.appendingPathComponent("ui.json") }

    init(model: TermModel, host: TerminalHostController) {
        self.model = model
        layout = ToolLayout.load(from: Self.url)
        files = FilesToolController(model: model)
        sidebar = NSHostingController(rootView: SidebarView(model: model))
        docks = [.left: DockViewController(side: .left, model: model), .right: DockViewController(side: .right, model: model)]
        super.init()

        files.dockMenu = { [weak self] in self?.menu(for: .files) ?? NSMenu() }
        // 파일 열기(2단계 편집기): 두 번 클릭·Enter = 새 탭(이미 열렸으면 그 화면), 오른쪽 클릭 = 나눠 열기
        files.onOpenFile = { [weak model] path in model?.openFile(path) }
        files.onOpenFileSplit = { [weak model] path, axis in model?.openFile(path, split: axis) }
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
            item.maximumThickness = 720
            item.holdingPriority = NSLayoutConstraint.Priority(260)
        }
        content.minimumThickness = 400
        content.holdingPriority = NSLayoutConstraint.Priority(250)
        split.addSplitViewItem(left)
        split.addSplitViewItem(content)
        split.addSplitViewItem(right)
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
        }
    }

    // MARK: - 배치 적용

    private func apply() {
        applying = true
        defer { applying = false }
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
    }

    /// 창을 띄운 뒤 한 번: 저장된 도크 폭으로
    func restoreWidths() {
        split.splitView.layoutSubtreeIfNeeded()
        applying = true
        for side in [DockSide.left, .right] where items[side]?.isCollapsed == false { setWidth(side) }
        applying = false
        widthsRestored = true
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
        guard next != layout else { return }
        layout = next
        apply()
        save()
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

    /// ⌘⇧E·⌘⇧S
    func toggle(_ tool: ToolID) {
        let hadFocus = ownsFirstResponder(tool)
        change { $0.toggle(tool) }
        if layout.isVisible(tool) {
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

    /// 메뉴·단축키 이름: tool-toggle:<도구>, tool-move:<도구>:<left|right|hidden>, tool-select:<도구>
    @discardableResult
    func perform(_ action: String) -> Bool {
        let parts = action.split(separator: ":").map(String.init)
        guard parts.count >= 2, let tool = ToolID(rawValue: parts[1]) else { return false }
        switch parts[0] {
        case "tool-toggle": toggle(tool)
        case "tool-select": select(tool)
        case "tool-move":
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
        let hide = ClosureMenuItem(title: "숨기기") { [weak self] in self?.move(tool, to: .hidden) }
        hide.keyEquivalent = tool == .files ? "e" : "s"
        hide.keyEquivalentModifierMask = [.command, .shift]
        for item in [left, right, NSMenuItem.separator(), hide] { menu.addItem(item) }
        return menu
    }

    static func shortcutLabel(_ tool: ToolID) -> String {
        tool == .files ? "⌘⇧E" : "⌘⇧S"
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
        return [.font: TermAppearance.uiFont(11, bold: isSelected), .foregroundColor: color]
    }

    private func hintAttributes(_ tool: ToolID) -> [NSAttributedString.Key: Any] {
        let color = tool == selected ? TermAppearance.chrome.withAlphaComponent(0.7) : TermAppearance.textDim.withAlphaComponent(0.7)
        return [.font: TermAppearance.uiFont(9), .foregroundColor: color]
    }

    private func layoutButtons() {
        rects = []
        var x: CGFloat = 0
        for tool in tools {
            let label = (tool.rawValue as NSString).size(withAttributes: attributes(tool)).width
            let hint = (ToolWindowsController.shortcutLabel(tool) as NSString).size(withAttributes: hintAttributes(tool)).width
            let rect = CGRect(x: x, y: 0, width: ceil(12 + label + 6 + hint + 12), height: bounds.height)
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
            label.draw(at: CGPoint(x: rect.minX + 12, y: rect.midY - size.height / 2), withAttributes: attributes(tool))
            let hint = ToolWindowsController.shortcutLabel(tool) as NSString
            let hintSize = hint.size(withAttributes: hintAttributes(tool))
            hint.draw(at: CGPoint(x: rect.minX + 12 + size.width + 6, y: rect.midY - hintSize.height / 2 + 0.5),
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
