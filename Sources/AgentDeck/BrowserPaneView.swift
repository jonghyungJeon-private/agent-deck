import AppKit
import BrowserCore
import ImageIO
import TermWire

/// 브라우저 화면: 에이전트 화면(owner)의 브라우저(abx 세션)를 CDP screencast 로 받아 그린다.
/// 지금은 보기만 한다(사람 입력은 다음 단계). 브라우저는 에이전트가 `abx` 를 처음 쓸 때 창 없이 뜬다.
final class BrowserPaneView: NSView {
    let owner: String
    private let header = NSTextField(labelWithString: "")
    private let screen = NSView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private var feed: BrowserFeed?

    init(owner: String, frame: NSRect) {
        self.owner = owner
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TermAppearance.background.cgColor

        header.font = .systemFont(ofSize: TermAppearance.scaled(11))
        header.textColor = TermAppearance.textDim
        header.lineBreakMode = .byTruncatingMiddle
        screen.wantsLayer = true
        screen.layer?.contentsGravity = .resizeAspect
        placeholder.alignment = .center
        placeholder.textColor = TermAppearance.textDim
        for view in [header, screen, placeholder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            screen.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            screen.leadingAnchor.constraint(equalTo: leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: trailingAnchor),
            screen.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: screen.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: screen.widthAnchor, constant: -40),
        ])
        show(.waiting("브라우저를 찾는 중…"))
    }

    required init?(coder: NSCoder) { fatalError() }

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
        "owner=\(owner.prefix(4)) placed=\(placed) visible=\(windowVisible) streaming=\(feed != nil) frames=\(framesShown)"
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

    // 보기만 하는 칸: 키보드는 받아서 버린다(골라 둔 채 친 글이 옆 터미널로 가지 않게)
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}

    private func startFeed() {
        guard feed == nil else { return }
        let feed = BrowserFeed(owner: owner)
        feed.onState = { [weak self] state in self?.show(state) }
        feed.onImage = { [weak self] image in
            self?.screen.layer?.contents = image
            self?.placeholder.isHidden = true
            self?.framesShown += 1
        }
        self.feed = feed
        feed.start()
    }

    private func stopFeed() {
        feed?.stop()
        feed = nil
    }

    private func show(_ state: BrowserFeed.State) {
        switch state {
        case .waiting(let text):
            header.stringValue = "브라우저"
            placeholder.stringValue = text
            placeholder.isHidden = false
            screen.layer?.contents = nil
        case .live(let status):
            let control: String
            switch status.control {
            case .agent: control = "AI 작업 중"
            case .user: control = "사용자에게 넘김" + (status.handoff.map { " — \($0)" } ?? "")
            case .switching: control = "넘기는 중…"
            case .idle: control = "쉬는 중"
            }
            let tab = status.activeTab
            let tabs = status.tabs.count > 1 ? " · 탭 \(status.tabs.count)개" : ""
            // 제목이 없는 페이지는 Chrome 이 주소를 제목으로 준다 — 같으면 한 번만
            let title = tab.flatMap { tab in tab.url.contains(tab.title) ? nil : tab.title }
            header.stringValue = [control, title, tab?.url].compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ") + tabs
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
    var onImage: ((CGImage) -> Void)?

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

    init(owner: String) {
        let env = BrowserBinding.environment(pane: owner, browser: nil)
        session = AbxSession(name: env["ABX_SESSION"]!, socketDir: env["ABX_SOCKET_DIR"]!,
                             stateDir: env["ABX_STATE_DIR"]!, profileDir: env["ABX_PROFILE_DIR"]!)
        watchDirs = [session.socketDir, session.stateDir, session.profileDir]
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
        queue.async { [self] in
            stopped = true
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
        guard let status = try? runner.status(session) else {
            publish(.waiting("브라우저 상태를 읽지 못했어요"))
            return
        }
        guard status.running, let url = status.cdpUrl else {
            disconnect()
            publish(.waiting("에이전트가 아직 브라우저를 쓰지 않았어요\n(이 화면의 claude·codex 가 abx 를 쓰면 여기에 보여요)"))
            return
        }
        publish(.live(status))
        if url != connectedURL { connect(url, status: status) }
        else { follow(status.activeTab?.targetId) }
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
                let stream = ScreencastStream(client: client)
                client.onEvent = { [weak stream] event in stream?.handle(event) }
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
                self.follow(status.activeTab?.targetId)
            }
        }
    }

    /// abx 가 마지막으로 본 활성 탭을 따라간다. 그 기록이 없거나(막 띄움) 그 탭이 이미 닫혔으면(오래된 기록)
    /// 보던 탭을 그대로 두거나 열린 페이지 하나를 보여 준다(`ScreencastStream.choose`).
    private func follow(_ target: String?) {
        guard let stream else { return }
        if let target, stream.currentTarget == target { return }
        Task {
            guard let pages = await stream.pages(),
                  let pick = ScreencastStream.choose(wanted: target, current: stream.currentTarget, open: pages) else { return }
            try? await stream.show(target: pick)
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
        decodeQueue.async { [weak self] in
            let image = CGImageSourceCreateWithData(frame.jpeg as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            if let image {
                DispatchQueue.main.async { self?.onImage?(image) }
            }
            self?.queue.async {
                guard let self, let next = self.frames.finish() else { return }
                self.decode(next)
            }
        }
    }
}
