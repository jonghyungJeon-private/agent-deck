import AppKit

/// 세션 창 오른쪽 아래, 🌐 버튼 왼쪽의 터미널 버튼: 누르면 고른 세션의 작은 터미널 창을 켜고 끈다(⌃`).
/// 28pt 둥근 모서리 버튼(15pt 가는 기호, 평소 textSecondary). 열려 있으면 속이 찬 기호 + 한 단계 밝은 바탕,
/// 창을 닫아 둔 채 명령이 돌고 있으면 오른쪽 위에 숨 쉬는 점(작업 중 점과 같은 시계).
final class ScratchToggleButton: FloatPillButton {
    /// 닫아 둔 작은 터미널에서 명령이 돌고 있음(앞에서 도는 프로그램이 셸이 아님)
    var busy = false { didSet { if busy != oldValue { refreshBusyDot(); updateTip() } } }

    static var size: CGFloat { FloatPillButton.height }
    private static var symbolSide: CGFloat { TermAppearance.scaled(15) }
    private let dot = CALayer()

    override var isOn: Bool { didSet { if isOn != oldValue { updateTip(); refreshBusyDot() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.cornerRadius = TermAppearance.scaled(4)
        dot.borderWidth = 1.5
        dot.isHidden = true
        layer?.addSublayer(dot)
        NotificationCenter.default.addObserver(self, selector: #selector(pulseChanged), name: WorkingPulse.didChange, object: nil)
        updateTip()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    override func scaleChanged() {
        super.scaleChanged()
        dot.cornerRadius = TermAppearance.scaled(4)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let side = TermAppearance.scaled(8)
        let inset = TermAppearance.scaled(2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = NSRect(x: bounds.maxX - side - inset, y: bounds.maxY - side - inset, width: side, height: side)
        CATransaction.commit()
    }

    override func refreshChrome(animated: Bool = true) {
        super.refreshChrome(animated: animated)
        refreshBusyDot()
    }

    @objc private func pulseChanged() { dot.setWorkingPulse(busy && !isOn) }

    /// 점은 창이 닫혀 있고 명령이 돌 때만
    private func refreshBusyDot() {
        let show = busy && !isOn
        dot.isHidden = !show
        dot.backgroundColor = TermAppearance.statusWorking.cg(in: self)
        dot.borderColor = TermAppearance.background.cg(in: self)
        dot.setWorkingPulse(show)
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = Self.symbolSide
        guard let image = NSImage(systemSymbolName: isOn ? "terminal.fill" : "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side, weight: .regular)
                .applying(.init(paletteColors: [emphasized ? TermAppearance.textPrimary : TermAppearance.textSecondary]))) else { return }
        let size = image.size
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }

    private func updateTip() {
        toolTip = "작은 터미널 (⌃`)" + (busy && !isOn ? " — 명령 실행 중" : "")
    }
}
