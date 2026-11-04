import AppKit

/// 작은 창 제목 줄·브라우저 머리 줄의 아이콘 버튼: 글자 크기를 따라 커지는 24pt 클릭 자리, 올리면 바탕이 밝아진다.
final class FloatIconButton: NSButton {
    static var side: CGFloat { TermAppearance.scaled(24) }
    private var sizeConstraints: [NSLayoutConstraint] = []
    private var symbol = ""
    private var hovering = false { didSet { refreshHoverColor() } }

    private func refreshHoverColor() { layer?.backgroundColor = hovering ? TermAppearance.chromeRaised.cg(in: self) : nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshHoverColor()
    }

    init(symbol: String, tip: String) {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 5
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
        setSymbol(symbol)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; contentTintColor = TermAppearance.textPrimary }
    override func mouseExited(with event: NSEvent) { hovering = false; contentTintColor = TermAppearance.textSecondary }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
