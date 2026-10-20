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
        terminal.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - height))
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
    private var matches: [BufferLineSearch.Match] = []
    private var cachedQuery = ""
    private var bufferChanged = true
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
        search(reset: true)
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

    func search(reset: Bool = false, backwards: Bool = false) {
        refreshWork?.cancel(); refreshWork = nil
        guard superview != nil else { return }
        let query = field.stringValue
        if reset || query.isEmpty { terminal.clearSearch() }
        if reset || bufferChanged || cachedQuery != query {
            matches = bufferMatches(query)
            cachedQuery = query
            bufferChanged = false
        }
        let options = SearchOptions(caseSensitive: caseSensitive)
        if !query.isEmpty {
            if backwards { terminal.findPrevious(query, options: options) }
            else { terminal.findNext(query, options: options) }
        }
        let start = terminal.selection.start
        let index = terminal.selection.active ? matches.firstIndex(where: { $0.start.row == start.row && $0.start.column == start.col }).map { $0 + 1 } ?? 0 : 0
        let summary = (index: index, total: matches.count)
        count.stringValue = "\(summary.index)/\(summary.total)"
        count.textColor = !query.isEmpty && summary.total == 0 ? TermAppearance.red : TermAppearance.textDim
        count.toolTip = "\(summary.total)개 일치"
    }

    private func bufferMatches(_ query: String) -> [BufferLineSearch.Match] {
        guard !query.isEmpty else { return [] }
        let engine = terminal.getTerminal()
        var rows: [String] = []
        var wrapped: Set<Int> = []
        var widths: [Character: Int] = [:]
        var row = 0
        while let line = engine.bufferLine(atRow: row) {
            if line.isWrapped { wrapped.insert(row) }
            let next = engine.bufferLine(atRow: row + 1)
            var text = ""
            for col in 0..<line.count {
                let cell = line[col]
                if cell.width == 0 { continue }
                // 넓은 글자가 다음 줄로 넘어가며 남긴 빈 칸은 검색에 넣지 않는다.
                let character = engine.getCharacter(for: cell)
                if col == line.count - 1, character == "\u{0}", next?.isWrapped == true, next?[0].width == 2 { continue }
                let ch: Character = character == "\u{0}" ? " " : character
                widths[ch] = Int(cell.width)
                text.append(ch)
            }
            if next?.isWrapped != true { while text.last == " " { text.removeLast() } }
            rows.append(text)
            row += 1
        }
        return BufferLineSearch.find(query, rows: rows, wrapped: wrapped, caseSensitive: caseSensitive,
                                   width: { widths[$0] ?? BufferLineSearch.cellWidth($0) })
    }

    /// 출력이 몰려도 찾기 막대가 열려 있을 때 한 번만 갱신한다.
    func contentChanged() {
        bufferChanged = true
        guard superview != nil, !field.stringValue.isEmpty, refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.refreshWork = nil
            self?.search(reset: true)
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc func close() {
        refreshWork?.cancel(); refreshWork = nil
        terminal.clearSearch()
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
    func controlTextDidChange(_ obj: Notification) { search(reset: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            search(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }
    var debugSummary: String { "terminal-find active=\(terminal.selection.active) selected=[\(terminal.selection.getSelectedText())] row=\(terminal.selection.start.row) col=\(terminal.selection.start.col) viewport=\(terminal.getTerminal().buffer.yDisp) query=\(field.stringValue) count=\(count.stringValue) case=\(caseSensitive) visible=\(superview != nil)" }
}
