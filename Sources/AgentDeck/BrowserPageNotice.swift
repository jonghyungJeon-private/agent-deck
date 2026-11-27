import AppKit
import BrowserCore

/// 브라우저 화면 위 가운데 카드. 창 없는(headless) Chrome 은 페이지의 대화상자(alert·confirm·prompt·beforeunload)를
/// 그리지 않아, 칸이 대신 보이고 사람의 답을 Chrome 에 보낸다. 답하기 전까지 그 탭의 페이지는 멈춰 있다.
/// 아무도 답할 수 없게 된 대화상자 등으로 탭이 응답하지 않으면 그렇다고 알리고 새로고침·탭 닫기를 준다.
final class PageNoticeView: NSView {
    /// 단추: (주 단추인지, prompt 글). 대화상자 = 확인/나가기(true)·취소/머무르기(false), 응답 없음 = 새로고침(true)·탭 닫기(false)
    var onAnswer: ((Bool, String?) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let field = NSTextField(string: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let cancelButton = PillButton(title: "", target: nil, action: nil)
    private let okButton = PillButton(title: "", target: nil, action: nil)
    private let stack = NSStackView()
    private var isPrompt = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = TermAppearance.scaled(10)
        layer?.borderWidth = 1
        titleLabel.font = TermAppearance.uiTextFont(TermAppearance.scaled(TypeSize.row), weight: .semibold)
        titleLabel.textColor = TermAppearance.textPrimary
        messageLabel.font = TermAppearance.uiTextFont(TermAppearance.scaled(TypeSize.row))
        messageLabel.textColor = TermAppearance.textPrimary
        messageLabel.maximumNumberOfLines = 8
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.cell?.truncatesLastVisibleLine = true
        messageLabel.isSelectable = true
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.font = TermAppearance.uiTextFont(TermAppearance.scaled(TypeSize.row))
        field.target = self
        field.action = #selector(ok)
        hintLabel.font = TermAppearance.uiTextFont(TermAppearance.scaled(TypeSize.secondary))
        hintLabel.textColor = TermAppearance.textSecondary
        for (button, action) in [(cancelButton, #selector(cancel)), (okButton, #selector(ok))] {
            button.font = TermAppearance.uiTextFont(TermAppearance.scaled(TypeSize.row), weight: .semibold)
            button.target = self
            button.action = action
        }
        cancelButton.style = .secondary
        okButton.style = .primary
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [hintLabel, spacer, cancelButton, okButton])
        buttons.orientation = .horizontal
        buttons.spacing = Space.sm
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.sm
        stack.edgeInsets = NSEdgeInsets(top: Space.md, left: Space.md, bottom: Space.md, right: Space.md)
        stack.setViews([titleLabel, messageLabel, field, buttons], in: .top)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Space.md),
            field.widthAnchor.constraint(equalTo: buttons.widthAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: buttons.widthAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: TermAppearance.scaled(300)),
        ])
        refreshLayerColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 여러 줄 글은 폭을 알아야 줄을 나눈다(자동 배치는 폭을 정한 뒤에야 안다)
    override func layout() {
        super.layout()
        let width = bounds.width - 2 * Space.md
        if width > 0, messageLabel.preferredMaxLayoutWidth != width {
            messageLabel.preferredMaxLayoutWidth = width
            needsLayout = true
        }
    }

    private func refreshLayerColors() {
        layer?.backgroundColor = TermAppearance.chrome.cg(in: self)
        layer?.borderColor = TermAppearance.border.cg(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayerColors()
    }

    /// 페이지의 대화상자. `canAnswer` = 사람이 제어를 가졌다(아니면 단추를 끄고 어떻게 답하는지 알린다)
    func show(dialog: PageDialog, canAnswer: Bool) {
        let (title, cancel, ok): (String, String?, String) = switch dialog.type {
        case "confirm": ("페이지가 확인을 묻습니다", "취소", "확인")
        case "prompt": ("페이지가 입력을 묻습니다", "취소", "확인")
        case "beforeunload": ("이 페이지에서 나갈까요?", "머무르기", "나가기")
        default: ("페이지 알림", nil, "확인")
        }
        let wasPrompt = isPrompt
        isPrompt = dialog.type == "prompt"
        if isPrompt, !wasPrompt || isHidden { field.stringValue = dialog.defaultPrompt }
        let message = dialog.message.isEmpty && dialog.type == "beforeunload" ? "변경한 내용이 저장되지 않을 수 있습니다." : dialog.message
        fill(title: title, message: message, cancel: cancel, ok: ok,
             hint: canAnswer ? nil : "답하려면 \u{201C}제어 가져오기\u{201D}", enabled: canAnswer)
        field.isHidden = !isPrompt
        field.isEnabled = canAnswer
        if isPrompt, canAnswer, window?.firstResponder !== field.currentEditor() { window?.makeFirstResponder(field) }
    }

    /// 보는 탭이 응답하지 않는다(답할 곳 없는 대화상자가 떠 있는 탭 등)
    func showUnresponsive() {
        isPrompt = false
        field.isHidden = true
        fill(title: "이 탭이 응답하지 않습니다",
             message: "페이지에 확인창(대화상자)이 떠 있는데 답할 곳이 없으면 이렇게 멈춥니다. 새로고침하면 확인창은 취소로 닫힙니다.",
             cancel: "탭 닫기", ok: "새로고침", hint: nil, enabled: true)
    }

    func hide() {
        guard !isHidden else { return }
        if let editor = field.currentEditor(), window?.firstResponder === editor { window?.makeFirstResponder(nil) }
        isHidden = true
        okButton.keyEquivalent = ""
        cancelButton.keyEquivalent = ""
    }

    private func fill(title: String, message: String, cancel: String?, ok: String, hint: String?, enabled: Bool) {
        titleLabel.stringValue = title
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
        messageLabel.toolTip = message
        hintLabel.stringValue = hint ?? ""
        hintLabel.isHidden = hint == nil
        cancelButton.title = cancel ?? ""
        cancelButton.isHidden = cancel == nil
        okButton.title = ok
        okButton.isEnabled = enabled
        cancelButton.isEnabled = enabled
        // Return = 주 단추, Esc = 취소(보이고 누를 수 있을 때만 — 숨은 카드가 화면의 키를 가져가지 않게)
        okButton.keyEquivalent = enabled ? "\r" : ""
        cancelButton.keyEquivalent = enabled && cancel != nil ? "\u{1b}" : ""
        isHidden = false
    }

    @objc private func ok() {
        guard okButton.isEnabled, !isHidden else { return }
        onAnswer?(true, isPrompt ? field.stringValue : nil)
    }

    @objc private func cancel() {
        guard cancelButton.isEnabled, !isHidden else { return }
        onAnswer?(false, nil)
    }

    /// 시험 명령 `browser-notice`: 보이는지·제목·글·단추
    var debugText: String {
        guard !isHidden else { return "hidden" }
        let buttons = [cancelButton.isHidden ? nil : cancelButton.title, okButton.title].compactMap { $0 }
        return "\(titleLabel.stringValue) | \(messageLabel.stringValue) | " + buttons.joined(separator: "/")
            + (okButton.isEnabled ? "" : " (disabled: \(hintLabel.stringValue))") + (isPrompt ? " field=\(field.stringValue)" : "")
    }
}
