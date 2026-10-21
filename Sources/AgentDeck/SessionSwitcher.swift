import AppKit
import TermLayout

extension TermModel {
    var sessionTargets: [SessionTarget] {
        workspace.tabs.enumerated().flatMap { index, tab in
            tab.root.panes.map { id in
                let row = row(id)
                let path = workspace.editors[id]?.path
                let folder = path.map { ($0 as NSString).deletingLastPathComponent } ?? row?.cwd ?? ""
                let state: String
                switch row?.status {
                case .waiting?: state = "waiting"
                case .error?: state = "error"
                case .done?: state = "done"
                case .orchestrating?: state = "orchestrating"
                default: state = ""
                }
                return SessionTarget(id: id, name: paneLabel(id), folder: folder, state: row?.dormant == true ? "" : state,
                                     stateAt: row?.statusAt ?? .distantPast,
                                     recentAt: paneRecent[id] ?? row?.statusAt ?? .distantPast, tab: index + 1)
            }
        }
    }

    func revealSession(_ id: String) {
        for group in groups {
            for section in group.sections where section.rows.contains(where: { $0.id == id }) {
                for key in [SpacesState.groupKey(group.path), SpacesState.worktreeKey(section.path)] where spaces.state.isCollapsed(key) {
                    spaces.toggle(key)
                }
            }
        }
        focus(pane: id)
        host?.focusPane()
    }

    func nextAttention() {
        host?.sessionSwitcher.close(restoreFocus: false)
        host?.navigator.closePopup(restoreFocus: false)
        guard let id = attentionCycle.next(sessionTargets, focused: selectedId) else {
            host?.sessionSwitcher.hint("확인할 세션이 없습니다")
            return
        }
        revealSession(id)
    }
}

final class SessionSwitcher {
    unowned let host: TerminalHostController
    private(set) var popup: NavigatorPopupView?
    private var targets: [SessionTarget] = []
    private var candidates: [SessionTarget] = []
    private var mouseMonitor: Any?
    private var hintLabel: NSTextField?
    private weak var previousResponder: NSResponder?
    private weak var previousField: NSTextField?
    init(host: TerminalHostController) { self.host = host }
    deinit { if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) } }

    func show() {
        close(restoreFocus: true)
        host.navigator.closePopup(restoreFocus: false)
        previousResponder = host.view.window?.firstResponder
        if let bar = host.focusedTerminal?.findBar, bar.fieldHasFocus { previousField = bar.field }
        else if let editor = previousResponder as? NSTextView, editor.isFieldEditor {
            previousField = editor.delegate as? NSTextField
        } else { previousField = nil }
        candidates = host.model.sessionTargets
        let popup = NavigatorPopupView(title: "세션 빠른 전환", searchable: true, placeholder: "세션 이름 · 폴더 · 작업 트리 검색")
        self.popup = popup
        popup.onQuery = { [weak self] in self?.filter($0) }
        popup.onClose = { [weak self] in self?.close(restoreFocus: true) }
        popup.onChoose = { [weak self] index in
            guard let self, self.targets.indices.contains(index) else { return }
            let id = self.targets[index].id
            self.close(restoreFocus: false)
            self.host.model.revealSession(id)
        }
        host.view.addSubview(popup)
        filter("")
        host.view.window?.makeFirstResponder(popup.field)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let popup = self.popup, event.window === popup.window else { return event }
            if !popup.bounds.contains(popup.convert(event.locationInWindow, from: nil)) { self.close(restoreFocus: false) }
            return event
        }
    }

    func filter(_ query: String) {
        guard let popup else { return }
        targets = SessionNavigation.ranked(candidates, query: query)
        popup.setRows(targets.map { target in
            let row = host.model.row(target.id)
            let editor = host.model.workspace.editors[target.id] != nil
            let status = row?.status ?? .none
            let label = row?.dormant == true ? "꺼짐" : status.label ?? (editor ? "편집기" : "셸")
            return NavigatorRow(badge: "●", badgeColor: status.color,
                title: NSAttributedString(string: target.name, attributes: [.font: EditorStyle.font, .foregroundColor: TermAppearance.textPrimary]),
                detail: "\(label) · \((target.folder as NSString).abbreviatingWithTildeInPath)",
                tag: target.tab <= 8 ? "⌘\(target.tab)" : target.tab == host.model.workspace.tabs.count ? "⌘9 · 탭 \(target.tab)" : "탭 \(target.tab)")
        }, empty: "일치하는 세션이 없습니다")
        popup.setStatus("\(targets.count)개 / 전체 \(candidates.count)개")
        layout()
    }

    func scaleChanged() {
        guard let query = popup?.field.stringValue else { return }
        let responder = previousResponder, field = previousField
        show()
        previousResponder = responder; previousField = field
        popup?.field.stringValue = query
        filter(query)
    }

    func layout() {
        guard let popup else { return }
        let bounds = host.view.bounds
        let width = max(160, min(TermAppearance.scaled(760), bounds.width - 24))
        let height = min(popup.preferredHeight, max(bounds.height - 90, 100))
        popup.frame = NSRect(x: (bounds.width - width) / 2, y: max(8, bounds.height - 70 - height), width: width, height: height).integral
    }

    func close(restoreFocus: Bool) {
        guard let popup else { return }
        popup.removeFromSuperview(); self.popup = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if restoreFocus {
            if let field = previousField, field.window === host.view.window {
                field.window?.makeFirstResponder(field)
            } else if let responder = previousResponder as? NSView, responder.window === host.view.window {
                responder.window?.makeFirstResponder(responder)
            } else { host.focusPane() }
        }
        previousResponder = nil; previousField = nil
    }

    func hint(_ text: String) {
        hintLabel?.removeFromSuperview()
        let label = NSTextField(labelWithString: text)
        label.font = TermAppearance.scaledUIFont(12)
        label.textColor = TermAppearance.textPrimary
        label.backgroundColor = TermAppearance.chrome
        label.drawsBackground = true
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.layer?.borderColor = TermAppearance.border.cgColor
        label.layer?.borderWidth = 1
        let width = TermAppearance.scaled(260), height = TermAppearance.scaled(32)
        label.frame = NSRect(x: (host.view.bounds.width - width) / 2, y: host.view.bounds.height - 80, width: width, height: height)
        host.view.addSubview(label)
        hintLabel = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self, weak label] in
            label?.removeFromSuperview()
            if self?.hintLabel === label { self?.hintLabel = nil }
        }
    }
}
