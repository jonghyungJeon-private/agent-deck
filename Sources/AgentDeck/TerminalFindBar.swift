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
        let height = bar.superview == nil ? 0 : min(TermAppearance.scaled(38), bounds.height)
        terminal.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        bar.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    }
}

final class TerminalFindBar: NSView, NSTextFieldDelegate {
    weak var surface: TerminalPaneSurface?
    unowned let terminal: TerminalView
    let field = NSTextField()
    private let count = NSTextField(labelWithString: "0/0")
    private let caseButton = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
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
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = TermAppearance.chrome.cgColor
        layer?.borderColor = TermAppearance.border.cgColor
        layer?.borderWidth = 1
        field.placeholderString = "터미널에서 찾기"
        field.delegate = self
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = TermAppearance.background
        field.textColor = TermAppearance.textPrimary
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        count.textColor = TermAppearance.textDim
        count.alignment = .right
        caseButton.target = self
        caseButton.action = #selector(toggleCase)
        caseButton.toolTip = "대소문자 구분"
        controls = [field, count, caseButton]
        for (title, action, help) in [("↑", #selector(previous), "이전 찾기 (⇧↩ · ⇧⌘G)"),
                                       ("↓", #selector(next), "다음 찾기 (↩ · ⌘G)"),
                                       ("×", #selector(close), "찾기 닫기 (esc)")] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .inline
            button.toolTip = help
            controls.append(button)
        }
        controls.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func show(query: String? = nil) {
        if superview == nil, let surface {
            surface.addSubview(self)
            surface.needsLayout = true
            surface.layoutSubtreeIfNeeded()
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
        for view in controls {
            (view as? NSControl)?.font = TermAppearance.scaledUIFont(12)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let u = TermAppearance.uiScale
        let h = bounds.height
        var x = bounds.width - u(8)
        for control in controls.dropFirst(3).reversed() {
            x -= u(26); control.frame = NSRect(x: x, y: (h - u(24)) / 2, width: u(24), height: u(24))
        }
        x -= u(50); caseButton.frame = NSRect(x: x, y: (h - u(24)) / 2, width: u(48), height: u(24))
        let counterWidth = min(u(76), max(u(42), bounds.width * 0.18))
        x -= counterWidth
        count.frame = NSRect(x: x, y: (h - u(18)) / 2, width: counterWidth - u(4), height: u(18))
        field.frame = NSRect(x: u(10), y: (h - u(22)) / 2, width: max(24, x - u(18)), height: u(22))
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
        count.textColor = !cachedQuery.isEmpty && total == 0 ? TermAppearance.red : TermAppearance.textDim
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
        removeFromSuperview()
        surface?.needsLayout = true
        terminal.window?.makeFirstResponder(terminal)
    }
    @objc private func next() { search() }
    @objc private func previous() { search(backwards: true) }
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
