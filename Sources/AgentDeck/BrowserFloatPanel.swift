import AppKit
import TermLayout

/// 세션 창 안에 떠 있는 작은 브라우저 창: 얇은 제목 줄(🌐 제목 · 크게 · ✕) + 브라우저 도구 내용.
/// 제목 줄을 끌면 옮기고, 가장자리·모서리를 끌면 크기를 바꾼다. 자리는 호스트(부모 뷰) 좌표 frame 으로 다루고,
/// 사람이 끌기를 마치면 `onFrameChanged` 로 알린다(저장은 ToolWindowsController).
final class BrowserFloatPanel: NSView {
    var onFrameChanged: ((NSRect) -> Void)?
    var onClose: (() -> Void)?
    var onToggleSize: (() -> Void)?
    /// 끌기(옮기기·크기 바꾸기) 시작·끝 — 끄는 동안 브라우저 페이지 크기는 맞추지 않는다(끝에서 한 번)
    var onGestureBegan: (() -> Void)?
    var onGestureEnded: (() -> Void)?

    /// 크기 바꾸기를 잡는 가장자리 두께
    static let edge: CGFloat = 6
    static var stripHeight: CGFloat { TermAppearance.scaled(26) }

    private let clip = NSView()
    private let strip = FloatTitleStrip()
    private let container = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sizeButton = NSButton(title: "크게", target: nil, action: nil)
    private var content: NSView?

    private enum Drag {
        case move
        case resize(left: Bool, right: Bool, bottom: Bool, top: Bool)
    }
    private var drag: Drag?
    private var dragOrigin = NSPoint.zero
    private var dragFrame = NSRect.zero
    private var edgeCursorShown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 10
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1
        clip.layer?.borderColor = TermAppearance.border.cgColor
        clip.layer?.backgroundColor = TermAppearance.background.cgColor
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
        sizeButton.target = self
        sizeButton.action = #selector(sizeClicked)
        Self.style(sizeButton)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "닫기") ?? NSImage(),
                             target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.contentTintColor = TermAppearance.textDim
        close.toolTip = "작은 창 닫기 (⌘⇧B 로 다시)"
        sizeButton.toolTip = "작은 창 크기 바꾸기"
        let row = NSStackView(views: [titleLabel, sizeButton, close])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(row)

        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.topAnchor.constraint(equalTo: clip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: Self.stripHeight),
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

    private static func style(_ button: NSButton) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = TermAppearance.scaledUIFont(10.5)
        button.contentTintColor = TermAppearance.textSecondary
    }

    func setTitle(_ text: String) { titleLabel.stringValue = text }
    func setLarge(_ large: Bool) { sizeButton.title = large ? "작게" : "크게" }
    var hasContent: Bool { content?.superview === container }

    /// 브라우저 도구 내용을 단다(nil = 뗀다). 다른 곳(옆 도크: 시험 명령)에 붙어 있었으면 거기서 먼저 뗀다.
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
            let minSize = BrowserFloatFrame.minSize
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
        onFrameChanged?(frame)
        layoutSubtreeIfNeeded() // 안쪽 화면이 마지막 크기로 자리 잡은 뒤 페이지를 맞추게
        onGestureEnded?()
    }

    // MARK: - 크기 바꾸기 커서

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = edges(at: point) {
            let diagonal = (hit.left || hit.right) && (hit.bottom || hit.top)
            let cursor: NSCursor = diagonal ? .crosshair : (hit.left || hit.right ? .resizeLeftRight : .resizeUpDown)
            cursor.set()
            edgeCursorShown = true
        } else if edgeCursorShown {
            NSCursor.arrow.set()
            edgeCursorShown = false
        }
    }

    override func mouseExited(with event: NSEvent) { edgeCursorShown = false }
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

    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.chrome.setFill()
        bounds.fill()
        TermAppearance.border.withAlphaComponent(0.6).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
