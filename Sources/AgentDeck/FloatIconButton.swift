import AppKit

/// 작은 창 제목 줄·브라우저 머리 줄의 아이콘 버튼: 글자 크기를 따라 커지는 24pt 클릭 자리, 올리면 바탕이 밝아진다(Motion.fast).
final class FloatIconButton: NSButton {
    static var side: CGFloat { TermAppearance.scaled(24) }
    private var sizeConstraints: [NSLayoutConstraint] = []
    private var symbol = ""
    private var hovering = false { didSet { if hovering != oldValue { refreshChrome(animated: true) } } }
    private var pressed = false { didSet { if pressed != oldValue { refreshChrome(animated: true) } } }
    /// 올렸을 때 그림 색(기본 textPrimary). 되돌릴 수 없는 동작(끝내기)은 빨강.
    var hoverTint: NSColor = TermAppearance.textPrimary

    private func refreshChrome(animated: Bool) {
        FloatFx.setColors(of: layer, in: self, background: pressed ? NSColor.palette(.selection) : (hovering ? TermAppearance.chromeRaised : nil),
                          animated: animated)
        contentTintColor = hovering || pressed ? hoverTint : TermAppearance.textSecondary
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChrome(animated: false)
    }

    init(symbol: String, tip: String) {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = TermAppearance.scaled(6)
        contentTintColor = TermAppearance.textSecondary
        toolTip = tip
        setAccessibilityLabel(tip)
        translatesAutoresizingMaskIntoConstraints = false
        sizeConstraints = [widthAnchor.constraint(equalToConstant: Self.side), heightAnchor.constraint(equalToConstant: Self.side)]
        NSLayoutConstraint.activate(sizeConstraints)
        setSymbol(symbol)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String) {
        symbol = name
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: TermAppearance.scaled(12), weight: .medium))
    }

    /// 글꼴 크기 배율이 바뀜: 크기·그림 다시
    func scaleChanged() {
        sizeConstraints.forEach { $0.constant = Self.side }
        layer?.cornerRadius = TermAppearance.scaled(6)
        setSymbol(symbol)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// 누르는 동안 바탕을 한 단계 진하게(동작은 마우스를 뗄 때 — NSButton 그대로)
    override func mouseDown(with event: NSEvent) {
        pressed = true
        super.mouseDown(with: event)
        pressed = false
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// 세션 창 오른쪽 위·아래에 떠 있는 28pt 버튼(🌐·⌨)의 공통 바탕: 터미널 글자 위에 떠 있어 바탕색을 먼저 채우고, 올리면(hover)·눌리면·켜지면
/// `chromeRaised`, 누르면 `selection` 으로(Motion.fast). 알약 안의 그림·글자는 하위 클래스가 `draw` 에서 그린다. 커서는 화살표.
class FloatPillButton: NSView {
    var onClick: (() -> Void)?

    static var height: CGFloat { TermAppearance.scaled(28) }
    static var cornerRadius: CGFloat { TermAppearance.scaled(8) }

    /// 켜짐(작은 창이 열려 있음): 바탕이 한 단계 밝고 그림이 속이 찬다
    var isOn = false { didSet { if isOn != oldValue { refreshChrome(animated: true) } } }
    /// 테두리 색(기본 border). 브라우저는 AI 가 조작 중일 때만 agent.
    var borderTint: NSColor { TermAppearance.border }
    private(set) var hovering = false { didSet { if hovering != oldValue { refreshChrome(animated: true) } } }
    private(set) var pressed = false { didSet { if pressed != oldValue { refreshChrome(animated: true) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 1
        refreshChrome(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 그림·글자 색: 올리거나 눌리거나 켜지면 textPrimary, 평소 textSecondary
    var emphasized: Bool { hovering || pressed || isOn }

    /// 상태가 바뀜(하위 클래스가 속성이 바뀔 때 부른다): 바탕·테두리를 부드럽게, 그림은 다시
    func refreshChrome(animated: Bool = true) {
        let fill = pressed ? NSColor.palette(.selection) : (isOn || hovering ? TermAppearance.chromeRaised : TermAppearance.background)
        FloatFx.setColors(of: layer, in: self, background: fill, border: borderTint, animated: animated && window != nil)
        needsDisplay = true
    }

    /// 글꼴 크기 배율이 바뀜: 모서리·크기를 다시
    func scaleChanged() {
        layer?.cornerRadius = Self.cornerRadius
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChrome(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// 동작은 누르는 즉시(전과 같다), 눌림 모양은 마우스를 뗄 때까지
    override func mouseDown(with event: NSEvent) {
        pressed = true
        onClick?()
        // 눌린 채 밖으로 끌어도 뗄 때까지 모양을 유지한다(mouseUp 이 이 뷰로 온다).
        // 동작이 메뉴·모달을 열어 뗌이 이 뷰로 오지 않았으면 이미 뗀 것이므로 바로 푼다.
        if NSEvent.pressedMouseButtons & 1 == 0 { pressed = false }
    }
    override func mouseUp(with event: NSEvent) { pressed = false }
    /// 뗌이 다른 곳으로 갔다가(뷰가 사라지거나 옮겨짐) 눌림·올림 모양이 남지 않게
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { pressed = false; hovering = false }
    }
    override func viewDidHide() {
        super.viewDidHide()
        pressed = false
        hovering = false
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { toolTip }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// 떠 있는 것들(작은 창·찾기 막대·목록 창)의 짧은 움직임 도우미. 모두 보이는 것만 움직이고(동작은 바로), 동작 줄이기에서는 움직임 없이 바로 바뀐다.
enum FloatFx {
    static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }

    /// 레이어의 바탕·테두리 색을 바꾼다(animated 면 Motion.fast 로 부드럽게). background nil = 투명.
    static func setColors(of layer: CALayer?, in view: NSView, background: NSColor?, border: NSColor? = nil, animated: Bool) {
        guard let layer else { return }
        let bg = background?.cg(in: view)
        let bd = border?.cg(in: view)
        func apply(_ key: String, _ old: CGColor?, _ new: CGColor?) {
            guard animated, !Motion.reduced else { return }
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = layer.presentation().flatMap { key == "backgroundColor" ? $0.backgroundColor : $0.borderColor } ?? old
            animation.toValue = new
            animation.duration = Motion.fast
            animation.timingFunction = timing
            layer.add(animation, forKey: key)
        }
        apply("backgroundColor", layer.backgroundColor, bg)
        layer.backgroundColor = bg
        if border != nil {
            apply("borderColor", layer.borderColor, bd)
            layer.borderColor = bd
        }
    }

    /// 화면에서 위로 가는 쪽이 +인 길이를 레이어 평행 이동 값으로(뷰 좌표가 뒤집혀 있으면 부호가 반대)
    private static func shift(_ dy: CGFloat, in view: NSView) -> CGFloat { (view.superview?.isFlipped ?? false) ? -dy : dy }

    /// 나타남: 투명 → 불투명 + 화면에서 dy 만큼 어긋난 자리에서 제자리로(dy > 0 = 위에서 내려옴, < 0 = 아래에서 올라옴).
    /// 모델 값은 그대로라 끝나면 아무것도 남지 않는다.
    static func fadeIn(_ view: NSView, duration: Double, dy: CGFloat = 0) {
        guard !Motion.reduced, view.window != nil else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = timing
        layer.add(fade, forKey: "floatFadeIn")
        if dy != 0 {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = shift(dy, in: view)
            move.toValue = 0
            move.duration = duration
            move.timingFunction = timing
            layer.add(move, forKey: "floatMoveIn")
        }
    }

    /// 뷰의 지금 모습(그림자 제외)
    static func snapshot(_ view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// 사라짐: 곧 떼어질 뷰의 모습(image)을 같은 자리에 올려 두고 투명해지며 화면에서 dy 만큼(+ = 위로) 밀려난 뒤 지운다(마우스는 통과).
    /// above: 이 뷰 위에 올린다(nil 이면 맨 위).
    static func ghost(_ image: NSImage?, frame: NSRect, in host: NSView, above sibling: NSView?, duration: Double, dy: CGFloat = 0) {
        guard !Motion.reduced, host.window != nil, let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let ghost = FloatGhostView(frame: frame)
        ghost.wantsLayer = true
        ghost.layer?.contents = cg
        ghost.layer?.contentsScale = host.window?.backingScaleFactor ?? 2
        host.addSubview(ghost, positioned: .above, relativeTo: sibling)
        guard let layer = ghost.layer else { ghost.removeFromSuperview(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = timing
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "floatGhostFade")
        if dy != 0 {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = 0
            move.toValue = shift(dy, in: ghost)
            move.duration = duration
            move.timingFunction = timing
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
            layer.add(move, forKey: "floatGhostMove")
        }
        CATransaction.commit()
    }
}

/// 사라지는 동안만 남는 그림(마우스는 아래로 통과)
final class FloatGhostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
