import AppKit
import SwiftTerm
import TermLayout
import TermWire

/// 오른쪽 터미널 영역: 위에 탭 줄, 아래에 지금 탭의 분할 화면.
/// 지금 탭에 보이는 화면만 터미널 뷰를 만든다(다른 탭은 데몬이 지난 출력만 들고 있다).
final class TerminalHostController: NSViewController {
    static let tabBarHeight: CGFloat = 28

    let model: TermModel
    private(set) var terminals: [String: PaneTerminal] = [:]
    private let container = SplitContainerView()
    private let placeholder = NSTextField(labelWithString: "")
    private let tabBar = TabBarView()
    private var tabBarHeight: NSLayoutConstraint!
    private var monitors: [Any] = []

    init(model: TermModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        // Shift+Enter = 줄바꿈. claude 는 이 터미널에서 확장 키 입력(kitty)을 켜지 않으므로
        // ⌥+Enter 와 같은 ESC CR 을 보낸다(claude 는 이를 줄바꿈으로 받는다).
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let pane = self.focusedTerminal, event.window === pane.view.window,
                  event.window?.firstResponder === pane.view,
                  event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.intersection([.shift, .command, .control, .option]) == .shift,
                  !pane.view.hasMarkedText(),
                  pane.view.getTerminal().keyboardEnhancementFlags.isEmpty
            else { return event }
            self.model.client.input(pane.id, [0x1b, 0x0d])
            return nil
        } as Any)
        // 화면을 누르면 그 화면으로 포커스(목록 선택·탭 제목도 따라온다)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === self.view.window, let id = self.container.paneId(at: event.locationInWindow) {
                self.model.focus(pane: id, fromClick: true)
            }
            return event
        } as Any)
    }

    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = BackgroundView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        root.color = TermAppearance.background // 칸에 안 맞는 아래 틈도 터미널과 같은 색

        tabBar.onSelect = { [weak self] index in self?.model.selectTab(index) }
        tabBar.onClose = { [weak self] index in
            self?.model.selectTab(index)
            self?.model.closeTab()
        }
        tabBar.onNew = { [weak self] in self?.model.newPane() }
        tabBar.onRename = { [weak self] index in
            guard let self, self.model.workspace.tabs.indices.contains(index) else { return }
            self.model.selectTab(index)
            self.model.rename(pane: self.model.workspace.tabs[index].focused)
        }
        for view in [container, placeholder, tabBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        placeholder.textColor = NSColor(white: 0.7, alpha: 1)
        placeholder.alignment = .center
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBarHeight,
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        container.onRatioChange = { [weak self] path, ratio in self?.model.setRatio(path: path, ratio: ratio) }
        view = root
        render()
    }

    var focusedTerminal: PaneTerminal? {
        model.workspace.selectedTab.flatMap { terminals[$0.focused] }
    }

    /// 탭·분할 배치가 바뀌면 부른다. 보일 화면의 뷰만 남기고 나머지는 버린다.
    func render() {
        guard isViewLoaded else { return }
        let tab = model.connected ? model.workspace.selectedTab : nil
        let visible = tab?.visibleRoot
        // 꺼진 화면이 보이게 되면 이때 되살린다(attach 보다 먼저 만들어지도록 같은 연결로 먼저 보낸다)
        // 되살린 화면은 예전 뷰(실패해 비어 있을 수 있음)를 버리고 새로 붙는다
        for id in model.revive(visible?.panes ?? []) {
            terminals[id]?.detach()
            terminals[id] = nil
        }
        let ids = Set(visible?.panes ?? [])
        for (id, terminal) in terminals where !ids.contains(id) {
            terminal.detach()
            terminals[id] = nil
        }
        var created: [PaneTerminal] = []
        for id in visible?.panes ?? [] where terminals[id] == nil {
            let terminal = PaneTerminal(id: id, client: model.client, frame: container.bounds)
            terminals[id] = terminal
            created.append(terminal)
        }
        container.update(tree: visible, views: terminals.mapValues { $0.view }, focused: tab?.focused, titles: paneTitles)
        // 크기가 정해진 뒤 붙어야 지난 출력이 맞는 크기로 그려진다
        created.forEach { $0.attach() }

        tabBarHeight.constant = tab == nil ? 0 : Self.tabBarHeight
        updateTabBar()
        placeholder.isHidden = tab != nil
        placeholder.stringValue = model.connected ? "왼쪽 위 버튼이나 ⌘T 로 새 화면을 여세요" : "데몬에 연결되지 않았습니다"
        focusTerminal()
    }

    /// 포커스만 바뀌었을 때(뷰는 그대로)
    func focusChanged() {
        container.setFocused(model.workspace.selectedTab?.focused, titles: paneTitles)
        updateTabBar()
        focusTerminal()
    }

    /// 목록이 새로 왔을 때 테두리 제목만 고친다(포커스는 건드리지 않음)
    func refreshTitles() {
        container.setFocused(model.workspace.selectedTab?.focused, titles: paneTitles)
        updateTabBar()
    }

    private func updateTabBar() {
        let workspace = model.workspace
        tabBar.update(tabs: workspace.tabs.map {
            TabBarView.Tab(title: model.tabTitle($0), paneCount: $0.root.panes.count, zoomed: $0.zoomed)
        }, selected: workspace.selectedIndex)
    }

    /// 분할 테두리에 쓰는 화면 제목
    private var paneTitles: [String: String] {
        Dictionary(uniqueKeysWithValues: terminals.keys.map { ($0, model.paneLabel($0)) })
    }

    private func focusTerminal() {
        guard let view = focusedTerminal?.view, let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    func receive(id: String, bytes: ArraySlice<UInt8>, replay: Bool) {
        terminals[id]?.receive(bytes, replay: replay)
    }

    func paneExited(_ id: String) {
        terminals[id]?.exited()
    }

    /// 새 화면 크기 어림: 새 탭이면 영역 전체, 나누면 지금 화면의 반
    func estimatedSize(splitting axis: SplitAxis?) -> (cols: Int, rows: Int) {
        if let axis, let size = focusedTerminal?.size {
            return axis == .horizontal ? (max(size.cols / 2, 10), size.rows) : (size.cols, max(size.rows / 2, 4))
        }
        let probe = TerminalView(frame: container.bounds.isEmpty ? view.bounds : container.bounds, font: TermAppearance.font)
        let terminal = probe.getTerminal()
        return (terminal.cols, terminal.rows)
    }

    // MARK: - 시험용

    /// 한글 입력기(IME)가 하는 것과 같은 순서로 조합 중 글자 → 확정 글자를 넣는다.
    func simulateIME(composing: [String], commit: String) {
        guard let terminalView = focusedTerminal?.view else { return }
        for text in composing {
            terminalView.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        terminalView.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 조합 중 글자만 띄운다(아무것도 보내지 않음). 빈 글자면 지운다.
    func debugMark(_ text: String) {
        focusedTerminal?.view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                                            replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func debugCursor() {
        guard let terminal = focusedTerminal?.view.getTerminal() else { return }
        let buffer = terminal.buffer
        print("cursor x=\(buffer.x) y=\(buffer.y) rows=\(terminal.rows) panes=\(terminals.keys.sorted())")
        fflush(stdout)
    }

    /// 터미널 영역(탭 줄 포함)을 그림으로 남긴다. 터미널 배경은 층(layer) 색이라 render 결과에 안 담기므로 바탕을 먼저 칠한다.
    func snapshotTerminal(to url: URL) {
        guard let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        // 터미널 글자는 터미널 층을 따로 그려야 담긴다(층 render 는 하위 층 좌표를 위아래 뒤집어 그린다)
        for terminal in terminals.values {
            guard let sublayer = terminal.view.layer else { continue }
            let frame = terminal.view.convert(terminal.view.bounds, to: view)
            context.saveGState()
            context.translateBy(x: frame.minX, y: size.height - frame.maxY)
            context.clip(to: CGRect(origin: .zero, size: frame.size))
            sublayer.render(in: context)
            context.restoreGState()
        }
        guard let content = context.makeImage(),
              let final = CGContext(data: nil, width: content.width, height: content.height, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        let rect = CGRect(x: 0, y: 0, width: content.width, height: content.height)
        final.setFillColor(TermAppearance.background.cgColor)
        final.fill(rect)
        final.draw(content, in: rect)
        guard let image = final.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    /// 화면 하나만 따로(예전 방식) — 글자가 그려지는지 확인용
    func snapshotPanes(in dir: URL) {
        for (id, terminal) in terminals {
            guard let layer = terminal.view.layer else { continue }
            let size = terminal.view.bounds.size
            guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.setFillColor(TermAppearance.background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
            context.scaleBy(x: 2, y: 2)
            layer.render(in: context)
            guard let image = context.makeImage() else { continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("pane-\(id.prefix(4)).png"), options: .atomic)
        }
    }

    /// 탭 줄만 따로
    func snapshotTabBar(to url: URL) {
        guard !tabBar.bounds.isEmpty, let rep = tabBar.bitmapImageRepForCachingDisplay(in: tabBar.bounds) else { return }
        tabBar.cacheDisplay(in: tabBar.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    func typeText(_ text: String) {
        guard let id = focusedTerminal?.id else { return }
        model.client.input(id, Array(text.utf8))
    }
}

/// 터미널과 같은 바탕색을 칠하는 영역(터미널 줄 높이에 안 맞아 남는 아래 틈이 튀지 않게)
final class BackgroundView: NSView {
    var color: NSColor = .textBackgroundColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}
