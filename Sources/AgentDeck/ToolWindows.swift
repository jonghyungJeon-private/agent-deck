import AppKit
import Combine
import SessionCore
import SwiftUI
import TermLayout
import TermWire

/// IntelliJ 식 도구 창: 창 = [왼쪽 도크 | 터미널 | 오른쪽 도크]. 도구(spaces·files)는 왼쪽·오른쪽·숨김 중 한 곳에 붙고,
/// 도구가 둘 붙은 도크는 위에 도구 버튼 줄이 생긴다. 보이는 도구가 없는 도크는 접힌다.
/// 배치·도크 폭은 `term/ui.json` 에 저장한다.
/// 설정 창 "화면" 탭의 작은 창 구석 — 설정 창(SwiftUI)과 도구 창 관리자가 함께 보는 값. 바뀌면 도구 창 관리자가 버튼·작은 창을 다시 놓는다.
final class FloatCornerSetting: ObservableObject {
    static let shared = FloatCornerSetting()
    @Published var corner: FloatCorner = .topRight
    private init() {}
}

/// 설정 창 "브라우저" 탭의 "에이전트가 브라우저를 쓰면 작은 창 자동으로 열기"(기본 켬) — `ui.json` 의 `autoOpenBrowser`.
/// 설정 창(SwiftUI)과 도구 창 관리자가 함께 보는 값이고, 바뀌면 도구 창 관리자가 저장한다.
final class BrowserAutoOpenSetting: ObservableObject {
    static let shared = BrowserAutoOpenSetting()
    @Published var enabled = true
    private init() {}
}

final class ToolWindowsController: NSObject {
    let split = NSSplitViewController()
    private(set) var layout: ToolLayout
    let files: FilesToolController
    private let model: TermModel
    private let sidebar: NSHostingController<SidebarView>
    private let docks: [DockSide: DockViewController]
    private let browserButton = BrowserToggleButton()
    /// 🌐 버튼 왼쪽의 ⌨ 버튼(작은 터미널 켜고 끄기)
    private let scratchButton = ScratchToggleButton()
    /// 세션 창 안에 떠 있는 작은 브라우저 창(host.view 위, 버튼 아래)
    private let floatPanel = FloatPanel(spec: .browser, closeTip: "작은 창 닫기 (⌘⇧B 로 다시)")
    /// 세션 창 안에 떠 있는 작은 터미널 창(세션마다 임시 셸 하나)
    private let scratchPanel = FloatPanel(spec: .terminal, closeTip: "작은 터미널 숨기기 (⌃`) — 셸은 계속 돌아요")
    private var cornerObserver: AnyCancellable?
    private var autoOpenObserver: AnyCancellable?
    /// 작은 창을 끄는 동안의 자동 배치 보류(창마다) — 끝나면 한 번 돌린다
    private var floatGate = FloatLayoutGate<FloatKind>()
    /// 에이전트 활동에 따른 자동 열기·닫기 중(그 열림·닫힘은 사람이 한 것이 아니다)
    private var autoChanging = false
    private var appearanceObserver: AnyCancellable?
    private var rowsObserver: AnyCancellable?
    private var connectedObserver: AnyCancellable?
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
        // 세션 창 구석(기본 오른쪽 위, 설정에서 오른쪽 아래) 🌐: 세션 창 안 브라우저 칸 켜고 끄기 + 브라우저 상태(터미널 위에 떠 있다 — 터미널 칸 자식들은 그대로라 맨 위에 남는다).
        // 크기는 버튼이 정한다(동그라미 ↔ 상태 알약, 오른쪽 가장자리 고정 — 알약은 왼쪽으로 늘어난다)
        browserButton.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(browserButton)
        browserButton.onClick = { [weak self] in self?.toggleBrowserFromButton() }
        // ⌨ 는 🌐 왼쪽(8pt) — 🌐 가 알약으로 늘어나 왼쪽 끝이 움직여도 따라간다
        scratchButton.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(scratchButton)
        anchorButtons()
        FloatCornerSetting.shared.corner = layout.floatCorner
        cornerObserver = FloatCornerSetting.shared.$corner.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] corner in self?.setFloatCorner(corner) }
        // 에이전트가 브라우저를 쓰면 작은 창 자동으로 열기(설정 → 브라우저): 바뀌면 ui.json 에 저장
        BrowserAutoOpenSetting.shared.enabled = layout.autoOpenBrowser
        autoOpenObserver = BrowserAutoOpenSetting.shared.$enabled.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.layout.autoOpenBrowser = enabled
                self?.save()
            }
        wireBrowserAuto()
        // 화면 모드(설정 → 화면): 바뀌면 ui.json 에 저장(적용은 AppearanceSetting 이 NSApp.appearance 로 바로 한다)
        layout.appearance = AppearanceSetting.shared.mode
        appearanceObserver = AppearanceSetting.shared.$mode.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.layout.appearance = mode
                self?.save()
            }
        host.onTabBarHeightChanged = { [weak self] in
            self?.tabBarChanged()
            self?.layoutFloat()
        }
        browserButton.onSizeChange = { [weak self] in self?.tabBarChanged() }
        host.onTabBarContentChanged = { [weak self] in self?.tabBarChanged() }
        tabBarChanged()
        scratchButton.onClick = { [weak self] in self?.toggleScratch() }
        scratchPanel.addTitleButton(symbol: "power", tip: "끝내기 — 이 작은 터미널의 셸을 끝냅니다(다음에 열면 새 셸)") { [weak self] in self?.endScratch() }
        floatPanel.addTitleButton(symbol: "rectangle.portrait.and.arrow.right", tip: "별도 창으로 떼기") { [weak self] in self?.popOutBrowser() }
        scratchPanel.onClose = { [weak self] in self?.hideScratch() }
        scratchPanel.onToggleSize = { [weak self] in self?.toggleFloatSize(.terminal) }
        scratchPanel.onFrameChanged = { [weak self] frame in self?.floatFrameChanged(.terminal, frame) }
        // 끄는 동안은 자동 배치(목록 갱신·호스트 크기·브라우저 열림에 따른 기본 자리…)가 자리를 되돌리지 않는다. 끝나면 미룬 것을 한 번.
        scratchPanel.onGestureBegan = { [weak self] in self?.floatGate.begin(.terminal) }
        scratchPanel.onGestureEnded = { [weak self] in self?.floatGestureEnded(.terminal) }
        model.scratch.onShellEnded = { [weak self] owner, hadFocus in
            guard let self, self.model.browserWindows.dock.owner == owner else { return }
            self.hideScratch(hadFocus: hadFocus)
        }
        model.onScratchChanged = { [weak self] in
            guard let self else { return }
            // 끊겼다 다시 붙은 뒤 첫 목록: 그동안 못 붙인 작은 터미널을 붙인다
            if self.layout.terminalFloat.shown, self.model.scratch.current == nil { self.applyScratch() }
            self.refreshScratch()
        }
        // 연결이 끊기면 작은 터미널 뷰를 떼고(ScratchTerminals.connectionLost), 창은 열림 기록대로 다시 붙을 때 되살린다
        connectedObserver = model.$connected.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyScratch() }
        // 세션 목록이 바뀜: 없어진 세션의 열림 기록을 지우고, 목록이 늦게 와 못 열었던 작은 터미널을 연다
        rowsObserver = model.$rows.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rowsChanged() }
        floatPanel.onClose = { [weak self] in self?.move(.browser, to: .hidden) }
        floatPanel.onToggleSize = { [weak self] in self?.toggleFloatSize(.browser) }
        floatPanel.onFrameChanged = { [weak self] frame in self?.floatFrameChanged(.browser, frame) }
        // 끌어 옮기거나 크기를 바꾸는 동안은 브라우저 페이지 크기를 맞추지 않고(그림만 줄이고 늘림) 끝나면 한 번 맞춘다
        floatPanel.onGestureBegan = { [weak self] in
            guard let self else { return }
            self.floatGate.begin(.browser)
            self.gesturePane = self.model.browserWindows.dock.hosted
            self.gesturePane?.beginResizeGesture()
            self.browserPanelTouched() // 작은 창을 끌었다 = 사람이 건드렸다(자동으로 닫지 않는다)
        }
        floatPanel.onGestureEnded = { [weak self] in
            guard let self else { return }
            self.floatGestureEnded(.browser) // 미룬 자동 배치를 먼저(그 크기 변화가 끝난 뒤 한 번만 페이지에 맞춘다)
            self.gesturePane?.endResizeGesture()
            self.gesturePane = nil
        }
        host.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(hostResized), name: NSView.frameDidChangeNotification,
                                               object: host.view)
        // 세션·상태가 바뀜: 🌐 버튼과 작은 창 제목(세션 이름)
        // 고른 세션이 바뀜: 두 작은 창을 그 세션이 열어 둔 것만 보이게(도크가 새 세션 칸을 달기 전에 — 안 보일 칸을 잠깐 붙이지 않게)
        model.browserWindows.dock.onOwnerWillRefresh = { [weak self] owner in self?.sessionChanged(owner) }
        model.browserWindows.onDockOwnerOrState = { [weak self] in
            guard let self else { return }
            self.refreshBrowserButton()
            // 제목만 — 자리는 건드리지 않는다(끄는 도중 상태가 바뀌어도 저장된 자리로 튀지 않게)
            self.floatPanel.setTitle(self.floatTitle())
            self.refreshScratch()
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
        applyScratch()
        model.browserWindows.dock.setToolVisible(layout.isBrowserShown)
    }

    // MARK: - 작은 창(세션 창 안에 떠 있는 브라우저·작은 터미널)

    private enum FloatKind: Hashable { case browser, terminal }

    private func panel(_ kind: FloatKind) -> FloatPanel { kind == .browser ? floatPanel : scratchPanel }
    private func spec(_ kind: FloatKind) -> FloatSpec { kind == .browser ? .browser : .terminal }
    private func state(_ kind: FloatKind) -> FloatState { kind == .browser ? layout.browserFloat : layout.terminalFloat }
    private func setFrame(_ kind: FloatKind, _ frame: FloatFrame?) {
        if kind == .browser { layout.browserFloat.frame = frame } else { layout.terminalFloat.frame = frame }
    }

    // MARK: 버튼 구석

    private var buttonConstraints: [NSLayoutConstraint] = []
    private var anchoredInTabRow = false

    /// 🌐·⌨ 를 설정한 구석에 붙인다(바꾸면 다시 붙인다). 오른쪽 위는 탭 줄이 있으면 탭 줄 오른쪽 끝(세로 가운데, 오른쪽에서 8pt)에 앉혀
    /// 화면 위쪽(찾기 막대·편집기 첫 줄·오른쪽 분할 화면 모서리)을 덮지 않고(탭 줄은 그 폭만큼 오른쪽을 비운다 — `updateTabBarReserve`),
    /// 탭이 하나도 없으면 예전처럼 맨 위 10pt 아래·오른쪽에서 22pt. 오른쪽 아래는 터미널 스크롤바(약 15pt)를 피해 오른쪽에서 22pt.
    private func anchorButtons() {
        NSLayoutConstraint.deactivate(buttonConstraints)
        switch layout.floatCorner {
        case .topRight where pillsInTabRow:
            buttonConstraints = [
                browserButton.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -Self.tabRowSideInset),
                browserButton.centerYAnchor.constraint(equalTo: host.tabBarCenterYAnchor),
                scratchButton.trailingAnchor.constraint(equalTo: browserButton.leadingAnchor, constant: -Self.pillGap),
                scratchButton.centerYAnchor.constraint(equalTo: browserButton.centerYAnchor),
            ]
        case .topRight:
            buttonConstraints = [
                browserButton.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -Self.bottomSideInset),
                browserButton.topAnchor.constraint(equalTo: host.belowTabBarAnchor, constant: Self.topInset),
                scratchButton.trailingAnchor.constraint(equalTo: browserButton.leadingAnchor, constant: -Self.pillGap),
                scratchButton.topAnchor.constraint(equalTo: browserButton.topAnchor),
            ]
        case .bottomRight:
            buttonConstraints = [
                browserButton.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -Self.bottomSideInset),
                browserButton.bottomAnchor.constraint(equalTo: host.view.bottomAnchor, constant: -12),
                scratchButton.trailingAnchor.constraint(equalTo: browserButton.leadingAnchor, constant: -Self.pillGap),
                scratchButton.bottomAnchor.constraint(equalTo: browserButton.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(buttonConstraints)
        anchoredInTabRow = pillsInTabRow
    }

    /// 탭 줄 안 오른쪽 여백(오른쪽 위 구석)
    private static let tabRowSideInset: CGFloat = 8
    /// 오른쪽 아래·탭이 없을 때 오른쪽 위: 터미널 스크롤바를 피한 여백
    private static let bottomSideInset: CGFloat = 22
    /// 탭이 없을 때 오른쪽 위 알약의 위쪽 간격
    private static let topInset: CGFloat = 10
    /// 두 알약 사이 간격과, 탭 줄이 알약 앞에 남기는 여유
    private static let pillGap: CGFloat = 8
    private static let pillClearance: CGFloat = 8

    /// 알약 묶음이 탭 줄 오른쪽에서 차지할 폭(🌐 가 상태 글자로 늘어나면 따라 늘어난다)
    private var pillClusterReserve: Double {
        let widths = [scratchButton, browserButton].filter { !$0.isHidden }.map { Double($0.intrinsicContentSize.width) }
        return TabBarFit.reserve(pillWidths: widths, gap: Double(Self.pillGap), trailing: Double(Self.tabRowSideInset),
                                 clearance: Double(Self.pillClearance))
    }

    /// 알약이 탭 줄 안에 앉는가: 오른쪽 위 구석이고 탭 줄이 있으며, 알약 폭을 뺀 나머지에 탭 제목을 최소로 줄인 탭 + "+" 가 들어갈 때.
    /// 탭이 없거나 아무리 줄여도 안 들어가면(좁은 창에 탭이 많음) 알약은 예전처럼 탭 줄 아래 맨 위에 앉는다 — 탭·"+" 를 가리지 않는다.
    private var pillsInTabRow: Bool {
        guard layout.floatCorner == .topRight, host.tabBarInset > 0 else { return false }
        let width = Double(host.view.bounds.width)
        return width <= 0 || width - pillClusterReserve >= Double(host.tabBarMinimumContentWidth)
    }

    /// 탭 줄 높이·탭·호스트 폭이 바뀜: 알약 자리(탭 줄 안 ↔ 탭 줄 아래)와 탭 줄의 오른쪽 여백을 맞춘다
    private func tabBarChanged() {
        if anchoredInTabRow != pillsInTabRow {
            anchorButtons()
            host.view.layoutSubtreeIfNeeded()
            layoutFloat()
        }
        updateTabBarReserve()
    }

    /// 탭 줄이 오른쪽에 비워 둘 폭 = 알약이 탭 줄 안이면 알약 묶음 폭, 아니면 0.
    private func updateTabBarReserve() {
        host.setTabBarTrailingReserve(pillsInTabRow ? CGFloat(pillClusterReserve) : 0)
    }

    /// 설정에서 구석을 바꿈: 버튼을 다시 붙이고, 두 작은 창의 저장된 자리는 지워 새 구석의 처음 자리로 다시 연다(열림은 그대로)
    func setFloatCorner(_ corner: FloatCorner) {
        guard corner != layout.floatCorner else { return }
        layout.setFloatCorner(corner)
        anchorButtons()
        updateTabBarReserve()
        host.view.layoutSubtreeIfNeeded()
        layoutFloat()
        save()
    }

    /// 시험 명령 `float-corner <top|bottom>`
    var floatCorner: FloatCorner { layout.floatCorner }

    /// 구석 쪽 세로 가장자리에서 띄울 거리. 오른쪽 아래: 브라우저는 🌐 버튼 윗선 + 14pt, 작은 터미널은 아래 가장자리 + 14pt.
    /// 오른쪽 위: 버튼이 탭 줄 안에 있으면 둘 다 탭 줄 아래 + 14pt(따로 비우지 않는다), 탭이 없어 버튼이 맨 위에 있으면 버튼 줄(10pt + 버튼 높이) 아래 + 14pt.
    private func edgeInset(_ kind: FloatKind) -> Double {
        switch layout.floatCorner {
        case .topRight:
            if !pillsInTabRow { return Double(host.tabBarInset + Self.topInset + BrowserToggleButton.size) + FloatSpec.margin }
            return Double(host.tabBarInset) + FloatSpec.margin
        case .bottomRight:
            return kind == .browser ? 12 + Double(BrowserToggleButton.size) + FloatSpec.margin : FloatSpec.margin
        }
    }

    /// host.view 좌표(위·아래가 뒤집혔을 수 있다)와 아래-왼쪽 원점 사각형을 오간다
    private func flipped(_ rect: NSRect) -> NSRect {
        guard host.view.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: host.view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 지금 있어야 할 작은 창 자리(저장된 자리 또는 기본, 호스트 안으로 맞춘 것)
    private func floatRect(_ kind: FloatKind) -> NSRect {
        let size = host.view.bounds.size
        // 작은 터미널의 기본 자리는 브라우저가 보이는지에 따라 다르다(혼자면 구석, 함께면 브라우저 옆). 저장된 자리는 그대로.
        let rect = kind == .terminal
            ? layout.terminalRect(in: size, browserEdgeInset: edgeInset(.browser), terminalEdgeInset: edgeInset(.terminal))
            : state(kind).frame?.rect(in: size, spec: spec(kind))
                ?? spec(kind).defaultRect(in: size, corner: layout.floatCorner, edgeInset: edgeInset(kind))
        return flipped(rect)
    }

    /// 고른 세션의 브라우저 작은 창을 켜고 끈다
    private func applyFloat() {
        let shown = layout.browserFloat.shown
        if shown {
            if floatPanel.superview !== host.view {
                host.view.addSubview(floatPanel, positioned: .below, relativeTo: scratchButton)
            }
            floatPanel.setContent(model.browserWindows.dock.view)
            layoutFloat()
        } else {
            floatPanel.setContent(nil)
            floatPanel.removeFromSuperview()
        }
    }

    private func layoutFloat() {
        layoutFloat(.browser)
        layoutFloat(.terminal)
    }

    /// animated: 브라우저가 열리고 닫혀 작은 터미널의 기본 자리가 바뀔 때 — 크기가 같고 자리만 옮겨질 때만 부드럽게
    /// (크기가 바뀌는 동안 터미널이 다시 줄바꿈하지 않게. 끌기·창 크기 바꾸기 중에는 쓰지 않는다)
    /// userInitiated: 사람이 끌기를 마치거나 "크게/작게"를 눌러 저장한 자리를 반영할 때. 그 밖의 모든 자동 배치(세션 목록 갱신·호스트 크기·
    /// 탭 줄 높이·브라우저 열림에 따른 터미널 기본 자리…)는 그 창을 끄는 동안 미뤄 두었다가 끝나면 한 번 돌린다(`floatGate`) —
    /// 끄는 도중 저장된·기본 자리로 되돌아가 튀거나 엉뚱한 자리가 저장되지 않게.
    private func layoutFloat(_ kind: FloatKind, animated: Bool = false, userInitiated: Bool = false) {
        let panel = panel(kind)
        guard state(kind).shown, panel.superview === host.view else { return }
        if !userInitiated, !floatGate.allowsAutoLayout(kind) { return }
        let rect = floatRect(kind)
        if panel.frame != rect {
            if animated, panel.window != nil, abs(panel.frame.width - rect.width) < 1, abs(panel.frame.height - rect.height) < 1,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.allowsImplicitAnimation = true
                    panel.animator().frame = rect
                }
            } else {
                panel.frame = rect
            }
        }
        panel.setLarge(isFloatLarge(kind))
        panel.setTitle(kind == .browser ? floatTitle() : scratchTitle())
    }

    private func floatTitle() -> String {
        let name = model.browserWindows.dock.owner.flatMap { model.row($0)?.title }
        return "🌐 브라우저" + (name.map { " · \($0)" } ?? "")
    }

    @objc private func hostResized() {
        tabBarChanged()
        layoutFloat()
    }

    /// 사람이 끌어 옮기거나 크기를 바꿈: 호스트 대비 비율로 저장(자리는 창 종류마다 하나를 함께 쓴다)
    private func floatFrameChanged(_ kind: FloatKind, _ frame: NSRect) {
        let size = host.view.bounds.size
        let rect = spec(kind).clamp(flipped(frame), in: size)
        setFrame(kind, FloatFrame(rect: rect, in: size))
        layoutFloat(kind, userInitiated: true)
        save()
    }

    /// 끌기 끝(또는 끌던 창이 사라짐): 끄는 동안 미룬 자동 배치가 있었으면 한 번
    private func floatGestureEnded(_ kind: FloatKind) {
        if floatGate.end(kind) { layoutFloat(kind) }
    }

    /// 사람이 브라우저 작은 창의 제목 줄·가장자리·버튼을 눌렀다
    private func browserPanelTouched() {
        if let owner = model.browserWindows.dock.owner { model.browserAuto.userInteracted(owner) }
    }

    /// 지금 "크게" 크기인가: 비율로 짐작하지 않고 크게 자리와 견준다(좁은 창에서는 기본 자리도 최소 폭에 걸려 넓어 보여서)
    private func isFloatLarge(_ kind: FloatKind) -> Bool {
        let size = host.view.bounds.size
        let large = spec(kind).clamp(spec(kind).largeRect(in: size, corner: layout.floatCorner, edgeInset: edgeInset(kind)), in: size)
        let now = floatRect(kind)
        return abs(now.width - large.width) < 2 && abs(now.height - large.height) < 2
    }

    /// "크게"/"작게": 크게 ↔ 기본 자리
    private func toggleFloatSize(_ kind: FloatKind) {
        let size = host.view.bounds.size
        let large = isFloatLarge(kind)
        setFrame(kind, large ? nil : FloatFrame(rect: spec(kind).largeRect(in: size, corner: layout.floatCorner, edgeInset: edgeInset(kind)), in: size))
        layoutFloat(kind, userInitiated: true)
        save()
        if kind == .browser { browserPanelTouched() }
    }

    /// "별도 창으로 떼기": 이 세션의 브라우저를 별도 창으로 보도록 바꾼다(작은 창은 닫힌다 — 한 세션의 브라우저는 한 곳에만)
    private func popOutBrowser() {
        guard let owner = model.browserWindows.dock.owner else { return }
        var next = model.browserWindows.display(owner)
        next.placement = .window
        model.browserWindows.choose(next, for: owner)
    }

    /// 작은 창으로 보이기(메뉴 "작은 창으로"·`dock browser float`): 도크에 있었으면 내리고, 이미 작은 창이면 그대로
    func showBrowserFloat() {
        guard !layout.browserFloat.shown else { return }
        change { $0.showBrowserFloat() }
    }

    // MARK: - 세션마다 열림·닫힘

    /// 세션 창에서 고른 세션이 바뀜(도크가 따라가는 세션과 같다): 브라우저·작은 터미널 창 각각 그 세션이 열어 둔 것만 보인다
    private func sessionChanged(_ owner: String?) {
        var next = layout
        next.follow(session: owner.map { BrowserBinding.sessionName(pane: $0) })
        guard next != layout else { return }
        let hadScratchFocus = model.scratch.hasFocus
        layout = next // 열림 기록은 그대로라 저장할 것이 없다
        applyFloat()
        applyScratch(keepFocus: hadScratchFocus)
        model.browserWindows.dock.setToolVisible(layout.isBrowserShown)
        model.browserAuto.sessionShown(owner) // 열려 있는 창을 보게 됐다: "결과 있음" 알림을 거둔다
        refreshBrowserButton()
    }

    /// 목록이 바뀜: 없어진 세션의 열림 기록을 지우고, 목록이 늦게 와 못 열었던 작은 터미널을 연다
    private func rowsChanged() {
        if model.connected, !model.rows.isEmpty {
            let live = Set((model.rows.map(\.id) + model.workspace.allPanes).filter { !LocalPane.isLocal($0) }
                .map { BrowserBinding.sessionName(pane: $0) })
            var next = layout
            next.prune(sessions: live)
            if next != layout {
                layout = next
                save()
            }
        }
        applyScratch(keepFocus: model.scratch.hasFocus)
        refreshScratch()
    }

    // MARK: - 작은 터미널

    /// 작은 터미널이 따라가는 세션: 도크와 같다(편집기 화면은 마지막 에이전트 세션 그대로)
    private var scratchOwner: String? { model.browserWindows.dock.owner }

    /// 그 세션이 데몬에 있거나 꺼진 채 목록에 있는지 + 연결됨(없는 세션에는 셸을 만들지 않는다)
    private func scratchOwnerReady(_ owner: String) -> Bool {
        model.connected && !model.scratch.awaitingState && model.row(owner) != nil
    }

    /// 지금 상태(고른 세션이 열어 둠)에 맞춰 창을 달거나 뗀다. 같은 상태면 자리만 맞춘다.
    private func applyScratch(keepFocus: Bool = false) {
        guard layout.terminalFloat.shown, let owner = scratchOwner, scratchOwnerReady(owner) else {
            if scratchPanel.superview != nil || model.scratch.current != nil {
                scratchPanel.setContent(nil)
                scratchPanel.removeFromSuperview()
                model.scratch.releaseAll()
            }
            refreshScratch()
            return
        }
        if scratchPanel.superview !== host.view {
            host.view.addSubview(scratchPanel, positioned: .below, relativeTo: scratchButton)
        }
        layoutFloat(.terminal, animated: true) // 브라우저가 열리고 닫히면 기본 자리가 바뀐다(저장된 자리는 그대로)
        let rect = floatRect(.terminal)
        if model.scratch.currentOwner != owner {
            let size = CGSize(width: rect.width, height: max(rect.height - FloatPanel.stripHeight, 40))
            scratchPanel.setContent(model.scratch.acquire(owner: owner, size: size).surface)
            if keepFocus { focusScratch() }
        }
        refreshScratch()
    }

    private func scratchTitle() -> String {
        guard let owner = scratchOwner else { return "⌨ 터미널" }
        var title = "⌨ 터미널"
        let name = model.row(owner)?.title
        if let name { title += " · \(name)" }
        let info = model.scratchPanes[ScratchPane.id(owner: owner)]
        let cwd = info.flatMap { ProcessUtil.cwd($0.pid) } ?? info?.cwd ?? model.row(owner)?.cwd
        // 폴더 이름이 세션 이름과 같으면(홈 폴더 세션 등) 한 번만 쓴다
        if let folder = cwd.map({ ($0 as NSString).lastPathComponent }), folder != name { title += " · \(folder)" }
        return title
    }

    /// ⌨ 버튼 모양·창 제목
    private func refreshScratch() {
        scratchButton.isOn = layout.terminalFloat.shown
        scratchButton.busy = !layout.terminalFloat.shown && (scratchOwner.map(model.scratch.isBusy(owner:)) ?? false)
        if layout.terminalFloat.shown, scratchPanel.superview === host.view { scratchPanel.setTitle(scratchTitle()) }
    }

    private func focusScratch() {
        if let view = model.scratch.current?.view { host.view.window?.makeFirstResponder(view) }
    }

    /// ⌨ 버튼·⌃`: 고른 세션의 작은 터미널을 켜고 끈다(켜면 키보드가 거기로)
    func toggleScratch() {
        if layout.terminalFloat.shown { hideScratch(); return }
        showScratch()
    }

    func showScratch() {
        guard !layout.terminalFloat.shown else { focusScratch(); return }
        guard let owner = scratchOwner, scratchOwnerReady(owner) else { NSSound.beep(); return }
        change { $0.toggleTerminalFloat() }
        focusScratch()
    }

    /// ✕·⌃`·⌘W: 창만 닫는다(셸은 계속 돈다). 키보드가 거기 있었으면 세션 화면으로 돌려준다.
    func hideScratch(hadFocus focused: Bool? = nil) {
        guard layout.terminalFloat.shown else { return }
        let hadFocus = focused ?? model.scratch.hasFocus
        change { $0.toggleTerminalFloat() }
        if hadFocus { focusTerminal() }
    }

    /// "끝내기": 이 세션의 임시 셸을 끝내고 창을 닫는다(다음에 열면 새 셸)
    func endScratch() {
        guard let owner = scratchOwner else { return }
        let hadFocus = model.scratch.hasFocus
        model.scratch.end(owner: owner)
        if layout.terminalFloat.shown { change { $0.toggleTerminalFloat() } }
        if hadFocus { focusTerminal() }
    }

    /// 작은 터미널에 키보드가 있는지(⌘W 는 이 창만 숨긴다)
    var scratchHasFocus: Bool { model.scratch.hasFocus }

    /// 시험 명령 `scratch-state`: 주인 세션·화면 ID·보임·자리·버튼 자리(창 좌표, 원점 왼쪽 아래 — `mouse down x y` 에 그대로 쓴다)
    var debugScratch: String {
        let f = layout.terminalFloat
        var text = "scratch-state \(model.scratch.debugSummary(owner: scratchOwner)) corner=\(layout.floatCorner.rawValue) shown=\(f.shown) "
        text += "saved=" + (f.frame.map { String(format: "right=%.3f bottom=%.3f w=%.3f h=%.3f", $0.right, $0.bottom, $0.width, $0.height) } ?? "default")
        text += " rect=\(layout.terminalRectKind.rawValue) session=\(f.session ?? "-")"
        text += " open-sessions=\(f.openSessions.count) host=\(Int(host.view.bounds.width))x\(Int(host.view.bounds.height))"
        if f.shown, scratchPanel.superview === host.view {
            let r = scratchPanel.convert(scratchPanel.bounds, to: nil)
            text += String(format: " panel(window)=x=%.0f y=%.0f w=%.0f h=%.0f content=%@", r.minX, r.minY, r.width, r.height,
                           scratchPanel.hasContent ? "yes" : "no")
        }
        let b = scratchButton.convert(scratchButton.bounds, to: nil)
        text += String(format: " button(window)=x=%.0f y=%.0f w=%.0f h=%.0f on=%@ busy=%@", b.minX, b.minY, b.width, b.height,
                       scratchButton.isOn ? "yes" : "no", scratchButton.busy ? "yes" : "no")
        return text
    }

    /// 시험 명령 `browsers`·`uilayout`: 작은 창 상태와 실제 자리(창 좌표, 원점 왼쪽 아래 — `mouse down x y` 에 그대로 쓴다)
    var debugFloat: String {
        let f = layout.browserFloat
        let place = f.shown ? "float" : (layout.side(of: .browser) == .hidden ? "hidden" : layout.side(of: .browser).rawValue)
        var text = "browser-float presentation=\(place) corner=\(layout.floatCorner.rawValue) shown=\(f.shown) "
        text += "saved=" + (f.frame.map { String(format: "right=%.3f bottom=%.3f w=%.3f h=%.3f", $0.right, $0.bottom, $0.width, $0.height) } ?? "default")
        text += " session=\(f.session ?? "-") open-sessions=\(f.openSessions.count) host=\(Int(host.view.bounds.width))x\(Int(host.view.bounds.height))"
        if f.shown, floatPanel.superview === host.view {
            let r = floatPanel.convert(floatPanel.bounds, to: nil)
            text += String(format: " panel(window)=x=%.0f y=%.0f w=%.0f h=%.0f content=%@", r.minX, r.minY, r.width, r.height,
                           floatPanel.hasContent ? "yes" : "no")
            let b = browserButton.convert(browserButton.bounds, to: nil)
            text += String(format: " button(window)=x=%.0f y=%.0f w=%.0f h=%.0f", b.minX, b.minY, b.width, b.height)
        }
        // 탭과 "+" 가 알약 아래로 들어가지 않는지(탭 줄 안에 알약이 있을 때만 뜻이 있다)
        if pillsInTabRow {
            let pillMinX = [scratchButton, browserButton].filter { !$0.isHidden }.map { $0.convert($0.bounds, to: nil).minX }.min() ?? 0
            let tabsMaxX = host.debugTabRowMaxX
            text += String(format: " tab-row tabs+plus-maxX=%.0f pills-minX=%.0f overlap=%@", tabsMaxX, pillMinX, tabsMaxX > pillMinX ? "YES" : "no")
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
        scratchButton.scaleChanged()
        tabBarChanged()
        floatPanel.scaleChanged()
        scratchPanel.scaleChanged()
        model.scratch.applyFont()
        model.browserWindows.scaleChanged()
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
        // 사람이 작은 창을 열거나 닫음(자동 열기·닫기는 제외): 자동 열기 기록에 알린다 — 닫으면 같은 작업에서는 다시 열지 않는다
        if !autoChanging, old.browserFloat.session == next.browserFloat.session, old.browserFloat.shown != next.browserFloat.shown,
           let owner = model.browserWindows.dock.owner {
            model.browserAuto.userToggled(owner, open: next.browserFloat.shown)
        }
    }

    // MARK: - 에이전트 활동에 따른 자동 열기·닫기

    private func wireBrowserAuto() {
        let auto = model.browserAuto
        auto.setting = { BrowserAutoOpenSetting.shared.enabled }
        // 세션 창 안 작은 창으로 보는 세션만(별도 창이 기본이므로 처음엔 🌐 로 한 번 세션 안으로 열어 본 세션부터)
        auto.floatPresentation = { [weak self] id in self?.model.browserWindows.display(id).placement == .dock }
        auto.panelOpen = { [weak self] id in self?.layout.browserFloat.isOpen(session: BrowserBinding.sessionName(pane: id)) ?? false }
        auto.setPanel = { [weak self] id, open in self?.autoSetBrowserFloat(pane: id, open: open) }
        auto.showTab = { [weak self] id, tab in self?.model.browserWindows.pane(id).showTab(tab) }
        auto.onBadgeChanged = { [weak self] in self?.refreshBrowserButton() }
        model.browserWindows.onPaneInteraction = { [weak self] id in self?.model.browserAuto.userInteracted(id) }
    }

    /// 그 세션의 브라우저 작은 창을 자동으로 열거나 닫는다. 키보드는 가져가지 않는다(🌐 버튼·⌘⇧B 와 달리 포커스를 옮기지 않음).
    /// 지금 보이는 세션이면 부드럽게(옅게 나타나고 사라짐), 다른 세션이면 그 세션의 열림 기록만 바꿔 그 세션으로 갔을 때 보이게 한다.
    private func autoSetBrowserFloat(pane id: String, open: Bool) {
        let key = BrowserBinding.sessionName(pane: id)
        guard layout.browserFloat.isOpen(session: key) != open else { return }
        let visible = model.browserWindows.dock.owner == id && host.view.window != nil
        let animate = visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if open {
            // 나타남은 작은 창이 붙을 때 스스로 한 번 옅게 떠오른다(`FloatPanel.viewDidMoveToWindow`) — 여기서 또 옅게 하지 않는다
            commitAutoBrowserFloat(id, key: key, open: true)
        } else if animate, floatPanel.superview === host.view {
            let run = model.browserAuto.states[id]?.runStartedAt
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                floatPanel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self else { return }
                // 사라지는 사이 사람이 건드렸거나(눌러서 자기 것이 됨) 이미 닫혔으면 그대로 둔다
                // 사라지는 사이 새 작업이 시작됐으면(작업 시작 시각이 바뀜) 그 작업의 창이니 닫지 않는다.
                // agentActive 로 보면 안 된다 — done.json 이 잠금이 풀린 상태보다 먼저 읽혀 끝난 작업도 아직 일하는 것으로 보인다
                let touched = self.model.browserAuto.states[id]?.userInteracted == true
                    || self.model.browserAuto.states[id]?.runStartedAt != run
                    || !self.layout.browserFloat.isOpen(session: key)
                if touched { self.floatPanel.alphaValue = 1; return }
                self.commitAutoBrowserFloat(id, key: key, open: false)
            })
        } else {
            commitAutoBrowserFloat(id, key: key, open: false)
        }
    }

    private func commitAutoBrowserFloat(_ id: String, key: String, open: Bool) {
        autoChanging = true
        defer { autoChanging = false; floatPanel.alphaValue = 1 }
        guard model.browserWindows.dock.owner == id else {
            // 보이는 세션이 아니다: 그 세션의 열림 기록만(화면은 그대로)
            var next = layout
            next.setBrowserFloat(open: open, session: key)
            guard next != layout else { return }
            layout = next
            save()
            return
        }
        let hadFocus = !open && ownsFirstResponder(.browser)
        change { $0.setBrowserFloat(open: open, session: key) }
        if hadFocus { focusTerminal() }
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
        browserButton.resultBadge = model.browserAuto.badge(owner)
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

/// 도크 위 도구 버튼 줄(분할 컨트롤 모양: 고른 것은 chromeRaised 바탕 + 으뜸 글자색). 오른쪽 클릭 = 옮기기·숨기기.
final class DockStripView: NSView {
    /// 터미널 탭 줄과 같은 높이(양쪽 줄이 한 선에 맞게)
    static var height: CGFloat { TerminalHostController.tabBarHeight }

    var onSelect: ((ToolID) -> Void)?
    var menuFor: ((ToolID) -> NSMenu?)?

    private var tools: [ToolID] = []
    private var selected: ToolID?
    private var hovered: ToolID?
    private var rects: [(ToolID, CGRect)] = []
    /// 고른 칸이 바뀔 때 바탕·글자색이 서로 섞인다(Motion.fast): 칸마다 고름 정도(0…1)의 시작값
    private lazy var tween: ViewTween = {
        let tween = ViewTween()
        tween.onTick = { [weak self] in self?.needsDisplay = true }
        return tween
    }()
    private var selectionFrom: [ToolID: CGFloat] = [:]

    override var isFlipped: Bool { true }

    func scaleChanged() {
        layoutButtons()
        tween.settle()
        needsDisplay = true
    }

    func update(tools: [ToolID], selected: ToolID?) {
        guard tools != self.tools || selected != self.selected else { return }
        let animates = window?.isVisible == true && !self.tools.isEmpty && tools == self.tools
        selectionFrom = Dictionary(uniqueKeysWithValues: self.tools.map { ($0, selectionAmount($0)) })
        self.tools = tools
        self.selected = selected
        layoutButtons()
        if animates { tween.run(duration: Motion.fast) } else { tween.settle() }
        needsDisplay = true
    }

    /// 이 칸이 골라진 정도(0 = 아님, 1 = 고름)
    private func selectionAmount(_ tool: ToolID) -> CGFloat {
        let target: CGFloat = tool == selected ? 1 : 0
        let from = selectionFrom[tool] ?? target
        return from + (target - from) * tween.eased
    }

    /// 칸 이름은 언어라 시스템 글꼴, 두께는 늘 같게(고르면 폭이 변하지 않게)
    private var labelFont: NSFont { TermAppearance.uiTextFont(TermAppearance.scaled(TypeSize.row), weight: .medium) }

    private func labelAttributes(_ tool: ToolID) -> [NSAttributedString.Key: Any] {
        let rest = tool == hovered ? TermAppearance.textPrimary : TermAppearance.textSecondary
        return [.font: labelFont, .foregroundColor: mixColor(rest, TermAppearance.textPrimary, selectionAmount(tool))]
    }

    /// 단축키는 데이터라 JetBrains Mono, 10pt, 보조 글자색
    private var hintAttributes: [NSAttributedString.Key: Any] {
        [.font: TermAppearance.scaledUIFont(TypeSize.caption), .foregroundColor: TermAppearance.textSecondary]
    }

    private func layoutButtons() {
        rects = []
        var x: CGFloat = TermAppearance.scaled(Space.xs)
        let nameAttributes: [NSAttributedString.Key: Any] = [.font: labelFont]
        for tool in tools {
            let label = (tool.rawValue as NSString).size(withAttributes: nameAttributes).width
            let hint = (ToolWindowsController.shortcutLabel(tool) as NSString).size(withAttributes: hintAttributes).width
            let pad = TermAppearance.scaled(Space.md), gap = TermAppearance.scaled(6)
            let rect = CGRect(x: x, y: 0, width: ceil(pad + label + gap + hint + pad), height: bounds.height)
            rects.append((tool, rect))
            x = rect.maxX + TermAppearance.scaled(2)
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
            // 고른 칸: 안쪽으로 들인 둥근 chromeRaised 바탕(분할 컨트롤처럼)
            let amount = selectionAmount(tool)
            if amount > 0 {
                mixColor(TermAppearance.chrome, TermAppearance.chromeRaised, amount).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: TermAppearance.scaled(Space.xs)), xRadius: 6, yRadius: 6).fill()
            }
            let label = tool.rawValue as NSString
            let attributes = labelAttributes(tool)
            let size = label.size(withAttributes: attributes)
            let pad = TermAppearance.scaled(Space.md), gap = TermAppearance.scaled(6)
            label.draw(at: CGPoint(x: rect.minX + pad, y: rect.midY - size.height / 2), withAttributes: attributes)
            let hint = ToolWindowsController.shortcutLabel(tool) as NSString
            let hintSize = hint.size(withAttributes: hintAttributes)
            hint.draw(at: CGPoint(x: rect.minX + pad + size.width + gap, y: rect.midY - hintSize.height / 2), withAttributes: hintAttributes)
        }
        // 아래 경계(도구 내용과 나눔)
        TermAppearance.border.setFill()
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
