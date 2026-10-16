import AppKit
import EditorCore

/// 이동 목록 한 줄(선언 고르기·사용 위치·심볼 찾기 공통)
struct NavigatorRow {
    var badge: String?
    var badgeColor: NSColor = TermAppearance.textDim
    /// 위 줄(코드 글꼴, 이름 강조 포함)
    var title: NSAttributedString
    /// 아래 줄(흐린 경로:줄)
    var detail: String
    /// 오른쪽 끝 작은 표시("선언" 등)
    var tag: String?
}

/// IntelliJ 식 작은 목록 창(창 안에 겹쳐 보이는 뷰 — 창 그림 시험에도 담긴다).
/// 키보드 먼저: ↑↓ 고르기, ↩ 열기, esc 닫기. 찾기 칸이 있으면(⌘O) 글을 치는 대로 onQuery.
final class NavigatorPopupView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let maxVisibleRows = 12
    static let headerHeight: CGFloat = 30
    static let fieldHeight: CGFloat = 34
    static let footerHeight: CGFloat = 22

    var onQuery: ((String) -> Void)?
    var onChoose: ((Int) -> Void)?
    var onClose: (() -> Void)?
    /// 고른 줄이 바뀜(심볼 찾기의 미리 보기 등에 쓸 수 있게)
    private(set) var rows: [NavigatorRow] = []
    let searchable: Bool

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    let field = NavigatorSearchField()
    let table = NavigatorTableView()
    private let scroll = NSScrollView()

    init(title: String, searchable: Bool, placeholder: String? = nil) {
        self.searchable = searchable
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        wantsLayer = true
        layer?.backgroundColor = TermAppearance.chrome.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = TermAppearance.border.cgColor
        layer?.masksToBounds = false
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            return shadow
        }()
        appearance = NSAppearance(named: .darkAqua)

        titleLabel.stringValue = title
        titleLabel.font = TermAppearance.uiFont(12, bold: true)
        titleLabel.textColor = TermAppearance.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = TermAppearance.uiFont(11)
        statusLabel.textColor = TermAppearance.textDim
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingHead
        footerLabel.font = TermAppearance.uiFont(10)
        footerLabel.textColor = TermAppearance.textDim
        footerLabel.stringValue = "↑↓ 고르기 · ↩ 열기 · esc 닫기"
        emptyLabel.font = TermAppearance.uiFont(12)
        emptyLabel.textColor = TermAppearance.textDim
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        field.isHidden = !searchable
        field.font = TermAppearance.uiFont(14)
        field.textColor = TermAppearance.textPrimary
        field.backgroundColor = TermAppearance.background
        field.drawsBackground = true
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(string: placeholder ?? "", attributes: [
            .foregroundColor: TermAppearance.textDim, .font: TermAppearance.uiFont(13),
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = TermAppearance.chrome
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = Self.rowHeight
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onEnter = { [weak self] in self?.chooseSelected() }
        table.onEscape = { [weak self] in self?.onClose?() }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        for view in [titleLabel, statusLabel, field, scroll, footerLabel, emptyLabel] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// 위 줄 코드 글꼴(앱 글꼴 크기를 따른다) + 아래 줄 경로
    static var rowHeight: CGFloat {
        let code = EditorStyle.font
        let detail = TermAppearance.uiFont(11)
        return ceil(code.ascender - code.descender + code.leading) + ceil(detail.ascender - detail.descender) + 14
    }

    /// 지금 줄 수에 맞는 높이(최대 12줄)
    var preferredHeight: CGFloat {
        let visible = CGFloat(max(1, min(rows.count, Self.maxVisibleRows)))
        return Self.headerHeight + (searchable ? Self.fieldHeight : 0) + visible * Self.rowHeight + Self.footerHeight + 4
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        titleLabel.frame = NSRect(x: 12, y: 7, width: w * 0.6 - 12, height: 17)
        statusLabel.frame = NSRect(x: w * 0.6, y: 8, width: w * 0.4 - 12, height: 16)
        var y = Self.headerHeight
        if searchable {
            field.frame = NSRect(x: 10, y: y, width: w - 20, height: Self.fieldHeight - 8)
            y += Self.fieldHeight
        }
        let listHeight = bounds.height - y - Self.footerHeight - 2
        scroll.frame = NSRect(x: 1, y: y, width: w - 2, height: max(listHeight, 0))
        emptyLabel.frame = NSRect(x: 12, y: y + max(listHeight, 0) / 2 - 9, width: w - 24, height: 18)
        footerLabel.frame = NSRect(x: 12, y: bounds.height - Self.footerHeight + 3, width: w - 24, height: 15)
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    override func draw(_ dirtyRect: NSRect) {
        // 머리 줄·꼬리 줄 경계
        TermAppearance.border.setFill()
        NSRect(x: 0, y: Self.headerHeight - 1, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - Self.footerHeight - 1, width: bounds.width, height: 1).fill()
    }

    func setTitle(_ title: String) { titleLabel.stringValue = title }

    func setStatus(_ text: String?) { statusLabel.stringValue = text ?? "" }

    /// 목록을 바꾼다(고른 줄은 맨 위로)
    func setRows(_ rows: [NavigatorRow], empty: String? = nil) {
        self.rows = rows
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        emptyLabel.stringValue = empty ?? ""
        emptyLabel.isHidden = !rows.isEmpty || (empty ?? "").isEmpty
    }

    var selectedRow: Int { table.selectedRow }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let current = max(table.selectedRow, 0)
        let next = min(max(current + delta, 0), rows.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func chooseSelected() {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return }
        onChoose?(row)
    }

    /// 첫 응답자로 삼을 뷰
    var focusTarget: NSView { searchable ? field : table }

    @objc private func clicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        onChoose?(row)
    }

    // MARK: - 표

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: NavigatorCellView.identifier, owner: nil) as? NavigatorCellView)
            ?? NavigatorCellView()
        cell.identifier = NavigatorCellView.identifier
        cell.row = rows[row]
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NavigatorRowView() }

    // MARK: - 찾기 칸

    func controlTextDidChange(_ obj: Notification) {
        onQuery?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): moveSelection(-Self.maxVisibleRows)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): moveSelection(Self.maxVisibleRows)
        case #selector(NSResponder.insertNewline(_:)): chooseSelected()
        case #selector(NSResponder.cancelOperation(_:)): onClose?()
        default: return false
        }
        return true
    }

    /// 이름은 영문이므로 찾기 칸에선 한글 입력기를 끈다(한글 자판인 채로 ⌘O 를 눌러도 바로 칠 수 있게)
    func preferRomanInput(_ on: Bool) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.inputContext?.allowedInputSourceLocales = on ? [NSAllRomanInputSourcesLocaleIdentifier] : nil
    }

    /// 시험용
    var debugSummary: String {
        var lines = ["popup title=\(titleLabel.stringValue) status=\(statusLabel.stringValue) rows=\(rows.count) "
            + "selected=\(table.selectedRow) query=\(searchable ? field.stringValue : "-") frame=\(frame)"]
        for (index, row) in rows.prefix(30).enumerated() {
            lines.append("  \(index == table.selectedRow ? ">" : " ")\(row.badge ?? " ") \(row.title.string) | \(row.detail)"
                + (row.tag.map { " [\($0)]" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}

/// ↩·esc 를 받는 표(↑↓ 는 표가 그대로 처리)
final class NavigatorTableView: NSTableView {
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onEnter?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class NavigatorSearchField: NSTextField {}

/// 고른 줄 바탕(강조색을 옅게)
final class NavigatorRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        TermAppearance.accent.withAlphaComponent(0.22).setFill()
        bounds.fill()
        TermAppearance.accent.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }

    override var isEmphasized: Bool { get { true } set {} }
}

/// [종류] 위 줄(코드) / 아래 줄(경로)
final class NavigatorCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("navigator-cell")
    var row: NavigatorRow? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let left: CGFloat = 12
        var x = left
        let codeFont = EditorStyle.font
        let codeHeight = ceil(codeFont.ascender - codeFont.descender + codeFont.leading)
        let top: CGFloat = 6
        if let badge = row.badge {
            let size: CGFloat = 18
            let rect = NSRect(x: x, y: top + (codeHeight - size) / 2, width: size, height: size)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            row.badgeColor.withAlphaComponent(0.18).setFill()
            path.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: TermAppearance.uiFont(11, bold: true), .foregroundColor: row.badgeColor]
            let text = badge as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attrs)
            x += size + 10
        }
        var tagWidth: CGFloat = 0
        if let tag = row.tag {
            let attrs: [NSAttributedString.Key: Any] = [.font: TermAppearance.uiFont(10, bold: true), .foregroundColor: TermAppearance.yellow]
            let size = (tag as NSString).size(withAttributes: attrs)
            tagWidth = size.width + 16
            (tag as NSString).draw(at: NSPoint(x: bounds.width - size.width - 12, y: top + (codeHeight - size.height) / 2), withAttributes: attrs)
        }
        let titleRect = NSRect(x: x, y: top, width: max(bounds.width - x - 12 - tagWidth, 10), height: codeHeight)
        row.title.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: TermAppearance.uiFont(11), .foregroundColor: TermAppearance.textDim,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingHead; return p }(),
        ]
        (row.detail as NSString).draw(with: NSRect(x: x, y: top + codeHeight + 2, width: max(bounds.width - x - 12, 10), height: 16),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: detailAttrs)
    }
}

extension SymbolKind {
    /// 목록 종류 표시 색(IntelliJ 아이콘 색 계열)
    var badgeColor: NSColor {
        switch self {
        case .class, .record, .object, .struct: return NSColor(srgbHex: 0x6ca0dc)
        case .interface, .protocol, .trait: return NSColor(srgbHex: 0x8cc47a)
        case .enum, .enumCase: return TermAppearance.yellow
        case .annotation: return NSColor(srgbHex: 0xb3ae60)
        case .function, .method, .constructor: return NSColor(srgbHex: 0xd7875f)
        case .property, .field, .variable, .constant: return TermAppearance.cyan
        case .typeAlias, .module: return TermAppearance.textDim
        }
    }
}
