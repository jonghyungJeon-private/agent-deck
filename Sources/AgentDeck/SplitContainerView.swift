import AppKit
import TermLayout

/// 분할 테두리 제목: 이름과 claude 작업 상태
struct PaneTitle: Equatable {
    var name: String
    var status: WorkStatus = .none
    /// 미리보기 편집기(파일 트리에서 다음 파일을 열면 바뀐다) — 기울인 제목 + "미리보기"
    var preview = false

    /// 테두리에 이름 앞에 붙일 상태(쉬는 중·모름은 붙이지 않는다)
    var statusLabel: String? {
        switch status {
        case .working, .waiting, .done, .orchestrating, .error: return status.label
        default: return nil
        }
    }
}

/// 한 탭의 분할 화면을 배치한다. 나눠져 있으면 herdr 처럼 화면마다 테두리와 제목을 두르고,
/// 포커스된 화면 테두리를 강조색으로 그려 어디에 입력되는지 한눈에 보이게 한다. 화면 사이 틈을 끌어 크기를 바꾼다.
final class SplitContainerView: NSView {
    /// 화면 사이 틈(끌어서 크기 조절하는 곳)
    static let gap: CGFloat = 4
    /// 테두리 안쪽 여백. 위는 제목 줄 자리(제목 글꼴이 배율을 따르므로 함께 커진다).
    static var insetTop: CGFloat { TermAppearance.scaled(18) }
    static var insetSide: CGFloat { TermAppearance.scaled(6) }
    static var insetBottom: CGFloat { TermAppearance.scaled(6) }
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
    /// 화면 제목 줄 오른쪽 위에 다는 것(브라우저 칩). 화면이 하나면 칩이 있을 때만 얇은 제목 줄을 둔다.
    private var chips: [String: NSView] = [:]

    func setChips(_ chips: [String: NSView]) {
        for (id, view) in self.chips where chips[id] !== view { view.removeFromSuperview() }
        let reshaped = Set(self.chips.keys) != Set(chips.keys)
        self.chips = chips
        for view in chips.values { addSubview(view) } // 다시 넣으면 맨 위로(화면 뷰가 덮지 않게)
        needsLayout = true
        if reshaped { needsDisplay = true }
    }

    /// 화면이 하나일 때 칩 자리로 위에 제목 줄을 둘지
    private func strip(_ id: String) -> Bool { !bordered && chips[id] != nil }

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
        for view in chips.values { addSubview(view) }
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

    /// 글꼴 크기 배율이 바뀜: 제목 줄 높이·글꼴을 다시
    func scaleChanged() {
        needsLayout = true
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
                : strip(id) ? CGRect(x: rect.minX, y: rect.minY + Self.insetTop, width: rect.width,
                                     height: max(0, rect.height - Self.insetTop))
                : rect
        }
        // 칩: 제목 줄 오른쪽 끝(나눠져 있으면 위 테두리 선 위에 바탕을 깔고 놓인다)
        for (id, chip) in chips {
            guard let rect = frames[id] else { chip.frame = .zero; continue }
            let size = chip.intrinsicContentSize
            let right = bordered ? Self.insetSide + TermAppearance.scaled(8) : TermAppearance.scaled(8)
            chip.frame = CGRect(x: rect.maxX - right - size.width, y: rect.minY + max(0, (Self.insetTop - size.height) / 2),
                                width: size.width, height: size.height)
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.background.setFill()
        dirtyRect.fill()
        if !bordered {
            // 화면이 하나인데 칩이 있으면: 얇은 제목 줄에 이름(나눈 화면의 제목과 같은 글꼴)
            for (id, rect) in frames where strip(id) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: TermAppearance.scaledUIFont(11), .foregroundColor: TermAppearance.textDim,
                ]
                let name = titles[id]?.name ?? ""
                let size = (name as NSString).size(withAttributes: attributes)
                (name as NSString).draw(at: NSPoint(x: rect.minX + TermAppearance.scaled(10), y: rect.minY + (Self.insetTop - size.height) / 2),
                                        withAttributes: attributes)
            }
            return
        }
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
                .font: TermAppearance.scaledUIFont(11, bold: isFocused),
                .foregroundColor: isFocused ? TermAppearance.accent : TermAppearance.textDim,
            ]
            let paneTitle = titles[id]
            let title = NSMutableAttributedString(string: " ", attributes: attributes)
            if let paneTitle, let label = paneTitle.statusLabel {
                title.append(NSAttributedString(string: label, attributes: [
                    .font: TermAppearance.scaledUIFont(11, bold: true), .foregroundColor: paneTitle.status.color,
                ]))
                title.append(NSAttributedString(string: " · ", attributes: attributes))
            }
            if paneTitle?.preview == true {
                // 미리보기: 이름을 기울이고 뒤에 작게 "미리보기"(VS Code 처럼). 고치거나 제목을 두 번 누르면 고정된다.
                var italic = attributes
                italic[.font] = TermAppearance.scaledUIFont(11, bold: isFocused, italic: true)
                title.append(NSAttributedString(string: paneTitle?.name ?? "", attributes: italic))
                title.append(NSAttributedString(string: "  미리보기 ", attributes: [
                    .font: TermAppearance.scaledUIFont(10), .foregroundColor: TermAppearance.textDim,
                ]))
            } else {
                title.append(NSAttributedString(string: "\(paneTitle?.name ?? "") ", attributes: attributes))
            }
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
        let point = convert(event.locationInWindow, from: nil)
        titlePress = nil
        guard let divider = divider(at: point), let window else {
            titlePress = titlePane(at: point).map { ($0, point) }
            // 미리보기 제목을 두 번 누르면 고정
            if event.clickCount == 2, let pane = titlePress?.pane, titles[pane]?.preview == true { onPin?(pane) }
            return
        }
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

    // MARK: - 제목 줄을 끌어 화면 옮기기

    /// 이보다 덜 움직이면 끌기가 아니다
    private static let dragThreshold: CGFloat = 4
    /// 화면을 끄는 중(창 좌표). 놓았으면 마지막 값이 true.
    var onPaneDrag: ((String, NSPoint, Bool) -> Void)?
    /// 제목 오른쪽 클릭 > 새 탭으로 꺼내기
    var onExtract: ((String) -> Void)?
    /// 미리보기 고정(제목 두 번 누르기·오른쪽 클릭 "고정")
    var onPin: ((String) -> Void)?
    private var titlePress: (pane: String, point: NSPoint)?
    private var titleDragging = false

    /// 분할 테두리 제목 줄 위의 화면(나눠져 있을 때만 제목이 있다)
    private func titlePane(at point: NSPoint) -> String? {
        guard bordered else { return nil }
        return frames.first { $0.value.contains(point) && point.y < $0.value.minY + Self.insetTop }?.key
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = titlePress else { return }
        if !titleDragging {
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - press.point.x, point.y - press.point.y) >= Self.dragThreshold else { return }
            titleDragging = true
        }
        onPaneDrag?(press.pane, event.locationInWindow, false)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            titlePress = nil
            titleDragging = false
        }
        guard let press = titlePress, titleDragging else { return }
        onPaneDrag?(press.pane, event.locationInWindow, true)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let pane = titlePane(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let menu = NSMenu()
        if titles[pane]?.preview == true {
            menu.addItem(MenuAction(title: "고정 (미리보기 끝내기)") { [weak self] in self?.onPin?(pane) })
        }
        menu.addItem(MenuAction(title: "새 탭으로 꺼내기") { [weak self] in self?.onExtract?(pane) })
        return menu
    }

    /// 놓을 곳: 가리킨 화면에서 가장 가까운 가장자리 쪽. rect 는 그 쪽 절반(이 뷰 좌표).
    func dropZone(at windowPoint: NSPoint) -> (pane: String, direction: Direction, rect: CGRect)? {
        let point = convert(windowPoint, from: nil)
        guard let (id, rect) = frames.first(where: { $0.value.contains(point) }) else { return nil }
        let fx = (point.x - rect.minX) / max(rect.width, 1)
        let fy = (point.y - rect.minY) / max(rect.height, 1)
        let edges: [(Direction, CGFloat)] = [(.left, fx), (.right, 1 - fx), (.up, fy), (.down, 1 - fy)]
        let direction = edges.min { $0.1 < $1.1 }?.0 ?? .right
        var zone = rect.insetBy(dx: 3, dy: 3)
        switch direction {
        case .left: zone.size.width /= 2
        case .right: zone.origin.x += zone.width / 2; zone.size.width /= 2
        case .up: zone.size.height /= 2
        case .down: zone.origin.y += zone.height / 2; zone.size.height /= 2
        }
        return (id, direction, zone)
    }

    /// 화면 자리(이 뷰 좌표)
    func paneFrame(_ id: String) -> CGRect? { frames[id] }
}
