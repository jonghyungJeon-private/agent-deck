import AppKit
import SwiftTerm
import TermLayout

final class TerminalPaneSurface: NSView {
    let terminal: TerminalView
    let bar: TerminalFindBar
    init(terminal: TerminalView, bar: TerminalFindBar) {
        self.terminal = terminal; self.bar = bar
        super.init(frame: terminal.frame)
        bar.surface = self
        addSubview(terminal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let height = bar.superview == nil ? 0 : min(TerminalFindBar.height, bounds.height)
        terminal.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        bar.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    }
}

final class TerminalFindBar: NSView, NSSearchFieldDelegate {
    /// 막대 높이(글꼴 크기 배율을 따른다)
    static var height: CGFloat { TermAppearance.scaled(32) }
    weak var surface: TerminalPaneSurface?
    unowned let terminal: TerminalView
    /// 찾기 칸: 돋보기·지우기 단추·포커스 링이 있는 시스템 검색 칸
    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "0/0")
    /// "Aa": 눌러 두는(recessed) 토글
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    /// ↑ ↓: 한 번 누르면 한 번 움직이는 작은 분할 버튼
    private let stepper = NSSegmentedControl()
    private let closeButton = NSButton()
    private var refreshWork: DispatchWorkItem?
    private var caseSensitive = false
    private var cursor = BufferSearchCursor()
    private var index = BufferSearchIndex()
    private var queryWork: DispatchWorkItem?
    private var cachedQuery = ""
    private var cachedCase = false
    private var bufferChanged = true
    private var bufferIdentity: ObjectIdentifier?
    private var trimmedRows = 0
    private struct CachedRow {
        let line: BufferLine
        let generation: UInt64
        let columns: Int
        let continues: Bool
        let nextStartsWide: Bool
        let row: BufferLineSearch.Row
    }
    private var rowCache: [ObjectIdentifier: CachedRow] = [:]
    private var extractedRows = 0
    private var recountMilliseconds: Double = 0
    private var controls: [NSView] = []

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        field.placeholderAttributedString = NSAttributedString(string: "터미널에서 찾기", attributes: [
            .font: TermAppearance.uiTextFont(12), .foregroundColor: TermAppearance.textSecondary,
        ])
        field.delegate = self
        field.target = self
        field.action = #selector(fieldAction)
        field.textColor = TermAppearance.textPrimary
        field.focusRingType = .default
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        count.textColor = TermAppearance.textSecondary
        count.alignment = .left
        caseButton.setButtonType(.pushOnPushOff)
        caseButton.bezelStyle = .recessed
        caseButton.controlSize = .small
        caseButton.target = self
        caseButton.action = #selector(toggleCase)
        caseButton.toolTip = "대소문자 구분"
        caseButton.setAccessibilityLabel("대소문자 구분")
        stepper.segmentCount = 2
        stepper.trackingMode = .momentary
        stepper.segmentStyle = .rounded
        stepper.controlSize = .small
        stepper.target = self
        stepper.action = #selector(stepped)
        for (index, (symbol, help)) in [("chevron.up", "이전 찾기 (⇧↩ · ⇧⌘G)"), ("chevron.down", "다음 찾기 (↩ · ⌘G)")].enumerated() {
            stepper.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)), forSegment: index)
            stepper.setImageScaling(.scaleNone, forSegment: index)
            stepper.setToolTip(help, forSegment: index)
        }
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "찾기 닫기")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        closeButton.contentTintColor = TermAppearance.textSecondary
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = "찾기 닫기 (esc)"
        closeButton.setAccessibilityLabel("찾기 닫기")
        controls = [field, count, caseButton, stepper, closeButton]
        controls.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }


    /// 바탕 + 아래쪽 줄 하나(위·옆 줄 없음 — 터미널 위에 얹힌 줄)
    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.chrome.setFill()
        bounds.fill()
        TermAppearance.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { true }

    func show(query: String? = nil) {
        if superview == nil, let surface {
            surface.addSubview(self)
            surface.needsLayout = true
            surface.layoutSubtreeIfNeeded()
            FloatFx.fadeIn(self, duration: Motion.fast, dy: 6) // 위에서 살짝 내려오며
        }
        applyFont()
        terminal.window?.makeFirstResponder(field)
        field.selectText(nil)
        if let query { field.stringValue = query }
        if query != nil || cachedQuery != field.stringValue { search(reset: true) }
        else { recount(reset: false, scroll: false) }
    }

    func applyFont() {
        surface?.needsLayout = true
        field.font = TermAppearance.scaledUIFont(12)
        count.font = TermAppearance.scaledUIFont(11)
        caseButton.font = TermAppearance.uiTextFont(TermAppearance.scaled(11), weight: .semibold)
        field.placeholderAttributedString = NSAttributedString(string: "터미널에서 찾기", attributes: [
            .font: TermAppearance.uiTextFont(TermAppearance.scaled(12)), .foregroundColor: TermAppearance.textSecondary,
        ])
        needsLayout = true
    }

    /// 왼쪽부터: 찾기 칸(너비는 320 × 배율까지 — 시스템 찾기 막대처럼 길게 늘이지 않는다) · 개수 · Aa · ↑↓, 맨 오른쪽 닫기. 남는 폭은 빈 막대. 모두 세로 가운데(높이 32 × 배율).
    override func layout() {
        super.layout()
        let u = TermAppearance.uiScale
        let h = bounds.height
        func centered(_ size: NSSize, x: CGFloat) -> NSRect {
            NSRect(x: x, y: ((h - size.height) / 2).rounded(), width: size.width, height: size.height)
        }
        closeButton.frame = centered(NSSize(width: u(24), height: u(24)), x: bounds.width - u(8) - u(24))
        stepper.sizeToFit()
        caseButton.sizeToFit()
        let stepperSize = NSSize(width: max(stepper.frame.width, u(52)), height: stepper.frame.height)
        let caseSize = NSSize(width: max(caseButton.frame.width, u(34)), height: caseButton.frame.height)
        let counterWidth = min(u(64), max(u(40), bounds.width * 0.14))
        let tail = counterWidth + u(8) + caseSize.width + u(8) + stepperSize.width
        let right = closeButton.frame.minX - u(4)
        let fieldHeight = max(field.intrinsicContentSize.height, u(22))
        let fieldWidth = max(24, min(u(320), right - u(8) - u(8) - tail))
        field.frame = NSRect(x: u(8), y: ((h - fieldHeight) / 2).rounded(), width: fieldWidth, height: fieldHeight)
        var x = field.frame.maxX + u(8)
        count.frame = centered(NSSize(width: counterWidth, height: u(16)), x: x)
        x = count.frame.maxX + u(8)
        caseButton.frame = centered(caseSize, x: x)
        x = caseButton.frame.maxX + u(8)
        stepper.frame = centered(stepperSize, x: x)
    }

    var fieldHasFocus: Bool {
        guard let editor = field.currentEditor() as? NSTextView else { return false }
        return terminal.window?.firstResponder === editor
    }

    func search(reset: Bool = false, backwards: Bool = false) {
        guard superview != nil, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        queryWork?.cancel(); queryWork = nil
        let changed = cachedQuery != field.stringValue || cachedCase != caseSensitive
        recount(reset: reset || changed, scroll: false)
        if !reset && !changed { cursor.move(backwards: backwards) }
        applyHighlight(scroll: true)
        updateCount()
    }

    private func syncBuffer() {
        let buffer = terminal.getTerminal().buffer
        let identity = ObjectIdentifier(buffer)
        let trimmed = buffer.totalLinesTrimmed
        if identity != bufferIdentity || trimmed < trimmedRows {
            rowCache.removeAll(); index = BufferSearchIndex(); cursor = BufferSearchCursor()
            bufferIdentity = identity
        } else {
            cursor.trimRows(trimmed - trimmedRows)
        }
        trimmedRows = trimmed
    }

    private func recount(reset: Bool, scroll: Bool) {
        let started = ProcessInfo.processInfo.systemUptime
        defer { recountMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
        refreshWork?.cancel(); refreshWork = nil
        syncBuffer()
        if reset { cachedQuery = field.stringValue; cachedCase = caseSensitive }
        if !cachedQuery.isEmpty {
            if reset || bufferChanged {
                let matches = index.find(cachedQuery, rows: bufferRows(), caseSensitive: cachedCase)
                let engine = terminal.getTerminal()
                let preferred = reset || cursor.anchor == nil ? engine.buffer.yDisp + min(2, engine.rows - 1) : nil
                cursor.replace(matches, preferredRow: preferred)
            }
        } else { cursor.replace([]) }
        bufferChanged = false
        applyHighlight(scroll: scroll)
        updateCount()
    }

    private func applyHighlight(scroll: Bool) {
        let engine = terminal.getTerminal()
        guard let match = cursor.current, !cachedQuery.isEmpty,
              engine.bufferLine(atRow: match.start.row) != nil,
              engine.bufferLine(atRow: match.end.row) != nil else {
            terminal.selection.selectNone()
            return
        }
        terminal.selection.setSearchSelection(start: Position(col: match.start.column, row: match.start.row),
                                             end: Position(col: match.end.column, row: match.end.row))
        guard scroll, !engine.isCurrentBufferAlternate else { return }
        let top = engine.buffer.yDisp
        let covered = Int(ceil(bounds.height / max(1, terminal.bounds.height / CGFloat(engine.rows))))
        if match.start.row < top + covered || match.end.row >= top + engine.rows {
            terminal.scrollTo(row: max(0, match.start.row - max(covered, engine.rows / 2)))
        } else {
            // 맨 아래에서 찾기를 시작했어도 이후 출력이 화면을 따라 내리지 않게 고정한다.
            terminal.scrollTo(row: top)
        }
    }

    private func updateCount() {
        let total = cursor.matches.count
        count.stringValue = "\(cursor.currentIndex.map { $0 + 1 } ?? 0)/\(total)"
        // 일치 없음도 보조 글자색(빨강은 "내 조작 필요"에만 — 찾아서 없는 것은 그 뜻이 아니다)
        count.textColor = TermAppearance.textSecondary
        count.toolTip = "\(total)개 일치"
    }

    private struct Cell: BufferSearchCell {
        let data: CharData
        let engine: Terminal
        var searchCharacter: Character? {
            let ch = engine.getCharacter(for: data)
            return ch == "\u{0}" ? nil : ch
        }
        var searchWidth: Int { Int(data.width) }
    }

    private func bufferRows() -> [BufferLineSearch.Row] {
        let engine = terminal.getTerminal()
        var rows: [BufferLineSearch.Row] = []
        rows.reserveCapacity(PaneTerminal.scrollback + engine.rows)
        var nextCache: [ObjectIdentifier: CachedRow] = [:]
        nextCache.reserveCapacity(rowCache.count)
        extractedRows = 0
        var row = 0
        while let line = engine.bufferLine(atRow: row) {
            let key = ObjectIdentifier(line)
            let next = engine.bufferLine(atRow: row + 1)
            let continues = next?.isWrapped == true
            let nextStartsWide = next.map { $0.count > 0 && $0[0].width == 2 } ?? false
            let columns = min(line.count, engine.cols)
            let cached: CachedRow
            if let old = rowCache[key], old.line === line, old.generation == line.generation,
               old.columns == columns, old.continues == continues, old.nextStartsWide == nextStartsWide {
                cached = old
            } else {
                let extracted = BufferLineSearch.extract(count: columns, wrapped: line.isWrapped,
                    continues: continues, nextStartsWide: nextStartsWide, cellAt: { Cell(data: line[$0], engine: engine) })
                cached = CachedRow(line: line, generation: line.generation, columns: columns,
                                   continues: continues, nextStartsWide: nextStartsWide, row: extracted)
                extractedRows += 1
            }
            rows.append(cached.row); nextCache[key] = cached
            row += 1
        }
        rowCache = nextCache
        return rows
    }

    /// feed가 지운 강조만 바로 복원한다. 개수 갱신은 모아서 하고 화면은 옮기지 않는다.
    func contentChanged() {
        bufferChanged = true
        guard superview != nil else { return }
        syncBuffer()
        applyHighlight(scroll: false)
        guard !cachedQuery.isEmpty, refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshWork = nil
            self.recount(reset: false, scroll: false)
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc func close() {
        refreshWork?.cancel(); refreshWork = nil
        queryWork?.cancel(); queryWork = nil
        terminal.selection.selectNone()
        if let surface, superview != nil { // 위로 살짝 걷히며 사라진다(막대 자체는 바로 뗀다)
            FloatFx.ghost(FloatFx.snapshot(self), frame: frame, in: surface, above: self, duration: Motion.fast, dy: 6)
        }
        removeFromSuperview()
        surface?.needsLayout = true
        terminal.window?.makeFirstResponder(terminal)
    }
    @objc private func next() { search() }
    @objc private func previous() { search(backwards: true) }
    @objc private func stepped(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { previous() } else { next() }
    }
    /// 지우기 단추(검색 칸 오른쪽 ⊗)가 글을 비웠다: 강조·개수도 비운다(글자를 칠 때는 controlTextDidChange 가 맡는다)
    @objc private func fieldAction() {
        guard field.stringValue.isEmpty, !cachedQuery.isEmpty else { return }
        queryWork?.cancel(); queryWork = nil
        search(reset: true)
    }
    func setCaseSensitive(_ enabled: Bool) {
        caseSensitive = enabled
        caseButton.state = enabled ? .on : .off
        search(reset: true)
    }
    @objc private func toggleCase() { setCaseSensitive(caseButton.state == .on) }
    func controlTextDidChange(_ obj: Notification) {
        queryWork?.cancel(); queryWork = nil
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.queryWork = nil
            self?.search(reset: true)
        }
        queryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            search(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        case #selector(NSResponder.cancelOperation(_:)):
            guard fieldHasFocus, !textView.hasMarkedText(),
                  let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return false }
            close()
        default: return false
        }
        return true
    }
    var debugSummary: String { "terminal-find active=\(terminal.selection.active) selected=[\(terminal.selection.getSelectedText())] row=\(terminal.selection.start.row) col=\(terminal.selection.start.col) viewport=\(terminal.getTerminal().buffer.yDisp) query=\(field.stringValue) count=\(count.stringValue) case=\(caseSensitive) visible=\(superview != nil) fieldFocus=\(fieldHasFocus) size=\(terminal.getTerminal().rows)x\(terminal.getTerminal().cols) extracted=\(extractedRows) groups=\(index.rebuiltGroups) recountMs=\(String(format: "%.2f", recountMilliseconds))" }
}
