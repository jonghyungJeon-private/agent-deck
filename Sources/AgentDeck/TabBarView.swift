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
    private static var tintedCache: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)"
        if let cached = cache[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return nil }
        cache[key] = image
        return image
    }

    /// 칠한 그림(기호 + 현재 모양에서 풀린 색마다 한 장 — 그릴 때마다 새로 만들지 않는다)
    private static func tinted(_ base: NSImage, key: String, color: NSColor) -> NSImage {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let full = "\(key)|\(resolved.redComponent),\(resolved.greenComponent),\(resolved.blueComponent),\(resolved.alphaComponent)"
        if let cached = tintedCache[full] { return cached }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        if tintedCache.count > 200 { tintedCache.removeAll() }
        tintedCache[full] = image
        return image
    }

    /// 그린 가로 길이. `fit` 이면 상자보다 큰 기호는 가로세로 비율을 지킨 채 상자에 들어가게 줄여 그린다(‹› 처럼 가로로 넓은 기호).
    @discardableResult
    static func draw(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, centeredIn box: CGRect,
                     fit: Bool = false) -> CGFloat {
        guard let base = image(name, size: size, weight: weight) else { return 0 }
        let tinted = tinted(base, key: "\(name)|\(size)|\(weight.rawValue)", color: color)
        var drawSize = base.size
        if fit, drawSize.width > 0, drawSize.height > 0 {
            let scale = min(1, box.width / drawSize.width, box.height / drawSize.height)
            drawSize = CGSize(width: drawSize.width * scale, height: drawSize.height * scale)
        }
        let rect = CGRect(x: box.midX - drawSize.width / 2, y: box.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return drawSize.width
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
        /// 탭 식별(탭 순서가 바뀌거나 탭이 닫혀도 같은 탭을 가리킨다 — ⌄ 메뉴가 쓴다)
        var id: String = ""
        /// 고른 화면의 폴더(⌄ 메뉴에서 같은 이름의 탭을 가른다). 홈은 ~ 로 줄인 글.
        var folder: String = ""
    }

    /// 상태 점 지름과 제목까지 간격
    private static var dotSize: CGFloat { TermAppearance.scaled(8) }
    private static var dotGap: CGFloat { TermAppearance.scaled(8) }
    /// 종류 아이콘 상자(가로 14 × 세로 12 — ✻·셸·‹› 가 같은 상자에 맞춰 그려진다)와 제목까지 간격
    static var iconBoxWidth: CGFloat { TermAppearance.scaled(14) }
    static var iconBoxHeight: CGFloat { TermAppearance.scaled(12) }
    static var iconGap: CGFloat { TermAppearance.scaled(6) }
    /// 제목을 줄이는 한계(이보다 좁아지지는 않는다 — 더 안 들어가면 ⌄ 메뉴로 보낸다)
    private static var minTitleWidth: CGFloat { TermAppearance.scaled(24) }
    /// 탭을 ⌄ 로 보내기 전까지 제목을 줄여 두는 폭(이보다 좁은 제목은 이름을 알아볼 수 없어 탭을 덜 보이는 쪽을 고른다)
    private static var comfortTitleWidth: CGFloat { TermAppearance.scaled(48) }
    /// "+" 와 ⌄ 단추 폭
    private var plusWidth: CGFloat { ui(32) }
    private var overflowWidth: CGFloat { ui(28) }
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
    /// 안 들어가는 탭을 모아 보이는 ⌄ 단추 자리(다 들어가면 .zero). 안 보이는 탭의 `tabRects` 는 폭 0 이다(왼쪽에 숨으면 맨 앞, 오른쪽에 숨으면 보이는 끝).
    private var overflowRect: CGRect = .zero
    private var hiddenTabs: [Int] = []
    /// 지난번에 보인 탭 구간의 첫 탭(구간이 제멋대로 되돌아가지 않게 — TabBarFit.visibleRange)
    private var visibleStart: Int?
    private var hoveringOverflow = false
    private var overflowMenuOpen = false

    // 움직임: 탭이 생기고 사라질 때 나머지가 미끄러지고, 지금 탭 표시가 옆 탭으로 미끄러진다
    private let tween = ViewTween()
    private var fromRects: [CGRect] = []
    private var fromAlpha: [CGFloat] = []
    private var fromPlus: CGRect = .zero
    private var fromSelection: CGRect?
    private var ghost: (tab: Tab, rect: CGRect)?
    /// 작업 중인 탭의 점 레이어(GPU 가 숨 쉬게 한다 — 점이 숨 쉬는 동안 탭 줄을 다시 그리지 않는다)
    private var dotLayers: [CALayer] = []
    private var pulseObserver: NSObjectProtocol?
    /// 탭마다 줄이지 않은 제목 폭과 줄인 뒤의 폭(오른쪽 여백 때문에 좁을 때만 다르다)
    private var titleWidths: [CGFloat] = []
    /// 끌기용 그림을 찍는 동안: 작업 중 점을 그림에 칠한다(평소엔 레이어가 그린다)
    private var paintsWorkingDots = false

    /// 탭 줄 오른쪽에서 비워 둘 폭: 오른쪽 위 구석의 🌐·⌨ 알약이 탭 줄 안에 있을 때 그 폭(없으면 0).
    /// 탭과 "+" 는 이 안쪽에만 놓이고, 안 들어가면 제목을 줄인다.
    var trailingReserve: CGFloat = 0 {
        didSet {
            guard trailingReserve != oldValue else { return }
            relayoutAnimated()
        }
    }
    /// 탭 줄 왼쪽에서 비워 둘 폭: 창 제목 줄과 합쳐졌을 때 신호등(●●●)이 이 줄 위에 있으면 그 폭(사이드바가 왼쪽에 있으면 0).
    /// 탭과 "+" 는 이 오른쪽에서 시작한다. 이 안쪽 빈 곳은 창을 끄는 자리다.
    var leadingInset: CGFloat = 0 {
        didSet {
            guard leadingInset != oldValue else { return }
            relayoutAnimated()
        }
    }
    /// 가장 좁게 줄였을 때 필요한 폭: 신호등 자리 + 탭 하나(제목 최소) + "+" (탭이 더 있으면 ⌄ 도) — 이보다 좁으면 알약을 탭 줄 안에 둘 수 없다.
    /// 나머지 탭은 ⌄ 메뉴가 맡으므로 탭이 많아도 이 폭은 늘지 않는다.
    private(set) var minimumContentWidth: CGFloat = 0
    /// `minimumContentWidth` 가 바뀜(탭이 생기고 사라짐·제목·배율)
    var onContentChanged: (() -> Void)?
    /// 탭과 "+" 를 놓을 수 있는 폭
    private var contentWidth: CGFloat { max(0, bounds.width - trailingReserve) }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        tween.onTick = { [weak self] in
            self?.needsDisplay = true
            self?.syncDotLayers()
        }
        wantsLayer = true
        pulseObserver = NotificationCenter.default.addObserver(forName: WorkingPulse.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.syncDotLayers()
        }
    }

    deinit {
        if let pulseObserver { NotificationCenter.default.removeObserver(pulseObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDotLayers()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncDotLayers()
    }

    /// 글꼴 크기 배율이 바뀜: 탭 폭·글꼴을 다시(움직임 없이)
    func scaleChanged() {
        layoutTabs()
        settle()
        needsDisplay = true
        syncDotLayers()
    }

    /// 오른쪽 여백이 바뀜(알약이 늘거나 줄어듦): 탭이 미끄러져 새 폭에 맞는다(움직임 없이 해야 하면 바로)
    private func relayoutAnimated() {
        guard !tabs.isEmpty else { layoutTabs(); settle(); return }
        let previousRects = displayRects()
        let previousSelection = currentSelectionRect()
        let previousPlus = displayPlus()
        layoutTabs()
        if drag == nil, window?.isVisible == true, !Motion.reduced, previousRects.count == tabRects.count {
            fromRects = previousRects
            fromAlpha = Array(repeating: 1, count: tabRects.count)
            fromPlus = previousPlus
            fromSelection = previousSelection
            ghost = nil
            tween.run(duration: Motion.standard)
        } else {
            settle()
        }
        needsDisplay = true
        syncDotLayers()
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
        syncDotLayers()
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

    /// 제목은 두께를 늘 같게(고르면 폭이 변하지 않게). 지금 탭 = 으뜸 글자색, 나머지 = 보조 글자색. 입력 대기도 점만 다르다(탭 모양은 그대로).
    private func titleAttributes(selected isSelected: Bool, hovered: Bool, truncating: Bool = false) -> [NSAttributedString.Key: Any] {
        let color = isSelected || hovered ? TermAppearance.textPrimary : TermAppearance.textSecondary
        var attributes: [NSAttributedString.Key: Any] = [.font: TermAppearance.scaledUIFont(12), .foregroundColor: color]
        if truncating {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
        }
        return attributes
    }

    private var smallAttributes: [NSAttributedString.Key: Any] {
        [.font: TermAppearance.scaledUIFont(10), .foregroundColor: TermAppearance.textSecondary]
    }

    /// 점을 그릴 상태(상태가 없는 셸·아직 모르는 claude 는 종류 아이콘이 이미 알려 주므로 점을 안 둔다)
    private func showsDot(_ status: WorkStatus) -> Bool { status.dotShape != nil }

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
        var fixed: [Double] = [], natural: [Double] = []
        for (index, tab) in tabs.enumerated() {
            var width: CGFloat = ui(12)
            if showsDot(tab.status) { width += Self.dotSize + Self.dotGap }
            width += Self.iconBoxWidth + Self.iconGap
            if let badge = badgeWidth(tab) { width += ui(8) + badge }
            width += ui(12) + tailWidth(index) + ui(12)
            fixed.append(Double(width))
            natural.append(Double(ceil((Self.short(tab.title) as NSString).size(withAttributes: titleAttributes(selected: false, hovered: false)).width)))
        }
        let minTitle = Double(Self.minTitleWidth)
        // 줄어드는 한계는 minTitle 이지만, 탭을 ⌄ 로 보낼지는 알아볼 수 있는 폭(comfortTitleWidth)으로 가른다
        let minWidths = zip(fixed, natural).map { $0 + min($1, Double(Self.comfortTitleWidth)) }
        // 탭이 시작하는 곳부터 알약 자리 앞까지 = 탭·"+"(·⌄)를 놓을 수 있는 폭
        let room = bounds.width > 0 ? max(0, contentWidth - leadingInset) : .infinity
        // 제목을 최소로 줄여도 안 들어가면 ⌄ 단추를 두고, 보일 탭 구간만 남긴다(고른 탭은 늘 보인다)
        let overflowing = bounds.width > 0 && minWidths.reduce(0, +) + Double(plusWidth) > Double(room)
        let range = overflowing
            ? TabBarFit.visibleRange(minWidths: minWidths, selected: selected,
                                     available: max(0, Double(room - plusWidth - overflowWidth)), previousStart: visibleStart)
            : 0..<tabs.count
        visibleStart = overflowing ? range.lowerBound : nil
        let visible = Array(range)
        // 보이는 탭의 제목은 남은 폭에 맞춘다(긴 제목부터 줄인다)
        let fitted = bounds.width > 0
            ? TabBarFit.titleWidths(titles: visible.map { natural[$0] }, fixed: visible.map { fixed[$0] },
                                    extra: Double(plusWidth + (overflowing ? overflowWidth : 0)), available: Double(room), minTitle: minTitle)
            : visible.map { natural[$0] }
        titleWidths = Array(repeating: 0, count: tabs.count)
        for (slot, index) in visible.enumerated() { titleWidths[index] = CGFloat(fitted[slot]) }
        // 가장 좁은 폭: 신호등 자리 + (고른 탭 또는 첫 탭) + "+" (+ ⌄)
        var minimum = leadingInset + plusWidth
        if !tabs.isEmpty {
            minimum += CGFloat(minWidths[min(max(selected ?? 0, 0), tabs.count - 1)]) + (tabs.count > 1 ? overflowWidth : 0)
        }
        if minimum != minimumContentWidth {
            minimumContentWidth = minimum
            DispatchQueue.main.async { [weak self] in self?.onContentChanged?() }
        }
        let height = bounds.height
        var rects = [CGRect](repeating: .zero, count: tabs.count)
        var closes = [CGRect](repeating: .zero, count: tabs.count)
        var x = leadingInset
        for index in visible {
            let rect = CGRect(x: x, y: 0, width: ceil(CGFloat(fixed[index]) + titleWidths[index]), height: height)
            let tail = tailWidth(index)
            rects[index] = rect
            closes[index] = CGRect(x: rect.maxX - ui(12) - tail - ui(4), y: 0, width: tail + ui(8), height: height)
            x = rect.maxX
        }
        for index in tabs.indices where !range.contains(index) {
            rects[index] = CGRect(x: index < range.lowerBound ? leadingInset : x, y: 0, width: 0, height: height)
        }
        tabRects = rects
        closeRects = closes
        hiddenTabs = tabs.indices.filter { !range.contains($0) }
        plusRect = CGRect(x: x, y: 0, width: plusWidth, height: height)
        overflowRect = hiddenTabs.isEmpty ? .zero : CGRect(x: plusRect.maxX, y: 0, width: overflowWidth, height: height)
        // 풍선 도움말: 줄이지 않은 제목(+ 위험한 실행 옵션), ⌄ 단추
        removeAllToolTips()
        for rect in tabRects where rect.width > 0 && rect.minX < contentWidth { addToolTip(rect, owner: self, userData: nil) }
        if overflowRect != .zero { addToolTip(overflowRect, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if overflowRect != .zero, overflowRect.contains(point) { return "숨은 탭 \(hiddenTabs.count)개 보기" }
        guard let index = tabRects.firstIndex(where: { $0.contains(point) }), tabs.indices.contains(index) else { return "" }
        let tab = tabs[index]
        return tab.title + (tab.warning.map { "\n⚠ " + $0 } ?? "")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTabs()
        settle()
        syncDotLayers()
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
        // 오른쪽 여백(알약 자리)에는 탭도 "+" 도 그리지 않는다
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: contentWidth, height: bounds.height)).addClip()
        if let selection {
            TermAppearance.background.setFill()
            selection.fill()
            // 강조 줄은 창 맨 위 가장자리(제목 줄의 윗선)에 붙지 않게 1pt 띄우고 양옆도 들인다
            TermAppearance.accent.setFill()
            NSBezierPath(roundedRect: CGRect(x: selection.minX + ui(8), y: 1, width: max(0, selection.width - ui(16)), height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
        let rects = displayRects()
        for (index, tab) in tabs.enumerated() where index < rects.count {
            let rect = rects[index]
            guard rect.width > 0, rect.intersects(dirtyRect) else { continue }
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
        // 탭이 없으면 줄만 있다(창 제목 줄 역할: 신호등 자리·창 끌기)
        guard !tabs.isEmpty else { return }
        let plus = displayPlus()
        if hoveringPlus {
            TermAppearance.chromeRaised.setFill()
            NSBezierPath(roundedRect: CGRect(x: plus.midX - ui(12), y: plus.midY - ui(12), width: ui(24), height: ui(24)),
                         xRadius: 6, yRadius: 6).fill()
        }
        SymbolDrawing.draw("plus", size: ui(11), weight: .semibold,
                           color: hoveringPlus ? TermAppearance.textPrimary : TermAppearance.textSecondary, centeredIn: plus)
        if overflowRect != .zero {
            let box = CGRect(x: plus.maxX, y: 0, width: overflowWidth, height: bounds.height)
            let active = hoveringOverflow || overflowMenuOpen
            if active {
                TermAppearance.chromeRaised.setFill()
                NSBezierPath(roundedRect: CGRect(x: box.midX - ui(12), y: box.midY - ui(12), width: ui(24), height: ui(24)),
                             xRadius: 6, yRadius: 6).fill()
            }
            SymbolDrawing.draw("chevron.down", size: ui(10), weight: .semibold,
                               color: active ? TermAppearance.textPrimary : TermAppearance.textSecondary, centeredIn: box)
        }
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
        var background = TermAppearance.chrome
        if isSelected {
            background = TermAppearance.background
        } else if isHovered {
            background = TermAppearance.chromeRaised
            background.setFill()
            rect.fill()
        }
        var x = rect.minX + ui(12)
        if showsDot(tab.status) {
            // 작업 중 점은 레이어가 그린다(숨 쉬는 동안 다시 그리지 않게). 끌기용 그림을 찍을 때만 여기서 칠한다.
            if tab.status != .working || paintsWorkingDots {
                tab.status.drawDot(in: CGRect(x: x, y: rect.midY - Self.dotSize / 2, width: Self.dotSize, height: Self.dotSize), cutout: background)
            }
            x += Self.dotSize + Self.dotGap
        }
        tab.kind.drawIcon(size: ui(11), in: CGRect(x: x, y: rect.midY - Self.iconBoxHeight / 2, width: Self.iconBoxWidth, height: Self.iconBoxHeight))
        x += Self.iconBoxWidth + Self.iconGap
        let title = Self.short(tab.title) as NSString
        let attributes = titleAttributes(selected: isSelected, hovered: isHovered, truncating: true)
        let size = title.size(withAttributes: attributes)
        let titleWidth = index.flatMap { titleWidths.indices.contains($0) ? titleWidths[$0] : nil } ?? ceil(size.width)
        title.draw(in: CGRect(x: x, y: rect.midY - size.height / 2, width: titleWidth, height: size.height), withAttributes: attributes)
        x += titleWidth
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

    /// 작업 중인 탭마다 점 레이어를 두고 공용 숨 쉬기 애니메이션(`setWorkingPulse` — 모든 점 같은 위상)을 붙인다. 탭이 움직이면 자리만 옮긴다.
    /// 끄는 동안·창이 없을 때는 없앤다. 겹쳐 둔 holder 는 탭이 생기고 사라질 때의 옅음을 따른다(숨 쉬기는 안쪽 점 레이어).
    private func syncDotLayers() {
        let rects = displayRects()
        let indices = drag == nil && window != nil
            ? tabs.indices.filter { tabs[$0].status == .working && $0 < rects.count && rects[$0].width > 0 && rects[$0].minX < contentWidth } : []
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while dotLayers.count > indices.count { dotLayers.removeLast().removeFromSuperlayer() }
        while dotLayers.count < indices.count {
            let holder = CALayer()
            holder.addSublayer(CALayer())
            root.addSublayer(holder)
            dotLayers.append(holder)
        }
        for (holder, index) in zip(dotLayers, indices) {
            let rect = rects[index]
            holder.frame = CGRect(x: rect.minX + ui(12), y: rect.midY - Self.dotSize / 2, width: Self.dotSize, height: Self.dotSize)
            holder.opacity = Float(displayAlpha(index))
            guard let dot = holder.sublayers?.first else { continue }
            dot.frame = holder.bounds
            dot.cornerRadius = Self.dotSize / 2
            dot.backgroundColor = TermAppearance.statusWorking.cg(in: self)
            dot.setWorkingPulse(true)
        }
        CATransaction.commit()
    }

    // MARK: - 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    /// 그 자리의 탭(오른쪽 여백 = 알약 자리는 탭이 아니다)
    private func tabIndex(at point: CGPoint) -> Int? {
        guard point.x < contentWidth else { return nil }
        return tabRects.firstIndex { $0.contains(point) }
    }

    private func isPlus(_ point: CGPoint) -> Bool { !tabs.isEmpty && point.x < contentWidth && plusRect.contains(point) }

    private func isOverflow(_ point: CGPoint) -> Bool { overflowRect != .zero && point.x < contentWidth && overflowRect.contains(point) }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = tabIndex(at: point)
        let close = index.map { closeRects[$0].contains(point) } ?? false
        let plus = isPlus(point)
        let overflow = isOverflow(point)
        guard index != hovered || close != hoveringClose || plus != hoveringPlus || overflow != hoveringOverflow else { return }
        hovered = index
        hoveringClose = close
        hoveringPlus = plus
        hoveringOverflow = overflow
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        hoveringClose = false
        hoveringPlus = false
        hoveringOverflow = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        press = nil
        if isPlus(point) {
            onNew?()
        } else if isOverflow(point) {
            showOverflowMenu()
        } else if let index = tabIndex(at: point) {
            if closeRects[index].contains(point) {
                onClose?(index)
            } else if event.clickCount == 2 {
                onRename?(index) // 두 번 누르면 이름 바꾸기
            } else {
                // 고르기는 놓을 때(끌면 옮기기 — 다른 탭을 끌어 지금 탭의 분할에 놓을 수 있게 미리 고르지 않는다)
                press = (index, point)
            }
        } else {
            // 빈 곳(신호등 자리·탭 오른쪽·알약 사이)은 제목 줄처럼: 끌면 창을 옮기고, 두 번 누르면 시스템 설정대로 확대·최소화
            WindowDragging.mouseDown(event, in: window)
        }
    }

    /// ⌄: 탭 목록(종류 아이콘 + 이름 + 상태 + 폴더, ⌘숫자, 지금 탭에 ✓). 줄 모양은 모든 탭이 같고, 고르면 그 탭으로 가고 탭 줄이 그 탭이 보이게 밀린다.
    /// 고르는 순간 탭 번호가 아니라 탭 식별로 찾는다(메뉴가 열려 있는 동안 탭이 닫히거나 옮겨져도 엉뚱한 탭으로 가지 않는다).
    private func makeOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, tab) in tabs.enumerated() {
            let tabID = tab.id
            let item = MenuAction(title: Self.short(tab.title, limit: 36)) { [weak self] in
                guard let self, let current = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                self.onSelect?(current)
            }
            if let key = trailing(index)?.dropFirst(), !key.isEmpty {
                item.keyEquivalent = String(key)
                item.keyEquivalentModifierMask = .command
            }
            item.state = index == selected ? .on : .off
            let title = NSMutableAttributedString(string: item.title)
            if let status = tab.status.label {
                title.append(NSAttributedString(string: "  " + status, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            }
            if !tab.folder.isEmpty {
                title.append(NSAttributedString(string: "  " + Self.short(tab.folder, limit: 30),
                                                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                             .font: TermAppearance.uiFont(11)]))
            }
            item.attributedTitle = title
            let kind = tab.kind
            item.image = NSImage(size: NSSize(width: 14, height: 12), flipped: false) { rect in
                kind.drawIcon(size: 11, in: rect)
                return true
            }
            item.toolTip = tab.title
            menu.addItem(item)
        }
        return menu
    }

    private func showOverflowMenu() {
        guard !hiddenTabs.isEmpty else { return }
        let menu = makeOverflowMenu()
        overflowMenuOpen = true
        needsDisplay = true
        menu.popUp(positioning: nil, at: NSPoint(x: overflowRect.minX, y: overflowRect.maxY), in: self)
        overflowMenuOpen = false
        hoveringOverflow = false
        needsDisplay = true
    }

    /// 시험용: ⌄ 메뉴 항목 제목들(없으면 빈 배열)
    var debugOverflowTitles: [String] { makeOverflowMenu().items.map { $0.attributedTitle?.string ?? $0.title } }

    /// 시험용: ⌄ 메뉴의 n 번째 항목을 고른 것과 같게
    func debugPickOverflow(_ n: Int) {
        let items = makeOverflowMenu().items
        guard items.indices.contains(n), let action = items[n].action else { return }
        NSApp.sendAction(action, to: items[n].target, from: items[n])
    }

    /// 시험용: ⌄ 를 눌러 메뉴를 연다(시험 명령이 막히지 않게 다음 차례에 띄우고, `closeAfter` 초 뒤 스스로 닫는다)
    func debugOpenOverflow(closeAfter: TimeInterval) {
        guard !hiddenTabs.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let menu = self.makeOverflowMenu()
            let timer = Timer(timeInterval: closeAfter, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(timer, forMode: .common)
            self.overflowMenuOpen = true
            self.needsDisplay = true
            menu.popUp(positioning: nil, at: NSPoint(x: self.overflowRect.minX, y: self.overflowRect.maxY), in: self)
            self.overflowMenuOpen = false
            self.needsDisplay = true
        }
    }

    /// 시험용: ⌄ 메뉴에 들어갈 탭 번호(왼쪽에서부터)
    var debugHiddenTabs: [Int] { hiddenTabs }

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
        guard let index = tabIndex(at: point) else { return nil }
        let menu = NSMenu()
        menu.addItem(MenuAction(title: "이름 바꾸기…") { [weak self] in self?.onRename?(index) })
        menu.addItem(MenuAction(title: "탭 닫기") { [weak self] in self?.onClose?(index) })
        return menu
    }

    /// 빈 곳 끌기는 `mouseDown` 이 `performDrag` 로 직접 한다(탭을 끌 때 창이 같이 움직이지 않게)
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

    /// 시험용: 탭과 "+" 의 오른쪽 끝
    var debugContentMaxX: CGFloat { tabs.isEmpty ? 0 : plusRect.maxX }

    /// 시험용: 탭 자리(창 좌표)
    var windowTabRects: [CGRect] { tabRects.map { convert($0, to: nil) } }

    private func snapshot(_ rect: CGRect) -> CGImage? {
        guard !rect.isEmpty, let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }

    private func beginDrag(_ index: Int, grab: CGFloat) {
        hovered = nil
        hoveringClose = false
        hoveringPlus = false
        settle()
        wantsLayer = true
        paintsWorkingDots = true
        let images = tabRects.map(snapshot) // 바탕만 그리기 전에 찍는다
        paintsWorkingDots = false
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
        syncDotLayers()
        needsDisplay = true
    }

    private func moveDrag(to point: CGPoint, window: NSPoint) {
        guard var drag else { return }
        let inside = isInBand(window)
        var frames = drag.rects
        if inside {
            let width = drag.rects[drag.index].width
            let end = drag.rects.last?.maxX ?? width
            let x = min(max(point.x - drag.grab, leadingInset), max(leadingInset, end - width))
            // 끄는 탭을 뺀 순서에서 가운데가 끄는 탭 가운데보다 왼쪽인 탭 수 = 놓일 자리
            let others = drag.rects.indices.filter { $0 != drag.index }
            var cursor = leadingInset
            var to = 0
            // 안 보이는 탭(폭 0): 왼쪽에 숨은 것은 늘 앞, 오른쪽에 숨은 것은 보이는 끝 뒤(끌어다 놓아도 그 앞에 놓인다)
            let firstVisible = drag.rects.firstIndex { $0.width > 0 } ?? drag.rects.count
            for i in others {
                if drag.rects[i].width == 0 {
                    if i < firstVisible { to += 1 }
                    continue
                }
                if cursor + drag.rects[i].width / 2 < x + width / 2 { to += 1 }
                cursor += drag.rects[i].width
            }
            cursor = leadingInset
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
        syncDotLayers()
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
