import AppKit
import TermLayout

/// 분할 테두리 제목: 이름과 claude 작업 상태
struct PaneTitle: Equatable {
    var name: String
    var status: WorkStatus = .none

    /// 테두리에 이름 앞에 붙일 상태(쉬는 중·모름은 붙이지 않는다)
    var statusLabel: String? {
        switch status {
        case .working, .waiting, .done, .error: return status.label
        default: return nil
        }
    }
}

/// 한 탭의 분할 화면을 배치한다. 나눠져 있으면 herdr 처럼 화면마다 테두리와 제목을 두르고,
/// 포커스된 화면 테두리를 강조색으로 그려 어디에 입력되는지 한눈에 보이게 한다. 화면 사이 틈을 끌어 크기를 바꾼다.
final class SplitContainerView: NSView {
    /// 화면 사이 틈(끌어서 크기 조절하는 곳)
    static let gap: CGFloat = 4
    /// 테두리 안쪽 여백. 위는 제목 줄 자리.
    static let insetTop: CGFloat = 18
    static let insetSide: CGFloat = 6
    static let insetBottom: CGFloat = 6
    /// 틈 양쪽으로 더 잡히는 폭
    static let grab: CGFloat = 2

    override var isFlipped: Bool { true }

    private(set) var tree: SplitNode?
    private var paneViews: [String: NSView] = [:]
    private var titles: [String: PaneTitle] = [:]
    private var focused: String?
    private var frames: [String: CGRect] = [:]
    private var dividers: [SplitNode.Divider] = []
    /// 선을 끌었을 때 (갈래 위치, 새 비율)
    var onRatioChange: (([Bool], Double) -> Void)?

    private var bordered: Bool { paneViews.count > 1 }

    func update(tree: SplitNode?, views: [String: NSView], focused: String?, titles: [String: PaneTitle]) {
        self.tree = tree
        self.focused = focused
        self.titles = titles
        for (id, view) in paneViews where views[id] !== view {
            view.removeFromSuperview()
        }
        for view in views.values where view.superview !== self {
            addSubview(view)
        }
        paneViews = views
        needsLayout = true
        layoutSubtreeIfNeeded()
        needsDisplay = true
    }

    func setFocused(_ id: String?, titles: [String: PaneTitle]) {
        guard focused != id || self.titles != titles else { return }
        focused = id
        self.titles = titles
        needsDisplay = true
    }

    func paneId(at windowPoint: NSPoint) -> String? {
        let point = convert(windowPoint, from: nil)
        return frames.first { $0.value.contains(point) }?.key
    }

    override func layout() {
        super.layout()
        guard let tree else {
            frames = [:]
            dividers = []
            return
        }
        let result = tree.layout(in: bounds, divider: bordered ? Self.gap : 0)
        frames = result.panes
        dividers = result.dividers
        for (id, view) in paneViews {
            guard let rect = frames[id] else {
                view.frame = .zero
                continue
            }
            view.frame = bordered
                ? CGRect(x: rect.minX + Self.insetSide, y: rect.minY + Self.insetTop,
                         width: max(0, rect.width - Self.insetSide * 2),
                         height: max(0, rect.height - Self.insetTop - Self.insetBottom))
                : rect
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.background.setFill()
        dirtyRect.fill()
        guard bordered else { return }
        // 포커스 화면을 마지막에 그려 겹치는 데가 강조색으로 보이게
        let order = frames.keys.filter { $0 != focused } + frames.keys.filter { $0 == focused }
        for id in order {
            guard let rect = frames[id] else { continue }
            let isFocused = id == focused
            let color = isFocused ? TermAppearance.accent : TermAppearance.border
            let box = rect.insetBy(dx: 1.5, dy: 0).offsetBy(dx: 0, dy: Self.insetTop / 2)
            let frame = CGRect(x: box.minX, y: box.minY, width: box.width,
                               height: max(0, rect.maxY - box.minY - Self.insetBottom / 2))
            let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
            path.lineWidth = isFocused ? 1.5 : 1
            color.setStroke()
            path.stroke()
            // 제목: 위 테두리 위에 바탕을 깔고 쓴다(herdr 처럼 ─ 제목 ───)
            // 상태가 있으면 "입력 대기 · 이름" 처럼 앞에 상태를 그 색(굵게)으로 붙인다
            let attributes: [NSAttributedString.Key: Any] = [
                .font: TermAppearance.uiFont(11, bold: isFocused),
                .foregroundColor: isFocused ? TermAppearance.accent : TermAppearance.textDim,
            ]
            let paneTitle = titles[id]
            let title = NSMutableAttributedString(string: " ", attributes: attributes)
            if let paneTitle, let label = paneTitle.statusLabel {
                title.append(NSAttributedString(string: label, attributes: [
                    .font: TermAppearance.uiFont(11, bold: true), .foregroundColor: paneTitle.status.color,
                ]))
                title.append(NSAttributedString(string: " · ", attributes: attributes))
            }
            title.append(NSAttributedString(string: "\(paneTitle?.name ?? "") ", attributes: attributes))
            let size = title.size()
            let maxWidth = max(0, frame.width - 24)
            let titleRect = CGRect(x: frame.minX + 10, y: frame.minY - size.height / 2,
                                   width: min(size.width, maxWidth), height: size.height)
            TermAppearance.background.setFill()
            titleRect.fill()
            title.draw(with: titleRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }
    }

    // MARK: - 틈 끌기

    private func divider(at point: NSPoint) -> SplitNode.Divider? {
        // 틈 위를 정확히 누른 것을 먼저, 없으면 잡는 폭을 넓혀 안쪽 갈래(작은 영역)부터
        dividers.reversed().first { $0.rect.contains(point) }
            ?? dividers.reversed().first { $0.rect.insetBy(dx: -Self.grab, dy: -Self.grab).contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local), divider(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        for divider in dividers {
            addCursorRect(divider.rect.insetBy(dx: -Self.grab, dy: -Self.grab),
                          cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    /// 창이 뒤에 있어도 첫 클릭으로 바로 끌 수 있게
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 틈을 누르면 놓을 때까지 직접 따라간다(끄는 동안 터미널이 이벤트를 가져가지 않게)
    override func mouseDown(with event: NSEvent) {
        guard let divider = divider(at: convert(event.locationInWindow, from: nil)), let window else { return }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            drag(divider, to: convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
        }
    }

    private func drag(_ divider: SplitNode.Divider, to point: NSPoint) {
        let parent = divider.parent
        let gap = Self.gap
        let ratio: Double
        if divider.axis == .horizontal {
            ratio = (point.x - parent.minX - gap / 2) / max(parent.width - gap, 1)
        } else {
            ratio = (point.y - parent.minY - gap / 2) / max(parent.height - gap, 1)
        }
        onRatioChange?(divider.path, ratio)
    }
}
