import AppKit
import SessionCore
import SwiftTerm
import SwiftUI
import TermLayout
import TermWire

// 내장 터미널 시제품: 왼쪽 세션 목록 + 오른쪽 터미널. 셸·claude 는 데몬(ClaudeTermDaemon)이 붙잡고 있다.

// Claude 세션 안에서 띄워도 그 세션 표시 변수가 데몬·셸로 넘어가지 않게(대화 저장이 꺼지는 문제)
InheritedEnvironment.reexecIfNeeded(executablePath: Bundle.main.executablePath)
signal(SIGPIPE, SIG_IGN)

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
    var snapshotTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let host = TerminalHostController(model: model)
        model.host = host

        // [왼쪽 도크 | 터미널 | 오른쪽 도크]. 도구(spaces·files)는 IntelliJ 처럼 양옆에 붙이거나 숨긴다(ToolWindows.swift).
        // 도크는 반투명 재질 없이 앱 색으로(herdr 처럼 터미널과 한 덩어리로 보이게)
        let tools = ToolWindowsController(model: model, host: host)
        toolWindows = tools

        let window = NSWindow(contentViewController: tools.split)
        window.title = "Claude Term (시제품)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = TermAppearance.chrome
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.setFrameAutosaveName("ClaudeTermMain")
        window.delegate = self
        tools.restoreWidths()
        self.window = window
        // 시험용: CLAUDE_TERM_NO_ACTIVATE=1 이면 앞으로 나오지 않는다(사용 중인 다른 앱의 포커스를 뺏지 않게 창을 뒤에 둔다)
        if ProcessInfo.processInfo.environment["CLAUDE_TERM_NO_ACTIVATE"] == "1" {
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
        default:
            return true
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Claude Term 종료(세션은 유지)", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // 파일(편집기): 저장 ⌘S — 편집기 화면일 때만 켜진다
        let file = NSMenu(title: "파일")
        addAction(file, "저장", "save", "s")
        addSubmenu(main, file)

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "편집")
        // 되돌리기·잘라내기·찾기는 편집기에서만 응답한다(터미널에선 꺼져 키가 그대로 터미널로 간다)
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "찾기…", action: #selector(EditorTextView.editorFind(_:)), keyEquivalent: "f")
        let replace = edit.addItem(withTitle: "바꾸기…", action: #selector(EditorTextView.editorReplace(_:)), keyEquivalent: "f")
        replace.keyEquivalentModifierMask = [.command, .option]
        edit.addItem(withTitle: "다음 찾기", action: #selector(EditorTextView.editorFindNext(_:)), keyEquivalent: "g")
        let previous = edit.addItem(withTitle: "이전 찾기", action: #selector(EditorTextView.editorFindPrevious(_:)), keyEquivalent: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
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
        shell.addItem(.separator())
        addAction(shell, "화면 닫기", "close", "w")
        addAction(shell, "탭 닫기", "close-tab", "w", [.command, .option])
        shell.addItem(.separator())
        addAction(shell, "이름 바꾸기…", "rename", "")
        addSubmenu(main, shell)

        // 이동(IntelliJ 식). ⌘[ ⌘] 는 편집기 화면에서만 뒤로·앞으로(터미널에선 이전·다음 화면)
        let navigate = NSMenu(title: "이동")
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
            ShortcutKey(17, .command): "new-tab",
            ShortcutKey(2, .command): "split-right",
            ShortcutKey(2, [.command, .shift]): "split-down",
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
        ]
        for (code, direction) in [(123, "left"), (124, "right"), (125, "down"), (126, "up")] as [(UInt16, String)] {
            map[ShortcutKey(code, [.command, .option])] = "focus:\(direction)"
            map[ShortcutKey(code, [.command, .control])] = "resize:\(direction)"
        }
        for (number, code) in zip(1...9, [18, 19, 20, 21, 23, 22, 26, 28, 25] as [UInt16]) {
            map[ShortcutKey(code, .command)] = "tab:\(number)"
        }
        return map
    }()

    private func startShortcuts() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
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
        if action.hasPrefix("font:") {
            TermAppearance.adjustFontSize(String(action.dropFirst(5)))
        } else if action.hasPrefix("tool-") {
            toolWindows?.perform(action)
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
        if let action = sender.representedObject as? String { perform(action) }
    }

    // MARK: - 시험용(CLAUDE_TERM_SNAPSHOT 또는 CLAUDE_TERM_DEBUG 가 있을 때만)

    /// CLAUDE_TERM_SNAPSHOT=<폴더> 면 1초마다 창 그림을 <폴더>/window.png 로 남긴다(화면 기록 권한 없이 확인용. 메모리를 더 쓴다).
    /// 둘 중 하나라도 있으면 분산 알림 "dev.claude-sessions.term.debug" 로 받은 명령을 실행한다.
    ///   select <화면 ID> | action <메뉴 동작 이름> | type <글자> | keys <글자> | ime <조합1>|<조합2>|…|<확정> | screen | close-window
    ///   도구 창: tool <files|spaces>(토글) | dock <도구> <left|right|hidden> | tool-select <도구> | uilayout | toolmenu <도구>
    ///   files: filesroot | expand <상대 경로> | collapse-all | open-file <상대 경로> | filesmenu <상대 경로>[|<항목>] | footprint
    private func startDebugHooks() {
        let env = ProcessInfo.processInfo.environment
        let snapshotDir = env["CLAUDE_TERM_SNAPSHOT"].flatMap { $0.isEmpty ? nil : $0 }
        guard snapshotDir != nil || env["CLAUDE_TERM_DEBUG"] == "1" else { return }
        if let snapshotDir {
            let url = URL(fileURLWithPath: snapshotDir).appendingPathComponent("window.png")
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.snapshot(to: url) }
            RunLoop.main.add(timer, forMode: .common)
            snapshotTimer = timer
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.claude-sessions.term.debug"), object: nil, queue: .main
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
        default:
            if !debugEditor(command: parts.first ?? "", argument: argument) { debugTerminal(parts.first ?? "", argument) }
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
        case "popup":
            say(navigator.popup?.debugSummary ?? "popup none")
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
            if key == "f7" { key = String(UnicodeScalar(NSF7FunctionKey)!); flags.insert(.function) }
            let shifted = ["[": "{", "]": "}", "d": "D", "=": "+", "e": "E", "s": "S", "v": "V", "b": "B", "o": "O"]
            let chars = flags.contains(.shift) ? (shifted[key] ?? key) : key
            // 실제 키보드(US 배열)의 키 코드
            let codes: [String: UInt16] = ["d": 2, "t": 17, "e": 14, "s": 1, "v": 9, "w": 13, "[": 33, "]": 30, "=": 24, "\r": 36,
                                           "b": 11, "o": 31, String(UnicodeScalar(NSF7FunctionKey)!): 98,
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
        case "drawstats":
            // drawstats <초>: 그 시간 동안 그리기 시간 통계(출력만으로 그려지는 경우 측정)
            let seconds = Double(argument) ?? 3
            var stats: [Double] = []
            TerminalView.lineCacheHits = 0
            TerminalView.lineCacheMisses = 0
            TerminalView.drawTrace = { ms, _ in stats.append(ms) }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                TerminalView.drawTrace = nil
                let sorted = stats.sorted()
                func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
                print(String(format: "drawstats draws=%d avg=%.2fms p50=%.2f p90=%.2f max=%.2f cache hit=%d miss=%d", stats.count,
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
                print("row \(row.id.prefix(4)) name=\(row.name) program=\(row.program) session=\(row.codex?.id.prefix(8) ?? row.session?.sessionId.prefix(8) ?? "-") fg=\(row.pane.foreground ?? "-") cwd=\(row.folder) status=\(row.status.debugName) seq=\(row.statusSeq.map(String.init) ?? "-")")
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
