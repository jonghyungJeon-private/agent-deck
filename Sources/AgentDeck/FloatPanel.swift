import AppKit
import TermLayout

/// 세션 창 안에 떠 있는 작은 창(브라우저·작은 터미널): 얇은 제목 줄(제목 · 추가 버튼 · 크게 · ✕) + 내용.
/// 제목 줄을 끌면 옮기고, 가장자리·모서리를 끌면 크기를 바꾼다. 자리는 호스트(부모 뷰) 좌표 frame 으로 다루고,
/// 사람이 끌기를 마치면 `onFrameChanged` 로 알린다(저장은 ToolWindowsController). 종류마다 `FloatSpec`(최소 크기)이 다르다.
final class FloatPanel: NSView {
    var onFrameChanged: ((NSRect) -> Void)?
    var onClose: (() -> Void)?
    var onToggleSize: (() -> Void)?
    /// 끌기(옮기기·크기 바꾸기) 시작·끝 — 끄는 동안 브라우저 페이지 크기는 맞추지 않고 자동 배치(ToolWindowsController.floatGate)도 미룬다(끝에서 한 번)
    var onGestureBegan: (() -> Void)?
    var onGestureEnded: (() -> Void)?

    /// 크기 바꾸기를 잡는 가장자리 두께
    static let edge: CGFloat = 6
    static var stripHeight: CGFloat { TermAppearance.scaled(30) }

    private let clip = NSView()
    private let strip = FloatTitleStrip()
    private let container = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sizeButton = FloatIconButton(symbol: "arrow.up.left.and.arrow.down.right", tip: "크게")
    private let closeButton: FloatIconButton
    private var iconButtons: [FloatIconButton] = []
    private var stripHeightConstraint: NSLayoutConstraint!
    private let edgeCursors = FloatEdgeCursorView()
    private let row = NSStackView()
    private var content: NSView?
    private let spec: FloatSpec
    private var extraActions: [() -> Void] = []
    private var large = false

    private enum Drag {
        case move
        case resize(left: Bool, right: Bool, bottom: Bool, top: Bool)
    }
    private var drag: Drag?
    private var dragOrigin = NSPoint.zero
    private var dragFrame = NSRect.zero

    init(spec: FloatSpec, closeTip: String) {
        self.spec = spec
        closeButton = FloatIconButton(symbol: "xmark", tip: closeTip)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 10
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1
        refreshLayerColors()
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)

        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.onDragBegan = { [weak self] event in self?.begin(.move, event) }
        strip.onDragMoved = { [weak self] event in self?.dragged(event) }
        strip.onDragEnded = { [weak self] in self?.endDrag() }
        container.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(container)
        clip.addSubview(strip)

        titleLabel.font = TermAppearance.scaledUIFont(11, bold: true)
        titleLabel.textColor = TermAppearance.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow - 1, for: .horizontal) // 남는 폭은 제목이 차지해 버튼이 오른쪽에 붙게
        sizeButton.target = self
        sizeButton.action = #selector(sizeClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        iconButtons = [sizeButton, closeButton]
        for view in [titleLabel, sizeButton, closeButton] { row.addArrangedSubview(view) }
        row.orientation = .horizontal
        row.spacing = 2
        row.setCustomSpacing(8, after: titleLabel)
        setLarge(false)
        row.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(row)

        // 제목 줄 위·가장자리 위에서 커서(안쪽 터미널·브라우저 화면의 커서가 이기지 않게): 맨 위에 올린 덮개가 크기 바꾸기 커서를 정한다
        edgeCursors.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edgeCursors)
        stripHeightConstraint = strip.heightAnchor.constraint(equalToConstant: Self.stripHeight)
        NSLayoutConstraint.activate([
            edgeCursors.topAnchor.constraint(equalTo: topAnchor),
            edgeCursors.leadingAnchor.constraint(equalTo: leadingAnchor),
            edgeCursors.trailingAnchor.constraint(equalTo: trailingAnchor),
            edgeCursors.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.topAnchor.constraint(equalTo: clip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stripHeightConstraint,
            container.topAnchor.constraint(equalTo: strip.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 레이어 색은 값으로 굳으므로 모양(라이트·다크)이 바뀔 때마다 다시 받는다. 그림자는 밝은 바탕에서 옅게.
    private func refreshLayerColors() {
        layer?.shadowOpacity = effectiveAppearance.isDark ? 0.45 : 0.2
        clip.layer?.borderColor = TermAppearance.border.cg(in: self)
        clip.layer?.backgroundColor = TermAppearance.background.cg(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayerColors()
    }

    func setTitle(_ text: String) { titleLabel.stringValue = text }

    var hasContent: Bool { content?.superview === container }

    func setLarge(_ large: Bool) {
        self.large = large
        sizeButton.setSymbol(large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        sizeButton.toolTip = large ? "작게" : "크게"
        sizeButton.setAccessibilityLabel(sizeButton.toolTip)
    }

    /// 글꼴 크기 배율이 바뀜: 제목 줄 높이·글꼴·버튼
    func scaleChanged() {
        stripHeightConstraint.constant = Self.stripHeight
        titleLabel.font = TermAppearance.scaledUIFont(11, bold: true)
        iconButtons.forEach { $0.scaleChanged() }
        setLarge(large)
    }

    /// 내용(브라우저 도구·터미널 뷰)을 단다(nil = 뗀다). 다른 곳(옆 도크: 시험 명령)에 붙어 있었으면 거기서 먼저 뗀다.
    func setContent(_ view: NSView?) {
        guard view !== content || view?.superview !== container else { return }
        if let old = content, old.superview === container { old.removeFromSuperview() }
        content = view
        guard let view else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// 제목 줄의 "크게" 앞에 아이콘 버튼을 더한다(브라우저의 "별도 창으로 떼기", 작은 터미널의 "끝내기")
    func addTitleButton(symbol: String, tip: String, action: @escaping () -> Void) {
        let button = FloatIconButton(symbol: symbol, tip: tip)
        button.target = self
        button.action = #selector(extraClicked(_:))
        button.tag = extraActions.count
        extraActions.append(action)
        iconButtons.append(button)
        row.insertArrangedSubview(button, at: row.arrangedSubviews.firstIndex(of: sizeButton) ?? row.arrangedSubviews.count)
    }

    @objc private func extraClicked(_ sender: NSButton) {
        if extraActions.indices.contains(sender.tag) { extraActions[sender.tag]() }
    }

    @objc private func sizeClicked() { onToggleSize?() }
    @objc private func closeClicked() { onClose?() }

    // MARK: - 끌기: 가장자리는 이 뷰가 받는다(안쪽 브라우저 화면이 가로채지 않게)

    private func edges(at point: NSPoint) -> (left: Bool, right: Bool, bottom: Bool, top: Bool)? {
        let e = Self.edge
        let hit = (left: point.x < e, right: point.x > bounds.width - e, bottom: point.y < e, top: point.y > bounds.height - e)
        return hit.left || hit.right || hit.bottom || hit.top ? hit : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let local = convert(point, from: superview)
        return edges(at: local) != nil ? self : hit
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = edges(at: point) else { return }
        begin(.resize(left: hit.left, right: hit.right, bottom: hit.bottom, top: hit.top), event)
    }
    override func mouseDragged(with event: NSEvent) { dragged(event) }
    override func mouseUp(with event: NSEvent) { endDrag() }

    private func begin(_ kind: Drag, _ event: NSEvent) {
        guard let host = superview else { return }
        drag = kind
        dragOrigin = host.convert(event.locationInWindow, from: nil)
        dragFrame = frame
        onGestureBegan?()
    }

    private func dragged(_ event: NSEvent) {
        guard let drag, let host = superview else { return }
        let point = host.convert(event.locationInWindow, from: nil)
        let dx = point.x - dragOrigin.x, dy = point.y - dragOrigin.y
        var next = dragFrame
        switch drag {
        case .move:
            next.origin.x += dx
            next.origin.y += dy
        case .resize(let left, let right, let bottom, let top):
            let minSize = spec.minSize
            if left {
                let width = max(dragFrame.width - dx, minSize.width)
                next.origin.x = dragFrame.maxX - width
                next.size.width = width
            }
            if right { next.size.width = max(dragFrame.width + dx, minSize.width) }
            if bottom {
                let height = max(dragFrame.height - dy, minSize.height)
                next.origin.y = dragFrame.maxY - height
                next.size.height = height
            }
            if top { next.size.height = max(dragFrame.height + dy, minSize.height) }
        }
        // 호스트 밖으로 나가지 않게(왼쪽·아래를 끌 때는 반대쪽 가장자리를 고정한 채 안으로 자른다)
        let host0 = host.bounds
        // (옮기기는 크기를 두고 자리만 안으로)
        if next.minX < 0 { if case .move = drag {} else { next.size.width += next.minX }; next.origin.x = 0 }
        if next.minY < 0 { if case .move = drag {} else { next.size.height += next.minY }; next.origin.y = 0 }
        if next.maxX > host0.width { if case .move = drag { next.origin.x = host0.width - next.width } else { next.size.width = host0.width - next.minX } }
        if next.maxY > host0.height { if case .move = drag { next.origin.y = host0.height - next.height } else { next.size.height = host0.height - next.minY } }
        frame = next
    }

    private func endDrag() {
        guard drag != nil else { return }
        drag = nil
        // 자리가 바뀌지 않은 클릭(제목 줄을 눌렀다 뗌)은 저장하지 않는다 — 기본 자리가 저장된 자리로 굳지 않게
        if frame != dragFrame { onFrameChanged?(frame) }
        layoutSubtreeIfNeeded() // 안쪽 화면이 마지막 크기로 자리 잡은 뒤 페이지를 맞추게
        onGestureEnded?()
    }

    /// 끄는 중에 창이 호스트에서 빠졌다(세션이 바뀌어 닫힘 등): 마우스 뗌이 오지 않으므로 끝을 알린다
    /// (끝 알림이 없으면 그 창의 자동 배치가 영영 미뤄진다)
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview == nil, drag != nil else { return }
        drag = nil
        onGestureEnded?()
    }

    // MARK: - 커서
    // 터미널·브라우저 화면은 자기 영역 전체에 커서(I빔·손가락)를 선언해, 위에 겹친 이 창이 선언하지 않으면 그것이 이긴다.
    // 제목 줄(FloatTitleStrip)은 화살표, 가장자리·모서리는 맨 위 덮개(FloatEdgeCursorView)가 크기 바꾸기 커서를 선언한다.
    // 안쪽 화면의 커서(작은 터미널의 I빔)는 그대로 둔다. 창이 옮겨지거나 크기가 바뀌면 커서 영역을 다시 잡는다.

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private func invalidateCursors() {
        guard let window else { return }
        window.invalidateCursorRects(for: self)
        window.invalidateCursorRects(for: edgeCursors)
        window.invalidateCursorRects(for: strip)
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); invalidateCursors() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); invalidateCursors() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); invalidateCursors() }

    // 마지막 보루: 위 선언이 안쪽 화면의 커서에 밀려도, 제목 줄·가장자리에 들어올 때 이 창이 직접 커서를 정한다
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let e = Self.edge, h = strip.frame.height
        var rects = [NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)] // 제목 줄(위쪽)
        rects += [NSRect(x: 0, y: 0, width: e, height: bounds.height), NSRect(x: bounds.width - e, y: 0, width: e, height: bounds.height),
                  NSRect(x: 0, y: 0, width: bounds.width, height: e), NSRect(x: 0, y: bounds.height - e, width: bounds.width, height: e)]
        for rect in rects {
            addTrackingArea(NSTrackingArea(rect: rect, options: [.cursorUpdate, .activeInKeyWindow], owner: self))
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = edges(at: point) { FloatEdgeCursorView.cursor(left: hit.left, right: hit.right, bottom: hit.bottom, top: hit.top).set() }
        else { NSCursor.arrow.set() }
    }
}

/// 크기 바꾸기 가장자리 위의 커서 선언 전용 덮개(마우스 이벤트는 받지 않는다 — FloatPanel.hitTest 가 가장자리를 맡는다)
final class FloatEdgeCursorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 모서리의 대각선 크기 바꾸기 커서: 공개된 것이 없어 AppKit 안의 이름으로 찾고, 없으면 십자
    private static let nwse: NSCursor = privateCursor("_windowResizeNorthWestSouthEastCursor") ?? .crosshair
    private static let nesw: NSCursor = privateCursor("_windowResizeNorthEastSouthWestCursor") ?? .crosshair

    private static func privateCursor(_ name: String) -> NSCursor? {
        let selector = NSSelectorFromString(name)
        guard NSCursor.responds(to: selector) else { return nil }
        return NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor
    }

    static func cursor(left: Bool, right: Bool, bottom: Bool, top: Bool) -> NSCursor {
        if (left || right) && (bottom || top) {
            // 아래-왼쪽·위-오른쪽은 ↗↙, 위-왼쪽·아래-오른쪽은 ↖↘
            return (left && bottom) || (right && top) ? nesw : nwse
        }
        return left || right ? .resizeLeftRight : .resizeUpDown
    }

    override func resetCursorRects() {
        let e = FloatPanel.edge, w = bounds.width, h = bounds.height
        guard w > 2 * e, h > 2 * e else { return }
        let c = e
        addCursorRect(NSRect(x: 0, y: 0, width: c, height: c), cursor: Self.cursor(left: true, right: false, bottom: true, top: false))
        addCursorRect(NSRect(x: w - c, y: 0, width: c, height: c), cursor: Self.cursor(left: false, right: true, bottom: true, top: false))
        addCursorRect(NSRect(x: 0, y: h - c, width: c, height: c), cursor: Self.cursor(left: true, right: false, bottom: false, top: true))
        addCursorRect(NSRect(x: w - c, y: h - c, width: c, height: c), cursor: Self.cursor(left: false, right: true, bottom: false, top: true))
        addCursorRect(NSRect(x: 0, y: c, width: e, height: h - 2 * c), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - e, y: c, width: e, height: h - 2 * c), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: c, y: 0, width: w - 2 * c, height: e), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: c, y: h - e, width: w - 2 * c, height: e), cursor: .resizeUpDown)
    }
}

/// 제목 줄: 빈 곳을 끌면 작은 창을 옮긴다(버튼은 자기 클릭을 받는다)
final class FloatTitleStrip: NSView {
    var onDragBegan: ((NSEvent) -> Void)?
    var onDragMoved: ((NSEvent) -> Void)?
    var onDragEnded: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDragBegan?(event) }
    override func mouseDragged(with event: NSEvent) { onDragMoved?(event) }
    override func mouseUp(with event: NSEvent) { onDragEnded?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.chrome.setFill()
        bounds.fill()
        TermAppearance.border.withAlphaComponent(0.6).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
