import AppKit

/// 터미널 위 탭 줄(herdr 처럼 납작하게, 지금 탭은 강조색으로 칠한다). AppKit 으로 직접 그린다.
final class TabBarView: NSView, NSViewToolTipOwner {
    struct Tab: Equatable {
        var title: String
        var paneCount: Int
        var zoomed: Bool
        /// 탭 안 화면들의 대표 상태(WorkStatus.top). claude 가 없으면 .none 이라 점을 안 그린다.
        var status: WorkStatus = .none
        /// 탭 안 화면 중 권한·승인·샌드박스를 건너뛰는 옵션으로 띄운 것의 설명(풍선 도움말에 ⚠ 로)
        var warning: String?
    }

    /// 상태 점 지름과 제목까지 간격
    private static var dotSize: CGFloat { TermAppearance.scaled(8) }
    private static var dotGap: CGFloat { TermAppearance.scaled(6) }
    /// 배율을 곱한 길이
    private func ui(_ value: CGFloat) -> CGFloat { TermAppearance.scaled(value) }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onRename: ((Int) -> Void)?

    private var tabs: [Tab] = []
    private var selected: Int?
    private var hovered: Int?
    private var hoveringClose = false
    private var hoveringPlus = false
    private var tabRects: [CGRect] = []
    private var closeRects: [CGRect] = []
    private var plusRect: CGRect = .zero

    override var isFlipped: Bool { true }

    /// 글꼴 크기 배율이 바뀜: 탭 폭·글꼴을 다시
    func scaleChanged() {
        layoutTabs()
        needsDisplay = true
    }

    func update(tabs: [Tab], selected: Int?) {
        guard tabs != self.tabs || selected != self.selected else { return }
        self.tabs = tabs
        self.selected = selected
        layoutTabs()
        needsDisplay = true
    }

    /// 긴 대화 제목은 가운데를 줄인다(탭이 너무 넓어지지 않게)
    static func short(_ title: String, limit: Int = 26) -> String {
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 9)) + "…" + String(title.suffix(8))
    }

    private func titleAttributes(_ index: Int) -> [NSAttributedString.Key: Any] {
        let isSelected = index == selected
        // 입력 대기 탭은 붉은 바탕 위라 흐린 글자 대신 밝은 글자로
        var waiting = false
        if tabs.indices.contains(index), case .waiting = tabs[index].status { waiting = true }
        let color = isSelected ? TermAppearance.chrome
            : index == hovered || waiting ? TermAppearance.textPrimary : TermAppearance.textDim
        return [.font: TermAppearance.scaledUIFont(12, bold: isSelected), .foregroundColor: color]
    }

    private func smallAttributes(_ index: Int, alpha: CGFloat) -> [NSAttributedString.Key: Any] {
        let color = index == selected ? TermAppearance.chrome : TermAppearance.textDim
        return [.font: TermAppearance.scaledUIFont(10), .foregroundColor: color.withAlphaComponent(alpha)]
    }

    private func badge(_ tab: Tab) -> String? {
        tab.paneCount > 1 ? (tab.zoomed ? "◫\(tab.paneCount)" : "⊞\(tab.paneCount)") : nil
    }

    private func trailing(_ index: Int) -> String {
        index < 9 ? "⌘\(index + 1)" : "×"
    }

    private func layoutTabs() {
        tabRects = []
        closeRects = []
        var x: CGFloat = 0
        let height = bounds.height
        for (index, tab) in tabs.enumerated() {
            var width: CGFloat = ui(12)
            if tab.status != .none { width += Self.dotSize + Self.dotGap }
            width += (Self.short(tab.title) as NSString).size(withAttributes: titleAttributes(index)).width
            if let badge = badge(tab) {
                width += ui(6) + (badge as NSString).size(withAttributes: smallAttributes(index, alpha: 1)).width
            }
            let tail = max((trailing(index) as NSString).size(withAttributes: smallAttributes(index, alpha: 1)).width, ui(12))
            width += ui(10) + tail + ui(12)
            let rect = CGRect(x: x, y: 0, width: ceil(width), height: height)
            tabRects.append(rect)
            closeRects.append(CGRect(x: rect.maxX - ui(12) - tail - ui(4), y: 0, width: tail + ui(8), height: height))
            x = rect.maxX
        }
        plusRect = CGRect(x: x, y: 0, width: ui(30), height: height)
        // 풍선 도움말: 줄이지 않은 제목(+ 위험한 실행 옵션)
        removeAllToolTips()
        for rect in tabRects { addToolTip(rect, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let index = tabRects.firstIndex(where: { $0.contains(point) }), tabs.indices.contains(index) else { return "" }
        let tab = tabs[index]
        return tab.title + (tab.warning.map { "\n⚠ " + $0 } ?? "")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTabs()
    }

    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.chrome.setFill()
        bounds.fill()
        // 끄는 동안엔 탭을 층(그림)으로 옮겨 그리므로 바탕만
        for (index, tab) in tabs.enumerated() where index < tabRects.count && drag == nil {
            let rect = tabRects[index]
            let isSelected = index == selected
            if isSelected {
                TermAppearance.accent.setFill()
                rect.fill()
            } else if index == hovered {
                TermAppearance.chromeRaised.setFill()
                rect.fill()
            }
            // 안 보고 있는 탭이 입력 대기면 바탕을 붉게 물들이고 아래에 붉은 줄(색과 모양 둘 다로 눈에 띄게)
            if !isSelected, case .waiting = tab.status {
                TermAppearance.red.withAlphaComponent(index == hovered ? 0.26 : 0.18).setFill()
                rect.fill()
                TermAppearance.red.setFill()
                CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2).fill()
            }
            var x = rect.minX + ui(12)
            if tab.status != .none {
                drawDot(tab.status, at: CGPoint(x: x + Self.dotSize / 2, y: rect.midY), onAccent: isSelected)
                x += Self.dotSize + Self.dotGap
            }
            let title = Self.short(tab.title) as NSString
            let attributes = titleAttributes(index)
            let size = title.size(withAttributes: attributes)
            title.draw(at: CGPoint(x: x, y: (rect.height - size.height) / 2), withAttributes: attributes)
            x += size.width
            if let badge = badge(tab) {
                let small = smallAttributes(index, alpha: 0.8)
                let badgeSize = (badge as NSString).size(withAttributes: small)
                (badge as NSString).draw(at: CGPoint(x: x + ui(6), y: (rect.height - badgeSize.height) / 2), withAttributes: small)
            }
            // 오른쪽 끝: 평소엔 ⌘숫자, 마우스를 올리면 닫기(×)
            let closing = index == hovered
            let tail = (closing ? "×" : trailing(index)) as NSString
            var tailAttributes = smallAttributes(index, alpha: closing ? (hoveringClose ? 1 : 0.8) : 0.6)
            if closing { tailAttributes[.font] = TermAppearance.scaledUIFont(13) }
            let tailSize = tail.size(withAttributes: tailAttributes)
            let closeRect = closeRects[index]
            tail.draw(at: CGPoint(x: closeRect.midX - tailSize.width / 2, y: (rect.height - tailSize.height) / 2),
                      withAttributes: tailAttributes)
            if !isSelected, index + 1 != selected {
                TermAppearance.border.withAlphaComponent(0.6).setFill()
                CGRect(x: rect.maxX - 0.5, y: rect.midY - ui(7), width: 1, height: ui(14)).fill()
            }
        }
        // 분할 화면을 끌어 와 탭으로 놓을 틈
        if let insertion, let last = tabRects.last {
            let x = insertion < tabRects.count ? tabRects[insertion].minX : last.maxX
            TermAppearance.accent.setFill()
            CGRect(x: max(0, x - 1.5), y: 3, width: 3, height: bounds.height - 6).fill()
        }
        let plus = "+" as NSString
        let plusAttributes: [NSAttributedString.Key: Any] = [
            .font: TermAppearance.scaledUIFont(14),
            .foregroundColor: hoveringPlus ? TermAppearance.textPrimary : TermAppearance.textDim,
        ]
        let plusSize = plus.size(withAttributes: plusAttributes)
        plus.draw(at: CGPoint(x: plusRect.midX - plusSize.width / 2, y: (plusRect.height - plusSize.height) / 2),
                  withAttributes: plusAttributes)
    }

    /// 상태 점(사이드바와 같은 모양): 쉬는 중은 속 빈 점, 입력 대기는 테두리 두른 점, 오케스트레이션 중은 점선 고리 + 가운데 점, 나머지는 찬 점.
    /// 강조색(지금 탭) 위에서는 바탕색 테두리를 둘러 점이 묻히지 않게 한다.
    private func drawDot(_ status: WorkStatus, at center: CGPoint, onAccent: Bool) {
        let size = Self.dotSize
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let color = status.color
        if onAccent {
            TermAppearance.chrome.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -1.5, dy: -1.5)).fill()
        }
        switch status {
        case .idle:
            color.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            ring.lineWidth = 1.2
            ring.stroke()
        case .waiting:
            color.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        case .orchestrating:
            // 점선 고리 + 가운데 작은 점(사이드바와 같은 모양)
            color.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            ring.lineWidth = 1.2
            ring.setLineDash([1.8, 1.3], count: 2, phase: 0)
            ring.stroke()
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.32, dy: size * 0.32)).fill()
        default:
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    // MARK: - 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = tabRects.firstIndex { $0.contains(point) }
        let close = index.map { closeRects[$0].contains(point) } ?? false
        let plus = plusRect.contains(point)
        guard index != hovered || close != hoveringClose || plus != hoveringPlus else { return }
        hovered = index
        hoveringClose = close
        hoveringPlus = plus
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        hoveringClose = false
        hoveringPlus = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        press = nil
        if plusRect.contains(point) {
            onNew?()
        } else if let index = tabRects.firstIndex(where: { $0.contains(point) }) {
            if closeRects[index].contains(point) {
                onClose?(index)
            } else if event.clickCount == 2 {
                onRename?(index) // 두 번 누르면 이름 바꾸기
            } else {
                // 고르기는 놓을 때(끌면 옮기기 — 다른 탭을 끌어 지금 탭의 분할에 놓을 수 있게 미리 고르지 않는다)
                press = (index, point)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        let point = convert(event.locationInWindow, from: nil)
        if drag == nil {
            guard hypot(point.x - press.point.x, point.y - press.point.y) >= Self.dragThreshold,
                  tabRects.indices.contains(press.index) else { return }
            beginDrag(press.index, grab: press.point.x - tabRects[press.index].minX)
        }
        moveDrag(to: point, window: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        guard let drag else {
            onSelect?(press.index)
            return
        }
        endDrag(drag, window: event.locationInWindow)
    }

    /// 오른쪽 클릭: 이름 바꾸기·탭 닫기
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabRects.firstIndex(where: { $0.contains(point) }) else { return nil }
        let menu = NSMenu()
        menu.addItem(MenuAction(title: "이름 바꾸기…") { [weak self] in self?.onRename?(index) })
        menu.addItem(MenuAction(title: "탭 닫기") { [weak self] in self?.onClose?(index) })
        return menu
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// 창이 뒤에 있어도 첫 클릭으로 바로 고르거나 끌 수 있게(분할 틈과 같게)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 끌어서 옮기기

    /// 이보다 덜 움직이고 놓으면 클릭
    private static let dragThreshold: CGFloat = 4
    /// 탭 줄 안에서 놓음: (탭, 옮긴 뒤 자리)
    var onMove: ((Int, Int) -> Void)?
    /// 탭 줄 밖(분할 영역)으로 끄는 중: 창 좌표, 탭 줄로 돌아오면 nil
    var onDragOutside: ((Int, NSPoint?) -> Void)?
    /// 탭 줄 밖에 놓음(창 좌표)
    var onDropOutside: ((Int, NSPoint) -> Void)?

    private struct Drag {
        var index: Int
        /// 시작할 때 탭 자리(끄는 동안 목록이 새로 와도 이것으로)
        var rects: [CGRect]
        /// 누른 곳이 탭 왼쪽에서 떨어진 거리
        var grab: CGFloat
        /// 탭마다 그림 한 장(다른 탭은 미끄러지듯 비키고 끄는 탭은 마우스를 따라간다)
        var layers: [CALayer]
        var inside = true
        /// 놓으면 갈 자리
        var to: Int
    }

    private var press: (index: Int, point: CGPoint)?
    private var drag: Drag?
    /// 분할 화면을 끌어 와 탭으로 놓을 틈(세로 줄로 보인다)
    private var insertion: Int?

    /// 탭 줄 위로 보는 범위(아래로 조금 벗어나도 순서 바꾸기로 둔다)
    func isInBand(_ windowPoint: NSPoint) -> Bool {
        let point = convert(windowPoint, from: nil)
        return !bounds.isEmpty && point.y >= -8 && point.y <= bounds.maxY + 14
            && point.x >= bounds.minX - 40 && point.x <= bounds.maxX + 40
    }

    /// 그 자리에 놓으면 들어갈 틈(0 = 맨 앞, 탭 수 = 맨 뒤)
    func gap(at windowPoint: NSPoint) -> Int {
        let x = convert(windowPoint, from: nil).x
        return tabRects.filter { $0.midX < x }.count
    }

    func setInsertion(_ gap: Int?) {
        guard gap != insertion else { return }
        insertion = gap
        needsDisplay = true
    }

    /// 시험용: 탭 자리(창 좌표)
    var windowTabRects: [CGRect] { tabRects.map { convert($0, to: nil) } }

    private func snapshot(_ rect: CGRect) -> CGImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }

    private func beginDrag(_ index: Int, grab: CGFloat) {
        hovered = nil
        hoveringClose = false
        hoveringPlus = false
        wantsLayer = true
        let images = tabRects.map(snapshot) // 바탕만 그리기 전에 찍는다
        var layers: [CALayer] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, rect) in tabRects.enumerated() {
            let tabLayer = CALayer()
            tabLayer.frame = rect
            tabLayer.contents = images[i]
            if i == index {
                tabLayer.zPosition = 1
                tabLayer.borderColor = TermAppearance.accent.cgColor
                tabLayer.borderWidth = 1
                tabLayer.shadowOpacity = 0.5
                tabLayer.shadowRadius = 6
                tabLayer.shadowOffset = .zero
            }
            layer?.addSublayer(tabLayer)
            layers.append(tabLayer)
        }
        CATransaction.commit()
        drag = Drag(index: index, rects: tabRects, grab: grab, layers: layers, to: index)
        needsDisplay = true
    }

    private func moveDrag(to point: CGPoint, window: NSPoint) {
        guard var drag else { return }
        let inside = isInBand(window)
        var frames = drag.rects
        if inside {
            let width = drag.rects[drag.index].width
            let end = drag.rects.last?.maxX ?? width
            let x = min(max(point.x - drag.grab, 0), max(0, end - width))
            // 끄는 탭을 뺀 순서에서 가운데가 끄는 탭 가운데보다 왼쪽인 탭 수 = 놓일 자리
            let others = drag.rects.indices.filter { $0 != drag.index }
            var cursor: CGFloat = 0
            var to = 0
            for i in others {
                if cursor + drag.rects[i].width / 2 < x + width / 2 { to += 1 }
                cursor += drag.rects[i].width
            }
            cursor = 0
            for (k, i) in others.enumerated() {
                if k == to { cursor += width }
                frames[i].origin.x = cursor
                cursor += drag.rects[i].width
            }
            frames[drag.index].origin.x = x
            drag.to = to
        }
        // 밖으로 나가면 다른 탭은 제자리로, 끄는 탭은 숨긴다(놓일 곳은 분할 영역 위에 보인다)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        for (i, tabLayer) in drag.layers.enumerated() where i != drag.index { tabLayer.frame = frames[i] }
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drag.layers[drag.index].frame = frames[drag.index]
        drag.layers[drag.index].isHidden = !inside
        CATransaction.commit()
        drag.inside = inside
        self.drag = drag
        onDragOutside?(drag.index, inside ? nil : window)
    }

    private func endDrag(_ drag: Drag, window: NSPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drag.layers.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        self.drag = nil
        needsDisplay = true
        onDragOutside?(drag.index, nil)
        guard drag.rects.count == tabs.count else { return } // 끄는 사이 탭이 열리거나 닫힘
        if !drag.inside {
            onDropOutside?(drag.index, window)
        } else if drag.to != drag.index {
            onMove?(drag.index, drag.to)
        } else {
            onSelect?(drag.index)
        }
    }
}

/// 닫힘 블록으로 동작하는 메뉴 항목
final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
