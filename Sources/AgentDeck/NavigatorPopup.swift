import AppKit
import EditorCore

/// 이동 목록 한 줄(선언 고르기·사용 위치·심볼 찾기·세션 전환 공통)
struct NavigatorRow {
    var badge: String?
    var badgeColor: NSColor = TermAppearance.textSecondary
    /// 위 줄(코드 글꼴, 이름 강조 포함)
    var title: NSAttributedString
    /// 아래 줄(흐린 경로:줄)
    var detail: String
    /// 오른쪽 끝 작은 표시("선언" 등)
    var tag: String?
    /// 세션 전환: 이름 앞의 맨 점(작업 상태 — 모양과 색은 WorkStatus 가 정한다). nil = 점 자리 없음
    var status: WorkStatus?
    /// 세션 전환: 이름 앞의 종류 아이콘과 종류 색(`SessionKind`)
    var kind: SessionKind?
    /// 아래 줄 맨 앞의 말(시스템 글꼴 — "작업 중" 같은 상태 글. 뒤따르는 `detail` 은 경로라 고정폭)
    var detailLead: String?
    /// 그 말의 색(사이드바 둘째 줄과 같은 규칙: 사람이 봐야 하는 상태만 상태 색, 나머지 보조 글자색)
    var detailLeadColor: NSColor = TermAppearance.textSecondary
}

/// IntelliJ 식 작은 목록 창(창 안에 겹쳐 보이는 뷰 — 창 그림 시험에도 담긴다).
/// 키보드 먼저: ↑↓ 고르기, ↩ 열기, esc 닫기. 찾기 칸이 있으면(⌘O) 글을 치는 대로 onQuery.
final class NavigatorPopupView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let maxVisibleRows = 12
    // 머리 줄·찾기 칸·꼬리 줄은 글꼴 크기 배율을 따른다(창은 열 때마다 새로 만든다)
    static var headerHeight: CGFloat { TermAppearance.scaled(30) }
    /// 제목이 없는 목록(세션 전환 — 찾기 칸 자신이 무슨 목록인지 말해 준다)은 머리 줄이 없고, 개수 표시는 꼬리 줄 오른쪽으로 간다
    private var hasHeader: Bool { !titleLabel.stringValue.isEmpty }
    private var headerExtent: CGFloat { hasHeader ? Self.headerHeight : 0 }
    static var fieldHeight: CGFloat { TermAppearance.scaled(44) }
    static var footerHeight: CGFloat { TermAppearance.scaled(24) }
    /// 창 모서리 반지름 · 고른 줄 알약의 안쪽 여백과 반지름(바깥 12 − 여백 6 = 안쪽 6: 같은 중심의 둥근 모서리)
    static let cornerRadius: CGFloat = 12
    static let pillInset: CGFloat = 6
    static let pillRadius: CGFloat = 6
    /// 머리·꼬리 글자의 왼쪽 자리(고른 줄 알약 안쪽 글자 시작과 맞춘다)
    static let textInset: CGFloat = 14

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
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        shadow = NSShadow()
        refreshLayerColors()

        titleLabel.stringValue = title
        // 머리·꼬리·빈 목록 안내는 말이므로 시스템 글꼴, 보조 글자는 textSecondary
        titleLabel.font = TermAppearance.uiTextFont(TermAppearance.scaled(12), weight: .semibold)
        titleLabel.textColor = TermAppearance.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = TermAppearance.uiTextFont(TermAppearance.scaled(11))
        statusLabel.textColor = TermAppearance.textSecondary
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingHead
        footerLabel.font = TermAppearance.uiTextFont(TermAppearance.scaled(10))
        footerLabel.textColor = TermAppearance.textSecondary
        footerLabel.stringValue = "↑↓ 고르기 · ↩ 열기 · esc 닫기"
        emptyLabel.font = TermAppearance.uiTextFont(TermAppearance.scaled(12))
        emptyLabel.textColor = TermAppearance.textSecondary
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        // 찾기 칸: 돋보기·지우기 단추·포커스 링이 있는 시스템 검색 칸(입력은 말이 아니라 사용자의 글이므로 시스템 글꼴 13)
        field.isHidden = !searchable
        field.font = TermAppearance.uiTextFont(TermAppearance.scaled(13))
        field.textColor = TermAppearance.textPrimary
        field.focusRingType = .default
        field.delegate = self
        field.target = self
        field.action = #selector(fieldAction)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(string: placeholder ?? "", attributes: [
            .foregroundColor: TermAppearance.textSecondary, .font: TermAppearance.uiTextFont(TermAppearance.scaled(13)),
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
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

    /// 레이어 색은 값으로 굳으므로 모양(라이트·다크)이 바뀔 때마다 다시 받는다. 그림자는 밝은 바탕에서 옅게.
    private func refreshLayerColors() {
        layer?.backgroundColor = TermAppearance.chrome.cg(in: self)
        layer?.borderColor = TermAppearance.border.cg(in: self)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(effectiveAppearance.isDark ? 0.5 : 0.2)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        self.shadow = shadow
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayerColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// 위 줄 코드 글꼴(앱 글꼴 크기를 따른다) + 아래 줄 경로
    static var rowHeight: CGFloat {
        let code = EditorStyle.font
        let detail = TermAppearance.scaledUIFont(11)
        return ceil(code.ascender - code.descender + code.leading) + ceil(detail.ascender - detail.descender) + 14
    }

    /// 지금 줄 수에 맞는 높이(최대 12줄)
    var preferredHeight: CGFloat {
        let visible = CGFloat(max(1, min(rows.count, Self.maxVisibleRows)))
        return headerExtent + (searchable ? Self.fieldHeight : 0) + visible * Self.rowHeight + Self.footerHeight + 4
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let ui = TermAppearance.uiScale
        let inset = Self.textInset
        titleLabel.frame = NSRect(x: inset, y: ui(7), width: w * 0.6 - inset, height: ui(17))
        if hasHeader {
            statusLabel.frame = NSRect(x: w * 0.6, y: ui(8), width: w * 0.4 - inset, height: ui(16))
        } else {
            statusLabel.frame = NSRect(x: w * 0.6, y: bounds.height - Self.footerHeight + ui(4), width: w * 0.4 - inset, height: ui(15))
        }
        var y = headerExtent
        if searchable {
            // 12pt 안쪽 여백 · 28pt 칸이 44pt 줄 가운데에
            let height = max(ui(28), field.intrinsicContentSize.height)
            field.frame = NSRect(x: Self.pillInset + 2, y: y + ((Self.fieldHeight - height) / 2).rounded(),
                                 width: w - 2 * (Self.pillInset + 2), height: height)
            y += Self.fieldHeight
        }
        let listHeight = bounds.height - y - Self.footerHeight - 2
        scroll.frame = NSRect(x: 1, y: y, width: w - 2, height: max(listHeight, 0))
        emptyLabel.frame = NSRect(x: inset, y: y + max(listHeight, 0) / 2 - ui(9), width: w - 2 * inset, height: ui(18))
        footerLabel.frame = NSRect(x: inset, y: bounds.height - Self.footerHeight + ui(4), width: (hasHeader ? w : w * 0.6) - 2 * inset, height: ui(15))
        table.tableColumns.first?.width = scroll.contentSize.width
        table.updatePill(animated: false)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 머리 줄·꼬리 줄 경계
        TermAppearance.border.setFill()
        if hasHeader { NSRect(x: 0, y: Self.headerHeight - 1, width: bounds.width, height: 1).fill() }
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
        table.updatePill(animated: false)
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

    /// 고른 줄 알약이 새 줄로 미끄러진다(Motion.fast)
    func tableViewSelectionDidChange(_ notification: Notification) { table.updatePill(animated: true) }

    // MARK: - 찾기 칸

    func controlTextDidChange(_ obj: Notification) {
        lastQuery = field.stringValue
        onQuery?(field.stringValue)
    }

    private var lastQuery = ""

    /// 검색 칸의 지우기 단추(⊗)가 글을 비웠다: 글을 칠 때는 controlTextDidChange 가 맡는다
    @objc private func fieldAction() {
        guard field.stringValue.isEmpty, !lastQuery.isEmpty else { return }
        lastQuery = ""
        onQuery?("")
    }

    // MARK: - 나타남·사라짐

    private var dismissing = false
    override func hitTest(_ point: NSPoint) -> NSView? { dismissing ? nil : super.hitTest(point) }

    /// 나타남: 투명 → 불투명(Motion.fast). 글꼴 크기를 바꿔 다시 띄울 때는 animated: false.
    func fadeIn(animated: Bool = true) {
        guard animated, !Motion.reduced, window != nil else { return }
        FloatFx.fadeIn(self, duration: Motion.fast)
    }

    /// 사라짐: 투명해진 뒤 뗀다(Motion.fast). 그동안 마우스는 아래로 통과한다.
    func dismiss(animated: Bool = true) {
        guard superview != nil else { return }
        guard animated, !Motion.reduced, window != nil, !dismissing else { removeFromSuperview(); return }
        dismissing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.fast
            context.timingFunction = FloatFx.timing
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
            self?.alphaValue = 1
            self?.dismissing = false
        })
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

/// ↩·esc 를 받는 표(↑↓ 는 표가 그대로 처리). 고른 줄 알약(안쪽 여백 6, 반지름 6)은 줄 밑에 깔린 레이어 하나가 줄 사이를 옮겨 다닌다.
final class NavigatorTableView: NSTableView {
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    private let pill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUp()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        pill.cornerRadius = NavigatorPopupView.pillRadius
        pill.isHidden = true
        layer?.insertSublayer(pill, at: 0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        pill.backgroundColor = TermAppearance.chromeRaised.cg(in: self)
    }

    /// 고른 줄 자리로. animated 면 Motion.fast 로 미끄러진다(동작 줄이기·창 밖이면 바로).
    func updatePill(animated: Bool) {
        let row = selectedRow
        guard row >= 0, row < numberOfRows else { pill.isHidden = true; return }
        let rect = self.rect(ofRow: row)
        let hInset = NavigatorPopupView.pillInset, vInset = TermAppearance.scaled(1)
        let frame = NSRect(x: rect.minX + hInset, y: rect.minY + vInset, width: max(rect.width - 2 * hInset, 0), height: rect.height - 2 * vInset)
        let wasHidden = pill.isHidden
        CATransaction.begin()
        if animated, !wasHidden, !Motion.reduced, window != nil {
            CATransaction.setAnimationDuration(Motion.fast)
            CATransaction.setAnimationTimingFunction(FloatFx.timing)
        } else {
            CATransaction.setDisableActions(true)
        }
        pill.backgroundColor = TermAppearance.chromeRaised.cg(in: self)
        pill.isHidden = false
        pill.frame = frame
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updatePill(animated: false)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onEnter?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// 찾기 칸: 돋보기·지우기 단추·포커스 링이 있는 시스템 검색 칸
final class NavigatorSearchField: NSSearchField {}

/// 고른 줄 바탕은 표가 그린 알약(NavigatorTableView.pill)이라 줄 자신은 그리지 않는다
final class NavigatorRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}

    override var isEmphasized: Bool { get { true } set {} }
}

/// [점][종류 아이콘 또는 심볼 배지] 위 줄(코드) / 아래 줄(경로) … 오른쪽 끝 표시
final class NavigatorCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("navigator-cell")
    var row: NavigatorRow? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let left: CGFloat = 13 // 칸이 1pt 안쪽에서 시작 → 알약 안쪽 글자 시작이 머리·꼬리 글자(14)와 맞는다
        var x = left
        let codeFont = EditorStyle.font
        let codeHeight = ceil(codeFont.ascender - codeFont.descender + codeFont.leading)
        let top = TermAppearance.scaled(6)
        let centerY = top + codeHeight / 2
        if let badge = row.badge {
            let size = TermAppearance.scaled(18)
            let rect = NSRect(x: x, y: top + (codeHeight - size) / 2, width: size, height: size)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            row.badgeColor.withAlphaComponent(0.18).setFill()
            path.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: TermAppearance.scaledUIFont(11, bold: true), .foregroundColor: row.badgeColor]
            let text = badge as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attrs)
            x += size + 10
        }
        // 세션 전환: 맨 점 + 종류 아이콘. 점 자리는 상태가 없어도 비워 둔다(이름 줄이 어긋나지 않게).
        if row.kind != nil || row.status != nil {
            // 점 8pt·종류 아이콘 상자 14×12·간격 8/6: 탭 제목과 같은 크기(점 크기는 사이드바·탭과 같다)
            let dot = TermAppearance.scaled(8)
            if let status = row.status {
                let selected = (superview as? NSTableRowView)?.isSelected == true
                status.drawDot(in: NSRect(x: x, y: centerY - dot / 2, width: dot, height: dot),
                               cutout: selected ? TermAppearance.chromeRaised : TermAppearance.chrome)
            }
            x += dot + TermAppearance.scaled(8)
            if let kind = row.kind {
                kind.drawIcon(size: TermAppearance.scaled(11),
                              in: CGRect(x: x, y: centerY - TabBarView.iconBoxHeight / 2, width: TabBarView.iconBoxWidth, height: TabBarView.iconBoxHeight))
                x += TabBarView.iconBoxWidth + TabBarView.iconGap
            }
        }
        var tagWidth: CGFloat = 0
        if let tag = row.tag {
            let attrs: [NSAttributedString.Key: Any] = [.font: TermAppearance.uiTextFont(TermAppearance.scaled(10), weight: .semibold),
                                                        .foregroundColor: TermAppearance.textSecondary]
            let size = (tag as NSString).size(withAttributes: attrs)
            tagWidth = size.width + 16
            (tag as NSString).draw(at: NSPoint(x: bounds.width - size.width - 14, y: top + (codeHeight - size.height) / 2), withAttributes: attrs)
        }
        let titleRect = NSRect(x: x, y: top, width: max(bounds.width - x - 14 - tagWidth, 10), height: codeHeight)
        row.title.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        let detail = NSMutableAttributedString()
        if let lead = row.detailLead {
            let font = TermAppearance.uiTextFont(TermAppearance.scaled(11))
            detail.append(NSAttributedString(string: lead, attributes: [.font: font, .foregroundColor: row.detailLeadColor]))
            detail.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: TermAppearance.textSecondary]))
        }
        detail.append(NSAttributedString(string: row.detail, attributes: [
            .font: TermAppearance.scaledUIFont(11), .foregroundColor: TermAppearance.textSecondary]))
        detail.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: detail.length))
        detail.draw(with: NSRect(x: x, y: top + codeHeight + 2, width: max(bounds.width - x - 14, 10), height: TermAppearance.scaled(16)),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

extension SymbolKind {
    /// 목록 종류 표시 색(IntelliJ 아이콘 색 계열)
    var badgeColor: NSColor {
        switch self {
        case .class, .record, .object, .struct: return NSColor.palette(.gitModified)
        case .interface, .protocol, .trait: return NSColor.palette(.gitAdded)
        case .enum, .enumCase: return NSColor.palette(.syntaxType)
        case .annotation: return NSColor.palette(.symbolAnnotation)
        case .function, .method, .constructor: return NSColor.palette(.syntaxKeyword)
        case .property, .field, .variable, .constant: return TermAppearance.textSecondary
        case .typeAlias, .module: return TermAppearance.textSecondary
        }
    }
}
