import AppKit
import TermLayout

// MARK: - 창 제목 줄과 합친 탭 줄(신호등 자리·창 끌기)

/// 제목 줄처럼 쓰는 빈 곳의 마우스: 끌면 창을 옮기고, 두 번 누르면 시스템 설정("제목 막대를 두 번 클릭하면")대로 확대·최소화.
enum WindowDragging {
    static var doubleClickAction: WindowChrome.DoubleClickAction {
        let defaults = UserDefaults.standard
        return WindowChrome.doubleClickAction(action: defaults.string(forKey: "AppleActionOnDoubleClick"),
                                              legacyMinimize: defaults.object(forKey: "AppleMiniaturizeOnDoubleClick") as? Bool)
    }

    static func mouseDown(_ event: NSEvent, in window: NSWindow?) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch doubleClickAction {
            case .zoom: window.performZoom(nil)
            case .minimize: window.performMiniaturize(nil)
            case .none: break
            }
        } else {
            window.performDrag(with: event)
        }
    }
}

/// 창 끌기 전용 빈 영역(왼쪽 도크 맨 위의 신호등 자리). 색만 칠한다.
final class WindowDragView: NSView {
    var color: NSColor = TermAppearance.chrome {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    override func mouseDown(with event: NSEvent) { WindowDragging.mouseDown(event, in: window) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { true }
}

/// 메인 창을 "탭 줄이 제목 줄에 들어간" 모양으로 맞춘다: 내용이 제목 줄 밑까지 올라오고(제목 줄은 투명, 글자는 숨김),
/// 신호등은 탭 줄 높이의 가운데에 앉으며(제목 줄 뷰 밖으로는 나가지 않게), 신호등 오른쪽 끝(`lightsMaxX`)을 탭 줄이 읽어 자리를 비운다.
/// 창 제목·부제는 그대로 설정해 둔다(창 메뉴·Mission Control 이 읽는다).
///
/// 시스템은 창 크기를 바꾸는 중·전체 화면을 오갈 때·제목 줄을 다시 짤 때 신호등을 제자리로 되돌린다. 그때마다 그려지기 전에 우리 자리로 다시 앉히려고
/// 신호등과 그 부모(제목 줄 뷰)의 틀 바뀜을 직접 듣는다(레이아웃 도중에 고치므로 한 프레임도 어긋나 보이지 않는다). `didUpdate` 는 마지막 안전망.
final class MainWindowChrome: NSObject {
    private weak var window: NSWindow?
    /// 신호등을 가운데에 앉힐 줄 높이(탭 줄 높이 — 글꼴 배율을 따른다)
    private let rowHeight: () -> CGFloat
    /// 신호등 자리·전체 화면이 바뀜(탭 줄이 비울 폭을 다시 정한다)
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// 틀 바뀜을 듣고 있는 뷰(전체 화면을 오가면 시스템이 부모를 바꾸므로 갱신 때마다 다시 건다)
    private var frameObservers: [(view: NSView, token: NSObjectProtocol)] = []
    private var isPlacing = false

    init(window: NSWindow, rowHeight: @escaping () -> CGFloat) {
        self.window = window
        self.rowHeight = rowHeight
        super.init()
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didChangeBackingPropertiesNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.refresh() })
        }
        observers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            self?.positionTrafficLights()
        })
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification, NSWindow.willStartLiveResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.observeButtonFrames()
                self?.onChange?()
            })
        }
        observeButtonFrames()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        frameObservers.forEach { NotificationCenter.default.removeObserver($0.token) }
    }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    private var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    /// 신호등과 그 부모의 틀이 바뀌면 곧바로 자리를 다시 잡는다
    private func observeButtonFrames() {
        let views = buttons.flatMap { button -> [NSView] in [button] + (button.superview.map { [$0] } ?? []) }
        let unique = views.reduce(into: [NSView]()) { result, view in if !result.contains(where: { $0 === view }) { result.append(view) } }
        guard unique.count != frameObservers.count || zip(unique, frameObservers).contains(where: { $0 !== $1.view }) else { return }
        frameObservers.forEach { NotificationCenter.default.removeObserver($0.token) }
        frameObservers = unique.map { view in
            view.postsFrameChangedNotifications = true
            let token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                self?.positionTrafficLights()
            }
            return (view, token)
        }
    }

    /// 신호등 오른쪽 끝(창 좌표 x). 전체 화면이거나 신호등이 없으면 0.
    var lightsMaxX: Double {
        guard !isFullScreen, let zoom = window?.standardWindowButton(.zoomButton), !zoom.isHidden, zoom.window != nil else { return 0 }
        return Double(zoom.convert(zoom.bounds, to: nil).maxX)
    }

    /// 신호등 세로 자리를 탭 줄 가운데에 맞추고, 바뀐 것을 알린다(글꼴 배율이 바뀔 때도 이리로 온다)
    func refresh() {
        observeButtonFrames()
        positionTrafficLights()
        onChange?()
    }

    func positionTrafficLights() {
        guard let window, !isFullScreen, !isPlacing else { return }
        isPlacing = true
        defer { isPlacing = false }
        let height = Double(rowHeight())
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), let superview = button.superview else { continue }
            var frame = button.frame
            // 제목 줄 뷰는 창 맨 위에 붙어 있다. 그 안에서 위에서부터 (줄 높이 − 단추 높이) / 2 만큼 내린다 — 단, 뷰 밖으로는 나가지 않게
            let top = CGFloat(WindowChrome.lightsTop(rowHeight: height, buttonHeight: Double(frame.height),
                                                     containerHeight: Double(superview.bounds.height)))
            frame.origin.y = superview.isFlipped ? top : superview.bounds.height - top - frame.height
            if button.frame != frame { button.frame = frame }
        }
    }

    /// 시험 명령 `chrome`: 신호등·제목 줄 뷰·탭 줄 자리(창 위에서 아래로 잰 값)
    var debugReport: String {
        guard let window else { return "chrome no-window" }
        var lines = ["chrome style=\(window.styleMask.rawValue) fullSize=\(window.styleMask.contains(.fullSizeContentView)) fullScreen=\(isFullScreen) "
                     + "titleVisible=\(window.titleVisibility == .visible) transparent=\(window.titlebarAppearsTransparent) "
                     + "title=\"\(window.title)\" subtitle=\"\(window.subtitle)\" zoomed=\(window.isZoomed) zoomable=\(window.standardWindowButton(.zoomButton)?.isEnabled ?? false) key=\(window.isKeyWindow) frame=\(window.frame) layoutRect=\(window.contentLayoutRect) rowHeight=\(Int(rowHeight()))"]
        let windowHeight = window.contentView?.bounds.height ?? 0
        for (name, type) in [("close", NSWindow.ButtonType.closeButton), ("mini", .miniaturizeButton), ("zoom", .zoomButton)] {
            guard let button = window.standardWindowButton(type) else { continue }
            let rect = button.convert(button.bounds, to: nil)
            lines.append(String(format: "chrome light %@ x=%.1f…%.1f top=%.1f…%.1f centerY(from top)=%.1f hidden=%@", name, rect.minX, rect.maxX,
                                windowHeight - rect.maxY, windowHeight - rect.minY, windowHeight - rect.midY, button.isHidden ? "yes" : "no"))
        }
        if let superview = window.standardWindowButton(.closeButton)?.superview {
            var chain: [String] = [], view: NSView? = superview
            while let current = view, chain.count < 4 {
                chain.append("\(type(of: current)) \(current.frame)")
                view = current.superview
            }
            lines.append("chrome chain " + chain.joined(separator: " <- "))
        }
        lines.append(String(format: "chrome lightsMaxX=%.1f", lightsMaxX))
        return lines.joined(separator: "\n")
    }
}
