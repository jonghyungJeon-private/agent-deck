import AppKit
import BrowserCore
import TermLayout
import TermWire

/// 화면(에이전트 세션) 하나의 브라우저가 지금 어떤지 — 🌐 버튼·브라우저 창 머리 줄·spaces 목록·알림이 쓴다
enum BrowserIndicator: Equatable {
    /// 브라우저가 떠 있고 아무도 쥐지 않음
    case idle
    /// 에이전트가 입력을 쥐고 있음(잠금)
    case agent
    /// 사용자가 제어를 가져와 조작 중(이 앱의 "제어 가져오기")
    case user
    /// 에이전트가 사용자에게 넘김(로그인·캡차 등) — 알림
    case waiting(String)
    /// 넘기기를 요청했고 에이전트 동작이 끝나길 기다리는 중
    case switching

    /// 이 앱이 "제어 가져오기"로 abx handoff 할 때 쓰는 말 — 에이전트가 넘긴 것과 구분한다
    static let takeMessage = "사용자가 브라우저를 직접 조작하는 중 — 끝나면 abx resume"

    /// 떠 있는 브라우저만(꺼진 브라우저는 nil). 넘김은 브라우저가 꺼져 있어도 남아 있으면 보인다.
    init?(_ status: AbxStatus) {
        switch status.control {
        case .user:
            let message = status.handoff ?? ""
            self = message == Self.takeMessage ? .user : .waiting(message)
        case .switching: self = .switching
        case .agent where status.running: self = .agent
        case .idle where status.running: self = .idle
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .idle: return "브라우저 대기"
        case .agent: return "AI 제어 중"
        case .user: return "내가 조작 중"
        case .waiting: return "내 조작 필요"
        case .switching: return "넘겨받는 중"
        }
    }

    /// 상태 색(알약의 아이콘·테두리·옅은 바탕): AI 가 쥘 때만 초록(`agent` — 테두리·커서와 같은 색), 사람이 쥐면 중립(`human`),
    /// 사람의 조작이 필요하면 주의(`statusAttention`), 쉬는 중은 보조 글자색. 알약의 글자는 늘 `textPrimary`.
    var color: NSColor {
        switch self {
        case .idle: return TermAppearance.textSecondary
        case .agent: return TermAppearance.agent
        case .user: return TermAppearance.human
        case .waiting, .switching: return TermAppearance.statusAttention
        }
    }

    var needsAttention: Bool { if case .waiting = self { return true } else { return false } }
}

/// 모든 화면의 브라우저 상태를 abx 상태 파일로 읽는다(스트림 없이, 프로세스 없이 — AbxStateReader).
/// abx 폴더(소켓·상태, 모든 세션이 함께 씀)가 바뀌면 곧바로, 그 밖에는 몇 초마다 다시 읽는다.
final class BrowserStatusStore {
    /// 메인 스레드에서 부른다: 브라우저가 있는 화면만(화면 ID → 상태)
    var onChange: (([String: AbxStatus]) -> Void)?
    /// 메인 스레드에서 부른다: `abx done` 이 남긴 `<세션>.done.json` 이 있는 화면만(화면 ID → 내용). 바뀔 때만(파일이 없다 생기거나 내용이 바뀌거나 지워질 때).
    /// 상태와 같은 감시(abx 폴더 쓰기 이벤트 → 0.15초 모아 읽기, 그 밖에는 2초마다)로 읽는다.
    var onDone: (([String: AbxDone]) -> Void)?
    /// 읽을 화면들(메인 스레드에서 묻는다)
    var panes: () -> [String] = { [] }

    private let queue = DispatchQueue(label: "agentdeck.browser.status")
    private let reader = AbxStateReader()
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var pending = false
    private var last: [String: AbxStatus] = [:]
    private var lastDone: [String: AbxDone] = [:]
    /// 첫 결과는 비어 있어도 알린다(앱을 켠 첫 상태로 기억하게 — 그 뒤 처음 보는 넘김은 새 요청으로 알린다)
    private var published = false
    /// 마지막으로 내보낸 결과가 화면이 있을 때 읽은 것인지(메인 스레드)
    private(set) var snapshotHadPanes = false

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 2)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    /// 바뀐 것이 없어도 다음 읽기 결과를 한 번 내보낸다(세션 목록을 처음 받았을 때 — 자동 열기의 기준 잡기)
    func publishNext() {
        queue.async { [weak self] in
            self?.published = false
            self?.schedule()
        }
    }

    /// 지금 바로 다시 읽기(제어 가져오기·돌려주기 직후 등)
    func refreshSoon() {
        queue.async { [weak self] in self?.schedule() }
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pending = false
            self?.refresh()
        }
    }

    private func watch() {
        let dirs = [BrowserBinding.socketDir().path, BrowserBinding.stateDir().path]
        guard watchers.count < dirs.count else { return }
        watchers.forEach { $0.cancel() }
        watchers = dirs.compactMap { dir in
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self, weak source] in
                // 폴더가 지워지거나 옮겨지면 감시를 다시 건다(다음 읽기에서)
                if let source, !source.data.isDisjoint(with: [.delete, .rename]) { self?.rewatch() }
                self?.schedule()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    private func rewatch() {
        watchers.forEach { $0.cancel() }
        watchers = []
    }

    private func refresh() {
        watch()
        let ids = DispatchQueue.main.sync { panes() }
        var next: [String: AbxStatus] = [:]
        var nextDone: [String: AbxDone] = [:]
        for id in ids {
            let env = BrowserBinding.environment(pane: id, browser: nil)
            let session = AbxSession(name: env["ABX_SESSION"]!, socketDir: env["ABX_SOCKET_DIR"]!,
                                     stateDir: env["ABX_STATE_DIR"]!, profileDir: env["ABX_PROFILE_DIR"]!)
            let status = reader.status(session)
            if BrowserIndicator(status) != nil { next[id] = status }
            if let done = reader.done(session) { nextDone[id] = done }
        }
        if nextDone != lastDone {
            lastDone = nextDone
            DispatchQueue.main.async { [weak self] in self?.onDone?(nextDone) }
        }
        guard next != last || !published else { return }
        last = next
        published = true
        let hadPanes = !ids.isEmpty
        DispatchQueue.main.async { [weak self] in
            // 이 결과가 세션 목록을 받은 뒤 읽은 것인지(자동 열기의 기준은 그런 결과로만 잡는다) — 메인에서만 읽고 쓴다
            self?.snapshotHadPanes = hadPanes
            self?.onChange?(next)
        }
    }
}

/// 브라우저 머리 줄의 높이 눈금(4pt 격자): 줄 32, 그 안의 조절 단추(알약·제어 단추) 24 — 위아래 4
enum BrowserHeader {
    static var rowHeight: CGFloat { TermAppearance.scaled(32) }
    static var controlHeight: CGFloat { TermAppearance.scaled(24) }
}

/// 브라우저 상태 알약(🌐 + 상태). 브라우저 창 머리 줄에서는 누를 곳 없이 상태만 보인다(onClick nil).
/// 글자는 늘 `textPrimary`(시스템 글꼴), 상태 색은 아이콘·테두리·옅은 바탕에만(한 색 = 한 뜻).
final class BrowserChipView: NSView {
    var indicator: BrowserIndicator = .idle {
        didSet {
            guard indicator != oldValue else { return }
            crossFadeNextChange()
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    private var font: NSFont { TermAppearance.uiTextFont(TermAppearance.scaled(11), weight: .medium) }
    private var text: String {
        if case .waiting = indicator { return indicator.label + " !" }
        return indicator.label
    }

    override var intrinsicContentSize: NSSize {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(width) + TermAppearance.scaled(32), height: BrowserHeader.controlHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = indicator.color
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        TermAppearance.background.setFill()
        pill.fill() // 테두리 선 위에 놓이므로 바탕을 먼저
        // 옅은 바탕(14%, 주의는 20%) — 글자는 색이 아니라 textPrimary 라 대비는 늘 충분하다
        color.withAlphaComponent(indicator.needsAttention ? 0.2 : 0.14).setFill()
        pill.fill()
        // 늘 테두리를 그어 바탕과 구분한다(주의는 진하게)
        color.withAlphaComponent(indicator.needsAttention ? 1 : 0.6).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        let side = TermAppearance.scaled(13)
        if let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side, weight: .semibold).applying(.init(paletteColors: [color.resolved(effectiveAppearance)]))) {
            globe.draw(in: NSRect(x: TermAppearance.scaled(8), y: (bounds.height - side) / 2, width: side, height: side))
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: TermAppearance.textPrimary.resolved(effectiveAppearance)]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: TermAppearance.scaled(26), y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    // 누를 곳이 없으면(브라우저 창 머리 줄의 상태 알약) 버튼이 아니라 상태 글자로 읽힌다
    override func accessibilityRole() -> NSAccessibility.Role? { onClick == nil ? .staticText : .button }
    override func accessibilityLabel() -> String? { onClick == nil ? "브라우저 \(indicator.label)" : "브라우저 창 열기 — \(indicator.label)" }
    override func accessibilityPerformPress() -> Bool { guard let onClick else { return false }; onClick(); return true }
}

/// 세션 하나의 브라우저 창(보는 곳이 "별도 창"인 세션). 창 크기가 곧 브라우저 크기(사람이 조작 중이거나 쉴 때 맞춘다).
/// 닫아도 브라우저·에이전트는 계속 돈다(보기만 닫힌다). 위치·크기는 세션별로 기억한다. 칸(BrowserPaneView)은
/// BrowserWindows 가 세션마다 하나 들고 있어, 세션 창 안으로 옮겨도 같은 칸(고른 탭·크기 기록)이 그대로 간다.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    /// 이 창이 보여 주는 화면(에이전트 세션)
    let paneId: String
    let pane: BrowserPaneView

    init(pane: BrowserPaneView, title: String) {
        self.paneId = pane.owner
        self.pane = pane
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.backgroundColor = TermAppearance.chrome
        super.init(window: window)
        window.delegate = self
        // 세션마다 따로 기억(같은 화면 ID 면 다시 열어도 그 자리)
        window.setFrameAutosaveName("AgentDeckBrowser-" + BrowserBinding.sessionName(pane: pane.owner))
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        setTitle(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ name: String) { window?.title = "브라우저 · " + name }

    /// 창 높이: 일반 / AgentDeck 쓸 때만 위(앱이 앞일 때만 떠 있음) / 항상 위
    func apply(_ level: BrowserDisplay.Level) {
        let floating: Bool
        switch level {
        case .normal: floating = false
        case .whileActive: floating = NSApp.isActive
        case .always: floating = true
        }
        window?.level = floating ? .floating : .normal
    }

    func show() {
        guard let window else { return }
        // 세션 창 안에서 데려온 칸이면 여기로 옮겨 단다
        if window.contentView !== pane { window.contentView = pane }
        pane.docked = false
        pane.attach()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(pane.focusTarget)
    }

    /// 칸을 다른 곳(세션 창 안)으로 보낸다: 칸을 떼고 창을 닫는다
    func release() {
        pane.detach()
        window?.contentView = NSView()
        window?.orderOut(nil)
    }

    /// 창이 닫힘(빨간 단추·⌘W) — 세션 창 안 안내 문구가 바뀐다
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        pane.detach()
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }
}

/// 세션별 브라우저 칸과 보는 곳(별도 창 / 세션 창 안 도크)을 맡는다. 칸은 세션마다 하나이고 한 번에 한 곳에만 보인다.
/// 보는 곳·창 높이는 별도 창 머리 줄 "⋯" 메뉴·작은 창 제목 줄 버튼에서 고르고 `term/browser-display.json` 에 둔다(고르면 그 세션 값 + 새 세션의 기본값).
final class BrowserWindows {
    private(set) var controllers: [String: BrowserWindowController] = [:]
    private var panes: [String: BrowserPaneView] = [:]

    /// 글꼴 크기 배율이 바뀜: 별도 창 머리 줄의 "⋯" 버튼
    func scaleChanged() { panes.values.forEach { $0.scaleChanged() } }
    /// 세션 창 안 browser 도구(지금 고른 세션의 브라우저)
    let dock = BrowserDockController()
    /// browser 도구를 보이게(숨김이면 마지막 쪽에, 다른 도구가 보이면 이것으로) — ToolWindowsController 가 단다
    var revealDock: (() -> Void)?
    /// browser 도구가 지금 보이는지
    var dockVisible: (() -> Bool)?
    /// browser 도구를 숨긴다(작은 창 닫기 — 옆 도크는 UI 에 없다)
    var moveDock: ((DockSide) -> Void)?
    /// browser 도구가 작은 창(세션 창 안에 떠 있는 패널)으로 보이는 중 / 작은 창으로 보인다
    var dockFloating: (() -> Bool)?
    var floatDock: (() -> Void)?
    /// 세션 이름(창 제목·도크 안내)
    var titleFor: ((String) -> String?)?
    /// 사람이 그 세션의 칸 안을 눌렀거나 제어를 가져왔다
    var onPaneInteraction: ((String) -> Void)?
    private var prefs: BrowserDisplayPrefs
    private var observers: [NSObjectProtocol] = []

    /// 마지막으로 연 창의 화면(키 창이 아닐 때 시험 명령이 쓴다)
    private(set) var lastOpened: String?

    static var url: URL { TermPaths.home.appendingPathComponent("browser-display.json") }

    init() {
        prefs = BrowserDisplayPrefs.load(from: Self.url)
        dock.paneFor = { [weak self] owner in
            guard let self, self.display(owner).placement == .dock else { return nil }
            // 칸은 한 곳에만: 아직 창이 들고 있으면 먼저 내려놓게 한다(빈 창이 남지 않게)
            if let controller = self.controllers.removeValue(forKey: owner) { controller.release() }
            return self.pane(owner)
        }
        dock.onShowHere = { [weak self] owner in self?.move(owner, to: .dock) }
        dock.onOwnerChange = { [weak self] in self?.onDockOwnerOrState?() }
        dock.onShowWindow = { [weak self] owner in self?.open(owner: owner, title: nil) }
        dock.titleFor = { [weak self] owner in self?.titleFor?(owner) }
        dock.windowOpen = { [weak self] owner in self?.controllers[owner]?.window?.isVisible == true }
        // "AgentDeck 쓸 때만 위": 앱이 앞으로 오고 갈 때 그 창들의 높이를 바꾼다
        let center = NotificationCenter.default
        let relevel: (Notification) -> Void = { [weak self] _ in self?.applyLevels() }
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: relevel),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: relevel),
        ]
    }

    private func key(_ owner: String) -> String { BrowserBinding.sessionName(pane: owner) }

    func display(_ owner: String) -> BrowserDisplay { prefs.display(for: key(owner)) }

    /// 세션의 칸(없으면 만든다)
    func pane(_ owner: String) -> BrowserPaneView {
        if let pane = panes[owner] { return pane }
        let pane = BrowserPaneView(owner: owner, frame: NSRect(x: 0, y: 0, width: 1024, height: 760))
        pane.displayMenu = { [weak self] in self?.menu(for: owner) ?? NSMenu() }
        pane.onUserInteraction = { [weak self] in self?.onPaneInteraction?(owner) }
        panes[owner] = pane
        return pane
    }

    /// 세션의 브라우저를 보는 곳에 보인다(⇧⌘B·칩·목록 아이콘·알림): 별도 창이면 그 창을 앞으로, 세션 창 안이면 도구를 꺼내 그 세션으로.
    func open(owner: String, title: String?) {
        lastOpened = owner
        switch display(owner).placement {
        case .window:
            let controller = controllers[owner] ?? BrowserWindowController(pane: pane(owner), title: title ?? titleFor?(owner) ?? "…")
            controllers[owner] = controller
            controller.onClose = { [weak self] in if self?.dock.owner == owner { self?.dock.refresh() } }
            if let title = title ?? titleFor?(owner) { controller.setTitle(title) }
            if dock.owner == owner {
                dock.refresh() // 도크가 이 칸을 들고 있었으면 내려놓게(한 곳에만)
                // 세션 창 안에서 보던 세션을 창으로 옮겼다: 빈 도구가 자리를 차지하지 않게 숨긴다(⌘⇧B·"여기서 보기"로 다시)
                if dockVisible?() == true, dock.hosted == nil { moveDock?(.hidden) }
            }
            controller.apply(display(owner).level)
            controller.show()
            if dock.owner == owner { dock.refresh() } // 안내: "창에서 보는 중"
        case .dock:
            controllers[owner]?.release()
            controllers[owner] = nil
            dock.follow(owner, force: true)
            revealDock?()
            // 세션 창이 최소화됐거나 뒤에 있으면 앞으로(알림을 눌러 왔을 때도 바로 보이게)
            if let window = dock.view.window {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            dock.focus()
        }
    }

    /// 세션 창에서 고른 세션이 바뀜: 도크는 그 세션의 브라우저로(편집기·미리보기 화면은 무시 — 마지막 세션 그대로)
    func follow(_ owner: String?) {
        guard let owner, !LocalPane.isLocal(owner) else { return }
        dock.follow(owner, force: false)
    }

    /// 도크가 따라가는 세션이나 브라우저 상태가 바뀜(세션 창 오른쪽 아래 🌐 버튼을 고친다)
    var onDockOwnerOrState: (() -> Void)?

    /// "⋯" 메뉴·작은 창 "별도 창으로 떼기"에서 고름
    func choose(_ display: BrowserDisplay, for owner: String) {
        let old = self.display(owner)
        freezeOthers(except: owner)
        prefs.choose(display, for: key(owner))
        save()
        if old.placement != display.placement { move(owner, to: display.placement, recorded: true) }
        else { controllers[owner]?.apply(display.level) }
    }

    /// 보는 곳을 옮긴다(창 ↔ 세션 창 안). 칸은 같은 것을 옮겨 단다.
    func move(_ owner: String, to placement: BrowserDisplay.Placement, recorded: Bool = false) {
        if !recorded {
            var display = self.display(owner)
            display.placement = placement
            freezeOthers(except: owner)
            prefs.choose(display, for: key(owner))
            save()
        }
        open(owner: owner, title: nil)
    }

    /// 고른 방식은 새 세션의 기본값이 된다 — 이미 열려 있는 다른 세션(따로 고른 적 없음)은 지금 보이는 방식 그대로 두게
    /// 그 값을 적어 둔다(기본값이 바뀌어 다른 세션의 창이 갑자기 도크로 가지 않게)
    private func freezeOthers(except owner: String) {
        for other in panes.keys where other != owner && prefs.sessions[key(other)] == nil {
            prefs.sessions[key(other)] = prefs.defaults
        }
    }

    private func applyLevels() {
        for (owner, controller) in controllers { controller.apply(display(owner).level) }
    }

    private func save() {
        guard let data = prefs.data() else { return }
        try? FileManager.default.createDirectory(at: TermPaths.home, withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }

    /// 별도 창 머리 줄 "⋯" 메뉴: 세션 안으로 보기 + 다른 창 위에 띄우기(창 층: 일반·쓸 때만 위·항상 위).
    /// 고른 방식은 새 세션의 기본값도 되는데, 그 설명은 메뉴 줄이 아니라 항목의 풍선 도움말에 둔다.
    func menu(for owner: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = display(owner)
        let remembered = "고른 방식은 새 세션의 기본값도 됩니다"
        let inside = ClosureMenuItem(title: "세션 안으로 보기") { [weak self] in
            var next = current
            next.placement = .dock
            self?.choose(next, for: owner)
        }
        inside.toolTip = remembered
        menu.addItem(inside)
        menu.addItem(.separator())
        // 머리 글: 14 이상은 시스템 구역 머리, 13 은 꺼진 작은 글 줄(같은 모양을 따라 그린다)
        if #available(macOS 14.0, *) {
            menu.addItem(NSMenuItem.sectionHeader(title: "다른 창 위에"))
        } else {
            let header = NSMenuItem(title: "다른 창 위에", action: nil, keyEquivalent: "")
            header.attributedTitle = NSAttributedString(string: header.title, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
            header.isEnabled = false
            menu.addItem(header)
        }
        let levels: [(BrowserDisplay.Level, String)] = [(.normal, "일반 창"), (.whileActive, "AgentDeck 쓸 때만 위"),
                                                        (.always, "항상 위 (다른 앱 위에도)")]
        for (level, title) in levels {
            let item = ClosureMenuItem(title: title) { [weak self] in
                var next = current
                next.level = level
                self?.choose(next, for: owner)
            }
            item.state = current.level == level ? .on : .off
            item.toolTip = remembered
            menu.addItem(item)
        }
        return menu
    }

    /// 도크가 그 세션을 실제로 화면에 보이는 중(도구가 보이고, 세션 창이 최소화·가려짐이 아님)
    private func dockShows(_ owner: String) -> Bool {
        guard dockVisible?() == true, dock.showing == owner, let window = dock.view.window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// 어딘가에 보이는지(창이 떠 있거나, 도크가 보이며 그 세션을 보여 주는 중)
    func isOpen(_ owner: String) -> Bool {
        controllers[owner]?.window?.isVisible == true || dockShows(owner)
    }

    /// 화면에 보이는지(쉬게 하기를 거를 때): 창이 떠 있고 가려지거나 최소화되지 않았거나, 도크에 보이는 중. 앱이 앞인지는 묻지 않는다
    /// (다른 앱을 쓰면서 옆 화면에 띄워 둔 브라우저도 보는 중)
    func isShown(_ owner: String) -> Bool {
        if let window = controllers[owner]?.window, window.isVisible, !window.isMiniaturized,
           window.occlusionState.contains(.visible) { return true }
        return dockShows(owner)
    }

    /// 사람이 지금 그 브라우저를 보고 있는지(알림을 거를 때): 앱이 앞이고, 그 창이 키 창이거나 도크에 보이는 중
    func isWatching(_ owner: String) -> Bool {
        guard NSApp.isActive else { return false }
        return keyController?.paneId == owner || dockShows(owner)
    }

    /// 세션이 닫힘: 창·도크에서 내리고 칸을 끝낸다
    func close(owner: String) {
        controllers[owner]?.close()
        controllers[owner] = nil
        if dock.owner == owner { dock.follow(nil, force: true) }
        panes.removeValue(forKey: owner)?.dispose()
    }

    func retitle(_ titles: (String) -> String?) {
        for (owner, controller) in controllers { if let t = titles(owner) { controller.setTitle(t) } }
        dock.refresh()
    }

    /// 키 창이 브라우저 창이면 그 화면, 세션 창의 도크 브라우저에 포커스가 있으면 그 화면(편집 메뉴·⌘W·시험 명령)
    var keyPane: BrowserPaneView? {
        if let pane = controllers.values.first(where: { $0.window?.isKeyWindow == true })?.pane { return pane }
        if let pane = dock.hosted, let window = pane.window, window.isKeyWindow,
           let responder = window.firstResponder as? NSView, responder.isDescendant(of: pane) { return pane }
        return nil
    }

    var keyController: BrowserWindowController? {
        controllers.values.first { $0.window?.isKeyWindow == true }
    }

    /// 시험 명령이 다룰 창: 앞에 있는 브라우저 창, 없으면 마지막으로 연 창
    var target: BrowserWindowController? {
        keyController ?? lastOpened.flatMap { controllers[$0] }.flatMap { $0.window?.isVisible == true ? $0 : nil }
    }

    /// 시험 명령이 다룰 칸: 앞 창의 칸, 없으면 도크에 보이는 칸
    var targetPane: BrowserPaneView? { target?.pane ?? (dockVisible?() == true ? dock.hosted : nil) }

    /// 보이는 창(시험 명령 `browsers`)
    var visible: [BrowserWindowController] { controllers.values.filter { $0.window?.isVisible == true } }
}
