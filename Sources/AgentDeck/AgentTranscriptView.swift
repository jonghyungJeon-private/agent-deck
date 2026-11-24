import AppKit
import SessionCore

/// 칸을 그릴 색 한 벌: 사용자의 Claude Code 테마(.claude.json 의 "theme") 팔레트 + 터미널 색.
/// 에이전트 글·결과 본문은 Claude 처럼 색을 주지 않고 터미널 기본 글자색을 쓴다. 테마 색은 사용자 프롬프트 줄·⏺·⎿·에러·코드에만.
struct ClaudeColors {
    var foreground: NSColor
    var text: NSColor
    var inactive: NSColor
    var success: NSColor
    var error: NSColor
    var permission: NSColor
    var userMessageBackground: NSColor

    init(themeName: String, dark: Bool) {
        let terminal = TermAppearance.theme(dark: dark)
        let palette = ClaudeTerminalTheme.palette(named: themeName, appDark: dark)
        func resolve(_ color: ClaudeThemeColor) -> NSColor {
            switch color {
            case .rgb(let r, let g, let b):
                return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            case .ansi(let index):
                return NSColor(srgbHex: terminal.palette[min(max(index, 0), terminal.palette.count - 1)])
            }
        }
        foreground = NSColor(srgbHex: terminal.foreground)
        text = resolve(palette.text)
        inactive = resolve(palette.inactive)
        success = resolve(palette.success)
        error = resolve(palette.error)
        permission = resolve(palette.permission)
        userMessageBackground = resolve(palette.userMessageBackground)
    }

    /// 같은 색 한 벌인지(모양이 바뀌어도 색이 그대로면 다시 그리지 않으려고)
    func same(as other: ClaudeColors) -> Bool {
        foreground == other.foreground && text == other.text && inactive == other.inactive && success == other.success
            && error == other.error && permission == other.permission && userMessageBackground == other.userMessageBackground
    }
}

private extension NSAttributedString.Key {
    /// 줄 전체(칸 너비)에 깔 배경색(NSColor). 글자 뒤에만 깔리는 .backgroundColor 와 달리 줄 끝까지 칠한다.
    static let rowBackground = NSAttributedString.Key("AgentDeck.rowBackground")
}

/// .rowBackground 가 붙은 글의 줄마다 칸 너비 전체를 칠한다(사용자 프롬프트 줄).
private final class RowBackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.rowBackground, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            color.setFill()
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                NSRect(x: origin.x + rect.minX, y: origin.y + rect.minY, width: rect.width, height: rect.height).fill()
            }
        }
    }
}

/// 하위 에이전트 칸의 내용: 기록 읽기 전용 보기(머리 글은 칸 테두리 제목이 보이므로 두지 않는다).
/// `load` 하면 기록 파일(agent-*.jsonl)의 끝을 1초마다 따라 읽어(AgentTranscriptTail) 새로 붙은 항목만 이어 그린다.
/// `unload`(탭이 가려져 칸이 화면에서 빠질 때) 는 타이머·읽기 상태·글을 모두 놓는다 — 보이는 탭의 칸만 읽는다.
final class AgentTranscriptView: NSView {
    private(set) var transcript: String?
    /// 기록을 읽으라고 한 상태인지(읽기 상태·타이머가 있을 수 있다)
    var isLoaded: Bool { transcript != nil }

    private let scroll = NSScrollView()
    private let textView = AgentTranscriptView.makeTextView()
    private var reader: AgentTranscriptTail?
    private var timer: Timer?
    /// 설정 파일(.claude.json)의 테마 이름을 읽어 둔 것(수정 시각이 바뀌어야 다시 읽는다). loadQueue 에서만 부른다.
    private static let themeSetting = ClaudeThemeSetting()
    private var themeName = ClaudeTerminalTheme.defaultName
    private var colors = ClaudeColors(themeName: ClaudeTerminalTheme.defaultName, dark: true)
    /// 지금 글이 안내 문구(항목이 없을 때)인지
    private var showingPlaceholder = false
    /// 안내 문구를 그렸을 때의 항목 수·파일 없음(그대로면 다시 그리지 않는다)
    private var placeholderState = (count: -1, missing: false)
    /// 처음 읽기(끝 512KiB 를 JSON 으로 풀기)는 메인 스레드 밖에서 한다 — 칸이 붙는 순간 화면이 멈칫하지 않게.
    /// 그 사이 unload·다른 load 가 오면 늦게 끝난 결과는 버린다(세대 번호).
    private var loadGeneration = 0
    private static let loadQueue = DispatchQueue(label: "agentdeck.agent-transcript-load", qos: .userInitiated)

    /// 줄 전체 배경을 칠 수 있게 TextKit 1 구성으로 만든다
    private static func makeTextView() -> NSTextView {
        let storage = NSTextStorage()
        let layout = RowBackgroundLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        return NSTextView(frame: .zero, textContainer: container)
    }

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
        "entries=\(reader?.entries.count ?? -1) missing=\(reader?.isMissing ?? false) chars=\(textView.textStorage?.length ?? 0) timer=\(timer != nil)"
    }

    private func refreshLayerColors() {
        layer?.backgroundColor = TermAppearance.background.cg(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayerColors()
        // 색은 앱 모양(터미널 색·auto·ansi 테마)에 따라 정해지므로 모양이 바뀌면 다시 그린다
        let before = colors
        refreshColors()
        if reader != nil, !colors.same(as: before) { rebuild(stickToBottom: isAtBottom) }
    }

    private var isDarkAppearance: Bool {
        (window != nil ? effectiveAppearance : NSApp?.effectiveAppearance ?? effectiveAppearance).isDark
    }

    private func refreshColors() {
        colors = ClaudeColors(themeName: themeName, dark: isDarkAppearance)
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
            let theme = Self.themeSetting.name() // .claude.json 은 클 수 있어 여기서 읽는다(수정 시각이 같으면 건너뜀)
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation, self.transcript == path else { return }
                self.themeName = theme
                self.refreshColors()
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
            // 안내 문구가 떠 있고 읽은 것이 지난번 그릴 때와 달라졌을 때만(짝 없는 결과만 있어 계속 빈 글이면 매초 다시 그리지 않게)
            if showingPlaceholder, reader.entries.count != placeholderState.count || reader.isMissing != placeholderState.missing {
                rebuild(stickToBottom: true)
            }
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

    private struct FontKey: Hashable { var size: CGFloat; var bold: Bool; var italic: Bool }
    private var fonts: [FontKey: NSFont] = [:]
    /// 위치(UTF-16)를 기억해 둔 tool_use 의 ⏺ 자리: tool_use id → 글 안 위치. 결과가 오면 그 글자 색만 바꾼다.
    private var toolDots: [String: Int] = [:]
    /// 마지막으로 그린 항목 종류(항목 사이 빈 줄을 넣을지 정한다)
    private var lastKind: AgentTranscriptEntry.Kind?

    private func font(bold: Bool, italic: Bool) -> NSFont {
        let base = bodyFont
        guard bold || italic else { return base }
        let key = FontKey(size: base.pointSize, bold: bold, italic: italic)
        if let cached = fonts[key] { return cached }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let made = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: base.pointSize) ?? base
        fonts[key] = made
        return made
    }

    private func attributes(_ color: NSColor, bold: Bool = false, italic: Bool = false) -> [NSAttributedString.Key: Any] {
        let styled = font(bold: bold, italic: italic)
        var attrs: [NSAttributedString.Key: Any] = [.font: styled, .foregroundColor: color]
        // 굵은·기울인 글꼴을 못 찾았을 때(글꼴 대체) 흉내만 낸다
        let found = styled.fontDescriptor.symbolicTraits
        if bold, !found.contains(.bold) { attrs[.strokeWidth] = -3 }
        if italic, !found.contains(.italic) { attrs[.obliqueness] = 0.2 }
        return attrs
    }

    /// 첫 줄은 0 에서, 둘째 줄부터는 indent 에서 시작하고 줄이 길어 접히면 indent 로 이어진다
    private func hang(_ piece: NSMutableAttributedString, indent: CGFloat) {
        let newline = (piece.string as NSString).range(of: "\n").location
        guard newline != NSNotFound else { return }
        let first = NSMutableParagraphStyle()
        first.firstLineHeadIndent = 0
        first.headIndent = indent
        piece.addAttribute(.paragraphStyle, value: first, range: NSRange(location: 0, length: newline + 1))
        let rest = NSMutableParagraphStyle()
        rest.firstLineHeadIndent = indent
        rest.headIndent = indent
        let restStart = newline + 1
        if restStart < piece.length {
            piece.addAttribute(.paragraphStyle, value: rest, range: NSRange(location: restStart, length: piece.length - restStart))
        }
    }

    /// ⏺ — U+23FA 는 그대로 쓰면 NSTextView 가 이모지(파란 네모)로 그린다. VS15(U+FE0E)로 글자 모양을 고른다. UTF-16 두 칸.
    private static let dot = "\u{23FA}\u{FE0E}"
    private static let dotLength = (dot as NSString).length

    private func dotColor(_ failed: Bool?) -> NSColor {
        guard let failed else { return colors.inactive }
        return failed ? colors.error : colors.success
    }

    /// 항목 하나(앞에 붙는 빈 줄 제외). 도구 호출이면 ⏺ 의 글 안 위치(piece 기준)도 돌려준다.
    private func attributed(_ entry: AgentTranscriptEntry, statuses: [String: Bool], charWidth: CGFloat, widths: (dot: CGFloat, result: CGFloat)) -> (piece: NSMutableAttributedString, dot: Int?) {
        let out = NSMutableAttributedString()
        var dot: Int?
        var indent = charWidth * 2
        switch entry.kind {
        case .prompt:
            out.append(NSAttributedString(string: "> " + entry.text, attributes: attributes(colors.text)))
        case .text:
            out.append(NSAttributedString(string: Self.dot + " ", attributes: attributes(colors.foreground)))
            for run in AgentTranscriptMarkdown.parse(entry.text) {
                out.append(NSAttributedString(string: run.text, attributes: attributes(
                    run.code ? colors.permission : colors.foreground, bold: run.bold || run.heading, italic: run.italic)))
            }
        case .tool:
            dot = 0
            let failed = entry.toolUseId.flatMap { statuses[$0] }
            out.append(NSAttributedString(string: Self.dot, attributes: attributes(dotColor(failed))))
            out.append(NSAttributedString(string: " ", attributes: attributes(colors.foreground)))
            out.append(NSAttributedString(string: entry.toolName ?? "tool", attributes: attributes(colors.foreground, bold: true)))
            if !entry.text.isEmpty {
                out.append(NSAttributedString(string: "(" + entry.text + ")", attributes: attributes(colors.foreground)))
            }
        case .result:
            indent = charWidth * 5
            out.append(NSAttributedString(string: "  ⎿  ", attributes: attributes(colors.inactive)))
            let body = entry.text.isEmpty ? "(No content)" : entry.text
            let bodyStart = out.length
            out.append(NSAttributedString(string: body, attributes: attributes(entry.isError ? colors.error : colors.foreground)))
            for range in entry.boldRanges where NSMaxRange(range) <= (body as NSString).length {
                out.setAttributes(attributes(colors.foreground, bold: true),
                                  range: NSRange(location: bodyStart + range.location, length: range.length))
            }
            // "… +N lines" 줄은 흐리게(에러가 아닐 때)
            if !entry.isError, let fold = body.range(of: "\n… +", options: .backwards), body[fold.upperBound...].hasSuffix(" lines"),
               !body[fold.upperBound...].contains("\n") {
                let location = bodyStart + (body as NSString).range(of: "\n… +", options: .backwards).location + 1
                out.addAttribute(.foregroundColor, value: colors.inactive,
                                 range: NSRange(location: location, length: out.length - location))
            }
        case .thinking:
            out.append(NSAttributedString(string: "✻ Thinking…", attributes: attributes(colors.inactive, italic: true)))
        }
        out.append(NSAttributedString(string: "\n", attributes: attributes(colors.foreground)))
        switch entry.kind {
        case .text, .tool: indent = widths.dot
        case .result: indent = widths.result
        default: break
        }
        hang(out, indent: indent)
        if entry.kind == .prompt {
            out.addAttribute(.rowBackground, value: colors.userMessageBackground, range: NSRange(location: 0, length: out.length))
        }
        return (out, dot)
    }

    /// 항목들을 이어 붙일 글로 만든다. 항목 사이에 빈 줄 하나(도구와 그 결과 사이는 붙여서). baseLength 는 이미 있는 글의 길이.
    private func render(_ entries: [AgentTranscriptEntry], statuses: [String: Bool], baseLength: Int) -> NSMutableAttributedString {
        let content = NSMutableAttributedString()
        let charWidth = ("0" as NSString).size(withAttributes: [.font: bodyFont]).width
        // 머리 글자(⏺ ·⎿) 폭은 글꼴에만 달렸으니 한 번만 잰다(⏺·⎿ 가 대체 글꼴로 그려져 고정폭 칸과 다를 수 있다)
        let widths = (dot: max(charWidth * 2, NSAttributedString(string: Self.dot + " ", attributes: attributes(colors.foreground)).size().width),
                      result: max(charWidth * 5, NSAttributedString(string: "  ⎿  ", attributes: attributes(colors.inactive)).size().width))
        for entry in entries where entry.isVisible {
            // 항목 상한으로 도구 호출이 밀려나 결과만 남은 것(짝 없는 result)은 그리지 않는다 — ⎿ 만 혼자 남지 않게.
            // 짝은 이미 그린 tool 의 id(toolDots)로 본다. id 가 없는 결과는 맨 앞에 올 때만 짝 없음으로 본다.
            if entry.kind == .result {
                if let id = entry.toolUseId { if toolDots[id] == nil { continue } } else if lastKind == nil { continue }
            }
            if let last = lastKind, !(last == .tool && entry.kind == .result) {
                content.append(NSAttributedString(string: "\n", attributes: attributes(colors.foreground)))
            }
            let (piece, dot) = attributed(entry, statuses: statuses, charWidth: charWidth, widths: widths)
            if let dot, let id = entry.toolUseId { toolDots[id] = baseLength + content.length + dot }
            content.append(piece)
            lastKind = entry.kind
        }
        return content
    }

    /// 도구 결과가 오면 그 도구의 ⏺ 색만 바꾼다(성공=success, 실패=error)
    private func recolorDots(for entries: [AgentTranscriptEntry], in storage: NSTextStorage) {
        for entry in entries where entry.kind == .result {
            guard let id = entry.toolUseId, let location = toolDots[id], location < storage.length else { continue }
            storage.addAttribute(.foregroundColor, value: dotColor(entry.isError), range: NSRange(location: location, length: Self.dotLength))
        }
    }

    private func placeholder() -> NSAttributedString {
        let message = reader?.isMissing == true
            ? "기록 파일을 찾을 수 없습니다. 이미 지워졌을 수 있습니다."
            : "아직 남긴 내용이 없습니다."
        return NSAttributedString(string: message, attributes: attributes(colors.inactive))
    }

    private func rebuild(stickToBottom: Bool) {
        guard let storage = textView.textStorage, let reader else { return }
        toolDots = [:]
        lastKind = nil
        fonts = [:]
        // 결과가 나중 줄에 오므로 항목 전체에서 먼저 모아 ⏺ 색을 한 번에 정한다
        var statuses: [String: Bool] = [:]
        for entry in reader.entries where entry.kind == .result {
            if let id = entry.toolUseId { statuses[id] = entry.isError }
        }
        let content = render(reader.entries, statuses: statuses, baseLength: 0)
        showingPlaceholder = content.length == 0
        placeholderState = (reader.entries.count, reader.isMissing)
        if showingPlaceholder { content.append(placeholder()) }
        storage.beginEditing()
        storage.setAttributedString(content)
        storage.endEditing()
        if stickToBottom { scrollToBottom() }
    }

    private func append(_ entries: [AgentTranscriptEntry], stickToBottom: Bool) {
        guard let storage = textView.textStorage else { return }
        var statuses: [String: Bool] = [:]
        for entry in entries where entry.kind == .result {
            if let id = entry.toolUseId { statuses[id] = entry.isError }
        }
        let content = render(entries, statuses: statuses, baseLength: storage.length)
        storage.beginEditing()
        storage.append(content)
        recolorDots(for: entries, in: storage)
        storage.endEditing()
        if stickToBottom { scrollToBottom() }
    }

    private func scrollToBottom() {
        textView.scrollRangeToVisible(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
    }

    /// 앱 글꼴 크기 변경: 글꼴을 다시 맞춘다(글은 새 글꼴로 다시 그린다)
    @objc private func fontSizeChanged() {
        textView.textContainerInset = NSSize(width: TermAppearance.scaled(Space.md), height: TermAppearance.scaled(Space.sm))
        if reader != nil { rebuild(stickToBottom: isAtBottom) }
    }
}
