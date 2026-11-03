import AppKit
import BrowserCore
import ImageIO
import TermWire

/// 브라우저 화면: 에이전트 화면(owner)의 브라우저(abx 세션)를 CDP screencast 로 받아 그린다.
/// 사람은 머리 줄의 "제어 가져오기"(abx handoff)로 제어를 받은 동안에만 클릭·키보드로 조작한다
/// (AI 가 쥐고 있을 때 보낸 입력은 버리고, Chrome 의 입력 잠금도 막는다). "AI에게 돌려주기" = abx resume.
/// 브라우저는 에이전트가 `abx` 를 처음 쓸 때 창 없이 뜬다.
final class BrowserPaneView: NSView {
    let owner: String
    private let header = NSTextField(labelWithString: "")
    /// 머리 줄 맨 앞의 상태 알약(화면 제목 줄의 브라우저 칩과 같은 모양·색): AI 제어 중·내가 조작 중·쉬는 중…
    private let statePill = BrowserChipView()
    private var headerAfterPill: NSLayoutConstraint!
    private var headerAtEdge: NSLayoutConstraint!
    private let controlButton = PillButton(title: "", target: nil, action: nil)
    private let pinButton = NSButton(title: "항상 위", target: nil, action: nil)
    /// 창에 넣었을 때: "항상 위" 를 누르면(켜짐 여부)
    var onPin: ((Bool) -> Void)? {
        didSet { pinButton.isHidden = onPin == nil }
    }
    private let screen = BrowserScreenView()
    /// 탭 칩 줄: 브라우저의 탭들(AI 작업 공간마다 묶음, 사람 탭은 뒤). 누르면 그 탭을 계속 보여 준다.
    private let tabBar = NSStackView()
    private let tabScroll = NSScrollView()
    private var tabBarHeight: NSLayoutConstraint!
    private var chips: [BrowserTabs.Chip] = []
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    /// 화면 아래 상태 줄(늘 있다 — 나타났다 사라지면 브라우저 크기가 바뀌어 페이지가 다시 그려진다):
    /// 지금 누가 쥐고 있고 사람은 무엇을 할 수 있는지 한 줄로
    private let statusBar = NSView()
    private let statusLine = NSTextField(labelWithString: "")
    /// AI 가 마지막으로 일한 탭이 보고 있는 탭이 아니면 그 탭 이름(탭 칩에서)
    private var agentElsewhere: String?
    /// 상태 줄이 탭 이름을 찾는 칩(칩 줄을 다시 그리지 않을 때도 최신)
    private var chipsForStatus: [BrowserTabs.Chip] = []
    /// 보고 있는 탭(바뀌면 그 전 탭의 AI 커서를 지운다)
    private var shownTarget: String?
    /// 보고 있는 페이지가 빈 탭이면 흰 화면 대신 안내를 보인다
    private var blankPage = false
    /// 빈 탭을 보는 동안 온 마지막 그림 — 다음 페이지의 첫 그림이 빈 탭 판정보다 먼저 오면 그것을 버리지 않고 보여 준다
    private var heldFrame: (image: CGImage, size: CGSize, target: String?)?
    /// 마지막으로 보인 그림 — 빈 주소로 바뀌었는데 내용이 있는 페이지였으면 다시 그리길 기다리지 않고 이걸 보인다
    private var lastFrame: (image: CGImage, size: CGSize, target: String?)?
    private var feed: BrowserFeed?
    /// 마지막 상태의 제어권(입력을 보낼지 정한다)
    private(set) var control: AbxStatus.Control?
    /// 제어 가져오기·돌려주기를 abx 에 보내 답을 기다리는 중
    private var requesting = false
    /// 마지막 프레임의 페이지 크기(CSS 픽셀) — 칸의 점을 페이지 좌표로 바꿀 때
    private(set) var viewport: CGSize = .zero
    /// 칸에 보이는 탭의 주소·제목(사람이 검색·이동하면 abx 의 기록보다 이것이 새것)
    private var page: (url: String, title: String)?
    private var lastStatus: AbxStatus?

    init(owner: String, frame: NSRect) {
        self.owner = owner
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TermAppearance.background.cgColor

        header.font = .systemFont(ofSize: TermAppearance.scaled(12))
        header.textColor = TermAppearance.textPrimary
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = TermAppearance.chrome.cgColor
        statusLine.font = .systemFont(ofSize: TermAppearance.scaled(12), weight: .medium)
        statusLine.lineBreakMode = .byTruncatingTail
        statusLine.textColor = TermAppearance.textSecondary
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        statusLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusBar.addSubview(statusLine)
        statePill.isHidden = true
        header.lineBreakMode = .byTruncatingMiddle
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 이 창에서 가장 중요한 버튼: 색을 채운 알약(누가 쥐고 있는지에 따라 색이 바뀐다 — setControl)
        controlButton.font = .systemFont(ofSize: TermAppearance.scaled(12), weight: .semibold)
        controlButton.target = self
        controlButton.action = #selector(toggleControl)
        controlButton.isHidden = true
        pinButton.bezelStyle = .inline
        pinButton.controlSize = .small
        pinButton.font = .systemFont(ofSize: TermAppearance.scaled(11))
        pinButton.setButtonType(.pushOnPushOff)
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        pinButton.isHidden = true
        pinButton.toolTip = "다른 창보다 항상 위에 두기"
        screen.pane = self
        placeholder.alignment = .center
        placeholder.textColor = TermAppearance.textSecondary
        tabBar.orientation = .horizontal
        tabBar.spacing = 4
        tabBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.documentView = tabBar
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = false
        tabScroll.hasVerticalScroller = false
        tabScroll.horizontalScrollElasticity = .allowed
        tabScroll.verticalScrollElasticity = .none
        tabScroll.isHidden = true
        for view in [statePill, header, pinButton, controlButton, tabScroll, screen, statusBar, placeholder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        tabBarHeight = tabScroll.heightAnchor.constraint(equalToConstant: 0)
        headerAfterPill = header.leadingAnchor.constraint(equalTo: statePill.trailingAnchor, constant: 6)
        headerAtEdge = header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            statePill.centerYAnchor.constraint(equalTo: controlButton.centerYAnchor),
            statePill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.centerYAnchor.constraint(equalTo: controlButton.centerYAnchor),
            headerAtEdge,
            header.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -8),
            pinButton.centerYAnchor.constraint(equalTo: controlButton.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: controlButton.leadingAnchor, constant: -6),
            controlButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            controlButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tabScroll.topAnchor.constraint(equalTo: controlButton.bottomAnchor, constant: 3),
            tabScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBarHeight,
            tabBar.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: tabScroll.contentView.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            screen.topAnchor.constraint(equalTo: tabScroll.bottomAnchor, constant: 3),
            screen.leadingAnchor.constraint(equalTo: leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: trailingAnchor),
            screen.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: TermAppearance.scaled(24)),
            statusLine.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLine.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -10),
            statusLine.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            placeholder.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: screen.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: screen.widthAnchor, constant: -40),
        ])
        show(.waiting("브라우저를 찾는 중…"))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 키보드를 받을 뷰(TerminalHostController 가 포커스를 줄 곳)
    var focusTarget: NSView { screen }

    /// 칸이 화면에 놓였다(TerminalHostController.render). 창이 실제로 보일 때만 스트림을 돈다.
    func attach() {
        placed = true
        updateFeed()
    }

    /// 칸이 화면에서 빠졌다(다른 탭·닫기). 브라우저·에이전트는 계속 돈다.
    func detach() {
        placed = false
        updateFeed()
    }

    private var placed = false
    private var framesShown = 0

    /// 시험 명령 `browsers` 가 찍는 상태
    var debugState: String {
        "owner=\(owner.prefix(4)) placed=\(placed) visible=\(windowVisible) streaming=\(feed != nil) frames=\(framesShown) "
            + "control=\(control?.rawValue ?? "-") viewport=\(Int(viewport.width))x\(Int(viewport.height))"
            + " " + (feed?.debugSize ?? "")
    }
    private var observers: [NSObjectProtocol] = []

    /// 창이 가려지거나(다른 창·최소화) 앱을 숨기면 멈추고, 다시 보이면 이어 받는다
    private var windowVisible: Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible) && !NSApp.isHidden
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            let center = NotificationCenter.default
            let update: (Notification) -> Void = { [weak self] _ in self?.updateFeed() }
            observers = [
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: update),
                center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main, using: update),
                center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main, using: update),
            ]
        }
        updateFeed()
    }

    private func updateFeed() {
        if placed && windowVisible { startFeed() } else { stopFeed() }
    }

    private func startFeed() {
        guard feed == nil else { return }
        let feed = BrowserFeed(owner: owner)
        feed.onState = { [weak self] state in self?.show(state) }
        feed.onPage = { [weak self] url, title in
            self?.page = (url, title)
            if let status = self?.lastStatus { self?.show(.live(status)) }
        }
        feed.onTabs = { [weak self] chips, pinned in self?.showTabs(chips, pinned: pinned) }
        feed.onCursor = { [weak self] cursor in self?.offerCursor(cursor) }
        feed.onImage = { [weak self] image, viewport, target in
            guard let self else { return }
            self.viewport = viewport
            self.framesShown += 1
            guard !self.blankPage else { // 빈 탭: 흰 그림 대신 안내
                self.heldFrame = (image, viewport, target)
                self.checkBlank(target)
                return
            }
            self.frameTarget = target
            self.heldFrame = nil // 더 새 그림
            self.lastFrame = (image, viewport, target)
            self.screen.show(image, viewport: viewport)
            self.placeholder.isHidden = true
            self.retryCursor() // 첫 그림을 기다리던 커서
        }
        self.feed = feed
        feed.start()
        feed.fit(to: screen.bounds.size)
    }

    /// 브라우저 크기를 칸에 맞춘다(창을 끌어 크기를 바꾸는 동안은 모았다가 한 번)
    private var fitWork: DispatchWorkItem?
    func screenResized() {
        fitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.feed?.fit(to: self.screen.bounds.size)
        }
        fitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func stopFeed() {
        screen.releaseInput()
        feed?.stop()
        feed = nil
    }

    private func show(_ state: BrowserFeed.State) {
        switch state {
        case .waiting(let text):
            setPill(nil)
            header.stringValue = "브라우저"
            blankPage = false
            // 브라우저가 없다: 예전 상태(AI 가 쓰는 중 등)를 상태 줄에 남기지 않는다
            lastStatus = nil
            page = nil
            shownTarget = nil
            placeholder.attributedStringValue = Self.placeholderText(text)
            placeholder.isHidden = false
            screen.show(nil, viewport: viewport)
            setControl(nil)
        case .live(let status):
            lastStatus = status
            // 누가 쥐고 있는지는 앞의 알약이 보인다. 여기는 덧붙일 말만(넘긴 이유, 기다리는 까닭)
            setPill(BrowserIndicator(status))
            let control: String?
            switch BrowserIndicator(status) {
            case .waiting(let message)?: control = message.isEmpty ? nil : message
            case .switching?: control = "AI 가 하던 동작이 끝나길 기다리는 중"
            default: control = nil
            }
            let shown = page ?? status.activeTab.map { ($0.url, $0.title) }
            // 빈 탭은 세지 않는다(칩에도 없다)
            let count = status.tabs.filter { !BrowserTabs.blank($0.url) }.count
            let tabs = count > 1 ? " · 탭 \(count)개" : ""
            // 보고 있는 페이지가 빈 탭(작업이 끝나고 남은 탭 등): 흰 화면 대신 어두운 안내
            if let url = shown?.0, !BrowserTabs.blank(url) { populatedBlank = nil }
            let populated = populatedBlank != nil && populatedBlank == shownTarget
            let blank = !populated && (shown.map { BrowserTabs.blank($0.0) } ?? false)
            if blank != blankPage {
                blankPage = blank
                if blank {
                    // 이 탭이 보낸 마지막 그림은 들고 있다가, 내용이 있는 페이지로 밝혀지면 바로 보인다
                    if heldFrame == nil, let last = lastFrame, last.target != nil, last.target == shownTarget { heldFrame = last }
                    screen.show(nil, viewport: viewport)
                    screen.hideCursor()
                    checkBlank(shownTarget)
                    placeholder.attributedStringValue = Self.placeholderText("열린 페이지가 없어요", detail: "AI 가 브라우저를 쓰면 여기에 보여요")
                }
                placeholder.isHidden = !blank
                // 빈 탭에서 나왔다: 그사이 온 새 페이지 그림을 바로(멈춘 페이지는 다음 그림이 늦게 올 수 있다)
                // 그 탭이 보낸 그림만(옮기기 직전 빈 탭의 흰 그림이면 다음 그림을 기다린다)
                if !blank { showHeldFrame() }
                if !blank { retryCursor() }
            }
            // 제목이 없는 페이지는 Chrome 이 주소를 제목으로 준다 — 같으면 한 번만
            let title = shown.flatMap { $0.0.contains($0.1) ? nil : $0.1 }
            header.stringValue = blank ? "빈 탭" + tabs : [control, title, shown?.0].compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ") + tabs
            setControl(status.control)
        }
    }

    /// 화면 가운데 안내(제목 15pt + 설명 12pt)
    private static func placeholderText(_ title: String, detail: String? = nil) -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: TermAppearance.scaled(15), weight: .semibold),
            .foregroundColor: TermAppearance.textPrimary, .paragraphStyle: center])
        if let detail {
            text.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: NSFont.systemFont(ofSize: TermAppearance.scaled(12)),
                .foregroundColor: TermAppearance.textSecondary, .paragraphStyle: center]))
        }
        return text
    }

    /// 아래 상태 줄: 지금 누가 쥐고 있고, 사람이 무엇을 할 수 있는지
    private func updateStatusLine() {
        let indicator = lastStatus.flatMap(BrowserIndicator.init)
        // AI 가 일하는 탭 = abx 의 활성 탭. 보고 있는 탭과 id 로 견준다(빈 탭은 칩에 없어도)
        let active = lastStatus?.activeTab?.targetId
        let onShown = active != nil && active == shownTarget
        agentElsewhere = onShown || active == nil ? nil
            : chipsForStatus.first(where: { $0.targetId == active })?.text ?? "빈 탭"
        let text: String
        let color: NSColor
        switch indicator {
        case _ where requesting:
            // 누른 뒤 답을 기다리는 중: 입력은 이미 막혔거나 아직이다 — 그렇다고 말한다
            text = givingBack ? "AI에게 넘기는 중…" : "제어 가져오는 중… AI 가 하던 동작이 끝나면 넘어와요"
            color = TermAppearance.yellow
        case .agent?:
            if let other = agentElsewhere {
                text = "●  AI 가 다른 탭(\(other))에서 작업 중 · 이 탭은 보기만 돼요"
            } else {
                text = "●  AI 가 이 탭을 쓰는 중 · 보기만 돼요 — 직접 하려면 \u{201C}제어 가져오기\u{201D}"
            }
            color = TermAppearance.agentColor
        case .user?:
            text = "직접 조작 중 — 끝나면 \u{201C}AI에게 돌려주기\u{201D}"
            color = TermAppearance.userColor
        case .waiting(let message)?:
            text = "AI 가 기다려요" + (message.isEmpty ? "" : ": \(message)") + " — 끝나면 \u{201C}AI에게 돌려주기\u{201D}"
            color = TermAppearance.yellow
        case .switching?:
            text = "제어를 넘겨받는 중… AI 가 하던 동작이 끝나길 기다려요"
            color = TermAppearance.yellow
        case .idle?:
            text = "브라우저 대기 — 페이지를 눌러 보려면 \u{201C}제어 가져오기\u{201D}"
            color = TermAppearance.textSecondary
        case nil:
            text = ""
            color = TermAppearance.textSecondary
        }
        statusLine.stringValue = text
        statusLine.textColor = color
        statusLine.toolTip = text
        // 초록 테두리는 AI 가 바로 이 탭에서 일할 때만(다른 탭에서 일하면 이 페이지에 그리면 헷갈린다)
        screen.setAgentActive(control == .agent && onShown && !blankPage)
    }

    private func setPill(_ indicator: BrowserIndicator?) {
        statePill.isHidden = indicator == nil
        if let indicator { statePill.indicator = indicator }
        // 나가는 제약을 먼저 끈다(둘이 함께 켜진 순간이 없게)
        if indicator == nil {
            headerAfterPill.isActive = false
            headerAtEdge.isActive = true
        } else {
            headerAtEdge.isActive = false
            headerAfterPill.isActive = true
        }
    }

    // MARK: - 탭 칩

    /// 탭이 둘 이상이거나 사람이 고른 탭을 보고 있으면 칩 줄을 보인다
    /// AI 커서: AI 가 쥐고 있을 때, 지금 그림이 나오는 그 탭의 것만(탭을 옮기는 사이 새 탭 커서가 옛 그림 위에 뜨지 않게).
    /// 아직 보여 줄 수 없으면(첫 그림이 오는 중, 빈 탭에서 넘어오는 중, 그 탭으로 옮기는 중) 들고 있다가 준비되면 —
    /// feed 는 같은 커서를 다시 보내지 않으니 여기서 놓치면 그 단계의 커서는 영영 안 보인다.
    private var pendingCursor: AgentCursor?
    /// 지금 칸에 있는 그림을 보낸 탭 — 탭을 옮긴 직후엔 아직 옛 탭 그림이다
    private var frameTarget: String?

    private func offerCursor(_ cursor: AgentCursor) {
        guard control == .agent, Date().timeIntervalSince1970 * 1000 - cursor.t < 3000 else { pendingCursor = nil; return }
        let shown = !blankPage && cursor.targetId == shownTarget && cursor.targetId == frameTarget && screen.showCursor(cursor)
        pendingCursor = shown ? nil : cursor
    }

    /// 빈 탭에 있는 동안 온 그림: 그 그림을 보낸 탭이 보이는 탭이 되면 바로 보인다(가만한 페이지는 다음 그림이 늦다).
    /// 옮기기 직전 빈 탭의 흰 그림이면 보이지 않고 그 탭의 그림을 기다린다.
    private func showHeldFrame() {
        guard let held = heldFrame, held.target != nil, held.target == shownTarget else { return }
        heldFrame = nil
        frameTarget = held.target
        screen.show(held.image, viewport: held.size)
        placeholder.isHidden = true
        retryCursor()
    }

    private func retryCursor() {
        if let cursor = pendingCursor { offerCursor(cursor) }
    }

    /// 주소만 about:blank 인데 내용이 있는 페이지(document.write·스타일 등 — 빈 문서의 틀 말고 무엇이든 있으면): 빈 페이지는 다시 그리지 않으니, 빈 탭에 그림이
    /// 오면 그때 문서가 정말 비었는지 본다. 내용이 있으면 그 탭은 보통 페이지처럼 보인다.
    private var populatedBlank: String?
    private var checkingBlank = false
    /// 확인하는 동안 다른 확인이 왔다(탭을 옮겼다 등): 끝나면 지금 탭을 다시 본다
    private var blankRecheck = false

    private func checkBlank(_ target: String?) {
        guard let target, target == shownTarget, populatedBlank != target, let feed else { return }
        guard !checkingBlank else { blankRecheck = true; return }
        checkingBlank = true
        blankRecheck = false
        feed.evaluate("document.documentElement.outerHTML.replace(/\\s/g, '') !== '<html><head></head><body></body></html>'") { [weak self] value in
            guard let self else { return }
            self.checkingBlank = false
            guard value as? Bool == true, self.blankPage, self.shownTarget == target else {
                if self.blankRecheck, self.blankPage { self.checkBlank(self.shownTarget) }
                return
            }
            self.populatedBlank = target
            self.feed?.keepBlank(target)
            if let status = self.lastStatus { self.show(.live(status)) }
        }
    }

    private func showTabs(_ chips: [BrowserTabs.Chip], pinned: Bool) {
        let shown = chips.first(where: \.shown)?.targetId
        if shown != shownTarget {
            shownTarget = shown
            populatedBlank = nil
            screen.hideCursor() // 커서는 그 탭의 것
            // 빈 주소인 탭으로 옮겼다: 내용이 있는지 이제 본다 — 가만한 페이지는 다시 그리지 않는다
            if blankPage { checkBlank(shown) }
            if !blankPage { showHeldFrame() }
            retryCursor() // 이 탭으로 옮기길 기다리던 커서
        }
        self.chipsForStatus = chips
        updateStatusLine()
        guard chips != self.chips || tabBar.arrangedSubviews.last?.identifier?.rawValue != (pinned ? "follow" : "chip") else { return }
        self.chips = chips
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let visible = chips.count > 1 || pinned
        tabScroll.isHidden = !visible
        tabBarHeight.constant = visible ? TermAppearance.scaled(22) : 0
        guard visible else { return }
        var group: String?? = .none
        for (i, chip) in chips.enumerated() {
            if group != .some(chip.group) {
                // 묶음 사이는 조금 더 띄운다
                if let last = tabBar.arrangedSubviews.last { tabBar.setCustomSpacing(10, after: last) }
                group = .some(chip.group)
                let label = NSTextField(labelWithString: chip.group ?? "내 탭")
                label.font = .systemFont(ofSize: TermAppearance.scaled(10), weight: .semibold)
                label.textColor = TermAppearance.textSecondary
                tabBar.addArrangedSubview(label)
            }
            let text = chip.text.count > 22 ? String(chip.text.prefix(21)) + "…" : chip.text
            let button = NSButton(title: (chip.agentHere ? "● " : "") + text, target: self, action: #selector(chipClicked(_:)))
            if chip.agentHere { Self.markAgent(button, text: text) }
            button.identifier = NSUserInterfaceItemIdentifier("chip")
            button.tag = i
            button.bezelStyle = .recessed
            button.setButtonType(.pushOnPushOff)
            button.controlSize = .small
            button.font = .systemFont(ofSize: TermAppearance.scaled(11))
            button.state = chip.shown ? .on : .off
            let owner = chip.users ? "사람이 연 탭" + (chip.group != nil ? " · AI 가 맡아 쓰는 중" : "") : "AI 탭 · 작업 공간 \(chip.group ?? BrowserTabs.main)"
            button.toolTip = [chip.title, chip.url, [chip.tabId, owner].compactMap { $0 }.joined(separator: " · "),
                              chip.agentHere ? "● AI 가 마지막으로 일한 탭" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            let menu = NSMenu()
            let close = NSMenuItem(title: "탭 닫기", action: #selector(closeChip(_:)), keyEquivalent: "")
            close.target = self
            close.tag = i
            menu.addItem(close)
            button.menu = menu
            tabBar.addArrangedSubview(button)
        }
        if pinned {
            let follow = NSButton(title: "AI 따라가기", target: self, action: #selector(followAgent))
            follow.identifier = NSUserInterfaceItemIdentifier("follow")
            follow.bezelStyle = .inline
            follow.controlSize = .small
            follow.font = .systemFont(ofSize: TermAppearance.scaled(11))
            follow.toolTip = "AI 가 일하는 탭을 다시 따라 보여 주기"
            tabBar.addArrangedSubview(follow)
        }
    }

    /// AI 가 마지막으로 일한 탭: 칩 앞의 ● 를 AI 색(초록)으로 또렷하게 — 회색 글자 사이에서도 바로 보이게
    private static func markAgent(_ button: NSButton, text: String) {
        let size = TermAppearance.scaled(11)
        let title = NSMutableAttributedString(string: "● ", attributes: [
            .foregroundColor: TermAppearance.agentColor,
            .font: NSFont.systemFont(ofSize: size + 1, weight: .heavy),
        ])
        title.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]))
        button.attributedTitle = title
        button.attributedAlternateTitle = title
    }

    @objc private func chipClicked(_ sender: NSButton) {
        guard chips.indices.contains(sender.tag) else { return }
        screen.hideCursor() // 다른 탭으로 가면 그 커서는 이제 보이지 않는 탭의 것
        feed?.watch(chips[sender.tag].targetId)
    }

    @objc private func closeChip(_ sender: NSMenuItem) {
        guard chips.indices.contains(sender.tag) else { return }
        feed?.closeTab(chips[sender.tag].targetId)
    }

    @objc private func followAgent() { feed?.watch(nil) }

    /// 시험 명령 `browser-tabs`·`browser-watch`·`browser-cursor`
    var debugTabs: String { feed?.debugTabs ?? "no feed" }
    var debugCursor: String { screen.debugCursor }
    func debugWatch(_ prefix: String) {
        if prefix == "follow" { feed?.watch(nil); return }
        if let chip = chips.first(where: { $0.targetId.hasPrefix(prefix) || $0.tabId == prefix || $0.text == prefix }) { feed?.watch(chip.targetId) }
    }

    private func setControl(_ control: AbxStatus.Control?) {
        // 사용자 제어가 끝나면(에이전트가 abx resume 했을 때 포함) 누르던 버튼·조합 중인 글자를 정리한다
        if self.control == .user, control != .user { screen.releaseInput() }
        self.control = control
        if control != .agent { screen.hideCursor(); pendingCursor = nil } // AI 커서는 AI 가 쥐고 있을 때만
        // AI 가 쓰는 동안: 화면에 초록 테두리, 아래 상태 줄에 "보기만 돼요"(ego-browser 처럼 — updateStatusLine)
        updateStatusLine()
        controlButton.isHidden = control == nil
        controlButton.isEnabled = !requesting && control != .switching
        // 누른 뒤 답을 기다리는 동안은 그렇다고 보인다
        controlButton.title = requesting ? (givingBack ? "AI에게 넘기는 중…" : "제어 가져오는 중…")
            : control == .user ? "AI에게 돌려주기" : "제어 가져오기"
        // 버튼 색 = 누르면 넘어갈 쪽: 가져오기는 사람(파랑), 돌려주기는 AI(초록)
        controlButton.fill = control == .user ? TermAppearance.agentColor : TermAppearance.userColor
    }

    /// 돌려주는 중: abx resume 이 끝나기 전부터 입력을 막는다(돌려준 뒤 AI 동작에 사람 입력이 섞이지 않게)
    private var givingBack = false

    @objc private func toggleControl() {
        guard let feed, !requesting else { return }
        requesting = true
        givingBack = control == .user
        setControl(control)
        let done: () -> Void = { [weak self] in
            self?.requesting = false
            self?.givingBack = false
            self?.setControl(self?.control)
        }
        if control == .user {
            screen.releaseInput() // 누르던 버튼·조합 중 글자를 먼저 정리하고
            givingBack = true     // 이 순간부터 입력을 버린 뒤
            feed.giveBack(completion: done) // 돌려준다
        } else {
            feed.takeControl(completion: done)
            window?.makeFirstResponder(screen)
        }
    }

    @objc private func togglePin() {
        onPin?(pinButton.state == .on)
    }

    /// 메뉴·시험 명령용
    func takeControl() { if control != .user { toggleControl() } }
    func giveBack() { if control == .user { toggleControl() } }

    // MARK: - 입력 (BrowserScreenView 가 부른다)

    /// 사람이 제어를 가진 동안만 보낸다(그 밖에는 버림)
    var acceptsInput: Bool { control == .user && !givingBack && feed != nil }

    func send(_ method: String, _ params: [String: Any]) {
        guard acceptsInput else { return }
        feed?.input(method, params)
    }

    /// 정리용 입력(누르던 버튼 떼기·조합 취소): 제어가 막 넘어간 뒤에도 보낸다 — 남겨 두면 다음 조작에 섞인다
    func sendCleanup(_ method: String, _ params: [String: Any]) {
        feed?.cleanup(method, params)
    }

    /// 화면 뷰의 점(위가 0) → 페이지 CSS 좌표
    func cssPoint(_ point: CGPoint) -> CGPoint? {
        ViewportTransform(bounds: screen.bounds.size, viewport: viewport).cssPoint(point)
    }

    /// 페이지 CSS 좌표 → 창 좌표(시험 명령 `browser-click` 이 실제 마우스 이벤트를 만들 때)
    func windowPoint(css: CGPoint) -> NSPoint? {
        let rect = ViewportTransform(bounds: screen.bounds.size, viewport: viewport).imageRect
        guard rect.width > 0 else { return nil }
        let local = NSPoint(x: rect.minX + css.x * rect.width / viewport.width, y: rect.minY + css.y * rect.height / viewport.height)
        return screen.convert(local, to: nil)
    }

    /// 포커스가 실제로 있는 요소(그림자 DOM·같은 출처 iframe 안까지)를 찾는 식의 앞부분
    private static let focusedJS = """
      const deep = () => { let doc = document, el = doc.activeElement;
        for (;;) {
          if (el && el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
          if (el && el.tagName === 'IFRAME') { try { doc = el.contentDocument; el = doc.activeElement; continue; } catch (e) {} }
          return { doc: el ? el.ownerDocument : doc, el };
        } };
      const { doc, el } = deep();
      const field = el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && el.selectionStart != null;
      // 비밀번호 칸은 Chrome 처럼 복사·잘라내기를 거절한다(클립보드에 평문으로 남지 않게)
      if (el && el.tagName === 'INPUT' && el.type === 'password') return null;
      const text = field ? el.value.substring(el.selectionStart, el.selectionEnd) : String(doc.getSelection());
    """

    /// 선택한 글(입력 칸 안의 선택 포함)을 macOS 클립보드로. cut 이면 같은 계산 안에서 지운다
    /// (읽기와 지우기 사이에 다른 입력이 끼어 엉뚱한 선택을 지우지 않게).
    func copySelection(cut: Bool = false) {
        guard acceptsInput, let feed else { return }
        let js = "(() => {" + Self.focusedJS + (cut ? "if (text) doc.execCommand('delete');" : "") + "return text; })()"
        feed.evaluate(js) { [weak self] value in
            // 그 사이 스트림이 바뀌었거나(멈춤·다시 시작) 제어가 넘어갔으면 버린다
            guard let self, self.feed === feed, let text = value as? String, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// 브라우저 그림을 그리고 사람 입력을 받는 뷰. 키보드는 macOS 입력기(NSTextInputClient)를 거쳐
/// 확정 글자 → `Input.insertText`(영문 한 글자는 키 이벤트), 조합 중 글자 → `Input.imeSetComposition`,
/// 편집 명령(줄바꿈·지우기·화살표…) → 키 이벤트로 보낸다. 제어가 없으면 받아서 버린다(옆 터미널로 새지 않게).
/// 색을 채운 알약 버튼(어두운 글자). 기본 버튼의 bezelColor 는 창이 앞에 있을 때만 칠해져, 늘 보이게 직접 그린다.
final class PillButton: NSButton {
    var fill: NSColor = TermAppearance.userColor { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryChange)
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 11)])
        return NSSize(width: ceil(size.width) + TermAppearance.scaled(20), height: ceil(size.height) + TermAppearance.scaled(6))
    }

    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let color = !isEnabled ? fill.withAlphaComponent(0.4) : isHighlighted ? fill.blended(withFraction: 0.25, of: .black) ?? fill : fill
        color.setFill()
        pill.fill()
        // 흐린 바탕(기다리는 중) 위에서는 흰 글자가 더 잘 보인다
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 11),
                                                         .foregroundColor: isEnabled ? TermAppearance.chrome : NSColor.white]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class BrowserScreenView: NSView, NSTextInputClient, NSMenuItemValidation {
    weak var pane: BrowserPaneView?
    private var marked = ""
    private var pressedButton: BrowserInput.Button = .none
    private var lastMove = Date.distantPast
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true } // 위가 0(페이지 좌표와 같은 방향)

    /// 프레임을 그리는 층. 뷰 자신의 층(AppKit 이 관리 — 기본은 늘려 채움)이 아니라 따로 둔 층에,
    /// 비율을 지킨 자리(ViewportTransform.imageRect — 마우스 좌표 변환과 같은 자리)를 직접 정해 그린다.
    private let imageLayer = CALayer()
    private var imageViewport: CGSize = .zero

    /// AI 커서(abx 가 적은 단계 자리 — AgentCursor): 화살표 + 할 일 이름표. 끝(position)이 가리키는 점.
    private let cursorLayer = CALayer()
    private let arrowLayer = CAShapeLayer()
    private let labelBack = CALayer()
    private let labelText = CATextLayer()
    private var cursorCSS: CGPoint?
    private var cursorHide: DispatchWorkItem?

    /// AI 가 쓰는 동안의 표시: 화면 둘레의 초록 테두리(천천히 숨 쉬듯)와 아래 가운데 "AI 사용 중" 알약
    private let agentFrame = CALayer()
    /// 초록 테두리 바깥의 어두운 1pt 선 — 흰 페이지 위에서도 테두리가 보이게
    private let agentOutline = CALayer()
    private(set) var agentActive = false
    /// macOS "동작 줄이기": 숨 쉬기·미끄러지기·퍼지는 원 없이
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resize // 자리를 이미 비율대로 정했으니 그 자리에 꼭 맞게
        imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
        setUpCursor()
        setUpAgentMark()
    }

    private var motionObserver: NSObjectProtocol?

    private func setUpAgentMark() {
        // "동작 줄이기"를 켜고 끄면 테두리 숨 쉬기도 바로 따른다
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshBreathing()
        }
        agentFrame.borderColor = TermAppearance.agentColor.cgColor
        agentFrame.borderWidth = 2
        agentFrame.zPosition = 5
        agentFrame.isHidden = true
        agentOutline.borderColor = TermAppearance.chrome.cgColor
        agentOutline.borderWidth = 1
        agentOutline.zPosition = 5
        agentOutline.isHidden = true
        layer?.addSublayer(agentOutline)
        layer?.addSublayer(agentFrame)
    }

    /// AI 가 쥐고 있는지(칸이 정한다 — setControl)
    func setAgentActive(_ active: Bool) {
        guard active != agentActive else { return }
        agentActive = active
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        agentFrame.isHidden = !active
        agentOutline.isHidden = !active
        if active {
            placeAgentMark()
        }
        CATransaction.commit()
        refreshBreathing()
    }

    private func refreshBreathing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if agentActive, !reduceMotion {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.45
            breathe.duration = 1.2
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            agentFrame.add(breathe, forKey: "breathe")
        } else {
            agentFrame.removeAnimation(forKey: "breathe")
        }
        CATransaction.commit()
    }

    /// 표시는 페이지 그림 자리(imageRect)를 따라간다
    private func placeAgentMark() {
        let rect = ViewportTransform(bounds: bounds.size, viewport: imageViewport).imageRect
        let area = rect.isEmpty ? bounds : rect
        agentOutline.frame = area
        agentFrame.frame = area.insetBy(dx: 1, dy: 1)
    }

    private func setUpCursor() {
        cursorLayer.anchorPoint = .zero
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        cursorLayer.opacity = 0
        cursorLayer.zPosition = 10
        // 위가 0인 좌표(이 뷰는 뒤집혀 있다)로 그린 보통 화살표 커서
        let arrow = CGMutablePath()
        arrow.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4.5, y: 13), CGPoint(x: 7.5, y: 20),
                                 CGPoint(x: 10, y: 19), CGPoint(x: 7, y: 12.5), CGPoint(x: 12.5, y: 12.5)])
        arrow.closeSubpath()
        arrowLayer.path = arrow
        arrowLayer.fillColor = NSColor.white.cgColor
        arrowLayer.strokeColor = NSColor.black.cgColor
        arrowLayer.lineWidth = 1.2
        arrowLayer.lineJoin = .round
        arrowLayer.shadowOpacity = 0.35
        arrowLayer.shadowRadius = 2
        arrowLayer.shadowOffset = CGSize(width: 0, height: -1)
        labelBack.backgroundColor = TermAppearance.agentColor.cgColor
        labelBack.cornerRadius = 5
        labelBack.shadowOpacity = 0.3
        labelBack.shadowRadius = 2
        labelText.foregroundColor = TermAppearance.chrome.cgColor
        labelText.alignmentMode = .left
        labelText.truncationMode = .end
        labelBack.addSublayer(labelText)
        cursorLayer.addSublayer(labelBack)
        cursorLayer.addSublayer(arrowLayer)
        layer?.addSublayer(cursorLayer)
    }

    /// AI 가 이제 하려는 단계: 그 자리로 커서를 옮기고(처음이면 바로 그 자리에) 이름표를 붙인다. 누르는 동작은 도착할 때 원이 퍼진다.
    /// 그림이 아직 없어 놓을 자리를 모르면 false
    @discardableResult
    func showCursor(_ cursor: AgentCursor) -> Bool {
        let css = CGPoint(x: cursor.x, y: cursor.y)
        guard let point = ViewportTransform(bounds: bounds.size, viewport: imageViewport).viewPoint(css) else { return false }
        let appearing = cursorCSS == nil || cursorLayer.opacity == 0
        cursorCSS = css
        let scale = window?.backingScaleFactor ?? 2
        let font = NSFont.systemFont(ofSize: TermAppearance.scaled(12), weight: .semibold)
        let text = cursor.label
        var size = (text as NSString).size(withAttributes: [.font: font])
        // 이름표(바탕 포함)는 240pt 까지, 칸 안쪽 8pt 를 넘지 않게
        size.width = min(size.width, 240 - 16, max(24, bounds.width - 16 - 16))
        // 이름표는 커서 오른쪽 아래 — 칸 끝에 닿으면 왼쪽·위로 뒤집는다
        let labelWidth = ceil(size.width) + 16, labelHeight = ceil(size.height) + 8
        let labelX: CGFloat = point.x + 14 + labelWidth + 8 > bounds.maxX ? -labelWidth - 4 : 14
        let labelY: CGFloat = point.y + 22 + labelHeight + 8 > bounds.maxY ? -labelHeight - 6 : 22
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelText.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: TermAppearance.chrome])
        labelText.contentsScale = scale
        labelText.frame = CGRect(x: 8, y: 4, width: ceil(size.width), height: ceil(size.height))
        labelBack.frame = CGRect(x: labelX, y: labelY, width: labelWidth, height: labelHeight)
        arrowLayer.contentsScale = scale
        if appearing { cursorLayer.position = point }
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : appearing ? 0.15 : 0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        cursorLayer.position = point
        cursorLayer.opacity = 1
        CATransaction.commit()
        if cursor.presses, !reduceMotion { pulse(after: appearing ? 0.1 : 0.25) }
        cursorHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in self?.hideCursor(animated: true) }
        cursorHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: hide)
        return true
    }

    /// 누를 때 끝에서 퍼지는 원
    private func pulse(after delay: CFTimeInterval) {
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
        ring.fillColor = TermAppearance.agentColor.withAlphaComponent(0.25).cgColor
        ring.strokeColor = TermAppearance.agentColor.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        cursorLayer.insertSublayer(ring, below: arrowLayer)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.beginTime = CACurrentMediaTime() + delay
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.5) { ring.removeFromSuperlayer() }
    }

    func hideCursor(animated: Bool = false) {
        cursorHide?.cancel()
        cursorHide = nil
        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(0.4) } else { CATransaction.setDisableActions(true) }
        cursorLayer.opacity = 0
        CATransaction.commit()
        cursorCSS = nil
    }

    /// 시험 명령 `browser-cursor`
    var debugCursor: String {
        guard let css = cursorCSS, cursorLayer.opacity > 0 else { return "cursor hidden" }
        return "cursor css=\(Int(css.x)),\(Int(css.y)) at=\(Int(cursorLayer.position.x)),\(Int(cursorLayer.position.y)) label=\((labelText.string as? NSAttributedString)?.string ?? "")"
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 새 프레임(없으면 지움)
    func show(_ image: CGImage?, viewport: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true) // 프레임마다 서서히 바뀌는 효과 없이
        imageLayer.contents = image
        if viewport != imageViewport {
            imageViewport = viewport
            placeImage()
        }
        CATransaction.commit()
    }

    private func placeImage() {
        let transform = ViewportTransform(bounds: bounds.size, viewport: imageViewport)
        imageLayer.frame = transform.imageRect
        // 칸 크기가 바뀌면 커서·AI 표시도 같은 페이지 자리로
        if let css = cursorCSS, let point = transform.viewPoint(css) { cursorLayer.position = point }
        if agentActive { placeAgentMark() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeImage()
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { pane?.screenResized() }
    }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// 누르던 버튼을 떼고 조합 중 글자를 지운다(제어를 돌려줄 때·스트림을 멈출 때). 제어 확인 없이 보낸다.
    func releaseInput() {
        if pressedButton != .none, let pane {
            pane.sendCleanup("Input.dispatchMouseEvent", BrowserInput.mouse(.released, at: lastCSS ?? .zero, button: pressedButton))
        }
        pressedButton = .none
        if !marked.isEmpty {
            pane?.sendCleanup("Input.imeSetComposition", ["text": "", "selectionStart": 0, "selectionEnd": 0])
            marked = ""
            inputContext?.discardMarkedText()
        }
    }

    // MARK: 마우스

    private func modifiers(_ flags: NSEvent.ModifierFlags) -> BrowserInput.Modifiers {
        var m: BrowserInput.Modifiers = []
        if flags.contains(.option) { m.insert(.alt) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.command) { m.insert(.meta) }
        if flags.contains(.shift) { m.insert(.shift) }
        return m
    }

    /// 마지막으로 보낸 페이지 좌표 — 누른 채 그림 밖(여백·칸 밖)에서 떼어도 떼기는 반드시 보낸다
    private var lastCSS: CGPoint?

    private func mouse(_ event: NSEvent, _ kind: BrowserInput.MouseKind, _ button: BrowserInput.Button) {
        guard let pane, pane.acceptsInput else { return }
        let inside = pane.cssPoint(convert(event.locationInWindow, from: nil))
        let dragging = button != .none && kind != .pressed
        guard let point = inside ?? (dragging ? lastCSS : nil) else { return }
        lastCSS = point
        pane.send("Input.dispatchMouseEvent",
                  BrowserInput.mouse(kind, at: point, button: button, clickCount: max(event.clickCount, 1),
                                     modifiers: modifiers(event.modifierFlags)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastClick = convert(event.locationInWindow, from: nil)
        pressedButton = .left
        mouse(event, .pressed, .left)
    }
    override func mouseUp(with event: NSEvent) { mouse(event, .released, .left); pressedButton = .none }
    override func mouseDragged(with event: NSEvent) { mouse(event, .moved, .left) }
    override func rightMouseDown(with event: NSEvent) { pressedButton = .right; mouse(event, .pressed, .right) }
    override func rightMouseUp(with event: NSEvent) { mouse(event, .released, .right); pressedButton = .none }
    override func rightMouseDragged(with event: NSEvent) { mouse(event, .moved, .right) }
    override func otherMouseDown(with event: NSEvent) { pressedButton = .middle; mouse(event, .pressed, .middle) }
    override func otherMouseUp(with event: NSEvent) { mouse(event, .released, .middle); pressedButton = .none }

    override func mouseMoved(with event: NSEvent) {
        // 마우스를 올리기만 한 움직임(hover)은 초당 30번까지
        guard Date().timeIntervalSince(lastMove) > 1.0 / 30 else { return }
        lastMove = Date()
        mouse(event, .moved, .none)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let pane, pane.acceptsInput,
              let point = pane.cssPoint(convert(event.locationInWindow, from: nil)) else { return }
        pane.send("Input.dispatchMouseEvent",
                  BrowserInput.wheel(at: point, scrollingDeltaX: event.scrollingDeltaX, scrollingDeltaY: event.scrollingDeltaY,
                                     precise: event.hasPreciseScrollingDeltas, modifiers: modifiers(event.modifierFlags)))
    }

    // MARK: 키보드

    /// 지금 처리 중인 키(입력기 없이 친 글자를 키 이벤트로 보내려고)
    private var currentKey: NSEvent?

    override func keyDown(with event: NSEvent) {
        guard pane?.acceptsInput == true else { return }
        currentKey = event
        defer { currentKey = nil }
        interpretKeyEvents([event])
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let wasComposing = !marked.isEmpty
        marked = ""
        guard let pane, !text.isEmpty else { return }
        // 조합 없이 친 영문·숫자·기호 한 글자는 keydown·keypress 까지 일어나게 키 이벤트로
        if !wasComposing, let key = currentKey, key.characters == text,
           let events = BrowserInput.character(text, keyCode: key.keyCode, modifiers: modifiers(key.modifierFlags)) {
            events.forEach { pane.send("Input.dispatchKeyEvent", $0) }
        } else {
            pane.send("Input.insertText", ["text": text])
        }
    }

    /// 조합 중 글자 안의 선택(입력기가 정한 것, UTF-16)
    private var markedSelection = NSRange(location: 0, length: 0)

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = text
        markedSelection = selectedRange
        pane?.send("Input.imeSetComposition", [
            "text": text, "selectionStart": selectedRange.location, "selectionEnd": selectedRange.location + selectedRange.length,
        ])
    }

    func unmarkText() {
        // 조합 중이던 글자를 그대로 확정
        guard !marked.isEmpty else { return }
        let text = marked
        marked = ""
        pane?.send("Input.insertText", ["text": text])
    }

    override func doCommand(by selector: Selector) {
        guard let pane, let (key, mods, commands) = BrowserInput.command(selector: NSStringFromSelector(selector)) else { return }
        // 실제로 누른 수정 키를 지킨다(⇧⏎ 줄바꿈이 그냥 ⏎ 전송이 되지 않게)
        let pressed = currentKey.map { modifiers($0.modifierFlags) } ?? []
        BrowserInput.press(key, modifiers: mods.union(pressed), commands: commands).forEach { pane.send("Input.dispatchKeyEvent", $0) }
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
    func selectedRange() -> NSRange { marked.isEmpty ? NSRange(location: 0, length: 0) : markedSelection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// 입력기 후보 창 자리: 마지막으로 누른 곳 근처(페이지의 실제 커서 자리는 아직 모른다)
    private var lastClick: NSPoint?
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let local = lastClick ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let rect = NSRect(x: local.x, y: local.y, width: 1, height: 18)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    // MARK: 편집 메뉴(⌘A ⌘C ⌘X ⌘V ⌘Z)

    @objc override func selectAll(_ sender: Any?) { shortcut("selectAll") }
    @objc func undo(_ sender: Any?) { shortcut("undo") }
    @objc func redo(_ sender: Any?) { shortcut("redo") }
    @objc func copy(_ sender: Any?) { pane?.copySelection() }
    @objc func cut(_ sender: Any?) { pane?.copySelection(cut: true) }
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        pane?.send("Input.insertText", ["text": text])
    }

    private func shortcut(_ command: String) {
        BrowserInput.shortcut(command)?.forEach { pane?.send("Input.dispatchKeyEvent", $0) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectAll(_:)), #selector(undo(_:)), #selector(redo(_:)), #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)):
            return pane?.acceptsInput == true
        default:
            return true
        }
    }
}

/// 브라우저 하나를 지켜보며 화면을 받아 온다(백그라운드).
/// - abx 상태(`abx status --json`)는 abx 폴더가 바뀔 때와 몇 초마다 다시 읽는다(브라우저를 띄우지 않는다).
/// - CDP 주소가 생기면 붙고, 에이전트가 보는 탭(활성 탭)을 따라 screencast 를 옮긴다.
/// - 프레임은 백그라운드에서 풀고, 밀리면 최신 것만 그린다.
final class BrowserFeed {
    enum State {
        case waiting(String)
        case live(AbxStatus)
    }

    var onState: ((State) -> Void)?
    /// 그릴 그림과 그 프레임의 페이지 크기(CSS 픽셀)
    /// 그림, viewport, 그 그림을 보낸 탭
    var onImage: ((CGImage, CGSize, String?) -> Void)?
    /// 보고 있는 탭의 주소·제목이 바뀜
    var onPage: ((String, String) -> Void)?
    /// 칸 위 탭 칩(브라우저의 탭들)과, 사람이 고른 탭을 보고 있는지(AI 를 따라가지 않음)
    var onTabs: (([BrowserTabs.Chip], Bool) -> Void)?
    /// AI 커서(abx 가 단계 직전에 적은 자리) — 보여 줄 탭의 것만
    var onCursor: ((AgentCursor) -> Void)?

    private let session: AbxSession
    private let watchDirs: [String]
    private let queue = DispatchQueue(label: "agentdeck.browser.feed")
    private let decodeQueue = DispatchQueue(label: "agentdeck.browser.decode", qos: .userInitiated)
    private var runner: AbxRunner?
    private var client: CDPClient?
    private var stream: ScreencastStream?
    private var connectedURL: String?
    private var connecting = false
    /// 붙는 중에 끊기·멈춤이 오면 늦게 열린 연결을 버리려는 세대 번호
    private var connectGeneration = 0
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var pendingRefresh = false
    private var frames = LatestFrameQueue<ScreencastFrame>()
    private var stopped = false
    /// 마지막 상태의 제어권(사람 입력·새 탭 따라가기)
    private var control: AbxStatus.Control?
    /// 돌려주는 중(abx resume 을 보냄)
    private var releasing = false
    /// 브라우저 페이지 크기(칸 크기에서 `BrowserViewOptions.pageSize`)와 그 바탕인 칸 크기
    private var size: CGSize?
    private var paneSize: CGSize?
    /// 선명도·데스크톱 유지(설정 창에서 바꾸면 알림으로 받는다)
    private var options = BrowserViewSettings.shared.options
    private var optionsObserver: NSObjectProtocol?
    /// 사람이 조작하다 연 탭 — 사람이 제어하는 동안은 abx 가 기억한 활성 탭보다 이것을 보여 준다
    private var userTarget: String?
    /// 사람이 탭 칩으로 고른 탭: AI 가 다른 탭에서 일해도 이 탭을 계속 보여 준다(nil = AI 따라가기).
    /// abx 도 안다(`<세션>.watch.json`): `abx done` 은 이 탭을 닫지 않고, `abx resume` 은 이 탭에서 이어 간다.
    private var pinned: String?
    /// 브라우저가 지금 연 페이지들(CDP 순서) — 사람이 연 탭도 abx 를 거치지 않고 바로 안다
    private var pages: [BrowserTabs.Page] = []
    /// abx 가 마지막으로 적은 탭 정보(이름·작업 공간·누가 열었는지)
    private var abxTabs: [AbxStatus.Tab] = []
    /// 마지막으로 쓴 watch 파일 내용(같으면 다시 쓰지 않는다 — 상태 폴더를 보고 있어 쓰면 다시 읽게 된다)
    private var lastWatch: String?
    /// 마지막으로 보낸 AI 커서
    private var lastCursor = 0

    init(owner: String) {
        let env = BrowserBinding.environment(pane: owner, browser: nil)
        session = AbxSession(name: env["ABX_SESSION"]!, socketDir: env["ABX_SOCKET_DIR"]!,
                             stateDir: env["ABX_STATE_DIR"]!, profileDir: env["ABX_PROFILE_DIR"]!)
        watchDirs = [session.socketDir, session.stateDir, session.profileDir]
        optionsObserver = NotificationCenter.default.addObserver(forName: BrowserViewSettings.changed, object: nil, queue: nil) {
            [weak self] note in
            guard let options = note.object as? BrowserViewOptions else { return }
            self?.queue.async { self?.apply(options) }
        }
    }

    /// 설정이 바뀜: 선명도는 screencast 를 다시 시작해(다시 붙어) 바로, 해상도·데스크톱 유지는 크기를 다시 맞춰 바로 반영
    private func apply(_ new: BrowserViewOptions) {
        guard !stopped, new != options else { return }
        let old = options
        options = new
        if let paneSize, new.pageSize(for: paneSize) != old.pageSize(for: paneSize) {
            size = new.pageSize(for: paneSize)
            applySize()
        }
        if new.screencast != old.screencast, connectedURL != nil {
            disconnect()
            refresh()
        }
    }

    func start() {
        queue.async { [self] in
            runner = AbxRunner.locate(bundleHelpers: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers"))
            guard runner != nil else {
                publish(.waiting("abx 를 찾지 못했어요 — abx 를 설치하거나 AGENTDECK_ABX 로 경로를 알려 주세요"))
                return
            }
            // 폴더가 아직 없을 수 있어(브라우저를 처음 쓰기 전) 몇 초마다도 읽는다
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 3)
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            self.timer = timer
        }
    }

    /// 메인 스레드에서 부른다. 알림을 바로 끊고(늦게 온 상태·프레임은 버림), 정리는 뒤에서.
    func stop() {
        onState = nil
        onImage = nil
        onPage = nil
        onTabs = nil
        onCursor = nil
        if let optionsObserver { NotificationCenter.default.removeObserver(optionsObserver) }
        queue.async { [self] in
            stopped = true
            // 칸이 닫히면 사람이 보던 탭도 없다
            if lastWatch != nil { try? FileManager.default.removeItem(at: watchFile) }
            timer?.cancel()
            watchers.forEach { $0.cancel() }
            watchers = []
            disconnect()
        }
    }

    // MARK: - 상태

    private func publish(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    /// 폴더 변경(파일 생김·지움·이름 바꿈)이 몰려 오면 한 번만 읽는다
    private func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pendingRefresh = false
            self?.refresh()
        }
    }

    private func watchNewDirs() {
        // 아직 없는 폴더가 있으면, 생겼는지 볼 때마다 다시 건다
        guard watchers.count < watchDirs.count else { return }
        watchers.forEach { $0.cancel() }
        watchers = watchDirs.compactMap { dir in
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self] in self?.scheduleRefresh() }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    private func refresh() {
        guard !stopped, let runner else { return }
        watchNewDirs()
        // 상태는 abx 를 띄우지 않고 파일로 읽는다(AbxStateReader — abx status --json 과 같은 규칙)
        let status = AbxStateReader().status(session)
        guard status.running, let url = status.cdpUrl else {
            disconnect()
            publish(.waiting("에이전트가 아직 브라우저를 쓰지 않았어요\n(이 화면의 claude·codex 가 abx 를 쓰면 여기에 보여요)"))
            return
        }
        let wasControlled = control == .agent || control == .switching
        control = status.control
        if control != .user { userTarget = nil }
        abxTabs = status.tabs
        // AI 가 쥐고 있는 동안 미뤄 둔 크기 맞추기를 이제 한다
        if wasControlled, control == .user || control == .idle { applySize() }
        publish(.live(status))
        if url != connectedURL { connect(url, status: status) }
        else { follow(wanted) }
        publishTabs()
        publishCursor()
    }

    private var cursorFile: URL {
        URL(fileURLWithPath: session.stateDir).appendingPathComponent("\(session.name).cursor.json")
    }

    /// abx 가 새 커서를 적었으면(보여 줄 탭의 것, 방금 것) 칸에 보낸다
    private func publishCursor() {
        guard let cursor = AgentCursor.read(cursorFile), cursor.seq != lastCursor,
              Date().timeIntervalSince1970 * 1000 - cursor.t < 3000 else { return }
        // 지금 그림이 나오는 탭의 것일 때만 보낸다 — 아직 그 탭으로 옮기는 중이면 다음에 다시 본다(3초 안)
        guard cursor.targetId == stream?.currentTarget else { return }
        lastCursor = cursor.seq
        DispatchQueue.main.async { [weak self] in self?.onCursor?(cursor) }
    }

    /// 보여 줄 탭: 사람이 고른 탭 > 사람이 조작하다 연 탭 > AI 의 활성 탭
    private var wanted: String? { pinned ?? userTarget ?? abxTabs.first(where: \.active)?.targetId }

    // MARK: - 탭 칩

    /// 탭 칩을 눌렀다: 그 탭을 계속 보여 준다. nil = 다시 AI 를 따라간다.
    func watch(_ target: String?) {
        queue.async { [self] in
            pinned = target
            if target == nil { userTarget = nil } // "AI 따라가기": 사람이 조작하다 연 탭보다 AI 의 탭
            follow(wanted)
            publishTabs()
        }
    }

    /// 칩 메뉴의 "탭 닫기"(사람이 닫는다 — 누가 연 탭이든)
    func closeTab(_ target: String) {
        queue.async { [self] in client?.post("Target.closeTarget", ["targetId": target]) }
    }

    private var watchFile: URL {
        URL(fileURLWithPath: session.stateDir).appendingPathComponent("\(session.name).watch.json")
    }

    /// 주소는 about:blank 인데 내용이 있는 탭: 다른 탭을 볼 때도 칩으로 남는다(돌아가거나 닫을 수 있게)
    private var populatedBlanks: Set<String> = []

    func keepBlank(_ target: String) {
        queue.async { [weak self] in
            guard let self, self.populatedBlanks.insert(target).inserted else { return }
            self.publishTabs()
        }
    }

    private func publishTabs() {
        let shown = stream?.currentTarget
        let chips = BrowserTabs.chips(pages: pages, tabs: abxTabs, shown: shown, keep: populatedBlanks)
        let isPinned = pinned != nil
        DispatchQueue.main.async { [weak self] in self?.onTabs?(chips, isPinned) }
        // abx 에 알린다: 사람이 보는 탭과, 사람이 골랐는지
        guard let shown else { return }
        let json = "{\"targetId\":\"\(shown)\",\"pinned\":\(isPinned)}"
        guard json != lastWatch else { return }
        lastWatch = json
        let file = watchFile
        let tmp = file.appendingPathExtension(UUID().uuidString)
        if (try? json.write(to: tmp, atomically: false, encoding: .utf8)) != nil {
            if rename(tmp.path, file.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
        }
    }

    /// CDP 의 페이지 알림으로 탭 목록을 맞춘다
    private func pageEvent(_ method: String, _ params: [String: Any]) {
        switch method {
        case "Target.targetCreated", "Target.targetInfoChanged":
            guard let info = params["targetInfo"] as? [String: Any], info["type"] as? String == "page",
                  let id = info["targetId"] as? String else { return }
            let page = BrowserTabs.Page(targetId: id, url: info["url"] as? String ?? "", title: info["title"] as? String ?? "")
            if let i = pages.firstIndex(where: { $0.targetId == id }) {
                guard pages[i] != page else { return }
                pages[i] = page
            } else {
                pages.append(page)
            }
        case "Target.targetDestroyed":
            guard let id = params["targetId"] as? String, let i = pages.firstIndex(where: { $0.targetId == id }) else { return }
            pages.remove(at: i)
            if pinned == id { pinned = nil } // 고른 탭이 닫히면 다시 AI 를 따라간다
            if userTarget == id { userTarget = nil }
            // 보던 탭이 닫혔다: 다음 볼 탭을 고른다. abx 의 활성 탭 기록이 아직 그 탭이면(늦은 기록) 남은 페이지 중에서.
            if stream?.currentTarget == id { follow(wanted == id ? nil : wanted) }
        default:
            return
        }
        publishTabs()
    }

    /// 시험 명령 `browser-tabs`
    var debugTabs: String {
        queue.sync {
            let chips = BrowserTabs.chips(pages: pages, tabs: abxTabs, shown: stream?.currentTarget, keep: populatedBlanks)
            return (["pinned=\(pinned.map { String($0.prefix(8)) } ?? "-")"] + chips.map { c in
                "\(c.shown ? ">" : " ")\(c.agentHere ? "●" : " ") \(c.targetId.prefix(8)) \(c.tabId ?? "-") [\(c.group ?? "user")] \(c.text)"
            }).joined(separator: "\n")
        }
    }

    // MARK: - CDP

    private func connect(_ url: String, status: AbxStatus) {
        guard !connecting, let endpoint = URL(string: url) else { return }
        disconnect()
        connecting = true
        let generation = connectGeneration
        // queue 는 강하게 잡는다: 이 feed 가 먼저 사라져도 늦게 열린 연결을 닫는 일은 반드시 돈다
        let queue = self.queue
        Task { [weak self] in
            let transport = try? await WebSocketTransport.connect(endpoint)
            queue.async {
                guard let self, !self.stopped, self.connectGeneration == generation else {
                    transport?.close()
                    return
                }
                self.connecting = false
                guard let transport else { return } // 다음 상태 읽기에서 다시 시도
                let client = CDPClient(transport: transport)
                let stream = ScreencastStream(client: client, settings: self.options.screencast)
                client.onEvent = { [weak self, weak stream] event in
                    if stream?.handle(event) == true { return }
                    if event.method.hasPrefix("Target.target") { self?.queue.async { self?.pageEvent(event.method, event.params) } }
                    if event.method == "Target.targetCreated" { self?.queue.async { self?.opened(event.params) } }
                    if event.method == "Target.targetInfoChanged", let info = event.params["targetInfo"] as? [String: Any],
                       let target = info["targetId"] as? String, target == stream?.currentTarget {
                        let url = info["url"] as? String ?? "", title = info["title"] as? String ?? ""
                        DispatchQueue.main.async { self?.onPage?(url, title) }
                    }
                }
                client.onClose = { [weak self, weak client] in
                    self?.queue.async {
                        guard let self, let client, self.client === client else { return }
                        self.disconnect()
                        self.scheduleRefresh()
                    }
                }
                stream.onFrame = { [weak self] frame in self?.queue.async { self?.received(frame) } }
                self.client = client
                self.stream = stream
                self.connectedURL = url
                // 이미 열린 탭들은 setDiscoverTargets 가 targetCreated 로 알려 준다(pageEvent)
                self.pages = []
                client.post("Target.setDiscoverTargets", ["discover": true])
                // 다시 붙을 때(선명도 바꿈 등) 사람이 보던 탭이 있으면 그것을 계속 본다
                self.follow(self.wanted)
            }
        }
    }

    /// abx 가 마지막으로 본 활성 탭을 따라간다. 그 기록이 없거나(막 띄움) 그 탭이 이미 닫혔으면(오래된 기록)
    /// 보던 탭을 그대로 두거나 열린 페이지 하나를 보여 준다(`ScreencastStream.choose`).
    private func follow(_ target: String?) {
        guard let stream else { return }
        if let target, stream.currentTarget == target { return }
        Task { [weak self] in
            guard let pages = await stream.pages(),
                  let pick = ScreencastStream.choose(wanted: target, current: stream.currentTarget, open: pages) else { return }
            let changed = stream.currentTarget != pick
            try? await stream.show(target: pick)
            if changed { self?.queue.async { self?.showing(pick) } }
        }
    }

    /// 사람이 조작하다 연 새 탭(링크의 target=_blank 등)은 바로 따라간다.
    /// AI 가 연 탭은 abx 가 활성 탭으로 알려 주므로(상태) 여기서는 따라가지 않는다.
    private func opened(_ params: [String: Any]) {
        // 붙자마자 Chrome 은 이미 있던 탭도 targetCreated 로 알린다 — 보던 탭이 정해지기 전(nil)이나 연 탭이 없는 탭(opener 없음)은
        // 사람이 연 새 탭이 아니다(처음부터 사람 제어면 기존 빈 탭으로 옮겨 가 화면이 멈춘 것처럼 보였다)
        guard control == .user, let info = params["targetInfo"] as? [String: Any], info["type"] as? String == "page",
              let target = info["targetId"] as? String, let stream, let current = stream.currentTarget,
              let opener = info["openerId"] as? String, opener == current else { return }
        userTarget = target
        if pinned != nil { pinned = target } // 고른 탭에서 연 새 탭도 계속 본다
        Task { [weak self] in
            try? await stream.show(target: target)
            self?.queue.async { self?.showing(target) }
        }
    }

    // MARK: - 사람 입력·제어

    /// 사람 입력을 지금 보는 탭에 보낸다. 제어가 사람에게 있을 때만(뷰도 거르지만 상태가 막 바뀐 경우까지),
    /// 돌려주는 중에는 버린다.
    func input(_ method: String, _ params: [String: Any]) {
        queue.async { [self] in
            guard control == .user, !releasing else { return }
            stream?.post(method, params)
        }
    }

    /// 정리용 입력(버튼 떼기·조합 취소)은 제어와 상관없이 보낸다
    func cleanup(_ method: String, _ params: [String: Any]) {
        queue.async { [self] in stream?.post(method, params) }
    }

    /// 시험 명령 `browsers`: 맞추려는 크기와 설정
    var debugSize: String {
        queue.sync { "page=\(size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-") resolution=\(options.resolution.rawValue) sharpness=\(options.sharpness.rawValue)" }
    }

    /// 브라우저 페이지 크기를 칸에 맞춘다(지금 보는 탭의 창). 탭을 옮겨 가거나 다시 붙으면 또 맞춘다.
    func fit(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        queue.async { [self] in
            paneSize = size
            self.size = options.pageSize(for: size)
            applySize()
        }
    }

    /// AI 가 입력을 쥐고 있는 동안(잠금·넘기는 중)은 페이지 크기를 바꾸지 않는다 — AI 가 본 화면 배치·좌표가
    /// 동작 도중에 바뀌지 않게. 그동안 그림만 창에 맞춰 줄이고 늘리며, 사람 차례·쉬는 중이 되면 맞춘다.
    private func applySize() {
        guard let stream, let size, stream.currentTarget != nil, control == .user || control == .idle else { return }
        let session = self.session
        Task {
            // abx 의 writer 자리를 잡고 크기를 바꾼다: 그동안 에이전트 동작은 시작하지 않고, 잡은 뒤 제어를 다시 보아
            // (그새 resume 등) AI 차례면 바꾸지 않는다 — 늦게 도착한 크기 변경이 AI 의 화면 배치를 바꾸지 않게.
            guard let lease = AbxWriterLease.acquire(stateDir: session.stateDir, session: session.name) else { return }
            defer { lease.release() }
            // 자리를 잡은 것은 이 앱이라, handoff 가 있으면 상태는 "넘기는 중"(writer 가 살아 있음)으로 읽힌다 — 그것도 사람 차례다
            let now = AbxStateReader().status(session)
            guard now.handoff != nil || now.control == .idle else { return }
            await stream.fit(to: size)
        }
    }

    /// 보는 탭이 바뀌었다: 크기를 맞추고 주소·제목을 알린다
    private func showing(_ target: String) {
        applySize()
        publishTabs()
        publishCursor() // 이 탭으로 옮기길 기다리던 AI 커서
        guard let stream else { return }
        Task { [weak self] in
            guard let info = await stream.info(target: target),
                  stream.currentTarget == target else { return } // 그새 다른 탭으로 옮겼으면 버린다(옛 주소가 덮지 않게)
            DispatchQueue.main.async { self?.onPage?(info.url, info.title) }
        }
    }

    func evaluate(_ expression: String, completion: @escaping (Any?) -> Void) {
        queue.async { [self] in
            guard let stream else { DispatchQueue.main.async { completion(nil) }; return } // 기다리는 쪽이 멈춰 있지 않게
            Task {
                let value = await stream.evaluate(expression)
                DispatchQueue.main.async { completion(value) }
            }
        }
    }

    /// 제어 가져오기 = `abx handoff`. 에이전트가 하던 동작이 다음 단계에서 멈출 때까지 기다릴 수 있다(그동안 상태는 switching).
    func takeControl(completion: @escaping () -> Void) {
        abx(["handoff", BrowserIndicator.takeMessage], timeout: 330, completion: completion)
    }

    /// AI에게 돌려주기 = `abx resume`. 부른 순간부터 사람 입력을 버린다(resume 이 끝나고 상태를 다시 읽기 전에도).
    func giveBack(completion: @escaping () -> Void) {
        queue.async { [self] in releasing = true }
        abx(["resume"], timeout: 30) { [weak self] in
            self?.queue.async { self?.releasing = false }
            completion()
        }
    }

    private func abx(_ arguments: [String], timeout: TimeInterval, completion: @escaping () -> Void) {
        queue.async { [self] in
            guard let runner else { DispatchQueue.main.async(execute: completion); return }
            let session = self.session
            // 오래 걸릴 수 있어 상태 읽기(queue)를 막지 않게 따로 돌린다
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = try? runner.run(arguments, session: session, timeout: timeout)
                self?.queue.async { self?.refresh() }
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private func disconnect() {
        connectGeneration += 1
        connecting = false
        if let stream { Task { await stream.stop() } }
        client?.onClose = nil
        client?.close()
        client = nil
        stream = nil
        connectedURL = nil
    }

    // MARK: - 프레임

    private func received(_ frame: ScreencastFrame) {
        guard !stopped, let next = frames.offer(frame) else { return }
        decode(next)
    }

    private func decode(_ frame: ScreencastFrame) {
        let target = frame.targetId
        decodeQueue.async { [weak self] in
            let image = CGImageSourceCreateWithData(frame.jpeg as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            if let image {
                DispatchQueue.main.async { self?.onImage?(image, frame.viewport, target) }
            }
            self?.queue.async {
                guard let self, let next = self.frames.finish() else { return }
                self.decode(next)
            }
        }
    }
}
