import AppKit

/// 터미널 위 탭 줄(herdr 처럼 납작하게, 지금 탭은 강조색으로 칠한다). AppKit 으로 직접 그린다.
final class TabBarView: NSView {
    struct Tab: Equatable {
        var title: String
        var paneCount: Int
        var zoomed: Bool
    }

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
        let color = isSelected ? TermAppearance.chrome : index == hovered ? TermAppearance.textPrimary : TermAppearance.textDim
        return [.font: TermAppearance.uiFont(12, bold: isSelected), .foregroundColor: color]
    }

    private func smallAttributes(_ index: Int, alpha: CGFloat) -> [NSAttributedString.Key: Any] {
        let color = index == selected ? TermAppearance.chrome : TermAppearance.textDim
        return [.font: TermAppearance.uiFont(10), .foregroundColor: color.withAlphaComponent(alpha)]
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
            var width: CGFloat = 12
            width += (Self.short(tab.title) as NSString).size(withAttributes: titleAttributes(index)).width
            if let badge = badge(tab) {
                width += 6 + (badge as NSString).size(withAttributes: smallAttributes(index, alpha: 1)).width
            }
            let tail = max((trailing(index) as NSString).size(withAttributes: smallAttributes(index, alpha: 1)).width, 12)
            width += 10 + tail + 12
            let rect = CGRect(x: x, y: 0, width: ceil(width), height: height)
            tabRects.append(rect)
            closeRects.append(CGRect(x: rect.maxX - 12 - tail - 4, y: 0, width: tail + 8, height: height))
            x = rect.maxX
        }
        plusRect = CGRect(x: x, y: 0, width: 30, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTabs()
    }

    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.chrome.setFill()
        bounds.fill()
        for (index, tab) in tabs.enumerated() where index < tabRects.count {
            let rect = tabRects[index]
            let isSelected = index == selected
            if isSelected {
                TermAppearance.accent.setFill()
                rect.fill()
            } else if index == hovered {
                TermAppearance.chromeRaised.setFill()
                rect.fill()
            }
            var x = rect.minX + 12
            let title = Self.short(tab.title) as NSString
            let attributes = titleAttributes(index)
            let size = title.size(withAttributes: attributes)
            title.draw(at: CGPoint(x: x, y: (rect.height - size.height) / 2), withAttributes: attributes)
            x += size.width
            if let badge = badge(tab) {
                let small = smallAttributes(index, alpha: 0.8)
                let badgeSize = (badge as NSString).size(withAttributes: small)
                (badge as NSString).draw(at: CGPoint(x: x + 6, y: (rect.height - badgeSize.height) / 2), withAttributes: small)
            }
            // 오른쪽 끝: 평소엔 ⌘숫자, 마우스를 올리면 닫기(×)
            let closing = index == hovered
            let tail = (closing ? "×" : trailing(index)) as NSString
            var tailAttributes = smallAttributes(index, alpha: closing ? (hoveringClose ? 1 : 0.8) : 0.6)
            if closing { tailAttributes[.font] = TermAppearance.uiFont(13) }
            let tailSize = tail.size(withAttributes: tailAttributes)
            let closeRect = closeRects[index]
            tail.draw(at: CGPoint(x: closeRect.midX - tailSize.width / 2, y: (rect.height - tailSize.height) / 2),
                      withAttributes: tailAttributes)
            if !isSelected, index + 1 != selected {
                TermAppearance.border.withAlphaComponent(0.6).setFill()
                CGRect(x: rect.maxX - 0.5, y: rect.midY - 7, width: 1, height: 14).fill()
            }
        }
        let plus = "+" as NSString
        let plusAttributes: [NSAttributedString.Key: Any] = [
            .font: TermAppearance.uiFont(14),
            .foregroundColor: hoveringPlus ? TermAppearance.textPrimary : TermAppearance.textDim,
        ]
        let plusSize = plus.size(withAttributes: plusAttributes)
        plus.draw(at: CGPoint(x: plusRect.midX - plusSize.width / 2, y: (plusRect.height - plusSize.height) / 2),
                  withAttributes: plusAttributes)
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
        if plusRect.contains(point) {
            onNew?()
        } else if let index = tabRects.firstIndex(where: { $0.contains(point) }) {
            if closeRects[index].contains(point) {
                onClose?(index)
            } else if event.clickCount == 2 {
                onRename?(index) // 두 번 누르면 이름 바꾸기
            } else {
                onSelect?(index)
            }
        }
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
