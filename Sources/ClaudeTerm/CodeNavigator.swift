import AppKit
import EditorCore
import TermLayout
import TermWire

/// 편집기 이동(IntelliJ 식, LSP 없이 이름 단위로 가볍게):
/// ⌘B·⌘클릭 = 선언으로(선언 위면 사용 위치), ⌥F7 = 사용 위치, ⌘O = 심볼로, ⌘[ ⌘] = 뒤로·앞으로(편집기 화면에서).
/// 후보 순서: 같은 파일 → 가져온(import) 것 → 같은 패키지 → 같은 폴더 → 가까운 모듈 → 나머지.
final class CodeNavigator {
    struct Location: Equatable {
        var path: String
        var offset: Int
    }

    /// 건너뛸 곳(줄은 0부터, 열은 UTF-16 — 모르면 이름으로 줄에서 찾는다)
    struct Target {
        var path: String
        var line: Int
        var column: Int?
        var name: String?
    }

    private unowned let host: TerminalHostController
    private var model: TermModel { host.model }
    let store = IndexStore()
    private(set) var history = NavigationHistory<Location>()
    private(set) var popup: NavigatorPopupView?
    private var popupTargets: [Target] = []
    private var popupAnchoredTop = false
    private var mouseMonitor: Any?
    /// 시험용: 마지막 안내 글
    private(set) var lastHint: String?
    /// 시험용: 마지막 받는 쪽 타입 풀이
    private(set) var lastResolution: String?
    /// 이동 요청 번호: 새 요청(⌘B·⌥F7·⌘O·뒤로·앞으로)과 목록 창 닫기마다 오른다. 늦게 온 옛 결과(백그라운드 찾기)는 버린다.
    private(set) var request = 0

    private func newRequest() -> Int {
        request += 1
        return request
    }

    init(host: TerminalHostController) {
        self.host = host
        NotificationCenter.default.addObserver(forName: EditorDocument.didSave, object: nil, queue: .main) { [weak self] note in
            guard let self, let document = note.object as? EditorDocument else { return }
            for index in self.store.existing(containing: document.path) { index.fileSaved(document.path) }
        }
    }

    // MARK: - 지금 편집기

    private struct Caret {
        var editor: EditorPaneView
        var textView: EditorTextView
        var language: SyntaxLanguage
        var text: String
        var name: String
        var range: NSRange
        var line: Int
        var column: Int
    }

    /// 지금 편집기 커서(또는 location) 아래 이름. 없으면 안내를 띄우고 nil.
    private func caret(at location: Int? = nil, action: String) -> Caret? {
        guard let editor = host.focusedEditor, editor.preview == nil, let textView = editor.textView else { return nil }
        guard let language = editor.document.language, SymbolLanguages.supported.contains(language) else {
            hint(editor, "이 파일 형식은 \(action)를 지원하지 않습니다")
            return nil
        }
        let text = textView.string
        let ns = text as NSString
        let at = location ?? textView.selectedRange().location
        guard let range = Identifier.range(in: ns, at: at, language: language) else {
            hint(editor, "이름 위에서 눌러 주세요")
            return nil
        }
        let lines = editor.document.lines
        let line = lines.line(containing: range.location)
        return Caret(editor: editor, textView: textView, language: language, text: text, name: ns.substring(with: range),
                     range: range, line: line, column: range.location - lines.starts[line])
    }

    @discardableResult
    private func hint(_ editor: EditorPaneView?, _ text: String, sticky: Bool = false) -> Int? {
        lastHint = text
        return editor?.showHint(text, sticky: sticky)
    }

    private func currentLocation() -> Location? {
        guard let editor = host.focusedEditor else { return nil }
        let offset = editor.textView?.selectedRange().location ?? editor.document.cursor
        return Location(path: editor.document.path, offset: offset)
    }

    private func project(for path: String) -> ProjectIndex? {
        let root = IndexStore.root(forFile: path)
        guard !IndexStore.isTooBroad(root.path) else { return nil }
        return store.index(root: root.path, isGit: root.isGit)
    }

    /// 지금 화면(편집기·터미널)의 프로젝트 — files 도구와 같은 규칙
    private func focusedProject() -> ProjectIndex? {
        if let editor = host.focusedEditor { return project(for: editor.document.path) }
        guard let row = model.focusedRow else { return nil }
        let root = row.git.map { ($0.worktreeRoot, true) } ?? ((row.cwd as NSString).standardizingPath, false)
        guard !IndexStore.isTooBroad(root.0) else { return nil }
        return store.index(root: root.0, isGit: root.1)
    }

    // MARK: - ⌘B 선언으로

    /// location: ⌘클릭한 곳(없으면 커서)
    func gotoDeclaration(at location: Int? = nil) {
        closePopup(restoreFocus: false)
        let generation = newRequest()
        guard let caret = caret(at: location, action: "선언 찾기") else { return }
        if let location { caret.textView.setSelectedRange(NSRange(location: location, length: 0)) }
        let editor = caret.editor
        let path = editor.document.path
        let name = caret.name
        let live = SymbolScanner.scan(caret.text, language: caret.language, includeLocals: true)

        // 선언 위에서 누르면 사용 위치(IntelliJ 와 같게)
        let lineText = Self.line(caret.text as NSString, editor.document.lines, caret.line)
        if live.contains(where: { $0.name == name && $0.line == caret.line }),
           Identifier.firstWholeWord(name, in: lineText, language: caret.language) == caret.column {
            findUsages(caret, generation: generation)
            return
        }
        let qualified = Identifier.isQualified(caret.text as NSString, range: caret.range)
        // obj.name: obj 의 타입을 같은 파일 선언에서 어림(userService: UserService → UserService 의 멤버 먼저)
        let receiverType = qualified ? Identifier.receiver(caret.text as NSString, range: caret.range)
            .flatMap { Identifier.receiverType($0, in: caret.text, language: caret.language) } : nil
        // 받는 쪽 없는 참조: 이 자리를 감싼 블록 안, 위쪽에 선언된 가장 가까운 지역 선언이 먼저(다른 함수의 같은 이름 지역은 아님)
        if !qualified, let local = LocalScope.nearest(live, name: name, line: caret.line) {
            jump(Target(path: path, line: local.line, column: nil, name: name))
            return
        }
        // 지역 선언(보이지 않는 곳의 것 포함)은 후보에서 뺀다 — 멤버·최상위만
        let sameFile = live.filter { $0.name == name && $0.scope == nil }.map {
            NavigationCandidate(path: path, line: $0.line, kind: $0.kind, name: name, container: $0.container)
        }
        let imports = ImportHints.parse(caret.text, language: caret.language, directory: (path as NSString).deletingLastPathComponent)
        guard let index = project(for: path) else {
            resolveReceiver(name, sameFile, from: path, text: caret.text, imports: imports, qualified: qualified,
                            receiverType: receiverType, editor: editor, root: nil, generation: generation)
            return
        }
        if !index.isReady {
            if !qualified, sameFile.count == 1 {
                jump(Target(path: path, line: sameFile[0].line, column: nil, name: name))
                hint(host.focusedEditor, "색인 중… 이 파일 안에서 찾았습니다")
                index.whenReady {}
                return
            }
        }
        let waiting = index.isReady ? nil : hint(editor, "색인 중… (\(index.name))", sticky: true)
        let document = editor.document
        let started = caret.textView.selectedRange()
        index.whenReady { [weak self] in
            index.lookup(name) { hits in
                editor.hideHint(waiting)
                guard let self, self.request == generation else { return }
                // 그사이 다른 화면으로 옮겼거나 커서를 옮겼으면 그만둔다
                guard let now = self.host.focusedEditor, now.document === document,
                      now.textView?.selectedRange() == started else { return }
                let others = hits.map {
                    NavigationCandidate(path: index.absolute($0.path), line: $0.line, kind: $0.kind, name: $0.name, container: $0.container)
                }.filter { $0.path != path }
                self.resolveReceiver(name, sameFile + others, from: path, text: caret.text, imports: imports, qualified: qualified,
                                     receiverType: receiverType, editor: editor, root: index.root, generation: generation)
            }
        }
    }

    /// obj.name 이고 obj 의 타입을 어림했으면: 그 타입의 패키지(명시 import → 그 패키지, 아니면 같은 패키지·별표 import)를 정하고,
    /// 후보 파일의 package 줄을 읽어 그 클래스의 멤버만 남긴다. 맞는 것이 없으면 이름 전체 후보로 돌아간다.
    private func resolveReceiver(_ name: String, _ candidates: [NavigationCandidate], from path: String, text: String,
                                 imports: [ImportHint], qualified: Bool, receiverType: String?, editor: EditorPaneView, root: String?,
                                 generation: Int) {
        let fallback = { [weak self] (list: [NavigationCandidate]) in
            self?.resolve(name, list, from: path, imports: imports, qualified: qualified, receiverType: receiverType, editor: editor,
                          root: root, generation: generation)
        }
        guard let receiverType else { fallback(candidates); return }
        let relevant = candidates.filter {
            $0.container == receiverType || ((($0.path as NSString).lastPathComponent as NSString).deletingPathExtension == receiverType)
        }
        guard !relevant.isEmpty else { fallback(candidates); return }
        let allowed = CandidateRanker.allowedPackages(for: receiverType, imports: imports, currentPackage: PackageInfo.parse(text))
        Self.readPackages(Set(relevant.map(\.path)), current: (path, text)) { [weak self] packages in
            guard let self, self.request == generation, self.host.focusedEditor === editor else { return }
            self.lastResolution = "receiver=\(receiverType) allowed=\(allowed.sorted()) "
                + "packages=\(packages.map { "\(($0.key as NSString).lastPathComponent):\($0.value)" }.sorted())"
            let restricted = CandidateRanker.restrict(candidates, receiverType: receiverType, allowed: allowed, packages: packages)
            fallback(restricted.isEmpty ? candidates : restricted)
        }
    }

    /// 후보 파일의 package 줄(앞 8KB 만 읽는다). 지금 파일은 편집 중인 글에서.
    static func readPackages(_ paths: Set<String>, current: (path: String, text: String),
                             _ completion: @escaping ([String: String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [String: String] = [:]
            for path in paths {
                let text: String?
                if path == current.path {
                    text = current.text
                } else if let handle = FileHandle(forReadingAtPath: path) {
                    text = String(decoding: handle.readData(ofLength: 8_192), as: UTF8.self)
                    try? handle.close()
                } else {
                    text = nil
                }
                if let text, let package = PackageInfo.parse(text) { result[path] = package }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func resolve(_ name: String, _ candidates: [NavigationCandidate], from path: String, imports: [ImportHint],
                         qualified: Bool, receiverType: String?, editor: EditorPaneView, root: String?, generation: Int) {
        guard !candidates.isEmpty else {
            hint(editor, "‘\(name)’ 의 선언을 찾지 못했습니다")
            return
        }
        let ranked = CandidateRanker.rank(candidates, from: path, name: name, imports: imports, receiverType: receiverType)
        if let one = CandidateRanker.decisive(ranked, qualified: qualified, receiverType: receiverType) {
            jump(Target(path: one.path, line: one.line, column: nil, name: name))
            return
        }
        let shown = Array(ranked.prefix(200))
        let editorText = editor.textView?.string
        let wanted = shown.map { ($0.candidate.path, $0.candidate.line) }
        Self.readLines(wanted, current: (path, editorText)) { [weak self] lines in
            guard let self, self.request == generation, self.host.focusedEditor === editor else { return }
            let rows = shown.map { item -> NavigatorRow in
                let c = item.candidate
                let snippet = lines["\(c.path):\(c.line)"] ?? ""
                var detail = "\(self.display(c.path, root: root)):\(c.line + 1)  ·  \(c.kind.label)"
                if let container = c.container, c.kind != .constructor { detail += " · \(container)" }
                return NavigatorRow(badge: c.kind.badge, badgeColor: c.kind.badgeColor,
                                    title: Self.snippet(snippet, highlight: name, column: nil), detail: detail,
                                    tag: item.tier == .sameFile ? "이 파일" : item.tier == .imported ? "import" : nil)
            }
            let popup = NavigatorPopupView(title: "‘\(name)’ 선언 고르기", searchable: false)
            popup.setStatus("\(ranked.count)개")
            self.present(popup, rows: rows, targets: shown.map { Target(path: $0.candidate.path, line: $0.candidate.line, column: nil, name: name) },
                         anchor: editor.caretRect(in: self.host.view))
        }
    }

    // MARK: - ⌥F7 사용 위치

    func findUsages() {
        closePopup(restoreFocus: false)
        let generation = newRequest()
        guard let caret = caret(action: "사용 위치 찾기") else { return }
        findUsages(caret, generation: generation)
    }

    private func findUsages(_ caret: Caret, generation: Int) {
        let editor = caret.editor
        let path = editor.document.path
        let name = caret.name
        guard let index = project(for: path) else {
            hint(editor, "프로젝트 폴더가 아니라 찾지 않습니다")
            return
        }
        let searching = hint(editor, index.isReady ? "‘\(name)’ 사용 위치 찾는 중…" : "색인 중… (\(index.name))", sticky: true)
        let live = SymbolScanner.scan(caret.text, language: caret.language, includeLocals: true)
        let text = caret.text
        let anchor = { [weak editor, weak self] () -> NSRect? in
            guard let self else { return nil }
            return editor?.caretRect(in: self.host.view)
        }
        index.whenReady { [weak self] in
            index.lookup(name) { declarations in
                index.usages(name, current: (path, text)) { hits, capped, seconds in
                    editor.hideHint(searching)
                    // 그사이 다른 이동(⌘O 등)을 했거나 창을 닫았으면 옛 결과로 덮지 않는다
                    guard let self, self.request == generation, self.host.focusedEditor === editor else { return }
                    let rel = index.relative(path) ?? (path as NSString).lastPathComponent
                    var declared = Set(declarations.map { "\($0.path):\($0.line)" })
                    declared.subtract(declarations.filter { $0.path == rel }.map { "\($0.path):\($0.line)" })
                    for d in live where d.name == name { declared.insert("\(rel):\(d.line)") }
                    // 선언 줄의 첫 통째 이름만 선언(같은 줄의 호출은 사용)
                    func isDeclaration(_ hit: ProjectIndex.UsageHit) -> Bool {
                        declared.contains("\(hit.path):\(hit.usage.line)")
                            && Identifier.firstWholeWord(name, in: hit.usage.text, language: SymbolLanguages.language(path: hit.path)) == hit.usage.column
                    }
                    let usageCount = hits.filter { !isDeclaration($0) }.count
                    if usageCount == 0 {
                        self.hint(editor, "‘\(name)’ 의 사용 위치가 없습니다")
                        return
                    }
                    let rows = hits.map { hit -> NavigatorRow in
                        NavigatorRow(badge: nil, title: Self.snippet(hit.usage.text, highlight: name, column: hit.usage.column),
                                     detail: "\(hit.path):\(hit.usage.line + 1)",
                                     tag: isDeclaration(hit) ? "선언" : (hit.path == rel ? "이 파일" : nil))
                    }
                    let popup = NavigatorPopupView(title: "‘\(name)’ 사용 위치", searchable: false)
                    let files = Set(hits.map(\.path)).count
                    popup.setStatus((capped ? "\(hits.count)개+ (처음 \(ProjectIndex.maxUsages)개)" : "\(usageCount)곳")
                        + " · 파일 \(files)개 · \(Int(seconds * 1000))ms")
                    self.present(popup, rows: rows, targets: hits.map {
                        Target(path: $0.path == rel ? path : index.absolute($0.path),
                               line: $0.usage.line, column: $0.usage.column, name: name)
                    }, anchor: anchor())
                }
            }
        }
    }

    // MARK: - ⌘O 심볼로

    func gotoSymbol() {
        closePopup(restoreFocus: false)
        _ = newRequest()
        guard let index = focusedProject() else {
            let popup = NavigatorPopupView(title: "심볼로 이동", searchable: true)
            present(popup, rows: [], targets: [], anchor: nil, empty: "프로젝트 폴더(git 저장소)의 화면에서 쓸 수 있습니다")
            return
        }
        let popup = NavigatorPopupView(title: "심볼로 이동 · \(index.name)", searchable: true,
                                       placeholder: "클래스·함수 이름 — 낙타 혹: UsrSvc → UserService")
        popup.onQuery = { [weak self, weak popup] query in
            guard let self, let popup else { return }
            self.querySymbols(query, index: index, popup: popup)
        }
        present(popup, rows: [], targets: [], anchor: nil, empty: "이름을 입력하세요")
        updateSymbolStatus(index, popup)
        index.whenReady { [weak self, weak popup] in
            guard let self, let popup, self.popup === popup else { return }
            self.updateSymbolStatus(index, popup)
            if !popup.field.stringValue.isEmpty { self.querySymbols(popup.field.stringValue, index: index, popup: popup) }
        }
    }

    private func updateSymbolStatus(_ index: ProjectIndex, _ popup: NavigatorPopupView) {
        if index.isReady {
            popup.setStatus("파일 \(Self.count(index.stats.files)) · 선언 \(Self.count(index.stats.symbols))")
        } else {
            popup.setStatus("색인 중…")
        }
    }

    private func querySymbols(_ query: String, index: ProjectIndex, popup: NavigatorPopupView) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            setRows(popup, [], targets: [], empty: "이름을 입력하세요")
            return
        }
        guard index.isReady else { return } // 다 만들면 whenReady 가 다시 찾는다
        index.search(query) { [weak self, weak popup] results in
            guard let self, let popup, self.popup === popup, popup.field.stringValue == query else { return }
            let rows = results.map { item -> NavigatorRow in
                let hit = item.hit
                let title = NSMutableAttributedString()
                let base: [NSAttributedString.Key: Any] = [.font: EditorStyle.font, .foregroundColor: TermAppearance.textPrimary]
                let name = NSMutableAttributedString(string: hit.name, attributes: base)
                let matched = Set(item.matched)
                // 맞춘 글자 강조(UTF-8 위치 — 이름은 대개 ASCII 라 글자 위치와 같다)
                if hit.name.utf8.count == hit.name.utf16.count {
                    for i in matched where i < name.length {
                        name.addAttributes([.foregroundColor: TermAppearance.accent, .font: Self.boldCode], range: NSRange(location: i, length: 1))
                    }
                }
                title.append(name)
                if let container = hit.container {
                    title.append(NSAttributedString(string: "  " + container, attributes: [
                        .font: TermAppearance.uiFont(max(EditorStyle.font.pointSize - 2, 9)), .foregroundColor: TermAppearance.textDim,
                    ]))
                }
                return NavigatorRow(badge: hit.kind.badge, badgeColor: hit.kind.badgeColor, title: title,
                                    detail: "\(hit.path):\(hit.line + 1)  ·  \(hit.kind.label)")
            }
            popup.setStatus(results.isEmpty ? "없음" : "\(results.count)\(results.count >= 200 ? "+" : "")개")
            self.setRows(popup, rows, targets: results.map { Target(path: index.absolute($0.hit.path), line: $0.hit.line, column: nil, name: $0.hit.name) },
                         empty: "‘\(query)’ 와 맞는 선언이 없습니다")
        }
    }

    // MARK: - 뒤로·앞으로

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    func back() {
        _ = newRequest()
        guard let target = history.goBack(from: currentLocation()) else { return }
        open(target)
    }

    func forward() {
        _ = newRequest()
        guard let target = history.goForward(from: currentLocation()) else { return }
        open(target)
    }

    private func open(_ location: Location) {
        closePopup(restoreFocus: false)
        model.openFile(location.path)
        guard let editor = host.focusedEditor, editor.document.path == (location.path as NSString).standardizingPath else { return }
        editor.reveal(offset: location.offset)
    }

    // MARK: - 건너뛰기

    /// 지금 위치를 기록하고 target 으로
    func jump(_ target: Target) {
        closePopup(restoreFocus: false)
        if let here = currentLocation() { history.record(here) }
        model.openFile(target.path)
        guard let editor = host.focusedEditor, editor.document.path == (target.path as NSString).standardizingPath else { return }
        let landed = editor.reveal(line: target.line, column: target.column, name: target.name)
        // 색인이 낡아 줄이 어긋났으면 그 파일만 다시 읽어 둔다
        if landed != target.line { for index in store.existing(containing: editor.document.path) { index.recheck(editor.document.path) } }
    }

    // MARK: - 목록 창

    private func present(_ popup: NavigatorPopupView, rows: [NavigatorRow], targets: [Target], anchor: NSRect?, empty: String? = nil) {
        closePopup(restoreFocus: false)
        self.popup = popup
        popupTargets = targets
        popupAnchoredTop = anchor == nil
        popup.onChoose = { [weak self] row in
            guard let self, self.popupTargets.indices.contains(row) else { return }
            self.jump(self.popupTargets[row])
        }
        popup.onClose = { [weak self] in self?.closePopup(restoreFocus: true) }
        popup.setRows(rows, empty: empty)
        let container = host.view
        container.addSubview(popup)
        place(popup, anchor: anchor)
        container.window?.makeFirstResponder(popup.focusTarget)
        if popup.searchable { popup.preferRomanInput(true) }
        // 바깥을 누르면 닫는다
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let popup = self.popup, event.window === popup.window else { return event }
            let point = popup.convert(event.locationInWindow, from: nil)
            if !popup.bounds.contains(point) { self.closePopup(restoreFocus: false) }
            return event
        }
    }

    private func setRows(_ popup: NavigatorPopupView, _ rows: [NavigatorRow], targets: [Target], empty: String?) {
        popupTargets = targets
        popup.setRows(rows, empty: empty)
        let top = popup.frame.maxY
        var frame = popup.frame
        frame.size.height = min(popup.preferredHeight, max(host.view.bounds.height - 80, 120))
        frame.origin.y = top - frame.height
        popup.frame = frame
    }

    private func place(_ popup: NavigatorPopupView, anchor: NSRect?) {
        let bounds = host.view.bounds
        let width = min(anchor == nil ? 760 : 680, bounds.width - 24)
        let height = min(popup.preferredHeight, max(bounds.height - 80, 120))
        var frame = NSRect(x: 0, y: 0, width: width, height: height)
        if let anchor {
            frame.origin.x = min(max(anchor.minX - 40, 12), bounds.width - width - 12)
            frame.origin.y = anchor.minY - height - 6
            if frame.minY < 8 { frame.origin.y = min(anchor.maxY + 6, bounds.height - height - 8) }
            frame.origin.y = max(frame.origin.y, 8)
        } else {
            frame.origin.x = (bounds.width - width) / 2
            frame.origin.y = bounds.height - TerminalHostController.tabBarHeight - 48 - height
            frame.origin.y = max(frame.origin.y, 8)
        }
        popup.frame = frame.integral
    }

    func closePopup(restoreFocus: Bool) {
        guard let popup else { return }
        request += 1 // 닫은 뒤 늦게 온 결과가 다시 띄우지 않게
        if popup.searchable { popup.preferRomanInput(false) }
        self.popup = nil
        popupTargets = []
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        popup.removeFromSuperview()
        if restoreFocus { host.focusPane() }
    }

    /// 목록 창이 키보드를 쥐고 있는지(그동안 화면 포커스를 빼앗지 않게)
    var popupHasFocus: Bool {
        guard let popup, let responder = popup.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: popup) || (popup.field.currentEditor() != nil && responder === popup.field.currentEditor())
    }

    // MARK: - 그리기 도우미

    private static var boldCode: NSFont { TermAppearance.uiFont(EditorStyle.font.pointSize, bold: true) }

    private static func count(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func display(_ path: String, root: String?) -> String {
        if let root, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// 코드 한 줄(앞 공백 뺌, 길면 자름) + 이름 강조. column 이 있으면 그 자리, 없으면 처음 나오는 곳.
    static func snippet(_ line: String, highlight name: String, column: Int?) -> NSAttributedString {
        let ns = line as NSString
        var start = 0
        while start < ns.length, ns.character(at: start) == 32 || ns.character(at: start) == 9 { start += 1 }
        let maxLength = 180
        let text = ns.substring(from: start)
        let shown = (text as NSString).length > maxLength ? (text as NSString).substring(to: maxLength) + "…" : text
        let result = NSMutableAttributedString(string: shown, attributes: [.font: EditorStyle.font, .foregroundColor: EditorStyle.text])
        let at = column.map { $0 - start } ?? Identifier.firstWholeWord(name, in: shown)
        if let at, at >= 0, at + (name as NSString).length <= (shown as NSString).length {
            result.addAttributes([.foregroundColor: TermAppearance.accent, .font: boldCode,
                                  .backgroundColor: TermAppearance.accent.withAlphaComponent(0.14)],
                                 range: NSRange(location: at, length: (name as NSString).length))
        }
        return result
    }

    static func line(_ text: NSString, _ lines: LineIndex, _ line: Int) -> String {
        guard line < lines.lineCount else { return "" }
        let start = lines.starts[line]
        let end = line + 1 < lines.lineCount ? lines.starts[line + 1] : text.length
        return text.substring(with: NSRange(location: start, length: max(end - start, 0)))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
    }

    /// 후보 줄 글을 백그라운드에서 읽는다("경로:줄" → 글). 지금 파일은 편집 중인 글에서.
    static func readLines(_ wanted: [(String, Int)], current: (path: String, text: String?),
                          _ completion: @escaping ([String: String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var byFile: [String: Set<Int>] = [:]
            for (path, line) in wanted { byFile[path, default: []].insert(line) }
            var result: [String: String] = [:]
            for (path, lines) in byFile {
                let text = path == current.path ? current.text : try? String(contentsOfFile: path, encoding: .utf8)
                guard let text else { continue }
                var number = 0
                let last = lines.max() ?? 0
                text.enumerateLines { line, stop in
                    if lines.contains(number) { result["\(path):\(number)"] = line }
                    number += 1
                    if number > last { stop = true }
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 시험용

    var debugHistory: String {
        "history back=[\(history.back.map { "\(($0.path as NSString).lastPathComponent)@\($0.offset)" }.joined(separator: ","))] "
            + "forward=[\(history.forward.map { "\(($0.path as NSString).lastPathComponent)@\($0.offset)" }.joined(separator: ","))]"
    }

    var debugIndexes: String {
        store.indexes.map { index in
            let s = index.stats
            return "index root=\(index.root) git=\(index.isGit) state=\(index.state) files=\(s.files) symbols=\(s.symbols) names=\(s.names) "
                + "scanned=\(s.scanned) list=\(Int(s.listSeconds * 1000))ms total=\(Int(s.totalSeconds * 1000))ms "
                + "refreshes=\(s.refreshes) truncated=\(s.truncated) progress=\(index.progress)"
        }.joined(separator: "\n")
    }

    /// 시험용: 루트 하나를 색인하고 걸린 시간·메모리를 알린다
    func debugBuild(root: String, completion: @escaping (String) -> Void) {
        let before = Memory.footprint()
        let started = Date()
        let isGit = GitWorktrees.locate(root) != nil
        let index = store.index(root: root, isGit: isGit)
        index.whenReady {
            let after = Memory.footprint()
            completion("index-build root=\(root) wall=\(Int(Date().timeIntervalSince(started) * 1000))ms "
                + "footprint before=\(Memory.format(before)) after=\(Memory.format(after)) "
                + "delta=\(Memory.format(after > before ? after - before : 0))\n" + self.debugIndexes)
        }
    }
}
