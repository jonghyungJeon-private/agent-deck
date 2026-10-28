import AppKit
import BrowserCore
import TermWire

/// 화면(에이전트 세션) 하나의 브라우저가 지금 어떤지 — 화면 제목 줄의 칩·spaces 목록·알림이 쓴다
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
        case .idle: return "브라우저"
        case .agent: return "AI 제어 중"
        case .user: return "내가 조작 중"
        case .waiting: return "나를 기다림"
        case .switching: return "넘겨받는 중"
        }
    }

    var color: NSColor {
        switch self {
        case .idle: return TermAppearance.textDim
        case .agent: return TermAppearance.accent
        case .user: return NSColor(srgbHex: 0x61afef)
        case .waiting, .switching: return NSColor(srgbHex: 0xe5c07b)
        }
    }

    var needsAttention: Bool { if case .waiting = self { return true } else { return false } }
}

/// 모든 화면의 브라우저 상태를 abx 상태 파일로 읽는다(스트림 없이, 프로세스 없이 — AbxStateReader).
/// abx 폴더(소켓·상태, 모든 세션이 함께 씀)가 바뀌면 곧바로, 그 밖에는 몇 초마다 다시 읽는다.
final class BrowserStatusStore {
    /// 메인 스레드에서 부른다: 브라우저가 있는 화면만(화면 ID → 상태)
    var onChange: (([String: AbxStatus]) -> Void)?
    /// 읽을 화면들(메인 스레드에서 묻는다)
    var panes: () -> [String] = { [] }

    private let queue = DispatchQueue(label: "agentdeck.browser.status")
    private let reader = AbxStateReader()
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var pending = false
    private var last: [String: AbxStatus] = [:]
    /// 첫 결과는 비어 있어도 알린다(앱을 켠 첫 상태로 기억하게 — 그 뒤 처음 보는 넘김은 새 요청으로 알린다)
    private var published = false

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 2)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
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
        for id in ids {
            let env = BrowserBinding.environment(pane: id, browser: nil)
            let session = AbxSession(name: env["ABX_SESSION"]!, socketDir: env["ABX_SOCKET_DIR"]!,
                                     stateDir: env["ABX_STATE_DIR"]!, profileDir: env["ABX_PROFILE_DIR"]!)
            let status = reader.status(session)
            if BrowserIndicator(status) != nil { next[id] = status }
        }
        guard next != last || !published else { return }
        last = next
        published = true
        DispatchQueue.main.async { [weak self] in self?.onChange?(next) }
    }
}

/// 화면 제목 줄 오른쪽 위의 브라우저 칩(🌐 + 상태). 누르면 그 화면의 브라우저 창.
final class BrowserChipView: NSView {
    var indicator: BrowserIndicator = .idle { didSet { if indicator != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    private var font: NSFont { TermAppearance.scaledUIFont(10, bold: true) }
    private var text: String {
        if case .waiting = indicator { return indicator.label + " !" }
        return indicator.label
    }

    override var intrinsicContentSize: NSSize {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(width) + TermAppearance.scaled(28), height: TermAppearance.scaled(16))
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = indicator.color
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        TermAppearance.background.setFill()
        pill.fill() // 테두리 선 위에 놓이므로 바탕을 먼저
        color.withAlphaComponent(0.18).setFill()
        pill.fill()
        if indicator.needsAttention {
            color.setStroke()
            pill.lineWidth = 1
            pill.stroke()
        }
        let side = TermAppearance.scaled(11)
        if let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side, weight: .semibold).applying(.init(paletteColors: [color]))) {
            globe.draw(in: NSRect(x: TermAppearance.scaled(6), y: (bounds.height - side) / 2, width: side, height: side))
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: TermAppearance.scaled(20), y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "브라우저 창 열기 — \(indicator.label)" }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// 세션 하나의 브라우저 창. 창 크기가 곧 브라우저 크기(사람이 조작 중이거나 쉴 때 맞춘다).
/// 닫아도 브라우저·에이전트는 계속 돈다(보기만 닫힌다). 위치·크기는 세션별로 기억한다.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    /// 이 창이 보여 주는 화면(에이전트 세션)
    let paneId: String
    let pane: BrowserPaneView

    init(owner: String, title: String) {
        self.paneId = owner
        pane = BrowserPaneView(owner: owner, frame: NSRect(x: 0, y: 0, width: 1024, height: 760))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        window.minSize = NSSize(width: 420, height: 320)
        window.backgroundColor = TermAppearance.chrome
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        // 세션마다 따로 기억(같은 화면 ID 면 다시 열어도 그 자리)
        window.setFrameAutosaveName("AgentDeckBrowser-" + BrowserBinding.sessionName(pane: owner))
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        setTitle(title)
        pane.onPin = { [weak window] pinned in window?.level = pinned ? .floating : .normal }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ name: String) { window?.title = "브라우저 · " + name }

    func show() {
        pane.attach()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(pane.focusTarget)
    }

    func windowWillClose(_ notification: Notification) {
        pane.detach()
    }
}

/// 세션별 브라우저 창들. 창은 세션마다 하나.
final class BrowserWindows {
    private(set) var controllers: [String: BrowserWindowController] = [:]

    /// 마지막으로 연 창의 화면(키 창이 아닐 때 시험 명령이 쓴다)
    private(set) var lastOpened: String?

    func open(owner: String, title: String) {
        let controller = controllers[owner] ?? BrowserWindowController(owner: owner, title: title)
        controllers[owner] = controller
        lastOpened = owner
        controller.setTitle(title)
        controller.show()
    }

    func isOpen(_ owner: String) -> Bool { controllers[owner]?.window?.isVisible == true }

    func close(owner: String) {
        controllers[owner]?.close()
        controllers[owner] = nil
    }

    func retitle(_ titles: (String) -> String?) {
        for (owner, controller) in controllers { if let t = titles(owner) { controller.setTitle(t) } }
    }

    /// 키 창이 브라우저 창이면 그 화면(편집 메뉴·⌘W·시험 명령이 그 창을 대상으로)
    var keyPane: BrowserPaneView? {
        controllers.values.first { $0.window?.isKeyWindow == true }?.pane
    }

    var keyController: BrowserWindowController? {
        controllers.values.first { $0.window?.isKeyWindow == true }
    }

    /// 시험 명령이 다룰 창: 앞에 있는 브라우저 창, 없으면 마지막으로 연 창
    var target: BrowserWindowController? {
        keyController ?? lastOpened.flatMap { controllers[$0] }.flatMap { $0.window?.isVisible == true ? $0 : nil }
    }

    /// 보이는 창(시험 명령 `browsers`)
    var visible: [BrowserWindowController] { controllers.values.filter { $0.window?.isVisible == true } }
}
