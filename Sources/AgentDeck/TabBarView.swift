import AppKit
import TermLayout

// MARK: - 탭 줄·도구 줄·분할 제목이 함께 쓰는 작은 도구(그리는 쪽 전용)

/// 짧은 화면 전환(0 → 1, 감속). 직접 그리는 뷰가 `onTick` 에서 다시 그린다. 동작 줄이기면 움직임 없이 바로 끝난다.
final class ViewTween {
    private var timer: Timer?
    private var startTime: CFTimeInterval = 0
    private var duration: Double = Motion.standard
    private(set) var progress: CGFloat = 1
    var onTick: (() -> Void)?

    /// 감속(ease-out) 을 건 진행 0…1
    var eased: CGFloat { 1 - pow(1 - progress, 3) }
    var isRunning: Bool { timer != nil }

    func run(duration: Double) {
        stop()
        guard !Motion.reduced else {
            progress = 1
            return
        }
        self.duration = duration
        startTime = CACurrentMediaTime()
        progress = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let value = min(1, (CACurrentMediaTime() - startTime) / duration)
        progress = CGFloat(value)
        if value >= 1 { stop() }
        onTick?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 움직임 없이 끝난 상태로
    func settle() {
        stop()
        progress = 1
    }

    deinit { timer?.invalidate() }
}

/// 그리는 중에 두 색을 섞는다(색 이름표는 그리는 모양으로 풀린다). t = 0 → a, 1 → b.
func mixColor(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    guard t > 0 else { return a }
    guard t < 1 else { return b }
    guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return b }
    func lerp(_ p: CGFloat, _ q: CGFloat) -> CGFloat { p + (q - p) * t }
    return NSColor(srgbRed: lerp(x.redComponent, y.redComponent), green: lerp(x.greenComponent, y.greenComponent),
                   blue: lerp(x.blueComponent, y.blueComponent), alpha: lerp(x.alphaComponent, y.alphaComponent))
}

func lerpRect(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
           width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
}

/// SF Symbol 을 글자 두께로 칠해 상자 가운데에 그린다(그리는 뷰 좌표가 뒤집혀 있어도 바로 선다).
enum SymbolDrawing {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)"
        if let cached = cache[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return nil }
        cache[key] = image
        return image
    }

    /// 그린 가로 길이
    @discardableResult
    static func draw(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, centeredIn box: CGRect) -> CGFloat {
        guard let base = image(name, size: size, weight: weight) else { return 0 }
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let rect = CGRect(x: box.midX - base.size.width / 2, y: box.midY - base.size.height / 2,
                          width: base.size.width, height: base.size.height)
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return base.size.width
    }
}

/// 터미널 위 탭 줄. AppKit 으로 직접 그린다. 지금 탭은 화면과 같은 바탕으로 이어 붙이고(위에 2pt 강조 줄), 나머지는 글자만.
final class TabBarView: NSView, NSViewToolTipOwner {
    struct Tab: Equatable {
        var title: String
        var paneCount: Int
        var zoomed: Bool
        /// 탭 안 화면들의 대표 상태(WorkStatus.top). claude 가 없으면 .none 이라 점을 안 그린다.
        var status: WorkStatus = .none
        /// 탭 안 화면 중 권한·승인·샌드박스를 건너뛰는 옵션으로 띄운 것의 설명(풍선 도움말에 ⚠ 로)
        var warning: String?
        /// 제목 앞 아이콘: 탭의 포커스 화면 종류(세션 목록과 같은 판별 — TermModel 줄에서 읽기만 한다)
        var kind: SessionKind = .shell
    }

    /// 상태 점 지름과 제목까지 간격
    private static var dotSize: CGFloat { TermAppearance.scaled(8) }
    private static var dotGap: CGFloat { TermAppearance.scaled(8) }
    /// 종류 아이콘 상자와 제목까지 간격
    private static var iconBox: CGFloat { TermAppearance.scaled(12) }
    private static var iconGap: CGFloat { TermAppearance.scaled(6) }
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

    // 움직임: 탭이 생기고 사라질 때 나머지가 미끄러지고, 지금 탭 표시가 옆 탭으로 미끄러진다
    private let tween = ViewTween()
    private var fromRects: [CGRect] = []
    private var fromAlpha: [CGFloat] = []
    private var fromPlus: CGRect = .zero
    private var fromSelection: CGRect?
    private var ghost: (tab: Tab, rect: CGRect)?
    private var pulseTimer: Timer?
    private var pulseObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        tween.onTick = { [weak self] in self?.needsDisplay = true }
        pulseObserver = NotificationCenter.default.addObserver(forName: WorkingPulse.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
            self?.syncPulse()
        }
    }

    deinit {
        pulseTimer?.invalidate()
        if let pulseObserver { NotificationCenter.default.removeObserver(pulseObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncPulse()
    }

    /// 글꼴 크기 배율이 바뀜: 탭 폭·글꼴을 다시(움직임 없이)
    func scaleChanged() {
        layoutTabs()
        settle()
        needsDisplay = true
    }

    func update(tabs: [Tab], selected: Int?) {
        guard tabs != self.tabs || selected != self.selected else { return }
        let old = self.tabs
        let previousRects = displayRects()
        let previousSelection = currentSelectionRect()
        let previousPlus = displayPlus()
        self.tabs = tabs
        self.selected = selected
        layoutTabs()
        // 끌기·처음 뜰 때·창이 안 보일 때·동작 줄이기에서는 움직임 없이 바로
        let animates = !old.isEmpty && !tabs.isEmpty && drag == nil && window?.isVisible == true && !Motion.reduced
        if animates, let change = Self.change(from: old, to: tabs), previousRects.count == old.count {
            fromRects = change.source.enumerated().map { index, source in source.map { previousRects[$0] } ?? tabRects[index] }
            fromAlpha = change.source.map { $0 == nil ? 0 : 1 }
            ghost = change.removed.map { (old[$0], previousRects[$0]) }
            fromSelection = previousSelection
            fromPlus = previousPlus
            tween.run(duration: Motion.standard)
        } else {
            settle()
        }
        needsDisplay = true
        syncPulse()
    }

    /// 바뀐 모양을 한 번의 끼움·빼기·같은 자리 변화로 풀 수 있으면 (새 탭마다 이전 탭 번호, 빠진 이전 탭 번호). 순서를 바꾼 것 등은 nil(움직임 없음).
    private static func change(from old: [Tab], to new: [Tab]) -> (source: [Int?], removed: Int?)? {
        if new.count == old.count {
            let differing = new.indices.filter { old[$0] != new[$0] }
            return differing.count < 2 ? (new.indices.map { Int?.some($0) }, nil) : nil
        }
        let common = zip(old, new).prefix { $0 == $1 }.count
        if new.count == old.count + 1, Array(old[common...]) == Array(new[(common + 1)...]) {
            return (new.indices.map { $0 < common ? $0 : $0 == common ? nil : $0 - 1 }, nil)
        }
        if new.count == old.count - 1, Array(old[(common + 1)...]) == Array(new[common...]) {
            return (new.indices.map { $0 < common ? $0 : $0 + 1 }, common)
        }
        return nil
    }

    /// 움직임 없이 지금 자리를 그대로
    private func settle() {
        tween.settle()
        fromRects = tabRects
        fromAlpha = Array(repeating: 1, count: tabRects.count)
        fromPlus = plusRect
        fromSelection = nil
        ghost = nil
    }

    private func displayRects() -> [CGRect] {
        guard fromRects.count == tabRects.count else { return tabRects }
        let t = tween.eased
        return tabRects.indices.map { lerpRect(fromRects[$0], tabRects[$0], t) }
    }

    private func displayAlpha(_ index: Int) -> CGFloat {
        guard fromAlpha.indices.contains(index) else { return 1 }
        return fromAlpha[index] + (1 - fromAlpha[index]) * tween.eased
    }

    private func displayPlus() -> CGRect { lerpRect(fromPlus == .zero ? plusRect : fromPlus, plusRect, tween.eased) }

    private func currentSelectionRect() -> CGRect? {
        guard let selected, tabRects.indices.contains(selected) else { return nil }
        guard let fromSelection else { return displayRects()[selected] }
        return lerpRect(fromSelection, tabRects[selected], tween.eased)
    }

    /// 긴 대화 제목은 가운데를 줄인다(탭이 너무 넓어지지 않게)
    static func short(_ title: String, limit: Int = 26) -> String {
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 9)) + "…" + String(title.suffix(8))
    }

    /// 제목은 두께를 늘 같게(고르면 폭이 변하지 않게). 지금 탭 = 으뜸 글자색, 나머지 = 보조 글자색.
    private func titleAttributes(selected isSelected: Bool, hovered: Bool, waiting: Bool) -> [NSAttributedString.Key: Any] {
        let color = isSelected || hovered || waiting ? TermAppearance.textPrimary : TermAppearance.textSecondary
        return [.font: TermAppearance.scaledUIFont(12), .foregroundColor: color]
    }

    private var smallAttributes: [NSAttributedString.Key: Any] {
        [.font: TermAppearance.scaledUIFont(10), .foregroundColor: TermAppearance.textSecondary]
    }

    private func isWaiting(_ tab: Tab) -> Bool {
        if case .waiting = tab.status { return true }
        return false
    }

    /// 점을 그릴 상태(claude 인데 아직 상태를 모르는 것은 종류 아이콘이 이미 알려 주므로 점을 안 둔다)
    private func showsDot(_ status: WorkStatus) -> Bool {
        switch status {
        case .none, .unknown, .codexUnknown: return false
        default: return true
        }
    }

    private func trailing(_ index: Int) -> String? {
        index < 9 ? "⌘\(index + 1)" : nil
    }

    private func tailWidth(_ index: Int) -> CGFloat {
        let text = trailing(index).map { ($0 as NSString).size(withAttributes: smallAttributes).width } ?? 0
        return max(text, ui(12))
    }

    private func badgeWidth(_ tab: Tab) -> CGFloat? {
        guard tab.paneCount > 1 else { return nil }
        return ui(12) + ui(3) + ("\(tab.paneCount)" as NSString).size(withAttributes: smallAttributes).width
    }

    private func layoutTabs() {
        tabRects = []
        closeRects = []
        var x: CGFloat = 0
        let height = bounds.height
        for (index, tab) in tabs.enumerated() {
            var width: CGFloat = ui(12)
            if showsDot(tab.status) { width += Self.dotSize + Self.dotGap }
            width += Self.iconBox + Self.iconGap
            width += (Self.short(tab.title) as NSString).size(withAttributes: titleAttributes(selected: false, hovered: false, waiting: false)).width
            if let badge = badgeWidth(tab) { width += ui(8) + badge }
            let tail = tailWidth(index)
            width += ui(12) + tail + ui(12)
            let rect = CGRect(x: x, y: 0, width: ceil(width), height: height)
            tabRects.append(rect)
            closeRects.append(CGRect(x: rect.maxX - ui(12) - tail - ui(4), y: 0, width: tail + ui(8), height: height))
            x = rect.maxX
        }
        plusRect = CGRect(x: x, y: 0, width: ui(32), height: height)
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
        settle()
    }

    // MARK: - 그리기

    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.chrome.setFill()
        bounds.fill()
        let selection = drag == nil ? currentSelectionRect() : nil
        // 아래 경계: 지금 탭 밑만 비워 화면과 이어 보이게
        TermAppearance.border.setFill()
        if let selection {
            CGRect(x: 0, y: bounds.height - 1, width: max(0, selection.minX), height: 1).fill()
            CGRect(x: selection.maxX, y: bounds.height - 1, width: max(0, bounds.width - selection.maxX), height: 1).fill()
        } else {
            CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
        // 끄는 동안엔 탭을 층(그림)으로 옮겨 그리므로 바탕만
        guard drag == nil else { return }
        if let selection {
            TermAppearance.background.setFill()
            selection.fill()
            TermAppearance.accent.setFill()
            CGRect(x: selection.minX, y: 0, width: selection.width, height: 2).fill()
        }
        let rects = displayRects()
        for (index, tab) in tabs.enumerated() where index < rects.count {
            let rect = rects[index]
            guard rect.intersects(dirtyRect) else { continue }
            drawTab(tab, index: index, rect: rect, alpha: displayAlpha(index))
        }
        if let ghost, tween.isRunning {
            // 닫힌 탭은 Motion.exit 만에 걷힌다
            let fade = 1 - min(1, tween.progress * CGFloat(Motion.standard / Motion.exit))
            if fade > 0 { drawTab(ghost.tab, index: nil, rect: ghost.rect, alpha: fade) }
        }
        // 분할 화면을 끌어 와 탭으로 놓을 틈
        if let insertion, let last = tabRects.last {
            let x = insertion < tabRects.count ? tabRects[insertion].minX : last.maxX
            TermAppearance.accent.setFill()
            CGRect(x: max(0, x - 1), y: 4, width: 2, height: bounds.height - 8).fill()
        }
        let plus = displayPlus()
        if hoveringPlus {
            TermAppearance.chromeRaised.setFill()
            NSBezierPath(roundedRect: CGRect(x: plus.midX - ui(12), y: plus.midY - ui(12), width: ui(24), height: ui(24)),
                         xRadius: 6, yRadius: 6).fill()
        }
        SymbolDrawing.draw("plus", size: ui(11), weight: .semibold,
                           color: hoveringPlus ? TermAppearance.textPrimary : TermAppearance.textSecondary, centeredIn: plus)
    }

    /// 탭 하나. index == nil 이면 닫히는 중인 탭(마우스 상태 없음). alpha < 1 이면 통째로 옅게(생기고 사라질 때).
    private func drawTab(_ tab: Tab, index: Int?, rect: CGRect, alpha: CGFloat) {
        let context = NSGraphicsContext.current?.cgContext
        if alpha < 1 {
            context?.saveGState()
            context?.setAlpha(alpha)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer {
            if alpha < 1 {
                context?.endTransparencyLayer()
                context?.restoreGState()
            }
        }
        let isSelected = index != nil && index == selected
        let isHovered = index != nil && index == hovered
        let waiting = isWaiting(tab)
        var background = TermAppearance.chrome
        if isSelected {
            background = TermAppearance.background
        } else if isHovered {
            background = TermAppearance.chromeRaised
            background.setFill()
            rect.fill()
        }
        // 안 보고 있는 탭이 입력 대기면 바탕을 붉게 물들이고 아래에 붉은 줄(색과 모양 둘 다로 눈에 띄게)
        if !isSelected, waiting {
            TermAppearance.statusAttention.withAlphaComponent(isHovered ? 0.2 : 0.14).setFill()
            rect.fill()
            TermAppearance.statusAttention.setFill()
            CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2).fill()
        }
        var x = rect.minX + ui(12)
        if showsDot(tab.status) {
            tab.status.drawDot(in: CGRect(x: x, y: rect.midY - Self.dotSize / 2, width: Self.dotSize, height: Self.dotSize), cutout: background)
            x += Self.dotSize + Self.dotGap
        }
        tab.kind.drawIcon(size: ui(11), in: CGRect(x: x, y: rect.midY - Self.iconBox / 2, width: Self.iconBox, height: Self.iconBox))
        x += Self.iconBox + Self.iconGap
        let title = Self.short(tab.title) as NSString
        let attributes = titleAttributes(selected: isSelected, hovered: isHovered, waiting: waiting)
        let size = title.size(withAttributes: attributes)
        title.draw(at: CGPoint(x: x, y: rect.midY - size.height / 2), withAttributes: attributes)
        x += size.width
        if tab.paneCount > 1 {
            x += ui(8)
            SymbolDrawing.draw(tab.zoomed ? "arrow.up.left.and.arrow.down.right" : "square.split.2x1", size: ui(10), weight: .regular,
                               color: TermAppearance.textSecondary, centeredIn: CGRect(x: x, y: rect.midY - ui(6), width: ui(12), height: ui(12)))
            let count = "\(tab.paneCount)" as NSString
            let countSize = count.size(withAttributes: smallAttributes)
            count.draw(at: CGPoint(x: x + ui(15), y: rect.midY - countSize.height / 2), withAttributes: smallAttributes)
        }
        // 오른쪽 끝: 평소엔 ⌘숫자, 마우스를 올리면 닫기(×)
        guard let index else { return }
        let tailBox = CGRect(x: rect.maxX - ui(12) - tailWidth(index), y: rect.minY, width: tailWidth(index), height: rect.height)
        if isHovered || trailing(index) == nil {
            SymbolDrawing.draw("xmark", size: ui(9), weight: .semibold,
                               color: isHovered && hoveringClose ? TermAppearance.textPrimary : TermAppearance.textSecondary,
                               centeredIn: tailBox)
        } else if let hint = trailing(index) as NSString? {
            let hintSize = hint.size(withAttributes: smallAttributes)
            hint.draw(at: CGPoint(x: tailBox.midX - hintSize.width / 2, y: rect.midY - hintSize.height / 2), withAttributes: smallAttributes)
        }
        if !isSelected, index + 1 != selected {
            TermAppearance.border.setFill()
            CGRect(x: rect.maxX - 0.5, y: rect.midY - ui(7), width: 1, height: ui(14)).fill()
        }
    }

    /// 작업 중인 탭이 있으면 점만 30fps 로 다시 그려 숨 쉬게 한다(멈춰야 하면 타이머도 멈춤 — WorkingPulse 기준)
    private func syncPulse() {
        let needs = drag == nil && window != nil && WorkingPulse.shared.isRunning && tabs.contains { $0.status == .working }
        if needs, pulseTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.invalidateWorkingDots() }
            RunLoop.main.add(timer, forMode: .common)
            pulseTimer = timer
        } else if !needs, pulseTimer != nil {
            pulseTimer?.invalidate()
            pulseTimer = nil
        }
    }

    private func invalidateWorkingDots() {
        guard drag == nil else { return }
        let rects = displayRects()
        for (index, tab) in tabs.enumerated() where tab.status == .working && index < rects.count {
            setNeedsDisplay(CGRect(x: rects[index].minX + ui(12) - 2, y: rects[index].midY - Self.dotSize, width: Self.dotSize + 4,
                                   height: Self.dotSize * 2))
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
        settle()
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
                tabLayer.borderColor = TermAppearance.accent.cg(in: self)
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
        pulseTimer?.invalidate()
        pulseTimer = nil
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
        syncPulse()
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
