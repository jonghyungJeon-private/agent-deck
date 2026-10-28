import AppKit
import BrowserCore
import ImageIO
import TermWire

/// 브라우저 화면: 에이전트 화면(owner)의 브라우저(abx 세션)를 CDP screencast 로 받아 그린다.
/// 사람은 머리 줄의 "제어 가져오기"(abx handoff)로 제어를 받은 동안에만 클릭·키보드로 조작한다
/// (AI 가 쥐고 있을 때 보낸 입력은 버리고, Chrome 의 입력 잠금도 막는다). "AI 에게 돌려주기" = abx resume.
/// 브라우저는 에이전트가 `abx` 를 처음 쓸 때 창 없이 뜬다.
final class BrowserPaneView: NSView {
    let owner: String
    private let header = NSTextField(labelWithString: "")
    private let controlButton = NSButton(title: "", target: nil, action: nil)
    private let pinButton = NSButton(title: "항상 위", target: nil, action: nil)
    /// 창에 넣었을 때: "항상 위" 를 누르면(켜짐 여부)
    var onPin: ((Bool) -> Void)? {
        didSet { pinButton.isHidden = onPin == nil }
    }
    private let screen = BrowserScreenView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private var feed: BrowserFeed?
    /// 마지막 상태의 제어권(입력을 보낼지 정한다)
    private(set) var control: AbxStatus.Control?
    /// 제어 가져오기·돌려주기를 abx 에 보내 답을 기다리는 중
    private var requesting = false
    /// 마지막 프레임의 페이지 크기(CSS 픽셀) — 칸의 점을 페이지 좌표로 바꿀 때
    private(set) var viewport: CGSize = .zero
    /// 칸에 보이는 탭의 주소·제목(사람이 검색·이동하면 abx 의 기록보다 이것이 새것)
    private var page: (url: String, title: String)?
    private var lastStatus: AbxStatus?

    init(owner: String, frame: NSRect) {
        self.owner = owner
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TermAppearance.background.cgColor

        header.font = .systemFont(ofSize: TermAppearance.scaled(11))
        header.textColor = TermAppearance.textDim
        header.lineBreakMode = .byTruncatingMiddle
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controlButton.bezelStyle = .inline
        controlButton.controlSize = .small
        controlButton.font = .systemFont(ofSize: TermAppearance.scaled(11))
        controlButton.target = self
        controlButton.action = #selector(toggleControl)
        controlButton.isHidden = true
        pinButton.bezelStyle = .inline
        pinButton.controlSize = .small
        pinButton.font = .systemFont(ofSize: TermAppearance.scaled(11))
        pinButton.setButtonType(.pushOnPushOff)
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        pinButton.isHidden = true
        pinButton.toolTip = "다른 창보다 항상 위에 두기"
        screen.pane = self
        placeholder.alignment = .center
        placeholder.textColor = TermAppearance.textDim
        for view in [header, pinButton, controlButton, screen, placeholder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.centerYAnchor.constraint(equalTo: controlButton.centerYAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -8),
            pinButton.centerYAnchor.constraint(equalTo: controlButton.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: controlButton.leadingAnchor, constant: -6),
            controlButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            controlButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            screen.topAnchor.constraint(equalTo: controlButton.bottomAnchor, constant: 3),
            screen.leadingAnchor.constraint(equalTo: leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: trailingAnchor),
            screen.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: screen.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: screen.widthAnchor, constant: -40),
        ])
        show(.waiting("브라우저를 찾는 중…"))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 키보드를 받을 뷰(TerminalHostController 가 포커스를 줄 곳)
    var focusTarget: NSView { screen }

    /// 칸이 화면에 놓였다(TerminalHostController.render). 창이 실제로 보일 때만 스트림을 돈다.
    func attach() {
        placed = true
        updateFeed()
    }

    /// 칸이 화면에서 빠졌다(다른 탭·닫기). 브라우저·에이전트는 계속 돈다.
    func detach() {
        placed = false
        updateFeed()
    }

    private var placed = false
    private var framesShown = 0

    /// 시험 명령 `browsers` 가 찍는 상태
    var debugState: String {
        "owner=\(owner.prefix(4)) placed=\(placed) visible=\(windowVisible) streaming=\(feed != nil) frames=\(framesShown) "
            + "control=\(control?.rawValue ?? "-") viewport=\(Int(viewport.width))x\(Int(viewport.height))"
    }
    private var observers: [NSObjectProtocol] = []

    /// 창이 가려지거나(다른 창·최소화) 앱을 숨기면 멈추고, 다시 보이면 이어 받는다
    private var windowVisible: Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible) && !NSApp.isHidden
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            let center = NotificationCenter.default
            let update: (Notification) -> Void = { [weak self] _ in self?.updateFeed() }
            observers = [
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: update),
                center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main, using: update),
                center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main, using: update),
            ]
        }
        updateFeed()
    }

    private func updateFeed() {
        if placed && windowVisible { startFeed() } else { stopFeed() }
    }

    private func startFeed() {
        guard feed == nil else { return }
        let feed = BrowserFeed(owner: owner)
        feed.onState = { [weak self] state in self?.show(state) }
        feed.onPage = { [weak self] url, title in
            self?.page = (url, title)
            if let status = self?.lastStatus { self?.show(.live(status)) }
        }
        feed.onImage = { [weak self] image, viewport in
            self?.viewport = viewport
            self?.screen.show(image, viewport: viewport)
            self?.placeholder.isHidden = true
            self?.framesShown += 1
        }
        self.feed = feed
        feed.start()
        feed.fit(to: screen.bounds.size)
    }

    /// 브라우저 크기를 칸에 맞춘다(창을 끌어 크기를 바꾸는 동안은 모았다가 한 번)
    private var fitWork: DispatchWorkItem?
    func screenResized() {
        fitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.feed?.fit(to: self.screen.bounds.size)
        }
        fitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func stopFeed() {
        screen.releaseInput()
        feed?.stop()
        feed = nil
    }

    private func show(_ state: BrowserFeed.State) {
        switch state {
        case .waiting(let text):
            header.stringValue = "브라우저"
            placeholder.stringValue = text
            placeholder.isHidden = false
            screen.show(nil, viewport: viewport)
            setControl(nil)
        case .live(let status):
            lastStatus = status
            let control: String
            switch status.control {
            case .agent: control = "AI 작업 중"
            case .user: control = "내가 조작 중" + (status.handoff.map { " — \($0)" } ?? "")
            case .switching: control = "넘겨받는 중… (AI 가 하던 동작이 끝나길 기다림)"
            case .idle: control = "쉬는 중"
            }
            let shown = page ?? status.activeTab.map { ($0.url, $0.title) }
            let tabs = status.tabs.count > 1 ? " · 탭 \(status.tabs.count)개" : ""
            // 제목이 없는 페이지는 Chrome 이 주소를 제목으로 준다 — 같으면 한 번만
            let title = shown.flatMap { $0.0.contains($0.1) ? nil : $0.1 }
            header.stringValue = [control, title, shown?.0].compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ") + tabs
            setControl(status.control)
        }
    }

    private func setControl(_ control: AbxStatus.Control?) {
        // 사용자 제어가 끝나면(에이전트가 abx resume 했을 때 포함) 누르던 버튼·조합 중인 글자를 정리한다
        if self.control == .user, control != .user { screen.releaseInput() }
        self.control = control
        controlButton.isHidden = control == nil
        controlButton.isEnabled = !requesting && control != .switching
        controlButton.title = control == .user ? "AI 에게 돌려주기" : "제어 가져오기"
    }

    /// 돌려주는 중: abx resume 이 끝나기 전부터 입력을 막는다(돌려준 뒤 AI 동작에 사람 입력이 섞이지 않게)
    private var givingBack = false

    @objc private func toggleControl() {
        guard let feed, !requesting else { return }
        requesting = true
        controlButton.isEnabled = false
        let done: () -> Void = { [weak self] in
            self?.requesting = false
            self?.givingBack = false
            self?.setControl(self?.control)
        }
        if control == .user {
            screen.releaseInput() // 누르던 버튼·조합 중 글자를 먼저 정리하고
            givingBack = true     // 이 순간부터 입력을 버린 뒤
            feed.giveBack(completion: done) // 돌려준다
        } else {
            feed.takeControl(completion: done)
            window?.makeFirstResponder(screen)
        }
    }

    @objc private func togglePin() {
        onPin?(pinButton.state == .on)
    }

    /// 메뉴·시험 명령용
    func takeControl() { if control != .user { toggleControl() } }
    func giveBack() { if control == .user { toggleControl() } }

    // MARK: - 입력 (BrowserScreenView 가 부른다)

    /// 사람이 제어를 가진 동안만 보낸다(그 밖에는 버림)
    var acceptsInput: Bool { control == .user && !givingBack && feed != nil }

    func send(_ method: String, _ params: [String: Any]) {
        guard acceptsInput else { return }
        feed?.input(method, params)
    }

    /// 정리용 입력(누르던 버튼 떼기·조합 취소): 제어가 막 넘어간 뒤에도 보낸다 — 남겨 두면 다음 조작에 섞인다
    func sendCleanup(_ method: String, _ params: [String: Any]) {
        feed?.cleanup(method, params)
    }

    /// 화면 뷰의 점(위가 0) → 페이지 CSS 좌표
    func cssPoint(_ point: CGPoint) -> CGPoint? {
        ViewportTransform(bounds: screen.bounds.size, viewport: viewport).cssPoint(point)
    }

    /// 페이지 CSS 좌표 → 창 좌표(시험 명령 `browser-click` 이 실제 마우스 이벤트를 만들 때)
    func windowPoint(css: CGPoint) -> NSPoint? {
        let rect = ViewportTransform(bounds: screen.bounds.size, viewport: viewport).imageRect
        guard rect.width > 0 else { return nil }
        let local = NSPoint(x: rect.minX + css.x * rect.width / viewport.width, y: rect.minY + css.y * rect.height / viewport.height)
        return screen.convert(local, to: nil)
    }

    /// 포커스가 실제로 있는 요소(그림자 DOM·같은 출처 iframe 안까지)를 찾는 식의 앞부분
    private static let focusedJS = """
      const deep = () => { let doc = document, el = doc.activeElement;
        for (;;) {
          if (el && el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
          if (el && el.tagName === 'IFRAME') { try { doc = el.contentDocument; el = doc.activeElement; continue; } catch (e) {} }
          return { doc: el ? el.ownerDocument : doc, el };
        } };
      const { doc, el } = deep();
      const field = el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && el.selectionStart != null;
      // 비밀번호 칸은 Chrome 처럼 복사·잘라내기를 거절한다(클립보드에 평문으로 남지 않게)
      if (el && el.tagName === 'INPUT' && el.type === 'password') return null;
      const text = field ? el.value.substring(el.selectionStart, el.selectionEnd) : String(doc.getSelection());
    """

    /// 선택한 글(입력 칸 안의 선택 포함)을 macOS 클립보드로. cut 이면 같은 계산 안에서 지운다
    /// (읽기와 지우기 사이에 다른 입력이 끼어 엉뚱한 선택을 지우지 않게).
    func copySelection(cut: Bool = false) {
        guard acceptsInput, let feed else { return }
        let js = "(() => {" + Self.focusedJS + (cut ? "if (text) doc.execCommand('delete');" : "") + "return text; })()"
        feed.evaluate(js) { [weak self] value in
            // 그 사이 스트림이 바뀌었거나(멈춤·다시 시작) 제어가 넘어갔으면 버린다
            guard let self, self.feed === feed, let text = value as? String, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// 브라우저 그림을 그리고 사람 입력을 받는 뷰. 키보드는 macOS 입력기(NSTextInputClient)를 거쳐
/// 확정 글자 → `Input.insertText`(영문 한 글자는 키 이벤트), 조합 중 글자 → `Input.imeSetComposition`,
/// 편집 명령(줄바꿈·지우기·화살표…) → 키 이벤트로 보낸다. 제어가 없으면 받아서 버린다(옆 터미널로 새지 않게).
final class BrowserScreenView: NSView, NSTextInputClient, NSMenuItemValidation {
    weak var pane: BrowserPaneView?
    private var marked = ""
    private var pressedButton: BrowserInput.Button = .none
    private var lastMove = Date.distantPast
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true } // 위가 0(페이지 좌표와 같은 방향)

    /// 프레임을 그리는 층. 뷰 자신의 층(AppKit 이 관리 — 기본은 늘려 채움)이 아니라 따로 둔 층에,
    /// 비율을 지킨 자리(ViewportTransform.imageRect — 마우스 좌표 변환과 같은 자리)를 직접 정해 그린다.
    private let imageLayer = CALayer()
    private var imageViewport: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resize // 자리를 이미 비율대로 정했으니 그 자리에 꼭 맞게
        imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 새 프레임(없으면 지움)
    func show(_ image: CGImage?, viewport: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true) // 프레임마다 서서히 바뀌는 효과 없이
        imageLayer.contents = image
        if viewport != imageViewport {
            imageViewport = viewport
            placeImage()
        }
        CATransaction.commit()
    }

    private func placeImage() {
        imageLayer.frame = ViewportTransform(bounds: bounds.size, viewport: imageViewport).imageRect
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeImage()
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { pane?.screenResized() }
    }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// 누르던 버튼을 떼고 조합 중 글자를 지운다(제어를 돌려줄 때·스트림을 멈출 때). 제어 확인 없이 보낸다.
    func releaseInput() {
        if pressedButton != .none, let pane {
            pane.sendCleanup("Input.dispatchMouseEvent", BrowserInput.mouse(.released, at: lastCSS ?? .zero, button: pressedButton))
        }
        pressedButton = .none
        if !marked.isEmpty {
            pane?.sendCleanup("Input.imeSetComposition", ["text": "", "selectionStart": 0, "selectionEnd": 0])
            marked = ""
            inputContext?.discardMarkedText()
        }
    }

    // MARK: 마우스

    private func modifiers(_ flags: NSEvent.ModifierFlags) -> BrowserInput.Modifiers {
        var m: BrowserInput.Modifiers = []
        if flags.contains(.option) { m.insert(.alt) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.command) { m.insert(.meta) }
        if flags.contains(.shift) { m.insert(.shift) }
        return m
    }

    /// 마지막으로 보낸 페이지 좌표 — 누른 채 그림 밖(여백·칸 밖)에서 떼어도 떼기는 반드시 보낸다
    private var lastCSS: CGPoint?

    private func mouse(_ event: NSEvent, _ kind: BrowserInput.MouseKind, _ button: BrowserInput.Button) {
        guard let pane, pane.acceptsInput else { return }
        let inside = pane.cssPoint(convert(event.locationInWindow, from: nil))
        let dragging = button != .none && kind != .pressed
        guard let point = inside ?? (dragging ? lastCSS : nil) else { return }
        lastCSS = point
        pane.send("Input.dispatchMouseEvent",
                  BrowserInput.mouse(kind, at: point, button: button, clickCount: max(event.clickCount, 1),
                                     modifiers: modifiers(event.modifierFlags)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastClick = convert(event.locationInWindow, from: nil)
        pressedButton = .left
        mouse(event, .pressed, .left)
    }
    override func mouseUp(with event: NSEvent) { mouse(event, .released, .left); pressedButton = .none }
    override func mouseDragged(with event: NSEvent) { mouse(event, .moved, .left) }
    override func rightMouseDown(with event: NSEvent) { pressedButton = .right; mouse(event, .pressed, .right) }
    override func rightMouseUp(with event: NSEvent) { mouse(event, .released, .right); pressedButton = .none }
    override func rightMouseDragged(with event: NSEvent) { mouse(event, .moved, .right) }
    override func otherMouseDown(with event: NSEvent) { pressedButton = .middle; mouse(event, .pressed, .middle) }
    override func otherMouseUp(with event: NSEvent) { mouse(event, .released, .middle); pressedButton = .none }

    override func mouseMoved(with event: NSEvent) {
        // 마우스를 올리기만 한 움직임(hover)은 초당 30번까지
        guard Date().timeIntervalSince(lastMove) > 1.0 / 30 else { return }
        lastMove = Date()
        mouse(event, .moved, .none)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let pane, pane.acceptsInput,
              let point = pane.cssPoint(convert(event.locationInWindow, from: nil)) else { return }
        pane.send("Input.dispatchMouseEvent",
                  BrowserInput.wheel(at: point, scrollingDeltaX: event.scrollingDeltaX, scrollingDeltaY: event.scrollingDeltaY,
                                     precise: event.hasPreciseScrollingDeltas, modifiers: modifiers(event.modifierFlags)))
    }

    // MARK: 키보드

    /// 지금 처리 중인 키(입력기 없이 친 글자를 키 이벤트로 보내려고)
    private var currentKey: NSEvent?

    override func keyDown(with event: NSEvent) {
        guard pane?.acceptsInput == true else { return }
        currentKey = event
        defer { currentKey = nil }
        interpretKeyEvents([event])
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let wasComposing = !marked.isEmpty
        marked = ""
        guard let pane, !text.isEmpty else { return }
        // 조합 없이 친 영문·숫자·기호 한 글자는 keydown·keypress 까지 일어나게 키 이벤트로
        if !wasComposing, let key = currentKey, key.characters == text,
           let events = BrowserInput.character(text, keyCode: key.keyCode, modifiers: modifiers(key.modifierFlags)) {
            events.forEach { pane.send("Input.dispatchKeyEvent", $0) }
        } else {
            pane.send("Input.insertText", ["text": text])
        }
    }

    /// 조합 중 글자 안의 선택(입력기가 정한 것, UTF-16)
    private var markedSelection = NSRange(location: 0, length: 0)

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = text
        markedSelection = selectedRange
        pane?.send("Input.imeSetComposition", [
            "text": text, "selectionStart": selectedRange.location, "selectionEnd": selectedRange.location + selectedRange.length,
        ])
    }

    func unmarkText() {
        // 조합 중이던 글자를 그대로 확정
        guard !marked.isEmpty else { return }
        let text = marked
        marked = ""
        pane?.send("Input.insertText", ["text": text])
    }

    override func doCommand(by selector: Selector) {
        guard let pane, let (key, mods, commands) = BrowserInput.command(selector: NSStringFromSelector(selector)) else { return }
        // 실제로 누른 수정 키를 지킨다(⇧⏎ 줄바꿈이 그냥 ⏎ 전송이 되지 않게)
        let pressed = currentKey.map { modifiers($0.modifierFlags) } ?? []
        BrowserInput.press(key, modifiers: mods.union(pressed), commands: commands).forEach { pane.send("Input.dispatchKeyEvent", $0) }
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
    func selectedRange() -> NSRange { marked.isEmpty ? NSRange(location: 0, length: 0) : markedSelection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// 입력기 후보 창 자리: 마지막으로 누른 곳 근처(페이지의 실제 커서 자리는 아직 모른다)
    private var lastClick: NSPoint?
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let local = lastClick ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let rect = NSRect(x: local.x, y: local.y, width: 1, height: 18)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    // MARK: 편집 메뉴(⌘A ⌘C ⌘X ⌘V ⌘Z)

    @objc override func selectAll(_ sender: Any?) { shortcut("selectAll") }
    @objc func undo(_ sender: Any?) { shortcut("undo") }
    @objc func redo(_ sender: Any?) { shortcut("redo") }
    @objc func copy(_ sender: Any?) { pane?.copySelection() }
    @objc func cut(_ sender: Any?) { pane?.copySelection(cut: true) }
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        pane?.send("Input.insertText", ["text": text])
    }

    private func shortcut(_ command: String) {
        BrowserInput.shortcut(command)?.forEach { pane?.send("Input.dispatchKeyEvent", $0) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectAll(_:)), #selector(undo(_:)), #selector(redo(_:)), #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)):
            return pane?.acceptsInput == true
        default:
            return true
        }
    }
}

/// 브라우저 하나를 지켜보며 화면을 받아 온다(백그라운드).
/// - abx 상태(`abx status --json`)는 abx 폴더가 바뀔 때와 몇 초마다 다시 읽는다(브라우저를 띄우지 않는다).
/// - CDP 주소가 생기면 붙고, 에이전트가 보는 탭(활성 탭)을 따라 screencast 를 옮긴다.
/// - 프레임은 백그라운드에서 풀고, 밀리면 최신 것만 그린다.
final class BrowserFeed {
    enum State {
        case waiting(String)
        case live(AbxStatus)
    }

    var onState: ((State) -> Void)?
    /// 그릴 그림과 그 프레임의 페이지 크기(CSS 픽셀)
    var onImage: ((CGImage, CGSize) -> Void)?
    /// 보고 있는 탭의 주소·제목이 바뀜
    var onPage: ((String, String) -> Void)?

    private let session: AbxSession
    private let watchDirs: [String]
    private let queue = DispatchQueue(label: "agentdeck.browser.feed")
    private let decodeQueue = DispatchQueue(label: "agentdeck.browser.decode", qos: .userInitiated)
    private var runner: AbxRunner?
    private var client: CDPClient?
    private var stream: ScreencastStream?
    private var connectedURL: String?
    private var connecting = false
    /// 붙는 중에 끊기·멈춤이 오면 늦게 열린 연결을 버리려는 세대 번호
    private var connectGeneration = 0
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var pendingRefresh = false
    private var frames = LatestFrameQueue<ScreencastFrame>()
    private var stopped = false
    /// 마지막 상태의 제어권(사람 입력·새 탭 따라가기)
    private var control: AbxStatus.Control?
    /// 돌려주는 중(abx resume 을 보냄)
    private var releasing = false
    /// 칸 크기(브라우저 페이지를 이 크기로 맞춘다). 아주 작은 칸은 최소 크기로
    private var size: CGSize?
    static let minimumSize = CGSize(width: 320, height: 240)
    /// 사람이 조작하다 연 탭 — 사람이 제어하는 동안은 abx 가 기억한 활성 탭보다 이것을 보여 준다
    private var userTarget: String?

    init(owner: String) {
        let env = BrowserBinding.environment(pane: owner, browser: nil)
        session = AbxSession(name: env["ABX_SESSION"]!, socketDir: env["ABX_SOCKET_DIR"]!,
                             stateDir: env["ABX_STATE_DIR"]!, profileDir: env["ABX_PROFILE_DIR"]!)
        watchDirs = [session.socketDir, session.stateDir, session.profileDir]
    }

    func start() {
        queue.async { [self] in
            runner = AbxRunner.locate(bundleHelpers: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers"))
            guard runner != nil else {
                publish(.waiting("abx 를 찾지 못했어요 — abx 를 설치하거나 AGENTDECK_ABX 로 경로를 알려 주세요"))
                return
            }
            // 폴더가 아직 없을 수 있어(브라우저를 처음 쓰기 전) 몇 초마다도 읽는다
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 3)
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            self.timer = timer
        }
    }

    /// 메인 스레드에서 부른다. 알림을 바로 끊고(늦게 온 상태·프레임은 버림), 정리는 뒤에서.
    func stop() {
        onState = nil
        onImage = nil
        onPage = nil
        queue.async { [self] in
            stopped = true
            timer?.cancel()
            watchers.forEach { $0.cancel() }
            watchers = []
            disconnect()
        }
    }

    // MARK: - 상태

    private func publish(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    /// 폴더 변경(파일 생김·지움·이름 바꿈)이 몰려 오면 한 번만 읽는다
    private func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pendingRefresh = false
            self?.refresh()
        }
    }

    private func watchNewDirs() {
        // 아직 없는 폴더가 있으면, 생겼는지 볼 때마다 다시 건다
        guard watchers.count < watchDirs.count else { return }
        watchers.forEach { $0.cancel() }
        watchers = watchDirs.compactMap { dir in
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self] in self?.scheduleRefresh() }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    private func refresh() {
        guard !stopped, let runner else { return }
        watchNewDirs()
        // 상태는 abx 를 띄우지 않고 파일로 읽는다(AbxStateReader — abx status --json 과 같은 규칙)
        let status = AbxStateReader().status(session)
        guard status.running, let url = status.cdpUrl else {
            disconnect()
            publish(.waiting("에이전트가 아직 브라우저를 쓰지 않았어요\n(이 화면의 claude·codex 가 abx 를 쓰면 여기에 보여요)"))
            return
        }
        let wasControlled = control == .agent || control == .switching
        control = status.control
        if control != .user { userTarget = nil }
        // AI 가 쥐고 있는 동안 미뤄 둔 크기 맞추기를 이제 한다
        if wasControlled, control == .user || control == .idle { applySize() }
        publish(.live(status))
        if url != connectedURL { connect(url, status: status) }
        else { follow(userTarget ?? status.activeTab?.targetId) }
    }

    // MARK: - CDP

    private func connect(_ url: String, status: AbxStatus) {
        guard !connecting, let endpoint = URL(string: url) else { return }
        disconnect()
        connecting = true
        let generation = connectGeneration
        // queue 는 강하게 잡는다: 이 feed 가 먼저 사라져도 늦게 열린 연결을 닫는 일은 반드시 돈다
        let queue = self.queue
        Task { [weak self] in
            let transport = try? await WebSocketTransport.connect(endpoint)
            queue.async {
                guard let self, !self.stopped, self.connectGeneration == generation else {
                    transport?.close()
                    return
                }
                self.connecting = false
                guard let transport else { return } // 다음 상태 읽기에서 다시 시도
                let client = CDPClient(transport: transport)
                let stream = ScreencastStream(client: client)
                client.onEvent = { [weak self, weak stream] event in
                    if stream?.handle(event) == true { return }
                    if event.method == "Target.targetCreated" { self?.queue.async { self?.opened(event.params) } }
                    if event.method == "Target.targetInfoChanged", let info = event.params["targetInfo"] as? [String: Any],
                       let target = info["targetId"] as? String, target == stream?.currentTarget {
                        let url = info["url"] as? String ?? "", title = info["title"] as? String ?? ""
                        DispatchQueue.main.async { self?.onPage?(url, title) }
                    }
                }
                client.onClose = { [weak self, weak client] in
                    self?.queue.async {
                        guard let self, let client, self.client === client else { return }
                        self.disconnect()
                        self.scheduleRefresh()
                    }
                }
                stream.onFrame = { [weak self] frame in self?.queue.async { self?.received(frame) } }
                self.client = client
                self.stream = stream
                self.connectedURL = url
                client.post("Target.setDiscoverTargets", ["discover": true])
                self.follow(status.activeTab?.targetId)
            }
        }
    }

    /// abx 가 마지막으로 본 활성 탭을 따라간다. 그 기록이 없거나(막 띄움) 그 탭이 이미 닫혔으면(오래된 기록)
    /// 보던 탭을 그대로 두거나 열린 페이지 하나를 보여 준다(`ScreencastStream.choose`).
    private func follow(_ target: String?) {
        guard let stream else { return }
        if let target, stream.currentTarget == target { return }
        Task { [weak self] in
            guard let pages = await stream.pages(),
                  let pick = ScreencastStream.choose(wanted: target, current: stream.currentTarget, open: pages) else { return }
            let changed = stream.currentTarget != pick
            try? await stream.show(target: pick)
            if changed { self?.queue.async { self?.showing(pick) } }
        }
    }

    /// 사람이 조작하다 연 새 탭(링크의 target=_blank 등)은 바로 따라간다.
    /// AI 가 연 탭은 abx 가 활성 탭으로 알려 주므로(상태) 여기서는 따라가지 않는다.
    private func opened(_ params: [String: Any]) {
        guard control == .user, let info = params["targetInfo"] as? [String: Any], info["type"] as? String == "page",
              let target = info["targetId"] as? String, let stream,
              info["openerId"] as? String == stream.currentTarget else { return }
        userTarget = target
        Task { [weak self] in
            try? await stream.show(target: target)
            self?.queue.async { self?.showing(target) }
        }
    }

    // MARK: - 사람 입력·제어

    /// 사람 입력을 지금 보는 탭에 보낸다. 제어가 사람에게 있을 때만(뷰도 거르지만 상태가 막 바뀐 경우까지),
    /// 돌려주는 중에는 버린다.
    func input(_ method: String, _ params: [String: Any]) {
        queue.async { [self] in
            guard control == .user, !releasing else { return }
            stream?.post(method, params)
        }
    }

    /// 정리용 입력(버튼 떼기·조합 취소)은 제어와 상관없이 보낸다
    func cleanup(_ method: String, _ params: [String: Any]) {
        queue.async { [self] in stream?.post(method, params) }
    }

    /// 브라우저 페이지 크기를 칸에 맞춘다(지금 보는 탭의 창). 탭을 옮겨 가거나 다시 붙으면 또 맞춘다.
    func fit(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        queue.async { [self] in
            self.size = CGSize(width: max(size.width, Self.minimumSize.width), height: max(size.height, Self.minimumSize.height))
            applySize()
        }
    }

    /// AI 가 입력을 쥐고 있는 동안(잠금·넘기는 중)은 페이지 크기를 바꾸지 않는다 — AI 가 본 화면 배치·좌표가
    /// 동작 도중에 바뀌지 않게. 그동안 그림만 창에 맞춰 줄이고 늘리며, 사람 차례·쉬는 중이 되면 맞춘다.
    private func applySize() {
        guard let stream, let size, stream.currentTarget != nil, control == .user || control == .idle else { return }
        let session = self.session
        Task {
            // abx 의 writer 자리를 잡고 크기를 바꾼다: 그동안 에이전트 동작은 시작하지 않고, 잡은 뒤 제어를 다시 보아
            // (그새 resume 등) AI 차례면 바꾸지 않는다 — 늦게 도착한 크기 변경이 AI 의 화면 배치를 바꾸지 않게.
            guard let lease = AbxWriterLease.acquire(stateDir: session.stateDir, session: session.name) else { return }
            defer { lease.release() }
            let now = AbxStateReader().status(session).control
            guard now == .user || now == .idle else { return }
            await stream.fit(to: size)
        }
    }

    /// 보는 탭이 바뀌었다: 크기를 맞추고 주소·제목을 알린다
    private func showing(_ target: String) {
        applySize()
        guard let stream else { return }
        Task { [weak self] in
            guard let info = await stream.info(target: target),
                  stream.currentTarget == target else { return } // 그새 다른 탭으로 옮겼으면 버린다(옛 주소가 덮지 않게)
            DispatchQueue.main.async { self?.onPage?(info.url, info.title) }
        }
    }

    func evaluate(_ expression: String, completion: @escaping (Any?) -> Void) {
        queue.async { [self] in
            guard let stream else { return }
            Task {
                let value = await stream.evaluate(expression)
                DispatchQueue.main.async { completion(value) }
            }
        }
    }

    /// 제어 가져오기 = `abx handoff`. 에이전트가 하던 동작이 다음 단계에서 멈출 때까지 기다릴 수 있다(그동안 상태는 switching).
    func takeControl(completion: @escaping () -> Void) {
        abx(["handoff", BrowserIndicator.takeMessage], timeout: 330, completion: completion)
    }

    /// AI 에게 돌려주기 = `abx resume`. 부른 순간부터 사람 입력을 버린다(resume 이 끝나고 상태를 다시 읽기 전에도).
    func giveBack(completion: @escaping () -> Void) {
        queue.async { [self] in releasing = true }
        abx(["resume"], timeout: 30) { [weak self] in
            self?.queue.async { self?.releasing = false }
            completion()
        }
    }

    private func abx(_ arguments: [String], timeout: TimeInterval, completion: @escaping () -> Void) {
        queue.async { [self] in
            guard let runner else { DispatchQueue.main.async(execute: completion); return }
            let session = self.session
            // 오래 걸릴 수 있어 상태 읽기(queue)를 막지 않게 따로 돌린다
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = try? runner.run(arguments, session: session, timeout: timeout)
                self?.queue.async { self?.refresh() }
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private func disconnect() {
        connectGeneration += 1
        connecting = false
        if let stream { Task { await stream.stop() } }
        client?.onClose = nil
        client?.close()
        client = nil
        stream = nil
        connectedURL = nil
    }

    // MARK: - 프레임

    private func received(_ frame: ScreencastFrame) {
        guard !stopped, let next = frames.offer(frame) else { return }
        decode(next)
    }

    private func decode(_ frame: ScreencastFrame) {
        decodeQueue.async { [weak self] in
            let image = CGImageSourceCreateWithData(frame.jpeg as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            if let image {
                DispatchQueue.main.async { self?.onImage?(image, frame.viewport) }
            }
            self?.queue.async {
                guard let self, let next = self.frames.finish() else { return }
                self.decode(next)
            }
        }
    }
}
