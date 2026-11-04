import AppKit

/// 세션 창 오른쪽 아래의 🌐 버튼: 누르면 세션 창 안 브라우저 칸을 켜고 끈다(⌘⇧B 와 같음).
/// 고른 세션의 브라우저 상태도 여기서 보인다(제목 줄 칩 대신) — 읽을 만한 상태(AI 제어·내가 조작·기다림·넘겨받는 중)면
/// 오른쪽 아래 자리를 지킨 채 왼쪽으로 늘어나 🌐 + 상태 글자 알약, 쉬는 중은 청록 동그라미, 없음은 흐린 회색 동그라미.
final class BrowserToggleButton: NSView {
    /// nil = 그 세션에 떠 있는 브라우저 없음(아직 안 씀·쉬는 중)
    var indicator: BrowserIndicator? {
        didSet { if indicator != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; updateTip() } }
    }
    /// 에이전트가 사용자에게 남긴 결과(abx done --keep)가 있다: "결과 있음" 알약(초록). 기다림·내가 조작 중이면 그 상태가 먼저다.
    var resultBadge = false {
        didSet { if resultBadge != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; updateTip() } }
    }
    /// 브라우저 칸이 열려 있음(버튼을 눌린 모양으로)
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true; updateTip() } } }
    var onClick: (() -> Void)?

    private var hovering = false { didSet { needsDisplay = true } }
    static var size: CGFloat { TermAppearance.scaled(44) }
    private static var globeSide: CGFloat { TermAppearance.scaled(21) }
    private static var labelFont: NSFont { TermAppearance.scaledUIFont(12.5, bold: true) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateTip()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 알약에 적는 상태 글자(nil = 동그라미만): 읽을 만한 상태일 때만. 기다림은 느낌표를 붙인다(색만으로 구분하지 않게).
    private var showsBadge: Bool {
        guard resultBadge else { return false }
        switch indicator {
        case .waiting, .user: return false
        default: return true
        }
    }

    private var statusText: String? {
        if showsBadge { return Self.badgeLabel }
        switch indicator {
        case .agent, .user, .switching: return indicator?.label
        case .waiting: return (indicator?.label ?? "") + " !"
        case .idle, nil: return nil
        }
    }

    private var textWidth: CGFloat {
        statusText.map { ceil(($0 as NSString).size(withAttributes: [.font: Self.labelFont]).width) } ?? 0
    }

    /// 지구본 왼쪽 여백: 동그라미일 때 지구본이 가운데에 오는 값 — 알약이 되어도 지구본은 제자리
    private var leadPad: CGFloat { (Self.size - Self.globeSide) / 2 }

    override var intrinsicContentSize: NSSize {
        guard statusText != nil else { return NSSize(width: Self.size, height: Self.size) }
        return NSSize(width: ceil(leadPad + Self.globeSide + TermAppearance.scaled(7) + textWidth + TermAppearance.scaled(17)),
                      height: Self.size)
    }

    /// 글꼴 크기 배율이 바뀜: 크기를 다시
    func scaleChanged() { invalidateIntrinsicContentSize(); needsDisplay = true }

    static let badgeLabel = "결과 있음"

    private var color: NSColor { showsBadge ? TermAppearance.green : (indicator?.color ?? TermAppearance.textSecondary) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2) // 동그라미 = 폭이 높이와 같은 알약
        let attention = indicator?.needsAttention == true
        TermAppearance.background.setFill()
        shape.fill() // 터미널 글자 위에 떠 있으므로 바탕을 먼저
        color.withAlphaComponent(isOn ? 0.3 : (hovering ? 0.2 : (statusText != nil ? 0.14 : 0.1))).setFill()
        shape.fill()
        color.withAlphaComponent(isOn || hovering || attention ? 1 : (statusText != nil ? 0.7 : 0.45)).setStroke()
        shape.lineWidth = attention ? 1.5 : 1
        shape.stroke()
        let side = Self.globeSide
        if let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side, weight: .semibold)
                .applying(.init(paletteColors: [color.withAlphaComponent(indicator == nil && !isOn ? 0.75 : 1)]))) {
            image.draw(in: NSRect(x: leadPad, y: (bounds.height - side) / 2, width: side, height: side))
        }
        if let text = statusText {
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: leadPad + side + TermAppearance.scaled(7), y: (bounds.height - size.height) / 2),
                                    withAttributes: attributes)
        }
        // 나를 기다림: 오른쪽 위 점
        if attention {
            let dot = TermAppearance.scaled(10)
            TermAppearance.background.setFill()
            // 오른쪽 끝 동그라미의 오른쪽 위(45도) 테두리 위에 놓는다
            let radius = bounds.height / 2
            let cx = bounds.maxX - radius + radius * 0.707, cy = bounds.maxY - radius + radius * 0.707
            NSBezierPath(ovalIn: NSRect(x: cx - dot / 2 - 1, y: cy - dot / 2 - 1, width: dot + 2, height: dot + 2)).fill()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - dot / 2, y: cy - dot / 2, width: dot, height: dot)).fill()
        }
    }

    private func updateTip() {
        let state = showsBadge ? Self.badgeLabel : (indicator?.label ?? "떠 있는 브라우저 없음")
        toolTip = "\(isOn ? "브라우저 칸 닫기" : "브라우저 칸 열기") (⌘⇧B) — \(state)"
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
