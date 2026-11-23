import AppKit
import Combine
import SessionCore
import TermLayout

/// agents 도구: 지금 고른 세션(TermModel.selectedId — 편집기 등 세션 줄이 아닌 화면이면 마지막 세션)이 띄운 하위 에이전트 목록과
/// 고른 에이전트의 기록(읽기 전용). 위에서 아래로 [머리 줄] / [에이전트 목록(작업 중 먼저, 그다음 최근 순)] / [기록].
/// 목록은 사이드바가 이미 훑은 `TermModel.agentActivities` 를 그대로 쓴다(따로 훑지 않는다).
/// 기록 읽기·타이머·글은 이 도구가 도크에 보이고(고른 도구) 에이전트를 골랐을 때만 있고, 가려지면 모두 놓는다.
/// 세션마다 고른 에이전트는 메모리에만 기억한다.
final class AgentsToolController: NSViewController, ToolContent, NSTableViewDataSource, NSTableViewDelegate {
    static let emptyMessage = "이 세션에서 최근 15분 안에 띄운 하위 에이전트가 없습니다."

    let model: TermModel
    /// 머리 줄 오른쪽 클릭 메뉴(옮기기·숨기기, 도구 창 관리자가 채운다)
    var dockMenu: (() -> NSMenu)?

    private let header = AgentsHeaderView()
    private let table = AgentsTableView()
    private let listScroll = NSScrollView()
    private let divider = BackgroundView()
    private let transcript = AgentTranscriptView(frame: .zero)
    private let empty = NSTextField(wrappingLabelWithString: AgentsToolController.emptyMessage)
    private var headerHeight: NSLayoutConstraint!
    private var listHeight: NSLayoutConstraint!

    private var toolVisible = false
    /// 따라가는 세션(화면 ID). 보이지 않을 때도 가볍게 따라간다(목록·기록은 보일 때만 만든다).
    private(set) var sessionId: String?
    /// 세션마다 고른 에이전트(메모리에만)
    private var selection: [String: String] = [:]
    /// 시험 명령(open-agent-view)이 끼워 넣은 가짜 에이전트(메모리에만)
    private var injected: [SubagentActivity] = []
    /// 지금 목록에 보이는 에이전트(보일 때만 채운다)
    private(set) var listed: [SubagentActivity] = []
    /// 프로그램이 표를 고르는 중(선택 변화를 사람이 고른 것으로 기록하지 않는다)
    private var selecting = false
    private var subscriptions: Set<AnyCancellable> = []

    init(model: TermModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        // 고른 화면·세션 줄이 바뀌면 따라간다(files 와 같은 방식: 다음 차례에 — 모델 값이 바뀐 뒤)
        Publishers.CombineLatest(model.$workspace, model.$rows)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.follow() }
            .store(in: &subscriptions)
        model.agentsChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged),
                                               name: TermAppearance.fontSizeChanged, object: nil)
        follow()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func loadView() {
        let root = BackgroundView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        root.color = TermAppearance.chrome

        header.menuProvider = { [weak self] in self?.dockMenu?() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agent"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = TermAppearance.chrome
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.onEscape = { [weak self] in self?.focusTerminal() }

        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = true
        listScroll.backgroundColor = TermAppearance.chrome
        listScroll.borderType = .noBorder
        listScroll.scrollerStyle = .overlay

        divider.color = TermAppearance.border

        empty.font = TermAppearance.uiTextFont(TermAppearance.scaled(TypeSize.secondary))
        empty.textColor = TermAppearance.textSecondary
        empty.alignment = .center
        empty.maximumNumberOfLines = 4
        empty.isHidden = true

        for view in [header, listScroll, divider, transcript, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        headerHeight = header.heightAnchor.constraint(equalToConstant: TerminalHostController.tabBarHeight)
        listHeight = listScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerHeight,
            listScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listHeight,
            divider.topAnchor.constraint(equalTo: listScroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            transcript.topAnchor.constraint(equalTo: divider.bottomAnchor),
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -40),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        view = root
        updateHeaderTitle()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateListHeight()
    }

    static var rowHeight: CGFloat { TermAppearance.scaled(40) }

    // MARK: - 보임·숨김

    /// 보이는 동안만 목록과 기록을 만든다. 숨기면(가려지거나 같은 도크의 다른 도구가 보이면) 읽기 상태·타이머·글·목록을 모두 놓는다.
    func setToolVisible(_ visible: Bool) {
        guard visible != toolVisible else { return }
        toolVisible = visible
        if visible {
            _ = view
            refresh()
        } else {
            transcript.unload()
            listed = []
            if isViewLoaded {
                reload()
                updateListHeight()
            }
        }
    }

    // MARK: - 세션 따라가기

    /// 고른 화면이 세션 줄이면 그 세션을, 아니면(편집기·막 만든 화면) 마지막 세션을 그대로 둔다
    private func follow() {
        if let id = model.selectedId, model.row(id) != nil, id != sessionId {
            sessionId = id
        }
        if toolVisible { refresh() } else if isViewLoaded { updateHeaderTitle() }
    }

    private func agents(of session: String?) -> [SubagentActivity] {
        guard let session else { return [] }
        let all = model.agentActivities + injected
        // 같은 에이전트가 목록과 시험 끼워 넣기에 둘 다 있으면 하나만
        var seen = Set<String>()
        return all.filter { $0.paneId == session && seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let l = lhs.isRunning, r = rhs.isRunning
                return l != r ? l : lhs.lastActive > rhs.lastActive
            }
    }

    /// 목록·고른 에이전트·기록을 지금 상태에 맞춘다(보일 때만)
    private func refresh() {
        guard toolVisible, isViewLoaded else { return }
        updateHeaderTitle()
        let next = agents(of: sessionId)
        // 이 세션에 고른 에이전트가 없거나 목록에서 사라졌으면: 작업 중인 것(가장 최근), 없으면 가장 최근 것
        if let sessionId {
            if selection[sessionId].map({ id in !next.contains { $0.id == id } }) ?? true {
                selection[sessionId] = next.first?.id
            }
        }
        if next != listed {
            listed = next
            reload()
        }
        updateListHeight()
        let hasAgents = !listed.isEmpty
        empty.isHidden = hasAgents
        listScroll.isHidden = !hasAgents
        divider.isHidden = !hasAgents
        transcript.isHidden = !hasAgents
        selectRow()
        syncTranscript()
    }

    /// 목록 높이: 줄 수만큼, 패널 높이의 40% 까지(넘으면 목록 안에서 스크롤)
    private func updateListHeight() {
        guard isViewLoaded else { return }
        let content = CGFloat(listed.count) * Self.rowHeight + TermAppearance.scaled(Space.xs)
        let cap = max(Self.rowHeight, view.bounds.height * 0.4)
        let target = listed.isEmpty ? 0 : min(content, cap)
        if abs(listHeight.constant - target) > 0.5 { listHeight.constant = target }
    }

    /// 표를 다시 그린다(그 사이 생기는 선택 변화는 사람이 고른 것이 아니다)
    private func reload() {
        selecting = true
        table.reloadData()
        selecting = false
    }

    private var selectedAgent: SubagentActivity? {
        guard let sessionId, let id = selection[sessionId] else { return nil }
        return listed.first { $0.id == id }
    }

    private func selectRow() {
        selecting = true
        defer { selecting = false }
        if let agent = selectedAgent, let row = listed.firstIndex(where: { $0.id == agent.id }) {
            if table.selectedRow != row {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
        } else {
            table.deselectAll(nil)
        }
    }

    /// 고른 에이전트의 기록(또는 Codex 안내)을 보인다. 다른 에이전트로 바뀌면 읽기 상태를 바꿔 쥔다. 고른 것이 없으면 놓는다.
    private func syncTranscript() {
        guard toolVisible, let agent = selectedAgent else {
            transcript.unload()
            return
        }
        let id = agent.id
        transcript.running = { [weak self] in self?.agents(of: self?.sessionId).first { $0.id == id }?.isRunning }
        if let path = agent.transcriptPath {
            if transcript.transcript == path, !transcript.isNote {
                transcript.refreshStatus()
            } else {
                transcript.load(transcript: path, description: agent.description, agentType: agent.agentType)
            }
        } else {
            transcript.loadNote(description: agent.description, agentType: agent.agentType, lastText: agent.lastText)
        }
    }

    private func updateHeaderTitle() {
        header.update(session: sessionId.flatMap { model.row($0)?.title })
    }

    // MARK: - 밖에서 부르는 것

    /// 사이드바 줄을 눌렀을 때: 이 에이전트를 그 세션의 고른 에이전트로 삼는다(그 세션이 지금 보이는 세션이면 바로 보인다)
    func select(_ agent: SubagentActivity) {
        selection[agent.paneId] = agent.id
        if sessionId != agent.paneId, model.selectedId == agent.paneId { sessionId = agent.paneId }
        refresh()
    }

    /// 기록 글에 키보드가 있나(⌘F 를 그 글 안에서 찾는 데 쓴다)
    var transcriptHasFocus: Bool {
        guard toolVisible, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: transcript)
    }

    func find(_ action: NSTextFinder.Action) { transcript.find(action) }

    private func focusTerminal() {
        if let target = model.host?.focusedPaneView { view.window?.makeFirstResponder(target) }
    }

    @objc private func fontSizeChanged() {
        guard isViewLoaded else { return }
        headerHeight.constant = TerminalHostController.tabBarHeight
        table.rowHeight = Self.rowHeight
        header.applyScale()
        if toolVisible { reload(); updateListHeight() }
    }

    // MARK: - 표

    func numberOfRows(in tableView: NSTableView) -> Int { listed.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FileRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < listed.count else { return nil }
        let id = AgentRowCell.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? AgentRowCell) ?? AgentRowCell()
        cell.identifier = id
        cell.configure(listed[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, let sessionId else { return }
        let row = table.selectedRow
        guard row >= 0, row < listed.count else { return }
        selection[sessionId] = listed[row].id
        syncTranscript()
    }

    // MARK: - 시험 명령

    /// 시험 명령(open-agent-view): 가짜 하위 에이전트를 지금 따라가는 세션 몫으로 끼워 넣는다
    func debugInject(_ agent: SubagentActivity) {
        injected.removeAll { $0.id == agent.id }
        injected.append(agent)
        refresh()
    }

    /// 시험 명령(agent-views): 패널 상태 한 줄
    var debugSummary: String {
        let selected = selectedAgent
        return "agents-panel followed=\(sessionId ?? "-") listed=\(listed.count) injected=\(injected.count) "
            + "selected=\(selected?.id ?? "-") codex-note=\(transcript.isNote) reader-entries=\(transcript.entryCount.map(String.init) ?? "-") "
            + "timer=\(transcript.timerOn ? "on" : "off") remembered=\(selection.count)"
    }

    var debugTranscript: String { transcript.debugSummary }
}

/// 머리 줄: "하위 에이전트 · <세션 이름>". 오른쪽 클릭 = 옮기기·숨기기(files 머리 줄과 같은 모양).
final class AgentsHeaderView: NSView {
    var menuProvider: (() -> NSMenu?)?
    private let title = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.textColor = TermAppearance.textPrimary
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        applyScale()
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TermAppearance.scaled(Space.md)),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -TermAppearance.scaled(Space.md)),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(session: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        TermAppearance.chrome.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    func applyScale() {
        title.font = TermAppearance.scaledUIFont(TypeSize.row, bold: true)
    }

    func update(session name: String?) {
        let text = "하위 에이전트" + (name.map { " · " + $0 } ?? "")
        title.stringValue = text
        toolTip = text
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// 에이전트 목록 표: Esc 는 터미널로 돌아간다(files 트리와 같게)
final class AgentsTableView: NSTableView {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

/// 목록 한 줄: 설명 / 상태(작업 중 · N분 전) · 종류. 사이드바 하위 에이전트 줄과 같은 말과 색.
final class AgentRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("AgentCell")

    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        let pad = TermAppearance.scaled(Space.md)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: TermAppearance.scaled(1)),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: TermAppearance.scaled(2)),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ agent: SubagentActivity) {
        let running = agent.isRunning
        title.font = TermAppearance.scaledUIFont(TypeSize.secondary)
        title.textColor = running ? TermAppearance.textPrimary : TermAppearance.textSecondary
        title.stringValue = agent.description
        let font = TermAppearance.scaledUIFont(TypeSize.caption)
        let when = running ? "작업 중" : "\(max(1, Int(Date().timeIntervalSince(agent.lastActive) / 60)))분 전"
        let text = NSMutableAttributedString(string: when, attributes: [
            .font: font, .foregroundColor: running ? TermAppearance.statusWorking : TermAppearance.textSecondary])
        if let type = agent.agentType, !type.isEmpty {
            text.append(NSAttributedString(string: " · " + type, attributes: [.font: font, .foregroundColor: TermAppearance.textSecondary]))
        }
        detail.attributedStringValue = text
        toolTip = [agent.description, agent.worktreePath].compactMap { $0 }.joined(separator: "\n")
    }
}
