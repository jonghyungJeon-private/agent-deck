import AppKit

/// 탭·분할 화면을 끄는 동안 터미널 영역 위에 덮는 그림(마우스는 그대로 아래로 통과).
/// 놓일 곳(강조색 반투명 — Ghostty·IntelliJ 식 절반), 옮겨 가는 화면(어둡게), 끄는 것의 이름표.
final class DropOverlayView: NSView {
    private var zone: CGRect?
    private var source: CGRect?
    private var chip: (title: String, point: CGPoint)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(zone: CGRect?, source: CGRect?, chip title: String, at point: CGPoint) {
        let before = dirtyRect
        self.zone = zone
        self.source = source
        chip = (title, point)
        isHidden = false
        setNeedsDisplay(before.union(dirtyRect))
    }

    func clear() {
        guard !isHidden else { return }
        zone = nil
        source = nil
        chip = nil
        isHidden = true
    }

    /// 배율을 따라가도록 그릴 때마다 만든다
    private static var chipAttributes: [NSAttributedString.Key: Any] {
        [.font: TermAppearance.scaledUIFont(11, bold: true), .foregroundColor: TermAppearance.textPrimary]
    }

    private var chipRect: CGRect? {
        guard let chip else { return nil }
        let size = (TabBarView.short(chip.title) as NSString).size(withAttributes: Self.chipAttributes)
        let width = ceil(size.width) + 16, height = ceil(size.height) + 6
        return CGRect(x: min(chip.point.x + 14, bounds.maxX - width - 2), y: min(chip.point.y + 10, bounds.maxY - height - 2),
                      width: width, height: height)
    }

    /// 다시 그릴 곳(끄는 동안 매번 전체를 그리지 않게)
    private var dirtyRect: CGRect {
        [zone, source, chipRect].compactMap { $0?.insetBy(dx: -3, dy: -3) }.reduce(CGRect.null) { $0.union($1) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let source {
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: source, xRadius: 4, yRadius: 4).fill()
        }
        if let zone {
            let path = NSBezierPath(roundedRect: zone, xRadius: 5, yRadius: 5)
            TermAppearance.accent.withAlphaComponent(0.22).setFill()
            path.fill()
            path.lineWidth = 2
            TermAppearance.accent.setStroke()
            path.stroke()
        }
        if let chip, let rect = chipRect {
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            TermAppearance.chromeRaised.setFill()
            path.fill()
            TermAppearance.accent.setStroke()
            path.stroke()
            (TabBarView.short(chip.title) as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 3),
                                                           withAttributes: Self.chipAttributes)
        }
    }
}
