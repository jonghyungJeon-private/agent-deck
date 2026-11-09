import AppKit
import SwiftTerm
import TermLayout

/// 세션 창 안에 떠 있는 작은 창(브라우저·작은 터미널): 얇은 제목 줄(제목 · 추가 버튼 · 크게 · ✕) + 내용.
/// 되돌릴 수 없는 추가 버튼(끝내기)은 "크게"와 8pt 떨어뜨려 닫기와 같은 무게로 붙어 있지 않게 한다.
/// 나타날 때·사라질 때는 투명도 + 아래로 6pt 정도만 움직인다(Motion.standard, 동작 줄이기에서는 바로).
/// 제목 줄을 끌면 옮기고, 가장자리·모서리를 끌면 크기를 바꾼다. 자리는 호스트(부모 뷰) 좌표 frame 으로 다루고,
/// 사람이 끌기를 마치면 `onFrameChanged` 로 알린다(저장은 ToolWindowsController). 종류마다 `FloatSpec`(최소 크기)이 다르다.
///
/// 투명도(종류마다 따로, 제목 줄 "⋯" 메뉴 또는 제목 줄 오른쪽 클릭 → "투명도" 100·90·80·70%): 포인터가 위에 있거나 키보드 포커스가 이 창 안에 있거나
/// 끄는 중이면 100%, 아니면 고른 값으로 돌아온다(Motion.standard 로 서서히 — 동작 줄이기·창이 뜨는 첫 순간은 바로).
/// 제목 줄·테두리·그림자는 늘 또렷하고 안쪽 내용만 옅어진다: 브라우저는 내용 전체(페이지 그림 포함), 작은 터미널은 바탕만(글자·커서는 그대로).
/// 창의 `alphaValue`(나타남·사라짐이 쓴다)가 아니라 안쪽 레이어를 건드려 서로 겹치지 않는다.
final class FloatPanel: NSView {
    var onFrameChanged: ((NSRect) -> Void)?
    var onClose: (() -> Void)?
    var onToggleSize: (() -> Void)?
    /// 끌기(옮기기·크기 바꾸기) 시작·끝 — 끄는 동안 브라우저 페이지 크기는 맞추지 않고 자동 배치(ToolWindowsController.floatGate)도 미룬다(끝에서 한 번)
    var onGestureBegan: (() -> Void)?
    var onGestureEnded: (() -> Void)?

    /// 크기 바꾸기를 잡는 가장자리 두께
    static let edge: CGFloat = 6
    static var stripHeight: CGFloat { TermAppearance.scaled(30) }

    private let clip = NSView()
    private let strip = FloatTitleStrip()
    private let container = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    /// 호스트가 준 제목 글(앞의 기호·"종류 · 이름 · 폴더" 모양을 나눠 그린다)
    private var titleText = ""
    /// 떼기 직전 내용이 아직 있을 때 찍어 둔 모습(사라짐에 쓴다)
    private var exitSnapshot: NSImage?
    private let sizeButton = FloatIconButton(symbol: "arrow.up.left.and.arrow.down.right", tip: "크게")
    private let closeButton: FloatIconButton
    private var iconButtons: [FloatIconButton] = []
    private let moreButton = FloatIconButton(symbol: "ellipsis", tip: "작은 창 설정 — 투명도")

    // MARK: 투명도 상태
    private let isBrowser: Bool
    /// 고른 값(100·90·80·70)
    private(set) var opacityPercent = 100
    private var pointerInside = false
    private var keyFocused = false
    /// 지금 그려진 불투명도(1 = 불투명). 포인터·포커스·끌기에 따라 `opacityPercent` 와 1 사이
    private var shownLevel: CGFloat = 1
    private var windowObservers: [NSObjectProtocol] = []
    private var responderObservation: NSKeyValueObservation?
    private var debugObserver: NSObjectProtocol?
    private var transparencyObserver: NSObjectProtocol?
    private var stripHeightConstraint: NSLayoutConstraint!
    private let edgeCursors = FloatEdgeCursorView()
    private let row = NSStackView()
    private var content: NSView?
    private let spec: FloatSpec
    private var extraActions: [() -> Void] = []
    private var large = false

    private enum Drag {
        case move
        case resize(left: Bool, right: Bool, bottom: Bool, top: Bool)
    }
    private var drag: Drag?
    private var dragOrigin = NSPoint.zero
    private var dragFrame = NSRect.zero

    init(spec: FloatSpec, closeTip: String) {
        self.spec = spec
        isBrowser = spec == .browser
        closeButton = FloatIconButton(symbol: "xmark", tip: closeTip)
        super.init(frame: .zero)
        opacityPercent = FloatOpacity.load(browser: isBrowser)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 10
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1
        refreshLayerColors()
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)

        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.onDragBegan = { [weak self] event in self?.begin(.move, event) }
        strip.onDragMoved = { [weak self] event in self?.dragged(event) }
        strip.onDragEnded = { [weak self] in self?.endDrag() }
        container.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(container)
        clip.addSubview(strip)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow - 1, for: .horizontal) // 남는 폭은 제목이 차지해 버튼이 오른쪽에 붙게
        sizeButton.target = self
        sizeButton.action = #selector(sizeClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        strip.menuProvider = { [weak self] in self?.settingsMenu() }
        iconButtons = [moreButton, sizeButton, closeButton]
        for view in [titleLabel, moreButton, sizeButton, closeButton] { row.addArrangedSubview(view) }
        row.orientation = .horizontal
        row.spacing = 2
        row.setCustomSpacing(8, after: titleLabel)
        setLarge(false)
        row.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(row)

        // 제목 줄 위·가장자리 위에서 커서(안쪽 터미널·브라우저 화면의 커서가 이기지 않게): 맨 위에 올린 덮개가 크기 바꾸기 커서를 정한다
        edgeCursors.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edgeCursors)
        stripHeightConstraint = strip.heightAnchor.constraint(equalToConstant: Self.stripHeight)
        NSLayoutConstraint.activate([
            edgeCursors.topAnchor.constraint(equalTo: topAnchor),
            edgeCursors.leadingAnchor.constraint(equalTo: leadingAnchor),
            edgeCursors.trailingAnchor.constraint(equalTo: trailingAnchor),
            edgeCursors.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.topAnchor.constraint(equalTo: clip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stripHeightConstraint,
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

    /// 레이어 색은 값으로 굳으므로 모양(라이트·다크)이 바뀔 때마다 다시 받는다. 그림자는 밝은 바탕에서 옅게.
    private func refreshLayerColors() {
        layer?.shadowOpacity = effectiveAppearance.isDark ? 0.4 : 0.16
        clip.layer?.borderColor = TermAppearance.border.cg(in: self)
        // 바탕만 옅어진다(제목 줄·테두리는 늘 또렷하게)
        clip.layer?.backgroundColor = TermAppearance.background.withAlphaComponent(shownLevel).cg(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayerColors()
        // 터미널 뷰는 모양이 바뀔 때 바탕을 불투명으로 다시 칠한다 — 그 뒤에 투명도를 다시 건다
        DispatchQueue.main.async { [weak self] in self?.applyTerminalBackground() }
    }

    func setTitle(_ text: String) {
        titleText = text
        renderTitle()
    }

    /// "⌨ 터미널 · 이름 · 폴더" → 종류 "터미널"은 시스템 글꼴 semibold(말), 나머지 이름·폴더는 고정폭 textSecondary(데이터). 앞의 기호는 뗀다.
    private func renderTitle() {
        var text = titleText
        while let first = text.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first) { text.removeFirst() }
        let separator = " · "
        var parts = text.components(separatedBy: separator)
        let lead = parts.removeFirst()
        let rest = parts.joined(separator: separator)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: lead, attributes: [
            .font: TermAppearance.uiTextFont(TermAppearance.scaled(11), weight: .semibold),
            .foregroundColor: TermAppearance.textPrimary, .paragraphStyle: paragraph,
        ])
        if !rest.isEmpty {
            result.append(NSAttributedString(string: "  " + rest, attributes: [
                .font: TermAppearance.scaledUIFont(11), .foregroundColor: TermAppearance.textSecondary, .paragraphStyle: paragraph,
            ]))
        }
        titleLabel.attributedStringValue = result
    }

    var hasContent: Bool { content?.superview === container }

    func setLarge(_ large: Bool) {
        self.large = large
        sizeButton.setSymbol(large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        sizeButton.toolTip = large ? "작게" : "크게"
        sizeButton.setAccessibilityLabel(sizeButton.toolTip)
    }

    /// 글꼴 크기 배율이 바뀜: 제목 줄 높이·글꼴·버튼
    func scaleChanged() {
        stripHeightConstraint.constant = Self.stripHeight
        renderTitle()
        iconButtons.forEach { $0.scaleChanged() }
        setLarge(large)
    }

    /// 내용(브라우저 도구·터미널 뷰)을 단다(nil = 뗀다). 다른 곳(옆 도크: 시험 명령)에 붙어 있었으면 거기서 먼저 뗀다.
    func setContent(_ view: NSView?) {
        guard view !== content || view?.superview !== container else { return }
        if let old = content, old.superview === container {
            // 내용을 떼면 사라지는 모습에 빈 틀만 남으므로 떼기 전에 찍어 둔다(곧 창도 떼어질 때 쓴다)
            if view == nil, window != nil, !Motion.reduced, !isFadedOut { exitSnapshot = FloatFx.snapshot(self) }
            old.removeFromSuperview()
        }
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
        applyTerminalBackground()
    }

    /// 제목 줄의 "크게" 앞에 아이콘 버튼을 더한다(브라우저의 "별도 창으로 떼기", 작은 터미널의 "끝내기")
    func addTitleButton(symbol: String, tip: String, action: @escaping () -> Void) {
        let button = FloatIconButton(symbol: symbol, tip: tip)
        // 끝내기(power)는 되돌릴 수 없다: 빨강으로 반응하고 "크게"·닫기와 8pt 떨어진다(같은 동작, 확인창은 없다)
        let destructive = symbol == "power"
        if destructive { button.hoverTint = TermAppearance.statusAttention }
        button.target = self
        button.action = #selector(extraClicked(_:))
        button.tag = extraActions.count
        extraActions.append(action)
        iconButtons.append(button)
        row.insertArrangedSubview(button, at: row.arrangedSubviews.firstIndex(of: moreButton) ?? row.arrangedSubviews.count)
        if destructive { row.setCustomSpacing(8, after: button) }
    }

    @objc private func extraClicked(_ sender: NSButton) {
        if extraActions.indices.contains(sender.tag) { extraActions[sender.tag]() }
    }

    @objc private func sizeClicked() { onToggleSize?() }
    @objc private func closeClicked() { onClose?() }

    // MARK: - 투명도

    private var isPointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// 이 창 안(브라우저 화면·터미널·찾기 막대)에 키보드가 있는지
    private var hasKeyboardFocus: Bool {
        guard let window, window.isKeyWindow, let responder = window.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    private func observeWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        responderObservation = nil
        guard let window else { return }
        let refresh: (Notification) -> Void = { [weak self] _ in self?.focusChanged() }
        windowObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: refresh),
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: refresh),
        ]
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.focusChanged() }
        }
        // 손쉬운 사용 설정이 바뀌면(투명도 줄이기) 바로 다시 맞춘다
        if transparencyObserver == nil {
            transparencyObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.applyTerminalBackground()
                self?.refreshOpacity(animated: false)
            }
        }
        if debugObserver == nil {
            debugObserver = NotificationCenter.default.addObserver(forName: FloatOpacity.debugNotification, object: nil, queue: .main) { [weak self] note in
                self?.debugCommand(note)
            }
        }
    }

    private func focusChanged() {
        keyFocused = hasKeyboardFocus
        refreshOpacity(animated: true)
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let debugObserver { NotificationCenter.default.removeObserver(debugObserver) }
        if let transparencyObserver { NSWorkspace.shared.notificationCenter.removeObserver(transparencyObserver) }
    }

    /// 손쉬운 사용의 "투명도 줄이기"가 켜져 있으면 고른 값과 상관없이 100%(저장된 값은 그대로 — 끄면 다시 고른 값)
    private var effectivePercent: Int {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 100 : opacityPercent
    }

    /// 지금 있어야 할 불투명도: 포인터가 위에 있거나 키보드가 안에 있거나 끄는 중이면 1, 아니면 고른 값(투명도 줄이기면 1)
    private var targetLevel: CGFloat {
        pointerInside || keyFocused || drag != nil ? 1 : CGFloat(effectivePercent) / 100
    }

    /// 투명도를 목표에 맞춘다. animated 면 Motion.standard(ease-out)로 서서히(동작 줄이기·창 밖이면 바로).
    private func refreshOpacity(animated: Bool) {
        keyFocused = hasKeyboardFocus
        let target = targetLevel
        guard target != shownLevel else { return }
        let from = shownLevel
        shownLevel = target
        let animate = animated && !Motion.reduced && window != nil
        guard let layer = clip.layer else { return }
        // 바탕색 알파가 투명도다. 제목 줄·테두리는 그대로 또렷하다(버튼이 늘 읽히게).
        let color = TermAppearance.background.withAlphaComponent(target).cg(in: self)
        Self.fade(layer, key: "backgroundColor", from: layer.presentation()?.backgroundColor ?? layer.backgroundColor, to: color, animate: animate) {
            layer.backgroundColor = color
        }
        // 브라우저는 페이지 그림도 함께(내용 전체 opacity). 작은 터미널은 글자·커서를 그대로 두고 터미널 뷰의 기본 바탕을 투명하게 둔다.
        if isBrowser {
            container.wantsLayer = true
            if let content = container.layer {
                Self.fade(content, key: "opacity", from: content.presentation()?.opacity ?? Float(from), to: Float(target), animate: animate) {
                    content.opacity = Float(target)
                }
            }
        }
    }

    private static func fade(_ layer: CALayer, key: String, from: Any?, to: Any?, animate: Bool, set: () -> Void) {
        set()
        guard animate else { layer.removeAnimation(forKey: "floatOpacity"); return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = Motion.standard
        animation.timingFunction = FloatFx.timing
        layer.add(animation, forKey: "floatOpacity")
    }

    /// 작은 터미널 뷰의 기본 바탕: 100% 면 터미널이 칠하고(예전 그대로), 아니면 투명하게 두고 clip 레이어가 칠한다(그 알파가 투명도)
    private func applyTerminalBackground() {
        guard !isBrowser, let terminal = (content as? TerminalPaneSurface)?.terminal else { return }
        terminal.backgroundOpacity = effectivePercent >= 100 ? 1 : 0
    }

    private func setOpacityPercent(_ percent: Int, persist: Bool = true) {
        guard FloatOpacity.levels.contains(percent) else { return }
        opacityPercent = percent
        if persist { FloatOpacity.save(percent, browser: isBrowser) }
        applyTerminalBackground()
        refreshOpacity(animated: true)
    }

    @objc private func moreClicked() {
        settingsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: moreButton)
    }

    /// 작은 창 자신의 메뉴: "투명도" ▸ 100·90·80·70%(고른 것에 체크)
    private func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "투명도", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for percent in FloatOpacity.levels {
            let entry = ClosureMenuItem(title: "\(percent)%") { [weak self] in self?.setOpacityPercent(percent) }
            entry.state = percent == opacityPercent ? .on : .off
            sub.addItem(entry)
        }
        item.submenu = sub
        menu.addItem(item)
        return menu
    }

    /// 시험 명령 `panel-opacity <browser|scratch> [퍼센트]`
    private func debugCommand(_ note: Notification) {
        guard let kind = note.userInfo?["kind"] as? String, kind == (isBrowser ? "browser" : "scratch"), window != nil else { return }
        if let percent = note.userInfo?["percent"] as? Int, percent > 0 { setOpacityPercent(percent, persist: false) }
        if note.userInfo?["blur"] as? Bool == true, hasKeyboardFocus { window?.makeFirstResponder(nil) } // 포커스를 이 창 밖으로(시험)
        pointerInside = isPointerInside
        refreshOpacity(animated: false)
        if let path = note.userInfo?["snap"] as? String, !path.isEmpty { debugSnapshot(to: path) }
        print("panel-opacity \(kind) chosen=\(opacityPercent) shown=\(String(format: "%.2f", Double(shownLevel))) hover=\(pointerInside) focus=\(keyFocused) "
              + "mode=\(isBrowser ? "content" : "background") clipBgAlpha=\(String(format: "%.2f", Double(clip.layer?.backgroundColor?.alpha ?? -1)))"
              + " terminalOpacity=\((content as? TerminalPaneSurface).map { String(format: "%.2f", Double($0.terminal.backgroundOpacity)) } ?? "-")"
              + " contentOpacity=\(String(format: "%.2f", Double(container.layer?.opacity ?? 1))) z=\(superview?.subviews.firstIndex(of: self) ?? -1)/\(superview?.subviews.count ?? 0)")
        fflush(stdout)
    }

    /// 시험: 이 창을 줄무늬 바탕 위에 층째 그린다(얼마나 비치는지 보려고 — 창 그림은 터미널 바탕을 빼먹는다)
    private func debugSnapshot(to path: String) {
        guard let layer = layer, let scale = window?.backingScaleFactor else { return }
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: bounds.size))
        ctx.setFillColor(NSColor(srgbRed: 0.9, green: 0.2, blue: 0.5, alpha: 1).cgColor)
        var y: CGFloat = 0
        while y < bounds.height { ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: 10)); y += 24 }
        // render(in:) 는 둥근 모서리 + 잘라내기 레이어의 바탕을 빼먹는다 — 그리는 동안만 잘라내기를 끈다
        var masked: [CALayer] = []
        func collect(_ l: CALayer) { if l.masksToBounds { masked.append(l); l.masksToBounds = false }; l.sublayers?.forEach(collect) }
        collect(layer)
        layer.render(in: ctx)
        masked.forEach { $0.masksToBounds = true }
        if let image = ctx.makeImage() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

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
        refreshOpacity(animated: true) // 끄는 동안은 불투명
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
            let minSize = spec.minSize
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
        // 자리가 바뀌지 않은 클릭(제목 줄을 눌렀다 뗌)은 저장하지 않는다 — 기본 자리가 저장된 자리로 굳지 않게
        if frame != dragFrame { onFrameChanged?(frame) }
        layoutSubtreeIfNeeded() // 안쪽 화면이 마지막 크기로 자리 잡은 뒤 페이지를 맞추게
        onGestureEnded?()
        pointerInside = isPointerInside
        refreshOpacity(animated: true)
    }

    /// 끄는 중에 창이 호스트에서 빠졌다(세션이 바뀌어 닫힘 등): 마우스 뗌이 오지 않으므로 끝을 알린다
    /// (끝 알림이 없으면 그 창의 자동 배치가 영영 미뤄진다)
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview == nil, drag != nil else { return }
        drag = nil
        onGestureEnded?()
    }

    // MARK: - 커서
    // 터미널·브라우저 화면은 자기 영역 전체에 커서(I빔·손가락)를 선언해, 위에 겹친 이 창이 선언하지 않으면 그것이 이긴다.
    // 제목 줄(FloatTitleStrip)은 화살표, 가장자리·모서리는 맨 위 덮개(FloatEdgeCursorView)가 크기 바꾸기 커서를 선언한다.
    // 안쪽 화면의 커서(작은 터미널의 I빔)는 그대로 둔다. 창이 옮겨지거나 크기가 바뀌면 커서 영역을 다시 잡는다.

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private func invalidateCursors() {
        guard let window else { return }
        window.invalidateCursorRects(for: self)
        window.invalidateCursorRects(for: edgeCursors)
        window.invalidateCursorRects(for: strip)
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); invalidateCursors() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); invalidateCursors() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateCursors()
        observeWindow()
        // 열릴 때는 애니메이션 없이 바로 그 상태로
        pointerInside = isPointerInside
        refreshOpacity(animated: false)
        // 열릴 때 떠오르듯 나타난다(앱이 막 뜨는 동안 복원되는 창은 그냥 나타난다)
        if window != nil, Self.pastLaunch { FloatFx.fadeIn(self, duration: Motion.standard, dy: -6) }
    }

    /// 앱이 뜬 지 몇 초 안에는 움직이지 않는다(복원되는 창)
    private static var pastLaunch: Bool {
        guard let launched = NSRunningApplication.current.launchDate else { return true }
        return Date().timeIntervalSince(launched) > 3
    }

    /// 창 자체가 거의 투명하다(바깥에서 `alphaValue` 로 사라지게 한 뒤)
    private var isFadedOut: Bool { alphaValue < 0.01 }

    /// 닫힐 때 그 자리에서 투명해지며 조금 내려앉는다(떼는 것은 바로 — 아래 그림만 남아 사라진다)
    override func removeFromSuperview() {
        // 이미 투명하게 사라진 창(자동으로 닫는 쪽이 alphaValue 로 먼저 걷었다)은 그림을 또 올려 두 번 사라지지 않게 한다
        if let host = superview, window != nil, !Motion.reduced, Self.pastLaunch, !isFadedOut {
            FloatFx.ghost(exitSnapshot ?? FloatFx.snapshot(self), frame: frame, in: host, above: self, duration: Motion.standard, dy: -6)
        }
        exitSnapshot = nil
        super.removeFromSuperview()
    }

    // 마지막 보루: 위 선언이 안쪽 화면의 커서에 밀려도, 제목 줄·가장자리에 들어올 때 이 창이 직접 커서를 정한다
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let e = Self.edge, h = strip.frame.height
        var rects = [NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)] // 제목 줄(위쪽)
        rects += [NSRect(x: 0, y: 0, width: e, height: bounds.height), NSRect(x: bounds.width - e, y: 0, width: e, height: bounds.height),
                  NSRect(x: 0, y: 0, width: bounds.width, height: e), NSRect(x: 0, y: bounds.height - e, width: bounds.width, height: e)]
        for rect in rects {
            addTrackingArea(NSTrackingArea(rect: rect, options: [.cursorUpdate, .activeInKeyWindow], owner: self))
        }
        // 포인터가 창 위에 있는지(투명도)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true; refreshOpacity(animated: true) }
    override func mouseExited(with event: NSEvent) { pointerInside = false; refreshOpacity(animated: true) }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = edges(at: point) { FloatEdgeCursorView.cursor(left: hit.left, right: hit.right, bottom: hit.bottom, top: hit.top).set() }
        else { NSCursor.arrow.set() }
    }
}

/// 크기 바꾸기 가장자리 위의 커서 선언 전용 덮개(마우스 이벤트는 받지 않는다 — FloatPanel.hitTest 가 가장자리를 맡는다)
final class FloatEdgeCursorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 모서리의 대각선 크기 바꾸기 커서: 공개된 것이 없어 AppKit 안의 이름으로 찾고, 없으면 십자
    private static let nwse: NSCursor = privateCursor("_windowResizeNorthWestSouthEastCursor") ?? .crosshair
    private static let nesw: NSCursor = privateCursor("_windowResizeNorthEastSouthWestCursor") ?? .crosshair

    private static func privateCursor(_ name: String) -> NSCursor? {
        let selector = NSSelectorFromString(name)
        guard NSCursor.responds(to: selector) else { return nil }
        return NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor
    }

    static func cursor(left: Bool, right: Bool, bottom: Bool, top: Bool) -> NSCursor {
        if (left || right) && (bottom || top) {
            // 아래-왼쪽·위-오른쪽은 ↗↙, 위-왼쪽·아래-오른쪽은 ↖↘
            return (left && bottom) || (right && top) ? nesw : nwse
        }
        return left || right ? .resizeLeftRight : .resizeUpDown
    }

    override func resetCursorRects() {
        let e = FloatPanel.edge, w = bounds.width, h = bounds.height
        guard w > 2 * e, h > 2 * e else { return }
        let c = e
        addCursorRect(NSRect(x: 0, y: 0, width: c, height: c), cursor: Self.cursor(left: true, right: false, bottom: true, top: false))
        addCursorRect(NSRect(x: w - c, y: 0, width: c, height: c), cursor: Self.cursor(left: false, right: true, bottom: true, top: false))
        addCursorRect(NSRect(x: 0, y: h - c, width: c, height: c), cursor: Self.cursor(left: true, right: false, bottom: false, top: true))
        addCursorRect(NSRect(x: w - c, y: h - c, width: c, height: c), cursor: Self.cursor(left: false, right: true, bottom: false, top: true))
        addCursorRect(NSRect(x: 0, y: c, width: e, height: h - 2 * c), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - e, y: c, width: e, height: h - 2 * c), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: c, y: 0, width: w - 2 * c, height: e), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: c, y: h - e, width: w - 2 * c, height: e), cursor: .resizeUpDown)
    }
}

/// 제목 줄: 빈 곳을 끌면 작은 창을 옮긴다(버튼은 자기 클릭을 받는다)
final class FloatTitleStrip: NSView {
    var onDragBegan: ((NSEvent) -> Void)?
    var onDragMoved: ((NSEvent) -> Void)?
    var onDragEnded: (() -> Void)?
    /// 오른쪽 클릭 메뉴(작은 창 메뉴와 같다)
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDragBegan?(event) }
    override func mouseDragged(with event: NSEvent) { onDragMoved?(event) }
    override func mouseUp(with event: NSEvent) { onDragEnded?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.chrome.setFill()
        bounds.fill()
        TermAppearance.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// 작은 창 투명도: 종류(브라우저 / 작은 터미널)마다 UserDefaults 에 퍼센트 정수로 둔다.
/// 키 `floatPanel.opacity.browser`·`floatPanel.opacity.terminal` — 100(기본, 예전 모습)·90·80·70. 없거나 다른 값이면 100.
enum FloatOpacity {
    static let levels = [100, 90, 80, 70]
    static func key(browser: Bool) -> String { browser ? "floatPanel.opacity.browser" : "floatPanel.opacity.terminal" }
    static func load(browser: Bool) -> Int {
        let value = UserDefaults.standard.integer(forKey: key(browser: browser))
        return levels.contains(value) ? value : 100
    }
    static func save(_ percent: Int, browser: Bool) { UserDefaults.standard.set(percent, forKey: key(browser: browser)) }
    /// 시험 명령 `panel-opacity` 가 보낸다(userInfo: kind = browser|scratch, percent)
    static let debugNotification = Notification.Name("AgentDeck.debugPanelOpacity")
}
