import AppKit

/// 세션 창 안 browser 도구(오른쪽 도크): 세션 창에서 고른 세션의 브라우저를 보여 준다.
/// 그 세션의 보는 곳이 "별도 창"이면 브라우저는 그 창에만 보이고, 여기는 안내와 "여기서 보기"만 둔다(한 번에 한 곳).
/// 칸(BrowserPaneView)은 BrowserWindows 가 세션마다 들고 있다 — 여기는 빌려 달고, 도구가 숨거나 다른 세션으로 가면 내려놓는다.
final class BrowserDockController: NSViewController, ToolContent {
    /// 따라가는 세션(세션 창에서 마지막으로 고른 에이전트 세션, 또는 ⇧⌘B·칩으로 연 세션)
    private(set) var owner: String?
    /// 지금 달려 있는 칸
    private(set) var hosted: BrowserPaneView?
    /// 도구가 보이는지(ToolWindowsController.apply)
    private var visible = false

    /// 세션의 칸 — 그 세션의 보는 곳이 세션 창 안일 때만(아니면 nil → 안내)
    var paneFor: ((String) -> BrowserPaneView?)?
    /// "여기서 보기": 그 세션의 보는 곳을 세션 창 안으로
    var onShowHere: ((String) -> Void)?
    /// "창 앞으로": 별도 창을 앞으로
    var onShowWindow: ((String) -> Void)?
    var titleFor: ((String) -> String?)?
    /// 그 세션의 별도 창이 떠 있는지(안내 문구)
    var windowOpen: ((String) -> Bool)?

    private let placeholder = NSStackView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let hereButton = PillButton(title: "여기서 보기", target: nil, action: nil)
    private let windowButton = NSButton(title: "창 앞으로", target: nil, action: nil)

    /// 보이는 칸의 세션(알림 거르기·isOpen)
    var showing: String? { visible ? hosted?.owner : nil }

    override func loadView() {
        let root = BackgroundView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        root.color = TermAppearance.background
        message.alignment = .center
        message.textColor = TermAppearance.textSecondary
        message.font = .systemFont(ofSize: TermAppearance.scaled(12.5))
        hereButton.font = .systemFont(ofSize: TermAppearance.scaled(12), weight: .semibold)
        hereButton.fill = TermAppearance.agentColor
        hereButton.target = self
        hereButton.action = #selector(showHere)
        windowButton.bezelStyle = .inline
        windowButton.font = .systemFont(ofSize: TermAppearance.scaled(11.5))
        windowButton.target = self
        windowButton.action = #selector(showWindow)
        let buttons = NSStackView(views: [hereButton, windowButton])
        buttons.spacing = 8
        placeholder.orientation = .vertical
        placeholder.spacing = 12
        placeholder.alignment = .centerX
        placeholder.addArrangedSubview(message)
        placeholder.addArrangedSubview(buttons)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -32),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        view = root
    }

    func setToolVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        refresh()
    }

    /// 따라갈 세션을 바꾼다. force = ⇧⌘B·칩처럼 그 세션을 콕 집어 열었을 때(같아도 다시 본다)
    func follow(_ owner: String?, force: Bool) {
        guard force || owner != self.owner else { return }
        self.owner = owner
        onOwnerWillRefresh?(owner) // 새 세션의 작은 창 열림 여부를 먼저 맞춘다(안 보일 칸을 잠깐 붙이지 않게)
        refresh()
        onOwnerChange?()
    }

    /// 따라가는 세션이 정해진 직후, 칸을 달기 전
    var onOwnerWillRefresh: ((String?) -> Void)?
    /// 따라가는 세션이 바뀜(어느 길로든 — 세션 고르기·알림·목록 아이콘): 🌐 버튼·작은 창 제목을 고친다
    var onOwnerChange: (() -> Void)?

    /// 지금 세션·보는 곳·보임에 맞춰 칸을 달거나 내려놓고 안내를 고친다
    func refresh() {
        _ = view
        let want = visible ? owner.flatMap { paneFor?($0) } : nil
        if hosted !== want {
            if let hosted, hosted.superview === view {
                hosted.detach()
                hosted.removeFromSuperview()
            }
            hosted = nil
            if let want {
                // 다른 곳(별도 창)에 달려 있었으면 BrowserWindows 가 먼저 떼었다 — 여기서는 옮겨 달기만
                want.removeFromSuperview()
                want.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(want)
                NSLayoutConstraint.activate([
                    want.topAnchor.constraint(equalTo: view.topAnchor),
                    want.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    want.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    want.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                ])
                want.docked = true
                want.attach()
                hosted = want
            }
        }
        placeholder.isHidden = hosted != nil
        guard hosted == nil else { return }
        if let owner {
            let name = titleFor?(owner).map { "“\($0)” " } ?? ""
            let open = windowOpen?(owner) == true
            message.stringValue = open ? "\(name)세션의 브라우저는 별도 창에서 보는 중이에요"
                                       : "\(name)세션의 브라우저는 별도 창으로 보도록 되어 있어요"
            windowButton.title = open ? "창 앞으로" : "창 열기"
            hereButton.isHidden = false
            windowButton.isHidden = false
        } else {
            message.stringValue = "세션을 고르면 그 세션의 브라우저가 여기에 보여요"
            hereButton.isHidden = true
            windowButton.isHidden = true
        }
    }

    /// 브라우저 화면에 키보드를 준다(⇧⌘B 로 열었을 때)
    func focus() {
        guard let hosted, let window = view.window else { return }
        window.makeFirstResponder(hosted.focusTarget)
    }

    @objc private func showHere() { if let owner { onShowHere?(owner) } }
    @objc private func showWindow() { if let owner { onShowWindow?(owner) } }
}
