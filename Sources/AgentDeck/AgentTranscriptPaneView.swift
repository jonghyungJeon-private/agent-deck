import AppKit
import SessionCore

/// 하위 에이전트 보기 화면(읽기 전용, 보이는 동안만 만든다): [머리 줄(설명 · 종류 · 상태)] / [기록].
/// 기록 파일(agent-*.jsonl)의 끝을 1초마다 따라 읽어(AgentTranscriptTail) 새로 붙은 항목만 이어 그린다.
/// 보이지 않게 되면(탭을 옮기거나 닫음) detach 로 타이머·읽기 상태·글을 모두 놓는다 — 보이는 화면만 읽고 그린다.
final class AgentTranscriptPaneView: NSView {
    let transcript: String
    private let descriptionText: String
    private let agentType: String?
    /// 일하는 중인지(nil = 모름). 머리 줄에 보이는 상태이며 알림과는 상관없다.
    var running: () -> Bool? = { nil }

    private let header = NSTextField(labelWithString: "")
    private let rule = NSView()
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var headerHeight: NSLayoutConstraint!
    private var reader: AgentTranscriptTail?
    private var timer: Timer?
    /// 지금 글이 안내 문구(항목이 없을 때)인지
    private var showingPlaceholder = false
    private var lastHeader = ""

    init(transcript: String, description: String, agentType: String?, frame: NSRect) {
        self.transcript = transcript
        self.descriptionText = description
        self.agentType = agentType
        super.init(frame: frame)
        wantsLayer = true
        header.lineBreakMode = .byTruncatingTail
        header.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false
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
        for view in [header, rule, scroll] as [NSView] { addSubview(view) }
        headerHeight = header.heightAnchor.constraint(equalToConstant: Self.headerHeight)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TermAppearance.scaled(Space.md)),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TermAppearance.scaled(Space.md)),
            headerHeight,
            rule.topAnchor.constraint(equalTo: header.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshLayerColors()
        reader = AgentTranscriptTail(path: transcript)
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged),
                                               name: TermAppearance.fontSizeChanged, object: nil)
        poll(force: true)
        updateHeader()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// 머리 줄 높이(글꼴 크기 배율을 따른다)
    static var headerHeight: CGFloat { TermAppearance.scaled(28) }

    /// 첫 응답자로 삼을 뷰(글을 고르고 ⌘C 할 수 있게)
    var focusTarget: NSView { textView }

    /// ⌘F·⌘G·⇧⌘G: 글 안 찾기(NSTextView 의 찾기 막대)
    func find(_ action: NSTextFinder.Action) {
        window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performFindPanelAction(item)
    }

    /// 시험 명령용 상태 한 줄
    var debugSummary: String {
        "agentview \((transcript as NSString).lastPathComponent) entries=\(reader?.entries.count ?? -1) missing=\(reader?.isMissing ?? false) "
            + "chars=\(textView.string.count) timer=\(timer != nil) running=\(running().map(String.init) ?? "nil") header=\(lastHeader)"
    }

    private func refreshLayerColors() {
        layer?.backgroundColor = TermAppearance.background.cg(in: self)
        rule.layer?.backgroundColor = TermAppearance.border.cg(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayerColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startTimer() } else { stopTimer() }
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

    private func updateHeader() {
        let running = running()
        let status = running == true ? "작업 중" : running == false ? "완료" : nil
        let statusColor = running == true ? TermAppearance.statusWorking : TermAppearance.statusDone
        let key = [descriptionText, agentType ?? "", status ?? ""].joined(separator: "|")
        guard key != lastHeader else { return }
        lastHeader = key
        let font = TermAppearance.uiTextFont(TermAppearance.scaled(TypeSize.row))
        let text = NSMutableAttributedString(string: descriptionText, attributes: [
            .font: TermAppearance.uiTextFont(TermAppearance.scaled(TypeSize.row), weight: .semibold),
            .foregroundColor: TermAppearance.textPrimary])
        if let agentType, !agentType.isEmpty {
            text.append(NSAttributedString(string: " · " + agentType, attributes: [.font: font, .foregroundColor: TermAppearance.textSecondary]))
        }
        if let status {
            text.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: TermAppearance.textSecondary]))
            text.append(NSAttributedString(string: status, attributes: [.font: font, .foregroundColor: statusColor]))
        }
        header.attributedStringValue = text
    }

    /// 앱 글꼴 크기 변경: 머리 줄·글꼴을 다시 맞춘다(글은 새 글꼴로 다시 그린다)
    @objc private func fontSizeChanged() {
        headerHeight.constant = Self.headerHeight
        textView.textContainerInset = NSSize(width: TermAppearance.scaled(Space.md), height: TermAppearance.scaled(Space.sm))
        lastHeader = ""
        updateHeader()
        if reader != nil { rebuild(stickToBottom: isAtBottom) }
    }

    /// 화면에서 뺄 때(탭을 옮기거나 닫을 때): 타이머·읽기 상태·글을 놓는다
    func detach() {
        stopTimer()
        reader = nil
        textView.textStorage?.setAttributedString(NSAttributedString())
        removeFromSuperview()
    }
}
