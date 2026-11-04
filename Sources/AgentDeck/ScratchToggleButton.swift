import AppKit

/// 세션 창 오른쪽 아래, 🌐 버튼 왼쪽의 ⌨ 버튼: 누르면 고른 세션의 작은 터미널 창을 켜고 끈다(⌃`).
/// 열려 있으면 속이 찬 모양, 창을 닫아 둔 채 명령이 돌고 있으면 오른쪽 위에 점.
final class ScratchToggleButton: NSView {
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true; updateTip() } } }
    /// 닫아 둔 작은 터미널에서 명령이 돌고 있음(앞에서 도는 프로그램이 셸이 아님)
    var busy = false { didSet { if busy != oldValue { needsDisplay = true; updateTip() } } }
    var onClick: (() -> Void)?

    private var hovering = false { didSet { needsDisplay = true } }
    static var size: CGFloat { TermAppearance.scaled(44) }
    private static var symbolSide: CGFloat { TermAppearance.scaled(20) }
    private var color: NSColor { TermAppearance.textSecondary }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateTip()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    /// 글꼴 크기 배율이 바뀜: 크기를 다시
    func scaleChanged() { invalidateIntrinsicContentSize(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(ovalIn: rect)
        let tint = isOn ? TermAppearance.accent : color
        TermAppearance.background.setFill()
        shape.fill() // 터미널 글자 위에 떠 있으므로 바탕을 먼저
        tint.withAlphaComponent(isOn ? 0.3 : (hovering ? 0.2 : 0.1)).setFill()
        shape.fill()
        tint.withAlphaComponent(isOn || hovering ? 1 : 0.45).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let side = Self.symbolSide
        if let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side, weight: .semibold)
                .applying(.init(paletteColors: [tint.withAlphaComponent(isOn || hovering ? 1 : 0.8)]))) {
            let size = image.size
            image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        if busy {
            let dot = TermAppearance.scaled(10)
            let radius = bounds.height / 2
            let cx = bounds.maxX - radius + radius * 0.707, cy = bounds.maxY - radius + radius * 0.707
            TermAppearance.background.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - dot / 2 - 1, y: cy - dot / 2 - 1, width: dot + 2, height: dot + 2)).fill()
            TermAppearance.agentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - dot / 2, y: cy - dot / 2, width: dot, height: dot)).fill()
        }
    }

    private func updateTip() {
        toolTip = "작은 터미널 (⌃`)" + (busy && !isOn ? " — 명령 실행 중" : "")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { toolTip }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
