import AppKit
import MetalKit
import SessionCore
import SwiftTerm
import SwiftUI
import TermLayout
import TermWire

// AgentDeck: 왼쪽 세션 목록 + 오른쪽 터미널. 셸·claude 는 데몬(AgentDeckDaemon)이 붙잡고 있다.
// 0.3 까지의 안쪽 이름(ClaudeTerm·ClaudeTermDaemon, dev.claude-sessions.term, ClaudeSessions 폴더, CLAUDE_TERM_*)에서
// 바꿨다. 예전 데이터·데몬은 DataLocation 이 이어받는다.

// Claude 세션 안에서 띄워도 그 세션 표시 변수가 데몬·셸로 넘어가지 않게(대화 저장이 꺼지는 문제)
InheritedEnvironment.reexecIfNeeded(executablePath: Bundle.main.executablePath)
signal(SIGPIPE, SIG_IGN)

// 데이터 위치는 무엇을 읽기 전에 정한다: 예전 데몬이 살아 있으면 그 폴더 그대로, 데몬이 없으면 예전 폴더를 새 폴더로 옮긴다
DataLocation.prepareForApp()

TermAppearance.registerBundledFonts()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let model = TermModel()
    var window: NSWindow?
    var toolWindows: ToolWindowsController?
    /// 설정 창(⌘,) — 처음 열 때 만든다
    lazy var settingsWindow = SettingsWindowController(settings: model.launch)
    var snapshotTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        model.openSettings = { [weak self] in self?.perform("settings") }
        let host = TerminalHostController(model: model)
        model.host = host

        // [왼쪽 도크 | 터미널 | 오른쪽 도크]. 도구(spaces·files)는 IntelliJ 처럼 양옆에 붙이거나 숨긴다(ToolWindows.swift).
        // 도크는 반투명 재질 없이 앱 색으로(herdr 처럼 터미널과 한 덩어리로 보이게)
        let tools = ToolWindowsController(model: model, host: host)
        toolWindows = tools

        let window = NSWindow(contentViewController: tools.split)
        window.title = "AgentDeck"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = TermAppearance.chrome
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.setFrameAutosaveName("AgentDeckMain")
        window.delegate = self
        tools.restoreWidths()
        self.window = window
        // 시험용: AGENTDECK_NO_ACTIVATE=1 이면 앞으로 나오지 않는다(사용 중인 다른 앱의 포커스를 뺏지 않게 창을 뒤에 둔다)
        if AgentDeckEnv.isOn("NO_ACTIVATE") {
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        model.start()
        startShortcuts()
        startDebugHooks()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 저장 안 한 편집기를 이미 물었는지(창 닫기 → 종료로 이어질 때 두 번 묻지 않게)
    private var quitConfirmed = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.confirmQuit() else { return false }
        quitConfirmed = true
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitConfirmed || model.confirmQuit() { return .terminateNow }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.host?.rememberEditorCursors()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01)) // 커서 기억(다음 차례로 미룬 것)을 마친다
        model.saveLayoutNow()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.representedObject as? String {
        case "pane-find", "pane-find-next", "pane-find-previous":
            guard NSApp.keyWindow === window else { return false }
            if let editor = model.host?.focusedEditor { return editor.preview == nil && editor.textView != nil }
            guard let pane = model.host?.focusedTerminal else { return false }
            return menuItem.representedObject as? String == "pane-find" || pane.findBar.superview != nil
                || !pane.findBar.field.stringValue.isEmpty
        case "clear-screen":
            return NSApp.keyWindow === window && model.host?.focusedTerminal != nil
        case "save":
            return model.focusedIsEditor
        case "markdown-preview":
            let editor = model.host?.focusedEditor
            menuItem.state = editor?.preview != nil ? .on : .off
            return editor?.canPreview ?? false
        case "goto-declaration", "find-usages":
            return model.host?.focusedEditor.map { $0.preview == nil && $0.textView != nil } ?? false
        case "nav-back":
            return model.host?.navigator.canGoBack ?? false
        case "nav-forward":
            return model.host?.navigator.canGoForward ?? false
        case "browser":
            // 에이전트(셸) 화면에서만 — 편집기·브라우저 화면에는 브라우저가 없다
            return model.selectedId.map { !LocalPane.isLocal($0) } ?? false
        case "extract-pane":
            return (model.workspace.selectedTab?.root.panes.count ?? 0) > 1
        case "move-tab:left":
            return (model.workspace.selectedIndex ?? 0) > 0
        case "move-tab:right":
            return model.workspace.selectedIndex.map { $0 < model.workspace.tabs.count - 1 } ?? false
        case "hooks-disconnect":
            return [.ok, .update].contains(model.hookState)
        case "relocate-data":
            menuItem.isHidden = !model.legacyDaemon
            return model.legacyDaemon && !model.relocating
        case "codex-hooks-disconnect":
            menuItem.isHidden = ![.ok, .update].contains(model.codexHookState)
            return !menuItem.isHidden
        default:
            return true
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "AgentDeck 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        addAction(appMenu, "업데이트 확인…", "update-check", "")
        appMenu.addItem(.separator())
        addAction(appMenu, "설정…", "settings", ",")
        appMenu.addItem(.separator())
        // hook 빼기(넣기는 사이드바 아래 "연결하기"). Codex 것은 연결돼 있을 때만 보인다.
        addAction(appMenu, "Claude Code 연결 해제…", "hooks-disconnect", "")
        addAction(appMenu, "Codex 연결 해제…", "codex-hooks-disconnect", "")
        // 예전 데몬에 붙어 있을 때만 보인다(상태 줄 "지금 옮기기…"와 같음)
        addAction(appMenu, "새 데이터 위치로 지금 옮기기…", "relocate-data", "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "AgentDeck 가리기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "기타 가리기", action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "모두 보기", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "AgentDeck 종료(세션은 유지)", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // 파일(편집기): 저장 ⌘S — 편집기 화면일 때만 켜진다
        let file = NSMenu(title: "파일")
        addAction(file, "저장", "save", "s")
        addSubmenu(main, file)

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "편집")
        // 되돌리기·잘라내기는 편집기에서 응답한다. 찾기는 지금 화면 종류로 보낸다.
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        addAction(edit, "찾기…", "pane-find", "f")
        let replace = edit.addItem(withTitle: "바꾸기…", action: #selector(EditorTextView.editorReplace(_:)), keyEquivalent: "f")
        replace.keyEquivalentModifierMask = [.command, .option]
        addAction(edit, "다음 찾기", "pane-find-next", "g")
        addAction(edit, "이전 찾기", "pane-find-previous", "g", [.command, .shift])
        editItem.submenu = edit

        // 단축키는 Ghostty 기본값과 같게
        let arrows: [(Direction, String, String)] = [
            (.left, String(UnicodeScalar(NSLeftArrowFunctionKey)!), "왼쪽"),
            (.right, String(UnicodeScalar(NSRightArrowFunctionKey)!), "오른쪽"),
            (.up, String(UnicodeScalar(NSUpArrowFunctionKey)!), "위"),
            (.down, String(UnicodeScalar(NSDownArrowFunctionKey)!), "아래"),
        ]
        let shell = NSMenu(title: "셸")
        addAction(shell, "새 탭", "new-tab", "t")
        addAction(shell, "오른쪽으로 나누기", "split-right", "d")
        addAction(shell, "아래로 나누기", "split-down", "d", [.command, .shift])
        addAction(shell, "브라우저 보기", "browser", "b", [.command, .shift])
        shell.addItem(.separator())
        addAction(shell, "화면 닫기", "close", "w")
        addAction(shell, "탭 닫기", "close-tab", "w", [.command, .option])
        shell.addItem(.separator())
        addAction(shell, "화면 지우기", "clear-screen", "k")
        shell.addItem(.separator())
        addAction(shell, "이름 바꾸기…", "rename", "")
        addAction(shell, "화면을 새 탭으로 꺼내기", "extract-pane", "")
        addSubmenu(main, shell)

        // 이동(IntelliJ 식). ⌘[ ⌘] 는 편집기 화면에서만 뒤로·앞으로(터미널에선 이전·다음 화면)
        let navigate = NSMenu(title: "이동")
        addAction(navigate, "다음 확인할 세션", "next-attention", "j")
        addAction(navigate, "세션 빠른 전환…", "session-switcher", "p")
        navigate.addItem(.separator())
        addAction(navigate, "선언으로 이동", "goto-declaration", "b")
        addAction(navigate, "사용 위치 찾기", "find-usages", String(UnicodeScalar(NSF7FunctionKey)!), [.option])
        addAction(navigate, "심볼로 이동…", "goto-symbol", "o")
        navigate.addItem(.separator())
        addAction(navigate, "뒤로", "nav-back", "[")
        addAction(navigate, "앞으로", "nav-forward", "]")
        addSubmenu(main, navigate)

        let view = NSMenu(title: "보기")
        // Markdown 파일: 편집 ↔ 미리보기(Markdown 편집기 화면일 때만 켜진다)
        addAction(view, "Markdown 미리보기", "markdown-preview", "v", [.command, .shift])
        view.addItem(.separator())
        addAction(view, "이전 화면", "previous-split", "[")
        addAction(view, "다음 화면", "next-split", "]")
        for (direction, key, name) in arrows {
            addAction(view, "\(name) 화면으로", "focus:\(direction.rawValue)", key, [.command, .option])
        }
        view.addItem(.separator())
        addAction(view, "글자 크게", "font:bigger", "+")
        addAction(view, "글자 작게", "font:smaller", "-")
        addAction(view, "기본 크기", "font:reset", "0")
        view.addItem(.separator())
        addAction(view, "화면 크게 보기/되돌리기", "zoom", "\r", [.command, .shift])
        addAction(view, "분할 크기 같게", "equalize", "=", [.command, .control])
        for (direction, key, name) in arrows {
            addAction(view, "나눈 선을 \(name)로", "resize:\(direction.rawValue)", key, [.command, .control])
        }
        view.addItem(.separator())
        addAction(view, "이전 탭", "previous-tab", "[", [.command, .shift])
        addAction(view, "다음 탭", "next-tab", "]", [.command, .shift])
        // 탭 옮기기(IntelliJ 의 왼쪽/오른쪽으로 옮기기와 같은 ⌥⇧⌘←/→). 끌어서도 옮긴다.
        addAction(view, "탭 왼쪽으로 옮기기", "move-tab:left", arrows[0].1, [.command, .option, .shift])
        addAction(view, "탭 오른쪽으로 옮기기", "move-tab:right", arrows[1].1, [.command, .option, .shift])
        for number in 1...9 {
            addAction(view, number == 9 ? "마지막 탭" : "탭 \(number)", "tab:\(number)", "\(number)")
        }
        // IntelliJ 식 도구 창: 숨김이면 보이고 고름 → 보이지만 안 골랐으면 고름 → 고른 상태면 숨김
        view.addItem(.separator())
        addAction(view, "files 도구 보이기/숨기기", "tool-toggle:files", "e", [.command, .shift])
        addAction(view, "spaces 도구 보이기/숨기기", "tool-toggle:spaces", "s", [.command, .shift])
        for (tool, label) in [("files", "files"), ("spaces", "spaces")] {
            let place = NSMenu(title: "\(label) 위치")
            addAction(place, "왼쪽", "tool-move:\(tool):left", "")
            addAction(place, "오른쪽", "tool-move:\(tool):right", "")
            addAction(place, "숨김", "tool-move:\(tool):hidden", "")
            let item = NSMenuItem(title: "\(label) 위치", action: nil, keyEquivalent: "")
            item.submenu = place
            view.addItem(item)
        }
        addSubmenu(main, view)
        NSApp.mainMenu = main
    }

    /// Ghostty 기본 단축키. 메뉴에도 같은 키를 적어 두지만, ⌘⇧ 조합은 메뉴가 놓치는 경우가 있고
    /// 한글 입력 중에도 똑같이 되도록 키 위치(키 코드)로 직접 받는다.
    private var shortcutMonitor: Any?

    private static let shortcuts: [ShortcutKey: String] = {
        var map: [ShortcutKey: String] = [
            ShortcutKey(38, .command): "next-attention",
            ShortcutKey(35, .command): "session-switcher",
            ShortcutKey(40, .command): "clear-screen",
            ShortcutKey(3, .command): "pane-find",
            ShortcutKey(5, .command): "pane-find-next",
            ShortcutKey(5, [.command, .shift]): "pane-find-previous",
            ShortcutKey(17, .command): "new-tab",
            ShortcutKey(2, .command): "split-right",
            ShortcutKey(2, [.command, .shift]): "split-down",
            ShortcutKey(11, [.command, .shift]): "browser",
            ShortcutKey(13, .command): "close",
            ShortcutKey(13, [.command, .option]): "close-tab",
            ShortcutKey(33, .command): "previous-split",
            ShortcutKey(30, .command): "next-split",
            ShortcutKey(33, [.command, .shift]): "previous-tab",
            ShortcutKey(30, [.command, .shift]): "next-tab",
            ShortcutKey(36, [.command, .shift]): "zoom",
            ShortcutKey(76, [.command, .shift]): "zoom",
            ShortcutKey(24, [.command, .control]): "equalize",
            ShortcutKey(48, .control): "next-tab",
            ShortcutKey(48, [.control, .shift]): "previous-tab",
            // 도구 창(⌘⇧E files, ⌘⇧S spaces)
            ShortcutKey(14, [.command, .shift]): "tool-toggle:files",
            // 글자 크기(⌘+ ⌘= ⌘− ⌘0, 터미널·편집기 전체)
            ShortcutKey(24, .command): "font:bigger",
            ShortcutKey(24, [.command, .shift]): "font:bigger",
            ShortcutKey(69, .command): "font:bigger",
            ShortcutKey(27, .command): "font:smaller",
            ShortcutKey(78, .command): "font:smaller",
            ShortcutKey(29, .command): "font:reset",
            ShortcutKey(82, .command): "font:reset",
            ShortcutKey(1, [.command, .shift]): "tool-toggle:spaces",
            // 설정(⌘,)
            ShortcutKey(43, .command): "settings",
        ]
        for (code, direction) in [(123, "left"), (124, "right"), (125, "down"), (126, "up")] as [(UInt16, String)] {
            map[ShortcutKey(code, [.command, .option])] = "focus:\(direction)"
            map[ShortcutKey(code, [.command, .control])] = "resize:\(direction)"
        }
        map[ShortcutKey(123, [.command, .option, .shift])] = "move-tab:left"
        map[ShortcutKey(124, [.command, .option, .shift])] = "move-tab:right"
        for (number, code) in zip(1...9, [18, 19, 20, 21, 23, 22, 26, 28, 25] as [UInt16]) {
            map[ShortcutKey(code, .command)] = "tab:\(number)"
        }
        return map
    }()

    private func startShortcuts() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if [36, 76].contains(event.keyCode),
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let pane = self.model.host?.focusedTerminal, pane.findBar.superview != nil,
               let fieldEditor = pane.findBar.field.currentEditor() as? NSTextView,
               event.window?.firstResponder === fieldEditor, !fieldEditor.hasMarkedText() {
                pane.findBar.search(backwards: event.modifierFlags.contains(.shift))
                return nil
            }
            if event.keyCode == 53,
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               self.model.host?.sessionSwitcher.popup == nil,
               self.model.host?.navigator.popup == nil, let pane = self.model.host?.focusedTerminal,
               pane.findBar.superview != nil, pane.findBar.fieldHasFocus,
               (pane.findBar.field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
                pane.findBar.close()
                return nil
            }
            // ⌘S = 편집기 저장(키 위치로 — 한글 입력 중에도). 편집기 화면이 아니면 그대로 보낸다(⌘⇧S 는 spaces).
            if ShortcutKey(event.keyCode, event.modifierFlags) == ShortcutKey(1, .command), self.model.focusedIsEditor {
                self.model.saveFocused()
                return nil
            }
            // 이동: ⌘B·⌥F7(⌥⌘F7)·⌘O. 편집기 화면이면 ⌘[ ⌘] 는 뒤로·앞으로(기록이 없으면 아무것도 안 함 — 화면 이동으로 넘기지 않는다)
            if let action = self.navigationAction(for: event) {
                if action != "none" { self.perform(action) }
                return nil
            }
            // ⇧⌘V = Markdown 편집 ↔ 미리보기. Markdown 편집기가 아니면 그대로 보낸다.
            if ShortcutKey(event.keyCode, event.modifierFlags) == ShortcutKey(9, [.command, .shift]),
               self.model.host?.focusedEditor?.canPreview == true {
                self.model.perform("markdown-preview")
                return nil
            }
            guard let action = Self.shortcuts[ShortcutKey(event.keyCode, event.modifierFlags)] else { return event }
            // ⌘K 화면 지우기는 터미널 화면에서만. 편집기 등 다른 화면이면 그대로 보낸다.
            if action == "clear-screen", self.model.host?.focusedTerminal == nil { return event }
            if ["pane-find-next", "pane-find-previous"].contains(action),
               let pane = self.model.host?.focusedTerminal, pane.findBar.superview == nil,
               pane.findBar.field.stringValue.isEmpty { return event }
            self.perform(action)
            return nil
        }
    }

    /// 이동 단축키(키 위치로 — 한글 입력 중에도). 받지 않으면 nil, 받았지만 할 일이 없으면 "none".
    private func navigationAction(for event: NSEvent) -> String? {
        let key = ShortcutKey(event.keyCode, event.modifierFlags)
        let editor = model.host?.focusedEditor
        let textEditor = editor.map { $0.preview == nil && $0.textView != nil } ?? false
        switch key {
        case ShortcutKey(11, .command): // ⌘B
            return textEditor ? "goto-declaration" : nil
        case ShortcutKey(98, .option), ShortcutKey(98, [.option, .command]): // ⌥F7 (⌥⌘F7 도)
            return textEditor ? "find-usages" : nil
        case ShortcutKey(31, .command): // ⌘O
            return "goto-symbol"
        case ShortcutKey(33, .command): // ⌘[
            guard editor != nil else { return nil }
            return model.host?.navigator.canGoBack == true ? "nav-back" : "none"
        case ShortcutKey(30, .command): // ⌘]
            guard editor != nil else { return nil }
            return model.host?.navigator.canGoForward == true ? "nav-forward" : "none"
        default:
            return nil
        }
    }

    /// 메뉴·단축키·시험 명령: 도구 창 동작(tool-…)은 도구 창 관리자가, 나머지는 모델이 맡는다
    private func perform(_ action: String) {
        if action.hasPrefix("pane-find") {
            model.host?.sessionSwitcher.close(restoreFocus: true)
            model.host?.navigator.closePopup(restoreFocus: true)
            if let editor = model.host?.focusedEditor {
                guard editor.preview == nil, let textView = editor.textView else { return }
                switch action {
                case "pane-find": textView.editorFind(nil)
                case "pane-find-next": textView.editorFindNext(nil)
                default: textView.editorFindPrevious(nil)
                }
            } else if let pane = model.host?.focusedTerminal {
                if action == "pane-find" { pane.findBar.show() }
                else {
                    if pane.findBar.superview == nil {
                        guard !pane.findBar.field.stringValue.isEmpty else { return }
                        pane.findBar.show()
                    }
                    pane.findBar.search(backwards: action == "pane-find-previous")
                }
            }
        } else if action.hasPrefix("font:") {
            TermAppearance.adjustFontSize(String(action.dropFirst(5)))
        } else if action.hasPrefix("tool-") {
            toolWindows?.perform(action)
        } else if action == "settings" {
            settingsWindow.show()
        } else {
            model.perform(action)
        }
    }

    private func addSubmenu(_ main: NSMenu, _ menu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = menu
        main.addItem(item)
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ action: String, _ key: String,
                           _ modifiers: NSEvent.ModifierFlags = .command) {
        let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = action
        item.target = self
        menu.addItem(item)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        if action.hasPrefix("pane-find"), NSApp.keyWindow !== window { return }
        // 설정 창 같은 다른 창이 앞에 있으면 ⌘W 는 그 창을 닫는다(터미널 화면을 닫지 않게)
        if ["close", "close-tab"].contains(action), let key = NSApp.keyWindow, key !== window {
            key.performClose(nil)
            return
        }
        perform(action)
    }

    // MARK: - 시험용(AGENTDECK_SNAPSHOT 또는 AGENTDECK_DEBUG 가 있을 때만, 예전 이름 CLAUDE_TERM_* 도 읽는다)

    /// AGENTDECK_SNAPSHOT=<폴더> 면 1초마다 창 그림을 <폴더>/window.png 로 남긴다(화면 기록 권한 없이 확인용. 메모리를 더 쓴다).
    /// 둘 중 하나라도 있으면 분산 알림 "dev.agentdeck.debug" 로 받은 명령을 실행한다.
    ///   select <화면 ID> | action <메뉴 동작 이름> | type <글자> | keys <글자> | ime <조합1>|<조합2>|…|<확정> | screen | close-window
    ///   도구 창: tool <files|spaces>(토글) | dock <도구> <left|right|hidden> | tool-select <도구> | uilayout | toolmenu <도구>
    ///   files: filesroot | expand <상대 경로> | collapse-all | open-file <상대 경로> | filesmenu <상대 경로>[|<항목>] | footprint
    ///          files-select a|b|c(여러 줄 고르기) | files-enter | files-scroll <상대 경로>(맨 위로) | editor-pin(미리보기 고정)
    ///   배포: alert-answer <번호…>(확인 창 대신) | update-state | update-open | hooks-state | appmenu | fonts
    ///   데이터 위치: location(위치·모드·데몬). 옮기기는 action relocate-data
    private func startDebugHooks() {
        let env = ProcessInfo.processInfo.environment
        let snapshotDir = AgentDeckEnv.nonEmpty("SNAPSHOT", in: env)
        guard snapshotDir != nil || AgentDeckEnv.isOn("DEBUG", in: env) else { return }
        if let snapshotDir {
            let url = URL(fileURLWithPath: snapshotDir).appendingPathComponent("window.png")
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.snapshot(to: url) }
            RunLoop.main.add(timer, forMode: .common)
            snapshotTimer = timer
        }
        // AGENTDECK_DEBUG_NAME: 시험 앱을 여럿 띄울 때 서로의 명령을 받지 않게 알림 이름을 바꾼다
        let channel = AgentDeckEnv.nonEmpty("DEBUG_NAME", in: env) ?? "dev.agentdeck.debug"
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(channel), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let command = note.object as? String else { return }
            self.debug(command)
        }
    }

    private func debug(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "select":
            model.focus(pane: argument)
        case "action":
            perform(argument)
        case "tool":
            // tool <files|spaces> = ⌘⇧E·⌘⇧S 와 같은 토글
            toolWindows?.perform("tool-toggle:\(argument)")
        case "dock":
            // dock <도구> <left|right|hidden>
            let v = argument.split(separator: " ").map(String.init)
            if v.count == 2 { toolWindows?.perform("tool-move:\(v[0]):\(v[1])") }
        case "tool-select":
            toolWindows?.perform("tool-select:\(argument)")
        case "uilayout":
            if let data = toolWindows?.layout.data() { print("uilayout " + (String(data: data, encoding: .utf8) ?? "")) }
            fflush(stdout)
        case "filesroot":
            print(toolWindows?.files.debugSummary ?? "filesroot -")
            fflush(stdout)
        case "expand":
            toolWindows?.files.debugExpand(argument)
        case "filesmenu":
            toolWindows?.files.debugMenu(argument)
        case "toolmenu":
            // toolmenu <도구>: 도구 버튼·머리 줄 오른쪽 클릭 메뉴 항목
            if let tool = ToolID(rawValue: argument), let menu = toolWindows?.menu(for: tool) {
                print("toolmenu \(argument): " + menu.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.state == .on ? "(✓)" : "") }.joined(separator: " / "))
                fflush(stdout)
            }
        case "open-file":
            toolWindows?.files.debugOpen(argument)
        case "files-select":
            // files-select a|b|c: 여러 줄 고르기(⌘누르기와 같음)
            toolWindows?.files.debugSelect(argument)
        case "files-enter":
            toolWindows?.files.debugEnter()
        case "files-scroll":
            toolWindows?.files.debugScroll(argument)
        case "font-size":
            // font-size <pt>: ⌘+ ⌘− 와 같은 길(앱 테두리 배율도 따라간다)
            if let size = Double(argument) { TermAppearance.setFontSize(CGFloat(size)) }
            print("font-size \(TermAppearance.fontSize) scale=\(TermAppearance.uiScale.factor)")
            fflush(stdout)
        case "editor-pin":
            // 지금 화면(편집기 미리보기)을 고정 — 분할 제목 두 번 누르기와 같음
            if let id = model.selectedId { model.pin(editor: id) }
        case "quit":
            // 앱 메뉴 "종료"(⌘Q)와 같은 길 — 데몬이 앱과 따로 남는지 시험할 때
            NSApp.terminate(nil)
        case "alert-answer":
            // alert-answer <번호…>: 다음 확인 창들에서 누를 버튼(0 = 첫 버튼)
            AppAlert.pendingAnswers += argument.split(separator: " ").compactMap { Int($0) }
        case "update-state":
            print("update-state current=\(model.updates.current ?? "-") available=\(model.updates.available?.tag ?? "-")")
            fflush(stdout)
        case "update-open":
            model.updates.presentUpdate()
        case "fonts":
            print("fonts " + TermAppearance.debugFontSources())
            fflush(stdout)
        case "location":
            print("location mode=\(DataLocation.mode.rawValue) root=\(DataLocation.root.path) term=\(TermPaths.home.path)"
                  + " legacyDaemon=\(model.legacyDaemon) connected=\(model.connected) relocating=\(model.relocating)"
                  + " link=\(model.link.phase) limited=\(model.link.limited) failures=\(model.link.failures)"
                  + " migrationPending=\(model.migrationPending.map(\.path))"
                  + " panes=\(model.workspace.allPanes.count) dormant=\(model.workspace.dormant.count)")
            fflush(stdout)
        case "launch-options":
            // launch-options [<JSON>]: 새 세션 기본 옵션(JSON 을 주면 그것으로 바꾼다 — 설정 창에서 고친 것과 같음)
            if !argument.isEmpty, let options = try? JSONDecoder().decode(LaunchOptions.self, from: Data(argument.utf8)) {
                model.launch.options = options
            }
            print("launch-options claude=[\(model.launch.command(.claude))] codex=[\(model.launch.command(.codex))] file="
                  + LaunchSettings.url.path)
            fflush(stdout)
        case "launch":
            // launch <claude|codex> <폴더>: + claude·+ codex 에서 폴더를 고른 것과 같음
            let v = argument.split(separator: " ", maxSplits: 1).map(String.init)
            if v.count == 2, let kind = AgentKind(rawValue: v[0]) { model.newAgent(kind, cwd: v[1]) }
        case "settings":
            settingsWindow.show()
            if argument == "key" { NSApp.windows.first { $0.windowNumber == settingsWindow.windowNumber }?.makeKey() }
            print("settings window=\(settingsWindow.windowNumber ?? -1)")
            fflush(stdout)
        case "footer-settings":
            // 도크 상태 줄 "설정" 버튼을 누른 것과 같음
            print("footer-settings")
            model.openSettings()
            fflush(stdout)
        case "settings-snap":
            settingsWindow.snapshot(to: URL(fileURLWithPath: argument))
        case "hooks-state":
            print("hooks-state claude=\(model.hookState) codex=\(model.codexHookState)")
            fflush(stdout)
        case "appmenu":
            if let menu = NSApp.mainMenu?.items.first?.submenu {
                menu.update()
                print("appmenu: " + menu.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.isHidden ? "(숨김)" : $0.isEnabled ? "" : "(꺼짐)") }
                    .joined(separator: " / "))
                fflush(stdout)
            }
        default:
            if debugEditor(command: parts.first ?? "", argument: argument) { return }
            if model.spaces.debug(parts.first ?? "", argument, groups: model.groups) { return }
            debugTerminal(parts.first ?? "", argument)
        }
    }

    /// 편집기 시험 명령. 다루면 true.
    ///   open-path <절대 경로>[|tab|right|down] | editor-type <글>(\n=줄바꿈) | editor-save | editor-undo | editor-state
    ///   editor-select <줄>[:<열>] | editor-answer <save|discard|cancel> (다음 확인 창 대신) | editor-banner <reload|overwrite>
    ///   editor-find | editor-check-disk | editors(모든 문서)
    ///   Markdown 미리보기: editor-preview [on|off|toggle] | editor-preview-state | editor-preview-html <파일>
    ///   editor-preview-snap <png>(웹 화면 그림) | editor-preview-js <식>(앱 쪽 세계에서) | editor-preview-raw(거르지 않은 HTML)
    private func debugEditor(command: String, argument: String) -> Bool {
        let editor = model.host?.focusedEditor
        switch command {
        case "open-path":
            let v = argument.split(separator: "|").map(String.init)
            guard let path = v.first else { return true }
            switch v.count > 1 ? v[1] : "tab" {
            case "right": model.openFile(path, split: .horizontal)
            case "down": model.openFile(path, split: .vertical)
            default: model.openFile(path)
            }
        case "editor-type":
            let text = argument.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
            guard let textView = editor?.textView else { print("editor-type: 편집기 없음"); fflush(stdout); return true }
            for piece in text.components(separatedBy: "\n").enumerated() {
                if piece.offset > 0 { textView.insertNewline(nil) }
                if !piece.element.isEmpty { textView.insertText(piece.element, replacementRange: textView.selectedRange()) }
            }
        case "editor-save":
            print("editor-save ok=\(model.saveFocused())")
            fflush(stdout)
        case "editor-undo":
            let manager = editor?.document.undoManager
            if manager?.canUndo == true { manager?.undo() }
            print("editor-undo canUndo=\(manager?.canUndo ?? false)")
            fflush(stdout)
        case "editor-select":
            guard let editor, let textView = editor.textView else { return true }
            let v = argument.split(separator: ":").compactMap { Int($0) }
            let lines = editor.document.lines
            let line = min(max((v.first ?? 1) - 1, 0), lines.lineCount - 1)
            let location = min(lines.starts[line] + max((v.count > 1 ? v[1] : 1) - 1, 0), (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        case "editor-state":
            if let editor {
                let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
                print(editor.document.debugSummary + " cursor=\(editor.textView?.selectedRange().location ?? -1)"
                    + " firstResponder=\(responder) " + editor.debugGeometry)
            } else {
                print("editor-state: 지금 화면은 편집기가 아님 (\(model.selectedId ?? "-"))")
            }
            fflush(stdout)
        case "editors":
            let docs = model.editors.documents.values.sorted { $0.name < $1.name }
            for doc in docs { print(doc.debugSummary) }
            print("editors count=\(docs.count) loaded=\(docs.filter(\.isLoaded).count) visible=\(docs.filter(\.isVisible).count) "
                + "dirty=\(docs.filter(\.isDirty).count) layoutEditors=\(model.workspace.editors.count) "
                + "footprint=\(Memory.format(Memory.footprint()))")
            fflush(stdout)
        case "editor-answer":
            for word in argument.split(separator: " ") {
                if let answer = EditorManager.CloseAnswer(rawValue: String(word)) { model.editors.pendingAnswers.append(answer) }
            }
        case "editor-banner":
            editor?.debugBanner(argument)
        case "editor-snap":
            // editor-snap <png>: 편집기 화면만 그림으로(글 뷰·여백 따로 그려 합친다)
            guard let editor else { return true }
            if let rep = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) {
                editor.cacheDisplay(in: editor.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
            }
            if let text = editor.textView, let rep = text.bitmapImageRepForCachingDisplay(in: text.visibleRect) {
                text.cacheDisplay(in: text.visibleRect, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument + ".text.png"))
            }
        case "editor-find":
            editor?.textView?.finderAction(.showFindInterface)
        case "editor-preview":
            guard let editor else { return true }
            switch argument {
            case "on": editor.setPreview(true)
            case "off": editor.setPreview(false)
            default: editor.togglePreview()
            }
        case "editor-preview-state":
            let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
            print("editor-preview-state canPreview=\(editor?.canPreview ?? false) scroll=\(editor?.document.previewScroll ?? -1) "
                + "firstResponder=\(responder) " + (editor?.preview?.debugSummary ?? "preview=nil")
                + " footprint=\(Memory.format(Memory.footprint()))")
            fflush(stdout)
        case "editor-preview-html":
            editor?.preview?.debugDump(to: argument)
        case "editor-preview-snap":
            editor?.preview?.debugSnapshot(to: argument) { ok in
                print("editor-preview-snap ok=\(ok) \(argument)")
                fflush(stdout)
            }
        case "editor-preview-js":
            editor?.preview?.debugEvaluate(argument) { result in
                print("editor-preview-js \(result)")
                fflush(stdout)
            }
        case "editor-preview-raw":
            if let editor, let storage = editor.document.storage { editor.preview?.debugShowUnsanitized(markdown: storage.string) }
        case "editor-check-disk":
            editor?.document.checkDisk()
        default:
            return debugNavigation(command: command, argument: argument)
        }
        return true
    }

    /// 이동 시험 명령. 다루면 true.
    ///   goto [<줄>:<열>] | usages [<줄>:<열>] | symbol <찾을 글> | popup | popup-key <up|down|enter|esc>
    ///   cmd-click <줄>:<열> | cmd-hover <줄>:<열>(⌘ 누른 채 마우스 올림, 밑줄 확인) | nav-back | nav-forward | nav-state
    ///   index-state | index-build <루트>(색인 시간·메모리)
    private func debugNavigation(command: String, argument: String) -> Bool {
        guard let host = model.host else { return false }
        let navigator = host.navigator
        func select(_ spec: String) {
            guard !spec.isEmpty else { return }
            debugEditor(command: "editor-select", argument: spec)
        }
        func say(_ text: String) {
            print(text)
            fflush(stdout)
        }
        func point(_ spec: String) -> NSPoint? {
            guard let editor = host.focusedEditor, let textView = editor.textView, let window else { return nil }
            let v = spec.split(separator: ":").compactMap { Int($0) }
            let lines = editor.document.lines
            let line = min(max((v.first ?? 1) - 1, 0), lines.lineCount - 1)
            let location = lines.starts[line] + max((v.count > 1 ? v[1] : 1) - 1, 0)
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            let screen = textView.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
            let inWindow = window.convertFromScreen(screen)
            return NSPoint(x: inWindow.midX, y: inWindow.midY)
        }
        switch command {
        case "goto":
            select(argument)
            navigator.gotoDeclaration()
        case "usages":
            select(argument)
            navigator.findUsages()
        case "symbol":
            navigator.gotoSymbol()
            if let popup = navigator.popup, !argument.isEmpty {
                popup.field.stringValue = argument
                popup.onQuery?(argument)
            }
        case "switcher":
            host.sessionSwitcher.show()
            if let popup = host.sessionSwitcher.popup {
                popup.field.stringValue = argument
                popup.onQuery?(argument)
            }
        case "terminal-find":
            host.focusedTerminal?.findBar.show(query: argument)
            say(host.focusedTerminal?.findBar.debugSummary ?? "terminal-find none")
        case "main-key": window?.makeKey()
        case "pane-find-menu":
            for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                for item in menu.items where (item.representedObject as? String)?.hasPrefix("pane-find") == true {
                    say("pane-find-menu \(item.representedObject ?? "-") enabled=\(validateMenuItem(item)) mainKey=\(NSApp.keyWindow === window)")
                }
            }
        case "pane-find-menu-action":
            for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                if let item = menu.items.first(where: { $0.representedObject as? String == argument }) { menuAction(item) }
            }
        case "terminal-click":
            if let view = host.focusedTerminal?.view, let window = view.window {
                let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
        case "terminal-find-state":
            say(host.focusedTerminal?.findBar.debugSummary ?? "terminal-find none")
        case "terminal-find-case": host.focusedTerminal?.findBar.setCaseSensitive(argument == "on")
        case "terminal-find-close": host.focusedTerminal?.findBar.close()
        case "popup":
            say(host.sessionSwitcher.popup?.debugSummary ?? navigator.popup?.debugSummary ?? "popup none")
        case "popup-key":
            guard let window else { return true }
            let codes: [String: (UInt16, Int)] = ["down": (125, NSDownArrowFunctionKey), "up": (126, NSUpArrowFunctionKey),
                                                  "enter": (36, 13), "esc": (53, 27)]
            guard let (code, scalar) = codes[argument], let ch = UnicodeScalar(scalar).map(String.init) else { return true }
            let flags: NSEvent.ModifierFlags = code >= 125 ? [.function, .numericPad] : []
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) {
                NSApp.sendEvent(event)
            }
        case "cmd-click", "cmd-hover":
            guard let window, let at = point(argument) else { return true }
            let kinds: [NSEvent.EventType] = command == "cmd-click" ? [.leftMouseDown, .leftMouseUp] : [.mouseMoved]
            for kind in kinds {
                if let event = NSEvent.mouseEvent(with: kind, location: at, modifierFlags: .command,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseUp ? 0 : 1) {
                    if kind == .mouseMoved { host.focusedEditor?.textView?.mouseMoved(with: event) } else { NSApp.sendEvent(event) }
                }
            }
            if command == "cmd-hover" { say("cmd-hover link=\(host.focusedEditor?.textView?.debugLink ?? "-")") }
        case "nav-back":
            if let action = navigationKey(33) { perform(action) }
        case "nav-forward":
            if let action = navigationKey(30) { perform(action) }
        case "nav-state":
            let editor = host.focusedEditor
            let caret = editor?.textView?.selectedRange().location ?? -1
            var lineCol = "-"
            if let editor, caret >= 0 {
                let line = editor.document.lines.line(containing: caret)
                lineCol = "\(line + 1):\(caret - editor.document.lines.starts[line] + 1)"
            }
            say("nav-state file=\(editor.map { ($0.document.path as NSString).lastPathComponent } ?? "-") at=\(lineCol) "
                + "hint=\(editor?.debugHint ?? "-") lastHint=\(navigator.lastHint ?? "-") " + navigator.debugHistory
                + " resolution=\(navigator.lastResolution ?? "-")")
        case "index-state":
            say(navigator.debugIndexes.isEmpty ? "index none" : navigator.debugIndexes)
        case "index-build":
            navigator.debugBuild(root: argument) { say($0) }
        case "index-forget":
            navigator.store.forget(root: argument)
        default:
            return false
        }
        return true
    }

    /// 시험용: ⌘[ ⌘] 를 실제 단축키 규칙대로
    private func navigationKey(_ code: UInt16) -> String? {
        guard let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
        else { return nil }
        let action = navigationAction(for: event)
        return action == "none" ? nil : action
    }

    private func debugTerminal(_ command: String, _ argument: String) {
        switch command {
        case "collapse-all":
            toolWindows?.files.collapseAll()
        case "footprint":
            print("footprint app=\(Memory.format(Memory.footprint())) bytes=\(Memory.footprint())")
            fflush(stdout)
        case "type":
            model.host?.typeText(argument.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\r", with: "\r"))
        case "ime":
            var pieces = argument.split(separator: "|").map(String.init)
            guard let commit = pieces.popLast() else { return }
            model.host?.simulateIME(composing: pieces, commit: commit)
        case "mark":
            model.host?.debugMark(argument)
        case "shift-enter":
            // 실제 키 입력과 같은 경로(로컬 키 감시)로 Shift+Enter 를 넣는다
            if let window, let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36) {
                NSApp.sendEvent(event)
            }
        case "keys":
            // 실제 키 입력과 같은 경로(창 → keyDown → 입력기)로 글자를 하나씩 넣는다
            guard let window else { return }
            for ch in argument {
                let s = String(ch)
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                        isARepeat: false, keyCode: 0) {
                        NSApp.sendEvent(event)
                    }
                }
            }
        case "chord":
            // 단축키 시험: chord cmd+shift+[ (실제 키 입력처럼 앱에 보낸다)
            guard let window else { return }
            var flags: NSEvent.ModifierFlags = []
            var parts = argument.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            var key = parts.popLast() ?? ""
            if key.isEmpty, parts.last == "" { key = "+"; parts.removeLast() }
            for part in parts {
                switch part {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "opt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
            let names = ["left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey,
                         "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey]
            if let code = names[key] { key = String(UnicodeScalar(code)!); flags.insert([.function, .numericPad]) }
            if key == "enter" { key = "\r" }
            if key == "esc" { key = "\u{1b}" }
            if key == "f7" { key = String(UnicodeScalar(NSF7FunctionKey)!); flags.insert(.function) }
            let shifted = ["[": "{", "]": "}", "d": "D", "=": "+", "e": "E", "s": "S", "v": "V", "b": "B", "o": "O"]
            let chars = flags.contains(.shift) ? (shifted[key] ?? key) : key
            // 실제 키보드(US 배열)의 키 코드
            let codes: [String: UInt16] = ["\u{1b}": 53, "d": 2, "t": 17, "e": 14, "s": 1, "v": 9, "w": 13, "[": 33, "]": 30, "=": 24, "\r": 36,
                                           "j": 38, "ㅓ": 38, "k": 40, "ㅏ": 40, "p": 35, "ㅔ": 35, "f": 3, "ㄹ": 3, "g": 5, "ㅎ": 5, "b": 11, "o": 31, String(UnicodeScalar(NSF7FunctionKey)!): 98,
                                           "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "9": 25,
                                           String(UnicodeScalar(NSLeftArrowFunctionKey)!): 123,
                                           String(UnicodeScalar(NSRightArrowFunctionKey)!): 124,
                                           String(UnicodeScalar(NSDownArrowFunctionKey)!): 125,
                                           String(UnicodeScalar(NSUpArrowFunctionKey)!): 126]
            if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: codes[key] ?? 0) {
                NSApp.sendEvent(event)
            }
        case "browsers":
            // 브라우저 화면: 주인 화면 앞 4자·화면에 놓임·창이 보임·스트림 도는 중·받은 프레임 수
            for (id, view) in model.host?.browserViews ?? [:] {
                print("browser \(id.dropFirst(BrowserPane.prefix.count).prefix(4)) \(view.debugState)")
            }
            print("browsers end")
            fflush(stdout)
        case "tabs":
            // 탭 순서·분할 나무(화면 ID 앞 4자 — 편집기는 파일 이름, ~ = 미리보기, browser(주인) = 브라우저, * = 포커스, > = 고른 탭)
            func describe(_ node: SplitNode, _ focused: String) -> String {
                switch node {
                case .pane(let id):
                    let name = model.workspace.editors[id].map {
                        ($0.path as NSString).lastPathComponent + ($0.isPreview ? "~" : "")
                    } ?? model.workspace.browsers[id].map { "browser(" + $0.owner.prefix(4) + ")" } ?? String(id.prefix(4))
                    return name + (id == focused ? "*" : "")
                case .split(let axis, _, let first, let second):
                    return "(" + describe(first, focused) + (axis == .horizontal ? " | " : " / ") + describe(second, focused) + ")"
                }
            }
            for (index, tab) in model.workspace.tabs.enumerated() {
                print("tabs \(index == model.workspace.selectedIndex ? ">" : " ")\(index) \(tab.id.prefix(4)) \(describe(tab.root, tab.focused))"
                    + (tab.zoomed ? " zoomed" : ""))
            }
            print("tabs end")
            fflush(stdout)
        case "dragpoints":
            print(model.host?.debugDragPoints() ?? "")
            print("dragpoints end")
            fflush(stdout)
        case "mouse":
            // 끌기 단계별 시험: mouse <down|drag|up|right> <x> <y> (창 좌표, 아래가 0). 사이에 그림을 찍어 볼 수 있다.
            let v = argument.split(separator: " ").map(String.init)
            guard v.count == 3, let window, let x = Double(v[1]), let y = Double(v[2]) else { return }
            let kinds: [String: NSEvent.EventType] = ["down": .leftMouseDown, "drag": .leftMouseDragged, "up": .leftMouseUp,
                                                      "right": .rightMouseDown]
            guard let kind = kinds[v[0]], let event = NSEvent.mouseEvent(
                with: kind, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            if kind == .rightMouseDown {
                // 오른쪽 클릭 메뉴 항목만 출력(메뉴를 띄우면 시험이 멈춘다)
                let view = window.contentView?.hitTest(window.contentView!.convert(event.locationInWindow, from: nil))
                let titles = view?.menu(for: event)?.items.map(\.title) ?? []
                print("menu " + titles.joined(separator: " / "))
                fflush(stdout)
                return
            }
            window.sendEvent(event)
        case "menu-pick":
            // menu-pick <x> <y> <항목 제목>: 그 자리 오른쪽 클릭 메뉴 항목 실행
            let v = argument.split(separator: " ", maxSplits: 2).map(String.init)
            guard v.count == 3, let window, let content = window.contentView, let x = Double(v[0]), let y = Double(v[1]),
                  let event = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: NSPoint(x: x, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1),
                  let item = content.hitTest(content.convert(event.locationInWindow, from: nil))?.menu(for: event)?
                    .items.first(where: { $0.title == v[2] }), let action = item.action
            else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        case "views":
            // 창 맨 위 뷰 구조(무엇이 탭 줄을 덮는지)
            func dump(_ view: NSView, _ depth: Int) {
                guard depth < 7 else { return }
                let frame = view.convert(view.bounds, to: nil)
                print(String(repeating: "  ", count: depth) + "\(type(of: view)) \(frame) hidden=\(view.isHidden) alpha=\(view.alphaValue)")
                view.subviews.forEach { dump($0, depth + 1) }
            }
            if let frameView = window?.contentView?.superview { dump(frameView, 0) }
            fflush(stdout)
        case "drag":
            // 분할 틈 끌기 시험: drag <x1> <y1> <x2> <y2> (창 좌표, 아래가 0)
            guard let window else { return }
            let v = argument.split(separator: " ").compactMap { Double($0) }
            guard v.count == 4 else { return }
            func make(_ kind: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent? {
                NSEvent.mouseEvent(with: kind, location: NSPoint(x: x, y: y), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            // 끄는 동안의 이벤트를 먼저 줄 세워 두고 누름을 보낸다(끌기는 누름 안에서 다음 이벤트를 기다린다)
            for event in [make(.leftMouseDragged, (v[0] + v[2]) / 2, (v[1] + v[3]) / 2), make(.leftMouseDragged, v[2], v[3]),
                          make(.leftMouseUp, v[2], v[3])].compactMap({ $0 }) {
                NSApp.postEvent(event, atStart: false)
            }
            if let down = make(.leftMouseDown, v[0], v[1]) { window.sendEvent(down) }
            fflush(stdout)
        case "scroll":
            // 스크롤 시험: scroll <한 번에 픽셀> <횟수> (트랙패드처럼 정밀 값, 약 60Hz)
            let v = argument.split(separator: " ").compactMap { Int($0) }
            guard v.count == 2, let view = model.host?.focusedTerminal?.view else { return }
            var stats: [Double] = []
            var fullDraws = 0
            TerminalView.lineCacheHits = 0
            TerminalView.lineCacheMisses = 0
            TerminalView.drawTrace = { ms, rect in
                stats.append(ms)
                if rect.height >= view.bounds.height - 1 { fullDraws += 1 }
            }
            let started = Date()
            for i in 0..<v[1] {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 60) {
                    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(v[0]), wheel2: 0, wheel3: 0),
                          let event = NSEvent(cgEvent: cg) else { return }
                    view.scrollWheel(with: event)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(v[1]) / 60 + 0.5) {
                TerminalView.drawTrace = nil
                let sorted = stats.sorted()
                func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
                print(String(format: "scroll draws=%d(full %d) avg=%.2fms p50=%.2f p90=%.2f max=%.2f total=%.2fs cache hit=%d miss=%d",
                             stats.count, fullDraws,
                             stats.reduce(0, +) / Double(max(stats.count, 1)), pct(0.5), pct(0.9), sorted.last ?? 0,
                             Date().timeIntervalSince(started), TerminalView.lineCacheHits, TerminalView.lineCacheMisses))
                fflush(stdout)
            }
        case "snapshot":
            snapshotTimer?.fireDate = argument == "off" ? .distantFuture : .distantPast
        case "snapshot-now":
            if let dir = AgentDeckEnv.nonEmpty("SNAPSHOT") {
                snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("window.png"))
            }
        case "window-focus":
            guard let view = model.host?.focusedTerminal?.view else { return }
            NSApp.unhideWithoutActivation()
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(view)
        case "window-position":
            let values = argument.split(separator: " ").compactMap { Double($0) }
            if values.count == 2 { window?.setFrameOrigin(NSPoint(x: values[0], y: values[1])) }
        case "window-pin":
            window?.deminiaturize(nil)
            window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window?.level = .floating
            window?.orderFrontRegardless()
        case "window-hide":
            NSApp.hide(nil)
        case "terminal-grid":
            let values = argument.split(separator: " ").compactMap { Int($0) }
            guard values.count == 2, let window, let content = window.contentView,
                  let view = model.host?.focusedTerminal?.view else { return }
            let optimal = view.getOptimalFrameSize()
            let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: view.scrollerStyle)
            let cellWidth = (optimal.width - scroller) / CGFloat(view.terminal.cols)
            let cellHeight = optimal.height / CGFloat(view.terminal.rows)
            let target = NSSize(width: CGFloat(values[0]) * cellWidth + scroller + 0.1,
                                height: CGFloat(values[1]) * cellHeight + 0.1)
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.width >= target.width
                && $0.visibleFrame.height >= target.height + window.frame.height - content.bounds.height }) {
                window.setFrameOrigin(screen.visibleFrame.origin)
            }
            window.setContentSize(NSSize(width: content.bounds.width + target.width - view.bounds.width,
                                         height: content.bounds.height + target.height - view.bounds.height))
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.width >= window.frame.width
                && $0.visibleFrame.height >= window.frame.height }) ?? window.screen {
                let area = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: max(area.minX, min(window.frame.minX, area.maxX - window.frame.width)),
                                              y: max(area.minY, area.maxY - window.frame.height)))
            }
        case "screens":
            for screen in NSScreen.screens {
                print("screen frame=\(screen.frame) visible=\(screen.visibleFrame) scale=\(screen.backingScaleFactor)")
            }
            fflush(stdout)
        case "window-front":
            window?.orderFrontRegardless()
        case "window-back":
            window?.orderBack(nil)
        case "render-state":
            guard let view = model.host?.focusedTerminal?.view else { return }
            let caret = view.subviews.first { String(describing: type(of: $0)) == "CaretView" }
            print("render-state active=\(NSApp.isActive) ordered=\(window?.isVisible ?? false) mini=\(window?.isMiniaturized ?? false) activeSpace=\(window?.isOnActiveSpace ?? false) level=\(window?.level.rawValue ?? 0) window=\(String(describing: window?.frame)) hidden=\(NSApp.isHidden) visible=\(window?.occlusionState.contains(.visible) ?? false) key=\(window?.isKeyWindow ?? false) focus=\(view.hasFocus) frame=\(view.bounds) cells=\(view.terminal.cols)x\(view.terminal.rows) font=\(view.font.pointSize) cursor=\(view.terminal.options.cursorStyle) caretAnimations=\(caret?.layer?.animationKeys() ?? []) snapshotNext=\(String(describing: snapshotTimer?.fireDate))")
            fflush(stdout)
        case "window-size":
            let size = argument.split(separator: " ").compactMap { Double($0) }
            if size.count == 2 { window?.setContentSize(NSSize(width: size[0], height: size[1])) }
        case "metal-snapshot":
            guard let view = model.host?.focusedTerminal?.view,
                  let metal = view.subviews.first(where: { $0 is MTKView }) as? MTKView,
                  let dir = AgentDeckEnv.nonEmpty("SNAPSHOT"), let device = metal.device else { return }
            // 진단용으로 잠시 끈 framebufferOnly 는 어느 경로로 끝나도 원래 값으로 돌린다.
            let framebufferOnly = metal.framebufferOnly
            var handedOff = false
            defer { if !handedOff { metal.framebufferOnly = framebufferOnly } }
            metal.framebufferOnly = false
            metal.releaseDrawables()
            guard let drawable = metal.currentDrawable else { return }
            handedOff = true
            let texture = drawable.texture
            drawable.addPresentedHandler { _ in
                defer { DispatchQueue.main.async { metal.framebufferOnly = framebufferOnly } }
                let rowBytes = (texture.width * 4 + 255) & ~255
                guard let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(),
                      let buffer = device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared),
                      let blit = command.makeBlitCommandEncoder() else { return }
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                          to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                          destinationBytesPerImage: rowBytes * texture.height)
                blit.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                let data = Data(bytes: buffer.contents(), count: rowBytes * texture.height)
                DispatchQueue.main.async {
                    guard let provider = CGDataProvider(data: data as CFData),
                          let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8,
                                              bitsPerPixel: 32, bytesPerRow: rowBytes,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                    else { return }
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("metal.png")
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                    print("metal-snapshot \(url.path)")
                    fflush(stdout)
                }
            }
            view.drawMetalFrameNow()
        case "terminal-select":
            guard let view = model.host?.focusedTerminal?.view, let row = Int(argument) else { return }
            view.selection.select(row: view.terminal.buffer.yDisp + row)
            print("terminal-select \(view.selection.debugDescription)")
            fflush(stdout)
        case "renderer-stats":
            guard let view = model.host?.focusedTerminal?.view else { return }
            let gpu = (view.subviews.first { $0 is MTKView } as? MTKView)?.device?.currentAllocatedSize ?? 0
            let caretHidden = view.subviews.first { String(describing: type(of: $0)) == "CaretView" }?.isHidden
            print("renderer-stats metal=\(view.isUsingMetalRenderer) gpuAllocatedBytes=\(gpu) caretHidden=\(String(describing: caretHidden)) status=\(view.metalRendererStatus)")
            fflush(stdout)
        case "renderer":
            guard let view = model.host?.focusedTerminal?.view else { return }
            do {
                try view.setUseMetal(argument == "metal")
                print("renderer metal=\(view.isUsingMetalRenderer) status=\(view.metalRendererStatus)")
            } catch { print("renderer error=\(error)") }
            fflush(stdout)
        case "drawstats":
            // drawstats <초>: 그 시간 동안 그리기 시간 통계(출력만으로 그려지는 경우 측정)
            let seconds = Double(argument) ?? 3
            var stats: [Double] = []
            var fullDraws = 0
            let height = model.host?.focusedTerminal?.view.bounds.height ?? 0
            TerminalView.lineCacheHits = 0
            TerminalView.lineCacheMisses = 0
            TerminalView.drawTrace = { ms, rect in
                stats.append(ms)
                if rect.height >= height - 1 { fullDraws += 1 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                TerminalView.drawTrace = nil
                let sorted = stats.sorted()
                func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
                print(String(format: "drawstats draws=%d(full %d) avg=%.2fms p50=%.2f p90=%.2f max=%.2f cache hit=%d miss=%d", stats.count, fullDraws,
                             stats.reduce(0, +) / Double(max(stats.count, 1)), pct(0.5), pct(0.9), sorted.last ?? 0,
                             TerminalView.lineCacheHits, TerminalView.lineCacheMisses))
                fflush(stdout)
            }
        case "verify-cache":
            if let view = model.host?.focusedTerminal?.view {
                let r = view.verifyLineCache()
                print("verify-cache same=\(r.same) different=\(r.different) cached=\(r.cached)")
                fflush(stdout)
            }
        case "rows":
            for row in model.rows {
                print("row \(row.id.prefix(4)) name=\(row.name) program=\(row.program) session=\(row.codex?.id.prefix(8) ?? row.session?.sessionId.prefix(8) ?? "-") fg=\(row.pane.foreground ?? "-") cwd=\(row.folder) status=\(row.status.debugName) seq=\(row.statusSeq.map(String.init) ?? "-")"
                      + " args=\((row.isCodex ? row.codexArgs : row.claudeArgs)?.joined(separator: " ") ?? "-") warn=\(row.launchWarning ?? "-")")
            }
            fflush(stdout)
        case "snap-panes":
            model.host?.snapshotPanes(in: URL(fileURLWithPath: argument))
        case "cursor":
            model.host?.debugCursor()
        case "screen":
            // 지금 화면 터미널의 보이는 줄을 글로(끝 공백 뺌) + 대체 화면 여부
            guard let pane = model.host?.focusedTerminal else {
                print("screen: 화면 없음")
                fflush(stdout)
                return
            }
            let terminal = pane.view.getTerminal()
            print("screen \(pane.id) \(terminal.cols)x\(terminal.rows) alt=\(terminal.isCurrentBufferAlternate) "
                + "altUnknown=\(terminal.altScreenStateUnknown)")
            for row in 0..<terminal.rows {
                let text = terminal.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? ""
                print(String(format: "%3d|", row) + text)
            }
            print("screen end")
            fflush(stdout)
        case "close-window":
            window?.performClose(nil)
        default:
            break
        }
    }

    private func snapshot(to url: URL) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
        // 창 그림에는 터미널 배경이 빠지므로 터미널만 따로 실제 색으로 남긴다
        model.host?.snapshotTerminal(to: url.deletingLastPathComponent().appendingPathComponent("terminal.png"))
        model.host?.snapshotTabBar(to: url.deletingLastPathComponent().appendingPathComponent("tabbar.png"))
    }


}

struct ShortcutKey: Hashable {
    let keyCode: UInt16
    let modifiers: UInt

    init(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .shift, .option, .control]).rawValue
    }
}
