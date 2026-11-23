import AppKit
import SessionCore

/// 하위 에이전트 기록 보기(읽기 전용, 기록만 — 설명·종류·상태는 바로 위 목록의 고른 줄이 보여 주므로 머리 줄을 두지 않는다). agents 도구 창 아래쪽에 들어간다.
/// `load` 로 에이전트를 고르면 기록 파일(agent-*.jsonl)의 끝을 1초마다 따라 읽어(AgentTranscriptTail) 새로 붙은 항목만 이어 그린다.
/// `unload`(도구 창이 가려짐·고른 에이전트 없음)·다른 에이전트로 바꿈 때는 타이머·읽기 상태·글을 모두 놓는다 — 보이는 동안 고른 것만 읽는다.
/// Codex 하위 에이전트는 기록 파일이 없어 `loadNote` 로 마지막 메시지만 보인다(읽기·타이머 없음).
final class AgentTranscriptView: NSView {
    private(set) var transcript: String?
    private var descriptionText = ""
    private var agentType: String?
    /// 일하는 중인지(nil = 모름). 머리 줄에 보이는 상태이며 알림과는 상관없다.
    var running: () -> Bool? = { nil }
    /// 지금 보이는 것이 기록 파일을 읽는 것이 아니라 안내 글(Codex)인지
    private(set) var isNote = false
    /// 기록을 읽으라고 한 상태인지(읽기 상태·타이머가 있을 수 있다)
    var isLoaded: Bool { transcript != nil || isNote }

    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var reader: AgentTranscriptTail?
    private var timer: Timer?
    /// 지금 글이 안내 문구(항목이 없을 때)인지
    private var showingPlaceholder = false
    private var lastHeader = ""

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

    /// 시험 명령용 상태 한 줄
    var debugSummary: String {
        "transcript \(transcript.map { ($0 as NSString).lastPathComponent } ?? "-") entries=\(reader?.entries.count ?? -1) missing=\(reader?.isMissing ?? false) "
            + "chars=\(textView.string.count) timer=\(timer != nil) note=\(isNote) running=\(running().map(String.init) ?? "nil") header=\(lastHeader)"
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
    func load(transcript path: String, description: String, agentType: String?) {
        unload()
        transcript = path
        descriptionText = description
        self.agentType = agentType
        reader = AgentTranscriptTail(path: path)
        poll(force: true)
        updateHeader()
        startTimer()
    }

    /// 기록 파일이 없는 에이전트(Codex): 읽지 않고 마지막 메시지와 안내만 보인다. 같은 에이전트에 다시 부르면 글만 고친다.
    func loadNote(description: String, agentType: String?, lastText: String?) {
        if !isNote { unload() }
        isNote = true
        descriptionText = description
        self.agentType = agentType
        let out = NSMutableAttributedString(string: "Codex 하위 에이전트는 대화 기록을 볼 수 없습니다\n\n",
                                            attributes: attributes(TermAppearance.textDim))
        let text = (lastText?.isEmpty == false) ? lastText! : "아직 남긴 메시지가 없습니다."
        out.append(NSAttributedString(string: text, attributes: attributes(TermAppearance.textPrimary)))
        textView.textStorage?.setAttributedString(out)
        showingPlaceholder = false
        textView.scrollToBeginningOfDocument(nil)
        updateHeader()
    }

    /// 머리 줄 상태(작업 중·완료)만 다시 맞춘다(목록이 바뀌었을 때)
    func refreshStatus() { updateHeader() }

    /// 타이머·읽기 상태·글을 모두 놓는다(도구 창이 가려지거나 고른 에이전트가 없어질 때, 다른 에이전트로 바꾸기 전)
    func unload() {
        stopTimer()
        reader = nil
        transcript = nil
        isNote = false
        showingPlaceholder = false
        descriptionText = ""
        agentType = nil
        lastHeader = ""
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
        updateHeader()
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

    /// 상태 요약(시험 명령 `agent-views` 의 header= 로만 보인다 — 화면에는 목록의 고른 줄이 같은 내용을 보인다)
    private func updateHeader() {
        let running = running()
        let status = running == true ? "작업 중" : running == false ? "완료" : nil
        guard isLoaded else { return }
        lastHeader = [descriptionText, agentType ?? "", status ?? ""].joined(separator: "|")
    }

    /// 앱 글꼴 크기 변경: 머리 줄·글꼴을 다시 맞춘다(글은 새 글꼴로 다시 그린다)
    @objc private func fontSizeChanged() {
        textView.textContainerInset = NSSize(width: TermAppearance.scaled(Space.md), height: TermAppearance.scaled(Space.sm))
        lastHeader = ""
        updateHeader()
        if reader != nil { rebuild(stickToBottom: isAtBottom) }
    }

}
