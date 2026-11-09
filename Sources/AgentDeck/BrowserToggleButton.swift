import AppKit

/// 세션 창 오른쪽 아래의 🌐 버튼: 누르면 세션 창 안 브라우저 칸을 켜고 끈다(⌘⇧B 와 같음).
/// 고른 세션의 브라우저 상태도 여기서 보인다(제목 줄 칩 대신) — 읽을 만한 상태(AI 제어·내가 조작·기다림·넘겨받는 중)면
/// 오른쪽 아래 자리를 지킨 채 왼쪽으로 늘어나 지구본 + 상태 글자 알약, 그 밖에는 28pt 버튼.
/// 색은 뜻이 있을 때만: AI 가 조작 중 = agent(초록), 내 조작 필요 = statusAttention(빨강 점), 결과 있음 = statusDone. 나머지는 중립.
final class BrowserToggleButton: FloatPillButton {
    /// nil = 그 세션에 떠 있는 브라우저 없음(아직 안 씀·쉬는 중)
    var indicator: BrowserIndicator? {
        didSet { if indicator != oldValue { invalidateIntrinsicContentSize(); refreshChrome(animated: true); updateTip() } }
    }
    /// 에이전트가 사용자에게 남긴 결과(abx done --keep)가 있다: "결과 있음" 알약(초록). 기다림·내가 조작 중이면 그 상태가 먼저다.
    var resultBadge = false {
        didSet { if resultBadge != oldValue { invalidateIntrinsicContentSize(); refreshChrome(animated: true); updateTip() } }
    }
    /// 브라우저 칸이 열려 있음(버튼을 눌린 모양으로)
    override var isOn: Bool { didSet { if isOn != oldValue { updateTip() } } }

    static var size: CGFloat { FloatPillButton.height }
    private static var globeSide: CGFloat { TermAppearance.scaled(15) }
    private static var labelFont: NSFont { TermAppearance.uiTextFont(TermAppearance.scaled(11), weight: .medium) }
    private let attentionDot = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        attentionDot.cornerRadius = TermAppearance.scaled(4)
        attentionDot.borderWidth = 1.5
        attentionDot.isHidden = true
        layer?.addSublayer(attentionDot)
        updateTip()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 알약에 적는 상태 글자(nil = 버튼만): 읽을 만한 상태일 때만. 기다림은 느낌표를 붙인다(색만으로 구분하지 않게).
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

    /// 지구본 왼쪽 여백: 버튼일 때 지구본이 가운데에 오는 값 — 알약이 되어도 지구본은 제자리
    private var leadPad: CGFloat { (Self.size - Self.globeSide) / 2 }
    private var labelGap: CGFloat { TermAppearance.scaled(6) }

    override var intrinsicContentSize: NSSize {
        guard statusText != nil else { return NSSize(width: Self.size, height: Self.size) }
        return NSSize(width: ceil(leadPad + Self.globeSide + labelGap + textWidth + TermAppearance.scaled(10)), height: Self.size)
    }

    static let badgeLabel = "결과 있음"

    /// 지구본·글자 색
    private var tint: NSColor {
        if showsBadge { return TermAppearance.statusDone }
        switch indicator {
        case .agent: return TermAppearance.agent
        case .waiting: return TermAppearance.statusAttention
        case .user, .idle: return TermAppearance.textPrimary
        case .switching, nil: return emphasized ? TermAppearance.textPrimary : TermAppearance.textSecondary
        }
    }

    override var borderTint: NSColor {
        if indicator == .agent { return TermAppearance.agent }
        if indicator?.needsAttention == true { return TermAppearance.statusAttention }
        return TermAppearance.border
    }

    override func scaleChanged() {
        super.scaleChanged()
        attentionDot.cornerRadius = TermAppearance.scaled(4)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let side = TermAppearance.scaled(8), inset = TermAppearance.scaled(2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attentionDot.frame = NSRect(x: bounds.maxX - side - inset, y: bounds.maxY - side - inset, width: side, height: side)
        CATransaction.commit()
    }

    override func refreshChrome(animated: Bool = true) {
        super.refreshChrome(animated: animated)
        // 나를 기다림: 오른쪽 위 점
        attentionDot.isHidden = indicator?.needsAttention != true
        attentionDot.backgroundColor = TermAppearance.statusAttention.cg(in: self)
        attentionDot.borderColor = TermAppearance.background.cg(in: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = Self.globeSide
        // 켜지면 속이 찬 지구본(지구본은 속이 찬 짝이 따로 없어 같은 기호를 두껍게 — 바탕 한 단계 밝음과 함께)
        if let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side, weight: isOn ? .semibold : .regular)
                .applying(.init(paletteColors: [tint]))) {
            let size = image.size
            image.draw(in: NSRect(x: leadPad + (side - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        if let text = statusText {
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: tint]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: leadPad + side + labelGap, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
    }

    private func updateTip() {
        let state = showsBadge ? Self.badgeLabel : (indicator?.label ?? "떠 있는 브라우저 없음")
        toolTip = "\(isOn ? "브라우저 칸 닫기" : "브라우저 칸 열기") (⌘⇧B) — \(state)"
    }
}
