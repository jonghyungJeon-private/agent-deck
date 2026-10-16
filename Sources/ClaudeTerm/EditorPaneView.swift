import AppKit
import EditorCore

/// 편집기 화면(보이는 동안만 만든다): [디스크 변경 배너] / [줄 번호·변경 표시 여백 | 글] / [상태 줄].
/// 바이너리·너무 큰 파일은 글 대신 안내만 보인다. Markdown 은 상태 줄의 편집·미리보기 단추(⇧⌘V)로 그 자리에서 바꾼다.
final class EditorPaneView: NSView, NSTextViewDelegate {
    let document: EditorDocument
    private(set) var textView: EditorTextView?
    private var scrollView: NSScrollView?
    private var gutter: EditorGutterView?
    private var container: NSTextContainer?
    private var highlighter: EditorHighlighter?
    private let banner = EditorBannerView()
    private let status = NSTextField(labelWithString: "")
    private var notice: EditorNoticeView?
    private var bannerHeight: NSLayoutConstraint!
    private let body = NSView()
    /// 미리보기(보는 동안만 있다)
    private(set) var preview: MarkdownPreviewView?
    private let modeSwitch = EditorModeSwitch()
    private var modeSwitchWidth: NSLayoutConstraint!
    private var previewRefreshQueued = false
    /// 미리보기에서 로컬 파일 링크를 눌렀을 때(경로)
    var onOpenFile: ((String) -> Void)?
    /// ⌘클릭(글 위치) — 선언으로 이동
    var onNavigate: ((Int) -> Void)?
    /// 잠깐 뜨는 안내("색인 중…", "선언을 찾지 못했습니다")
    private let hintLabel = EditorHintView()
    private var hintWork: DispatchWorkItem?
    private var hintToken = 0

    static let statusHeight: CGFloat = 20

    init(document: EditorDocument, frame: NSRect) {
        self.document = document
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = EditorStyle.background.cgColor

        status.font = TermAppearance.uiFont(10)
        status.textColor = TermAppearance.textDim
        status.lineBreakMode = .byTruncatingHead
        status.alignment = .right
        banner.onReload = { [weak self] in self?.document.reloadFromDisk() }
        banner.onOverwrite = { [weak self] in self?.document.overwriteDisk() }
        modeSwitch.onSelect = { [weak self] preview in self?.setPreview(preview) }
        for view in [banner, body, modeSwitch, status, hintLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        hintLabel.isHidden = true
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        modeSwitchWidth = modeSwitch.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: topAnchor),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            bannerHeight,
            body.topAnchor.constraint(equalTo: banner.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: status.topAnchor),
            modeSwitch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            modeSwitch.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            modeSwitch.heightAnchor.constraint(equalToConstant: EditorModeSwitch.height),
            modeSwitchWidth,
            status.leadingAnchor.constraint(equalTo: modeSwitch.trailingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: Self.statusHeight),
            hintLabel.topAnchor.constraint(equalTo: body.topAnchor, constant: 10),
            hintLabel.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -18),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: body.leadingAnchor, constant: 18),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged),
                                               name: TermAppearance.fontSizeChanged, object: nil)
        document.loadIfNeeded()
        document.onViewUpdate = { [weak self] update in self?.documentUpdated(update) }
        document.onTextEdited = { [weak self] range, delta in
            self?.highlighter?.edited(range, delta: delta)
            self?.schedulePreviewRefresh()
        }
        buildContent()
        document.becameVisible()
        updateBanner()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// 첫 응답자로 삼을 뷰(미리보기 중이면 미리보기, 아니면 글, 없으면 안내)
    var focusTarget: NSView? { preview?.webView ?? textView ?? notice }

    // MARK: - 내용

    private func buildContent() {
        teardownPreview()
        body.subviews.forEach { $0.removeFromSuperview() }
        teardownText()
        notice = nil
        switch document.content {
        case .text:
            buildText()
        case .notice(let title, let detail):
            let view = EditorNoticeView(title: title, detail: detail)
            embed(view)
            notice = view
            status.stringValue = "읽기 전용"
        case .unloaded:
            break
        }
        applyMode()
    }

    /// 앱 글꼴 크기 변경: 글·줄 번호 여백 글꼴을 바꾸고 여백 폭을 다시 정한다
    @objc private func fontSizeChanged() {
        guard let textView else { return }
        document.applyFontSize()
        textView.font = EditorStyle.font
        textView.defaultParagraphStyle = EditorStyle.paragraph
        textView.typingAttributes = EditorStyle.textAttributes
        gutter?.fontChanged()
        textView.needsDisplay = true
        colorVisible()
    }

    private func embed(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: body.topAnchor),
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }

    private func buildText() {
        guard let layoutManager = document.layoutManager, let storage = document.storage else { return }
        let scroll = NSScrollView(frame: body.bounds)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorStyle.background
        scroll.scrollerStyle = .legacy
        scroll.appearance = NSAppearance(named: .darkAqua)

        // 줄바꿈 없이(가로로 길게) — 글 상자는 끝없이 넓게
        let size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let container = NSTextContainer(size: size)
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 4
        layoutManager.addTextContainer(container)
        let contentSize = scroll.contentSize
        let textView = EditorTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: container)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = size
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.configure()
        textView.delegate = self
        if let language = document.language, SymbolLanguages.supported.contains(language) {
            textView.linkLanguage = language
            textView.linkKeywords = language.spec.keywords
            textView.onCommandClick = { [weak self] index in self?.onNavigate?(index) }
        }
        scroll.documentView = textView

        // 줄 번호 여백은 글 옆에 따로 둔 뷰(스크롤에 맞춰 다시 그린다)
        let gutter = EditorGutterView(textView: textView, document: document)
        for view in [gutter, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        let gutterWidth = gutter.widthAnchor.constraint(equalToConstant: gutter.thickness)
        gutter.widthConstraint = gutterWidth
        NSLayoutConstraint.activate([
            gutter.topAnchor.constraint(equalTo: body.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            gutterWidth,
            scroll.topAnchor.constraint(equalTo: body.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
        self.scrollView = scroll
        self.textView = textView
        self.gutter = gutter
        self.container = container
        if document.highlightEnabled, let language = document.language {
            highlighter = EditorHighlighter(scanner: SyntaxScanner(language), storage: storage, layoutManager: layoutManager)
        }

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        // 커서를 마지막 자리로
        let location = min(max(document.cursor, 0), storage.length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView = self.textView else { return }
            textView.scrollRangeToVisible(textView.selectedRange())
            self.colorVisible()
        }
        updateStatus()
    }

    private func teardownText() {
        if let scrollView { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: scrollView.contentView) }
        if let textView { document.cursor = textView.selectedRange().location }
        if let container, let layoutManager = document.layoutManager,
           let index = layoutManager.textContainers.firstIndex(where: { $0 === container }) {
            layoutManager.removeTextContainer(at: index)
        }
        textView?.delegate = nil
        scrollView = nil
        textView = nil
        gutter = nil
        container = nil
        highlighter = nil
    }

    /// 화면에서 뺄 때(탭을 옮기거나 닫을 때). 깨끗한 문서는 글을 놓는다.
    func detach() {
        teardownPreview()
        teardownText()
        document.onViewUpdate = nil
        document.onTextEdited = nil
        document.becameHidden()
        document.releaseIfClean()
        removeFromSuperview()
    }

    private func documentUpdated(_ update: EditorDocument.Update) {
        if update.contains(.content) {
            let hadFocus = window?.firstResponder === textView
            if textView == nil || document.content != .text {
                buildContent()
            } else {
                highlighter?.invalidateAll()
                colorVisible()
                gutter?.refresh()
                refreshPreview() // 디스크에서 다시 읽은 내용
            }
            if hadFocus, let target = focusTarget { window?.makeFirstResponder(target) }
        }
        if update.contains(.markers) { gutter?.needsDisplay = true }
        if update.contains(.banner) || update.contains(.content) { updateBanner() }
        if update.contains(.title) { updateStatus() }
    }

    private func updateBanner() {
        banner.show(document.diskConflict)
        bannerHeight.constant = document.diskConflict == nil ? 0 : EditorBannerView.height
    }

    private func updateStatus() {
        guard document.content == .text, let textView, let storage = document.storage else { return }
        if preview != nil {
            var parts = ["미리보기 · 읽기 전용", "⇧⌘V 편집으로"]
            if document.isDirty { parts.insert("● 저장 안 됨 (편집 중인 내용을 보여 줌)", at: 0) }
            status.stringValue = parts.joined(separator: "  ·  ")
            return
        }
        let location = min(textView.selectedRange().location, storage.length)
        let line = document.lines.line(containing: location)
        let column = location - document.lines.starts[line] + 1
        var parts = ["\(line + 1):\(column)", "UTF-8" + (document.hasBOM ? " BOM" : ""), document.lineEnding.label]
        if let language = document.language { parts.append(language.rawValue) }
        if !document.highlightEnabled, document.language != nil { parts.append("색 없음(500KB 넘음)") }
        if !document.markersEnabled { parts.append("변경 표시 없음(큰 파일)") }
        if document.isDirty { parts.insert("● 저장 안 됨", at: 0) }
        status.stringValue = parts.joined(separator: "  ·  ")
    }

    // MARK: - Markdown 미리보기

    /// 미리보기를 쓸 수 있는지(Markdown 이고 글로 연 파일)
    var canPreview: Bool { document.isMarkdown && document.content == .text }

    func togglePreview() { setPreview(!document.showsPreview) }

    /// 편집 ↔ 미리보기. 이 화면에 포커스가 있었으면 바뀐 쪽으로 옮긴다.
    func setPreview(_ on: Bool) {
        guard !on || canPreview, on != (preview != nil) else { return }
        let hadFocus = (window?.firstResponder as? NSView).map { $0.isDescendant(of: self) } ?? false
        document.showsPreview = on
        applyMode()
        if hadFocus, let target = focusTarget { window?.makeFirstResponder(target) }
    }

    /// 문서 상태에 맞춰 글 / 미리보기를 보인다(미리보기 웹 화면은 이때 만들고, 편집으로 돌아가면 버린다)
    private func applyMode() {
        let on = document.showsPreview && canPreview
        if on, preview == nil, let storage = document.storage {
            let view = MarkdownPreviewView(path: document.path, scroll: document.previewScroll, frame: body.bounds)
            view.onOpenFile = { [weak self] path in self?.onOpenFile?(path) }
            embed(view)
            preview = view
            view.show(markdown: storage.string)
        } else if !on {
            teardownPreview()
        }
        scrollView?.isHidden = on
        gutter?.isHidden = on
        modeSwitch.isHidden = !canPreview
        modeSwitch.selected = on ? 1 : 0
        modeSwitchWidth.constant = canPreview ? modeSwitch.fittingWidth : 0
        updateStatus()
    }

    private func teardownPreview() {
        guard let preview else { return }
        self.preview = nil
        let document = self.document
        preview.close { y in document.previewScroll = y }
    }

    /// 버퍼가 바뀌면(되돌리기 등) 한 차례에 한 번만 다시 그린다
    private func schedulePreviewRefresh() {
        guard preview != nil, !previewRefreshQueued else { return }
        previewRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.previewRefreshQueued = false
            self?.refreshPreview()
        }
    }

    private func refreshPreview() {
        guard let preview, let storage = document.storage else { return }
        preview.show(markdown: storage.string)
    }

    // MARK: - 이동(⌘B·뒤로 등)

    /// 줄로 가서 가운데에 보인다. 열을 모르면 그 줄에서 이름을 찾고, 줄이 어긋났으면(파일이 바뀜) 가까운 줄에서 찾는다.
    /// 실제로 간 줄을 돌려준다.
    @discardableResult
    func reveal(line: Int, column: Int?, name: String?) -> Int {
        guard let textView, let storage = document.storage, document.content == .text else { return line }
        let text = storage.string as NSString
        let lines = document.lines
        var target = min(max(line, 0), lines.lineCount - 1)
        var col = column
        if col == nil, let name {
            if let found = Identifier.firstWholeWord(name, in: CodeNavigator.line(text, lines, target), language: document.language) {
                col = found
            } else {
                // 가까운 줄부터(위아래로 200줄까지)
                for distance in 1...200 {
                    for candidate in [target - distance, target + distance] where candidate >= 0 && candidate < lines.lineCount {
                        if let found = Identifier.firstWholeWord(name, in: CodeNavigator.line(text, lines, candidate), language: document.language) {
                            target = candidate
                            col = found
                            break
                        }
                    }
                    if col != nil { break }
                }
            }
        }
        if col == nil {
            // 줄 첫 글자(들여쓰기 뒤)
            let lineText = CodeNavigator.line(text, lines, target) as NSString
            var first = 0
            while first < lineText.length, lineText.character(at: first) == 32 || lineText.character(at: first) == 9 { first += 1 }
            col = first
        }
        let location = min(lines.starts[target] + (col ?? 0), text.length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        center(location, flash: name.map { ($0 as NSString).length } ?? 0)
        return target
    }

    /// 글 위치로(뒤로·앞으로)
    func reveal(offset: Int) {
        guard let textView, let storage = document.storage else {
            document.cursor = offset
            return
        }
        let location = min(max(offset, 0), storage.length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        center(location, flash: 0)
    }

    /// 화면 배치가 끝난 뒤 그 줄을 세로 가운데로(IntelliJ 처럼). flash = 잠깐 밝힐 글자 수(이름)
    private func center(_ location: Int, flash: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView = self.textView, let scrollView = self.scrollView,
                  let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }
            self.layoutSubtreeIfNeeded()
            let length = storage.length
            let at = min(location, length)
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: at, length: 0))
            var rect: NSRect
            if length == 0 || at >= length {
                rect = layoutManager.extraLineFragmentRect
                if rect.isEmpty, length > 0 {
                    rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: length - 1), effectiveRange: nil)
                }
            } else {
                rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: at), effectiveRange: nil)
            }
            rect.origin.y += textView.textContainerOrigin.y
            let clip = scrollView.contentView
            let visibleHeight = clip.bounds.height
            let maxY = max(textView.frame.height - visibleHeight, 0)
            clip.scroll(to: NSPoint(x: 0, y: min(max(rect.midY - visibleHeight / 2, 0), maxY)))
            scrollView.reflectScrolledClipView(clip)
            textView.scrollRangeToVisible(NSRange(location: at, length: 0)) // 가로
            self.colorVisible()
            self.gutter?.needsDisplay = true
            if flash > 0, at + flash <= length { textView.flash(NSRange(location: at, length: flash)) }
        }
    }

    /// 커서 자리(view 좌표) — 목록 창을 그 아래에 띄운다
    func caretRect(in view: NSView) -> NSRect? {
        guard let textView, let window = textView.window else { return nil }
        let screen = textView.firstRect(forCharacterRange: NSRange(location: textView.selectedRange().location, length: 0), actualRange: nil)
        guard screen != .zero else { return nil }
        let inWindow = window.convertFromScreen(screen)
        var rect = view.convert(inWindow, from: nil)
        rect.size.width = max(rect.width, 1)
        return rect
    }

    /// 오른쪽 위에 잠깐 안내(sticky 면 hideHint 까지)
    @discardableResult
    func showHint(_ text: String, sticky: Bool = false) -> Int {
        hintWork?.cancel()
        hintToken += 1
        hintLabel.text = text
        hintLabel.isHidden = false
        guard !sticky else { return hintToken }
        let work = DispatchWorkItem { [weak self] in self?.hintLabel.isHidden = true }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        return hintToken
    }

    /// token 이 있으면 그 안내가 아직 떠 있을 때만 내린다(뒤에 띄운 다른 요청의 안내는 두고)
    func hideHint(_ token: Int? = nil) {
        if let token, token != hintToken { return }
        hintWork?.cancel()
        hintLabel.isHidden = true
    }

    /// 시험용: 안내 글(안 보이면 nil)
    var debugHint: String? { hintLabel.isHidden ? nil : hintLabel.text }

    /// 시험용: 뷰 크기
    var debugGeometry: String {
        guard let textView, let scrollView else { return "geometry=-" }
        return "pane=\(frame.size) scroll=\(scrollView.frame.size) text=\(textView.frame) visible=\(textView.visibleRect) "
            + "used=\(textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero) gutter=\(gutter?.thickness ?? 0) "
            + "banner=\(bannerHeight.constant)"
    }

    /// 시험용: 배너 단추 누르기
    func debugBanner(_ name: String) { banner.press(name) }

    @objc private func scrolled() {
        colorVisible()
        gutter?.needsDisplay = true
    }

    private func colorVisible() {
        guard let highlighter, let textView, let layoutManager = document.layoutManager, let container else { return }
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        highlighter.color(characters)
    }

    // MARK: - NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { document.undoManager }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView?.needsDisplay = true // 지금 줄 바탕
        gutter?.needsDisplay = true
        updateStatus()
        if let textView { document.cursor = textView.selectedRange().location }
    }

    func textDidChange(_ notification: Notification) {
        gutter?.refresh()
        DispatchQueue.main.async { [weak self] in self?.colorVisible() }
        updateStatus()
    }
}

// MARK: - 글

final class EditorTextView: NSTextView {
    func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        font = EditorStyle.font
        textColor = EditorStyle.text
        backgroundColor = EditorStyle.background
        drawsBackground = true
        insertionPointColor = EditorStyle.caret
        selectedTextAttributes = [.backgroundColor: EditorStyle.selection]
        defaultParagraphStyle = EditorStyle.paragraph
        typingAttributes = EditorStyle.textAttributes
        appearance = NSAppearance(named: .darkAqua)
    }

    /// 지금 줄(커서가 있는 줄) 사각형(글 뷰 좌표, 폭 전체)
    func currentLineRect() -> NSRect? {
        guard let layoutManager, let storage = textStorage else { return nil }
        let location = selectedRange().location
        let length = storage.length
        var rect: NSRect
        let string = storage.string as NSString
        if length == 0 || (location >= length && string.character(at: length - 1) == 10) {
            rect = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, length - 1))
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        }
        guard rect.height > 0 else { return nil }
        rect.origin.y += textContainerOrigin.y
        rect.origin.x = 0
        rect.size.width = max(bounds.width, visibleRect.maxX)
        return rect
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if selectedRange().length == 0, let line = currentLineRect(), line.intersects(rect) {
            EditorStyle.currentLine.setFill()
            line.intersection(rect).fill()
        }
    }

    /// Enter: 윗줄 들여쓰기를 이어 간다(그 이상은 하지 않는다 — 가벼운 편집기)
    override func insertNewline(_ sender: Any?) {
        let string = self.string as NSString
        let selection = selectedRange()
        let line = string.lineRange(for: NSRange(location: selection.location, length: 0))
        var end = line.location
        while end < selection.location, end < string.length {
            let c = string.character(at: end)
            guard c == 32 || c == 9 else { break }
            end += 1
        }
        let indent = string.substring(with: NSRange(location: line.location, length: end - line.location))
        insertText("\n" + indent, replacementRange: selection)
    }

    // 찾기(⌘F·⌘G·⌘⇧G·⌥⌘F). 편집기만 응답하는 이름이라 터미널의 ⌘F 는 그대로 터미널로 간다.
    @objc func editorFind(_ sender: Any?) { finderAction(.showFindInterface) }
    @objc func editorFindNext(_ sender: Any?) { finderAction(.nextMatch) }
    @objc func editorFindPrevious(_ sender: Any?) { finderAction(.previousMatch) }
    @objc func editorReplace(_ sender: Any?) { finderAction(.showReplaceInterface) }

    func finderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }

    // MARK: ⌘클릭(선언으로) — ⌘ 를 누른 채 이름 위에 있으면 밑줄·손가락 커서

    /// 선언 찾기를 지원하는 언어일 때만 켠다
    var linkLanguage: SyntaxLanguage?
    var linkKeywords: Set<String> = []
    var onCommandClick: ((Int) -> Void)?
    private var linkRange: NSRange?
    private var linkTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTracking { removeTrackingArea(linkTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        linkTracking = area
    }

    /// 창 좌표 아래의 이름(글자 위에 있을 때만, 키워드 빼고)
    func identifierRange(atWindowPoint windowPoint: NSPoint) -> NSRange? {
        guard linkLanguage != nil, let layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let point = convert(windowPoint, from: nil)
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.insetBy(dx: -0.5, dy: 0).contains(inContainer) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let text = storage.string as NSString
        guard let range = Identifier.range(in: text, at: index, language: linkLanguage), NSLocationInRange(index, range),
              !linkKeywords.contains(text.substring(with: range)) else { return nil }
        return range
    }

    private func updateLink(_ windowPoint: NSPoint, _ flags: NSEvent.ModifierFlags) {
        let commandOnly = flags.intersection([.command, .shift, .option, .control]) == .command
        // 마우스 이동은 키 창에서만 오고(추적 영역), ⌘ 변화는 첫 응답자에게만 온다
        let range = commandOnly ? identifierRange(atWindowPoint: windowPoint) : nil
        guard range != linkRange else { return }
        clearLink()
        guard let range, let layoutManager else {
            NSCursor.iBeam.set()
            return
        }
        linkRange = range
        layoutManager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: TermAppearance.accent],
                                             forCharacterRange: range)
        NSCursor.pointingHand.set()
    }

    private func clearLink() {
        guard let range = linkRange else { return }
        linkRange = nil
        guard let layoutManager, let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
    }

    /// 시험용: 밑줄 중인 이름
    var debugLink: String? {
        guard let linkRange, let storage = textStorage, NSMaxRange(linkRange) <= storage.length else { return nil }
        return (storage.string as NSString).substring(with: linkRange)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, event.clickCount == 1,
           let onCommandClick, let range = identifierRange(atWindowPoint: event.locationInWindow) {
            clearLink()
            window?.makeFirstResponder(self)
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            onCommandClick(NSLocationInRange(index, range) || index == NSMaxRange(range) ? index : range.location)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if linkLanguage != nil { updateLink(event.locationInWindow, event.modifierFlags) }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard linkLanguage != nil, let window else { return }
        let point = window.mouseLocationOutsideOfEventStream
        if visibleRect.contains(convert(point, from: nil)) { updateLink(point, event.modifierFlags) } else { clearLink() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearLink()
    }

    override func cursorUpdate(with event: NSEvent) {
        if linkRange != nil { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        clearLink()
        super.keyDown(with: event)
    }

    /// 건너뛴 곳의 이름을 잠깐 밝힌다
    func flash(_ range: NSRange) {
        guard let layoutManager, let storage = textStorage, NSMaxRange(range) <= storage.length, range.length > 0 else { return }
        layoutManager.addTemporaryAttribute(.backgroundColor, value: TermAppearance.accent.withAlphaComponent(0.35), forCharacterRange: range)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, let layoutManager = self.layoutManager, let storage = self.textStorage,
                  NSMaxRange(range) <= storage.length else { return }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
    }
}

/// 편집기 오른쪽 위에 잠깐 뜨는 안내(둥근 바탕)
final class EditorHintView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = TermAppearance.chromeRaised.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = TermAppearance.border.cgColor
        label.font = TermAppearance.uiFont(12)
        label.textColor = TermAppearance.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 줄 번호·git 변경 표시

final class EditorGutterView: NSView {
    private weak var editor: EditorTextView?
    private let document: EditorDocument
    private var lastDigits = 0
    static let markerWidth: CGFloat = 3
    private(set) var thickness: CGFloat = 40
    var widthConstraint: NSLayoutConstraint?

    init(textView: EditorTextView, document: EditorDocument) {
        self.editor = textView
        self.document = document
        super.init(frame: .zero)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var numberAttributes: [NSAttributedString.Key: Any] {
        [.font: TermAppearance.uiFont(EditorStyle.gutterFontSize), .foregroundColor: EditorStyle.lineNumber]
    }

    /// 글꼴 크기가 바뀌면 자릿수 폭을 다시 잰다
    func fontChanged() {
        lastDigits = 0
        refresh()
    }

    /// 줄 수 자릿수에 맞춰 폭을 정한다
    func refresh() {
        let digits = max(3, String(document.lines.lineCount).count)
        if digits != lastDigits {
            lastDigits = digits
            let width = ("8" as NSString).size(withAttributes: numberAttributes).width * CGFloat(digits)
            thickness = ceil(width + 14 + Self.markerWidth + 8)
            widthConstraint?.constant = thickness
        }
        needsDisplay = true
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        EditorStyle.gutter.setFill()
        dirtyRect.intersection(bounds).fill()
        drawLines()
    }

    /// 클릭은 글로(여백을 눌러도 그 줄로 가게 하진 않는다 — 가볍게)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func drawLines() {
        guard let textView = editor, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage else { return }
        let lines = document.lines
        let string = storage.string as NSString
        let length = storage.length
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let currentLine = lines.line(containing: min(textView.selectedRange().location, length))
        let markerX = bounds.width - Self.markerWidth - 5

        // 보이는 줄의 화면 위치
        var frames: [Int: NSRect] = [:]
        var line = lines.line(containing: characters.location)
        let lastLocation = NSMaxRange(characters)
        while line < lines.lineCount {
            let start = lines.starts[line]
            if start > lastLocation { break }
            var fragment: NSRect
            if start >= length {
                // 마지막 줄바꿈 뒤 빈 줄(또는 빈 파일)
                guard length == 0 || string.character(at: length - 1) == 10 else { break }
                fragment = layoutManager.extraLineFragmentRect
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
            let frame = NSRect(x: 0, y: y, width: bounds.width, height: fragment.height)
            frames[line] = frame
            var attributes = numberAttributes
            if line == currentLine { attributes[.foregroundColor] = EditorStyle.currentLineNumber }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: markerX - 6 - size.width, y: frame.minY + (frame.height - size.height) / 2),
                       withAttributes: attributes)
            line += 1
        }
        guard let first = frames.keys.min(), let last = frames.keys.max() else { return }

        // git 변경 표시
        for change in document.changes {
            switch change.kind {
            case .added, .modified:
                let end = change.start + change.count - 1
                guard end >= first, change.start <= last else { continue }
                (change.kind == .added ? EditorStyle.added : EditorStyle.modified).setFill()
                for index in max(change.start, first)...min(end, last) {
                    guard let frame = frames[index] else { continue }
                    NSRect(x: markerX, y: frame.minY, width: Self.markerWidth, height: frame.height).fill()
                }
            case .deleted:
                // 지워진 줄 자리: 그 줄의 위 경계(맨 끝이면 마지막 줄의 아래 경계)에 작은 삼각형
                let y: CGFloat
                if let frame = frames[change.start] {
                    y = frame.minY
                } else if let frame = frames[change.start - 1] {
                    y = frame.maxY
                } else {
                    continue
                }
                EditorStyle.deleted.setFill()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: markerX - 1, y: y - 4))
                path.line(to: NSPoint(x: markerX + 6, y: y))
                path.line(to: NSPoint(x: markerX - 1, y: y + 4))
                path.close()
                path.fill()
            }
        }
    }
}

// MARK: - 글자 색(보이는 줄만, 바뀐 줄부터 다시)

final class EditorHighlighter {
    private let scanner: SyntaxScanner
    private weak var storage: NSTextStorage?
    private weak var layoutManager: NSLayoutManager?
    /// 줄 시작 위치별 훑기 상태(앞에서부터 다시 훑지 않게). 위치 순.
    private var checkpoints: [(location: Int, state: ScanState)] = [(0, .normal)]
    /// 이미 칠한 범위(편집하면 비운다 — 보이는 곳만 다시 칠한다)
    private var colored = IndexSet()
    static let checkpointSpacing = 8_192

    init(scanner: SyntaxScanner, storage: NSTextStorage, layoutManager: NSLayoutManager) {
        self.scanner = scanner
        self.storage = storage
        self.layoutManager = layoutManager
    }

    func edited(_ range: NSRange, delta: Int) {
        // 바뀐 곳 뒤의 줄 시작 상태는 달라졌을 수 있다(그 앞은 그대로)
        checkpoints.removeAll { $0.location > range.location }
        if checkpoints.isEmpty { checkpoints = [(0, .normal)] }
        colored = IndexSet()
    }

    func invalidateAll() {
        checkpoints = [(0, .normal)]
        colored = IndexSet()
    }

    /// 보이는 글 범위를 칠한다(이미 칠한 줄은 건너뛴다)
    func color(_ visible: NSRange) {
        guard let storage, let layoutManager, storage.length > 0 else { return }
        let string = storage.string as NSString
        let clamped = NSIntersectionRange(visible, NSRange(location: 0, length: string.length))
        let paragraphs = string.paragraphRange(for: clamped)
        var missing = IndexSet(integersIn: paragraphs.location..<NSMaxRange(paragraphs))
        missing.subtract(colored)
        for range in missing.rangeView {
            // 칠한 범위는 줄 단위라 빈 곳도 줄 시작에서 시작한다(안전하게 한 번 더 맞춘다)
            let lineRange = string.paragraphRange(for: NSRange(location: range.lowerBound, length: range.count))
            let state = self.state(at: lineRange.location, in: string)
            var tokens: [SyntaxToken] = []
            withCharacters(string, lineRange) { buffer in
                scanner.scan(buffer, base: lineRange.location, state: state) { tokens.append($0) }
            }
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: lineRange)
            for token in tokens {
                let clippedToken = NSIntersectionRange(token.range, lineRange)
                guard clippedToken.length > 0 else { continue }
                layoutManager.addTemporaryAttribute(.foregroundColor, value: EditorStyle.color(token.kind), forCharacterRange: clippedToken)
            }
            colored.insert(integersIn: lineRange.location..<NSMaxRange(lineRange))
        }
    }

    private func withCharacters(_ string: NSString, _ range: NSRange, _ body: (UnsafeBufferPointer<UInt16>) -> Void) {
        var buffer = [unichar](repeating: 0, count: range.length)
        buffer.withUnsafeMutableBufferPointer { pointer in
            if range.length > 0 { string.getCharacters(pointer.baseAddress!, range: range) }
        }
        buffer.withUnsafeBufferPointer(body)
    }

    /// location(줄 시작)의 훑기 상태: 가장 가까운 앞 기록에서부터 훑고, 지나는 길에 일정 간격으로 기록을 남긴다
    private func state(at location: Int, in string: NSString) -> ScanState {
        var low = 0, high = checkpoints.count
        while low < high {
            let mid = (low + high) / 2
            if checkpoints[mid].location <= location { low = mid + 1 } else { high = mid }
        }
        var insertAt = max(low - 1, 0)
        var (position, state) = checkpoints[insertAt]
        insertAt += 1
        while position < location {
            var end = min(position + Self.checkpointSpacing, location)
            if end < location {
                // 덩어리 끝을 줄 시작에 맞춘다
                let paragraph = string.paragraphRange(for: NSRange(location: end, length: 0))
                end = min(NSMaxRange(paragraph), location)
            }
            let chunk = NSRange(location: position, length: end - position)
            let start = position
            withCharacters(string, chunk) { buffer in
                state = scanner.scan(buffer, base: start, state: state) { _ in }
            }
            position = end
            // 기록은 위치 순서를 지킨다(뒤쪽에 이미 있는 기록 앞에 끼운다)
            if insertAt < checkpoints.count, checkpoints[insertAt].location == position {
                checkpoints[insertAt].state = state
            } else {
                checkpoints.insert((position, state), at: insertAt)
            }
            insertAt += 1
        }
        return state
    }
}

// MARK: - 편집·미리보기 단추

/// 상태 줄 왼쪽의 [편집 | 미리보기] 두 칸 단추(Markdown 파일만). 고른 칸은 강조색.
final class EditorModeSwitch: NSView {
    static let height: CGFloat = 16
    static let titles = ["편집", "미리보기"]
    var onSelect: ((Bool) -> Void)?
    var selected = 0 {
        didSet { if selected != oldValue { needsDisplay = true } }
    }
    private var hovered: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "편집 ↔ 미리보기 (⇧⌘V)"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func attributes(_ index: Int) -> [NSAttributedString.Key: Any] {
        let on = index == selected
        return [.font: TermAppearance.uiFont(10, bold: on),
                .foregroundColor: on ? TermAppearance.accent : (hovered == index ? TermAppearance.textPrimary : TermAppearance.textDim)]
    }

    /// 두 칸 폭의 합(굵은 글꼴 기준이라 고른 칸이 바뀌어도 흔들리지 않게 넉넉히)
    var fittingWidth: CGFloat { Self.widths.reduce(0, +) }

    private static let widths: [CGFloat] = titles.map {
        ceil(($0 as NSString).size(withAttributes: [.font: TermAppearance.uiFont(10, bold: true)]).width) + 16
    }

    private func segmentRects() -> [NSRect] {
        let total = fittingWidth
        let widths = Self.widths
        let scale = bounds.width / max(total, 1)
        var x: CGFloat = 0
        return widths.map { width in
            defer { x += width * scale }
            return NSRect(x: x, y: 0, width: width * scale, height: bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        TermAppearance.chrome.setFill()
        outline.fill()
        let rects = segmentRects()
        for (index, rect) in rects.enumerated() {
            if index == selected {
                let fill = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 3, yRadius: 3)
                TermAppearance.accent.withAlphaComponent(0.16).setFill()
                fill.fill()
            }
            let title = Self.titles[index] as NSString
            let attrs = attributes(index)
            let size = title.size(withAttributes: attrs)
            title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
        if rects.count == 2 {
            TermAppearance.border.setFill()
            NSRect(x: rects[1].minX, y: 3, width: 1, height: bounds.height - 6).fill()
        }
        (selected == 1 ? TermAppearance.accent.withAlphaComponent(0.55) : TermAppearance.border).setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return segmentRects().firstIndex { $0.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = index(at: event) else { return }
        onSelect?(index == 1)
    }

    override func mouseMoved(with event: NSEvent) {
        let index = index(at: event)
        if index != hovered { hovered = index; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - 배너·안내

/// "디스크에서 바뀌었습니다 · 다시 읽기 / 내 것으로 덮어쓰기"
final class EditorBannerView: NSView {
    static let height: CGFloat = 30
    var onReload: (() -> Void)?
    var onOverwrite: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let reload = NSButton(title: "다시 읽기", target: nil, action: nil)
    private let overwrite = NSButton(title: "내 것으로 덮어쓰기", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbHex: 0x4a3f24).cgColor
        clipsToBounds = true
        label.font = TermAppearance.uiFont(11, bold: true)
        label.textColor = NSColor(srgbHex: 0xf0d58a)
        label.lineBreakMode = .byTruncatingTail
        for button in [reload, overwrite] {
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = TermAppearance.uiFont(11)
            button.target = self
            button.appearance = NSAppearance(named: .darkAqua)
        }
        reload.action = #selector(reloadPressed)
        overwrite.action = #selector(overwritePressed)
        for view in [label, reload, overwrite] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            reload.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
            reload.centerYAnchor.constraint(equalTo: centerYAnchor),
            overwrite.leadingAnchor.constraint(equalTo: reload.trailingAnchor, constant: 6),
            overwrite.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            overwrite.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ conflict: EditorDocument.DiskConflict?) {
        isHidden = conflict == nil
        switch conflict {
        case .changed?:
            label.stringValue = "⚠ 디스크에서 바뀌었습니다 (내 편집은 아직 저장 안 됨)"
            reload.isHidden = false
            overwrite.title = "내 것으로 덮어쓰기"
        case .deleted?:
            label.stringValue = "⚠ 디스크에서 지워졌습니다"
            reload.isHidden = true
            overwrite.title = "내 것으로 저장"
        case nil:
            break
        }
    }

    @objc private func reloadPressed() { onReload?() }
    @objc private func overwritePressed() { onOverwrite?() }

    /// 시험용
    func press(_ name: String) {
        if name == "reload", !reload.isHidden { onReload?() }
        if name == "overwrite" { onOverwrite?() }
    }
}

/// 열지 않는 파일(바이너리·너무 큼·UTF-8 아님) 안내
final class EditorNoticeView: NSView {
    private let path: String

    init(title: String, detail: String) {
        path = detail
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.badge.ellipsis", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = TermAppearance.textDim
        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = TermAppearance.uiFont(13, bold: true)
        titleLabel.textColor = TermAppearance.textPrimary
        titleLabel.alignment = .center
        let detailLabel = NSTextField(wrappingLabelWithString: (detail as NSString).abbreviatingWithTildeInPath)
        detailLabel.font = TermAppearance.uiFont(11)
        detailLabel.textColor = TermAppearance.textDim
        detailLabel.alignment = .center
        let reveal = NSButton(title: "Finder 에서 보기", target: self, action: #selector(revealInFinder))
        reveal.bezelStyle = .rounded
        reveal.appearance = NSAppearance(named: .darkAqua)
        let stack = NSStackView(views: [icon, titleLabel, detailLabel, reveal])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        EditorStyle.background.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
