import AppKit
import SessionCore

/// 하위 에이전트 칸의 내용: 기록 읽기 전용 보기(머리 글은 칸 테두리 제목이 보이므로 두지 않는다).
/// `load` 하면 기록 파일(agent-*.jsonl)의 끝을 1초마다 따라 읽어(AgentTranscriptTail) 새로 붙은 항목만 이어 그린다.
/// `unload`(탭이 가려져 칸이 화면에서 빠질 때) 는 타이머·읽기 상태·글을 모두 놓는다 — 보이는 탭의 칸만 읽는다.
final class AgentTranscriptView: NSView {
    private(set) var transcript: String?
    /// 기록을 읽으라고 한 상태인지(읽기 상태·타이머가 있을 수 있다)
    var isLoaded: Bool { transcript != nil }

    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var reader: AgentTranscriptTail?
    private var timer: Timer?
    /// 지금 글이 안내 문구(항목이 없을 때)인지
    private var showingPlaceholder = false
    /// 처음 읽기(끝 512KiB 를 JSON 으로 풀기)는 메인 스레드 밖에서 한다 — 칸이 붙는 순간 화면이 멈칫하지 않게.
    /// 그 사이 unload·다른 load 가 오면 늦게 끝난 결과는 버린다(세대 번호).
    private var loadGeneration = 0
    private static let loadQueue = DispatchQueue(label: "agentdeck.agent-transcript-load", qos: .userInitiated)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: TermAppearance.scaled(Space.md), height: TermAppearance.scaled(Space.sm))
        scroll.documentView = textView
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshLayerColors()
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged),
                                               name: TermAppearance.fontSizeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// 첫 응답자로 삼을 뷰(글을 고르고 ⌘C 할 수 있게)
    var focusTarget: NSView { textView }

    /// ⌘F·⌘G·⇧⌘G: 글 안 찾기(NSTextView 의 찾기 막대)
    func find(_ action: NSTextFinder.Action) {
        window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performFindPanelAction(item)
    }

    /// 읽은 항목 수(읽는 중이 아니면 nil)
    var entryCount: Int? { reader?.entries.count }
    var timerOn: Bool { timer != nil }

    /// 시험 명령(agent-views)용: 읽은 항목 수·기록 없음·글자 수·타이머
    var debugSummary: String {
        "entries=\(reader?.entries.count ?? -1) missing=\(reader?.isMissing ?? false) chars=\(textView.string.count) timer=\(timer != nil)"
    }

    private func refreshLayerColors() {
        layer?.backgroundColor = TermAppearance.background.cg(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayerColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startTimer() } else { stopTimer() }
    }

    // MARK: - 고르기·놓기

    /// 이 에이전트의 기록을 읽어 보인다(이미 읽던 것은 놓고 새로 읽는다 — 읽기 상태는 하나뿐)
    func load(transcript path: String) {
        unload()
        transcript = path
        let fresh = AgentTranscriptTail(path: path)
        let generation = loadGeneration
        Self.loadQueue.async { [weak self] in
            _ = fresh.poll() // 처음 읽기: 끝 512KiB 를 읽어 항목으로 푼다(무거운 일)
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation, self.transcript == path else { return }
                self.reader = fresh
                self.rebuild(stickToBottom: true)
                self.startTimer()
            }
        }
    }

    /// 타이머·읽기 상태·글을 모두 놓는다(칸이 화면에서 빠질 때)
    func unload() {
        loadGeneration += 1 // 아직 끝나지 않은 처음 읽기는 버린다
        stopTimer()
        reader = nil
        transcript = nil
        showingPlaceholder = false
        textView.textStorage?.setAttributedString(NSAttributedString())
    }

    // MARK: - 읽기

    private func startTimer() {
        guard timer == nil, reader != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll(force: false) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll(force: false)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 창이 보이는 동안만 읽는다(가려지거나 최소화되면 쉰다)
    private var windowVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func poll(force: Bool) {
        guard let reader, force || windowVisible else { return }
        let wasAtBottom = isAtBottom
        let change = reader.poll()
        switch change {
        case .none:
            if showingPlaceholder, !reader.entries.isEmpty || reader.isMissing { rebuild(stickToBottom: true) }
        case .appended(let entries):
            if showingPlaceholder { rebuild(stickToBottom: true) } else { append(entries, stickToBottom: wasAtBottom) }
        case .reset:
            rebuild(stickToBottom: wasAtBottom || textView.textStorage?.length == 0)
        }
    }

    /// 기록 맨 아래를 보고 있는지(아니면 새 글이 와도 읽던 자리를 지킨다)
    private var isAtBottom: Bool {
        let visible = scroll.documentVisibleRect
        return visible.maxY >= textView.frame.height - TermAppearance.scaled(24)
    }

    // MARK: - 그리기

    private var bodyFont: NSFont { TermAppearance.font }

    private func attributes(_ color: NSColor, bold: Bool = false, spacing: CGFloat = 0, indent: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        let size = bodyFont.pointSize
        let font = bold ? (NSFont(descriptor: bodyFont.fontDescriptor.withSymbolicTraits(.bold), size: size) ?? bodyFont) : bodyFont
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    private func attributed(_ entry: AgentTranscriptEntry) -> NSAttributedString {
        let gap = TermAppearance.scaled(Space.sm)
        let tight = TermAppearance.scaled(2)
        let out = NSMutableAttributedString()
        switch entry.kind {
        case .prompt:
            out.append(NSAttributedString(string: "❯ ", attributes: attributes(TermAppearance.accentText, bold: true)))
            var promptAttributes = attributes(TermAppearance.textPrimary, spacing: gap)
            promptAttributes[.backgroundColor] = TermAppearance.chromeRaised
            out.append(NSAttributedString(string: entry.text, attributes: promptAttributes))
        case .text:
            out.append(NSAttributedString(string: entry.text, attributes: attributes(TermAppearance.textPrimary, spacing: gap)))
        case .tool:
            out.append(NSAttributedString(string: "▸ " + (entry.toolName ?? "tool"), attributes: attributes(TermAppearance.textSecondary, bold: true, spacing: tight)))
            if !entry.text.isEmpty {
                out.append(NSAttributedString(string: "  " + entry.text, attributes: attributes(TermAppearance.textSecondary, spacing: tight)))
            }
        case .result:
            let color = entry.isError ? TermAppearance.statusAttention : TermAppearance.textDim
            let text = entry.text.isEmpty ? "(내용 없음)" : entry.text
            out.append(NSAttributedString(string: "  ↳ " + text, attributes: attributes(color, spacing: gap, indent: 0)))
        }
        out.append(NSAttributedString(string: "\n", attributes: attributes(TermAppearance.textPrimary)))
        return out
    }

    private func placeholder() -> NSAttributedString {
        let message = reader?.isMissing == true
            ? "기록 파일을 찾을 수 없습니다. 이미 지워졌을 수 있습니다."
            : "아직 남긴 내용이 없습니다."
        return NSAttributedString(string: message, attributes: attributes(TermAppearance.textDim))
    }

    private func rebuild(stickToBottom: Bool) {
        guard let storage = textView.textStorage, let reader else { return }
        let content = NSMutableAttributedString()
        showingPlaceholder = reader.entries.isEmpty
        if showingPlaceholder {
            content.append(placeholder())
        } else {
            for entry in reader.entries { content.append(attributed(entry)) }
        }
        storage.beginEditing()
        storage.setAttributedString(content)
        storage.endEditing()
        if stickToBottom { scrollToBottom() }
    }

    private func append(_ entries: [AgentTranscriptEntry], stickToBottom: Bool) {
        guard let storage = textView.textStorage else { return }
        let content = NSMutableAttributedString()
        for entry in entries { content.append(attributed(entry)) }
        storage.beginEditing()
        storage.append(content)
        storage.endEditing()
        if stickToBottom { scrollToBottom() }
    }

    private func scrollToBottom() {
        textView.scrollRangeToVisible(NSRange(location: textView.string.utf16.count, length: 0))
    }

    /// 앱 글꼴 크기 변경: 글꼴을 다시 맞춘다(글은 새 글꼴로 다시 그린다)
    @objc private func fontSizeChanged() {
        textView.textContainerInset = NSSize(width: TermAppearance.scaled(Space.md), height: TermAppearance.scaled(Space.sm))
        if reader != nil { rebuild(stickToBottom: isAtBottom) }
    }
}
