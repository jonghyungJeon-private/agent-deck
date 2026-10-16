import AppKit
import CoreText
import EditorCore
import TermLayout

/// 편집기 화면 하나의 문서(파일 내용·저장 상태·git 변경 표시). 뷰는 보이는 동안만 있고, 문서는 화면을 닫을 때까지 남는다.
/// 숨은 문서가 저장된 상태(깨끗함)면 글을 놓고(메모리 반납) 다시 보일 때 디스크에서 읽는다. 바뀐 문서는 글을 그대로 쥐고 있다.
final class EditorDocument: NSObject, NSTextStorageDelegate {
    enum Content: Equatable {
        case unloaded
        case text
        /// 열기만 하는 안내(바이너리·너무 큼·UTF-8 아님·읽기 실패)
        case notice(title: String, detail: String)
    }

    /// 디스크 쪽이 바뀌어 사용자가 골라야 하는 상태(배너)
    enum DiskConflict: Equatable {
        case changed, deleted
    }

    /// git 기준(HEAD) 내용
    enum Base {
        case unknown, loading
        /// 저장소가 아님·무시된 파일·너무 큼 → 표시 없음
        case none
        /// 새 파일(추적 안 함) → 모든 줄이 추가
        case untracked
        case text([UInt8])
    }

    /// 뷰가 다시 그릴 것
    struct Update: OptionSet {
        let rawValue: Int
        static let markers = Update(rawValue: 1)
        static let banner = Update(rawValue: 2)
        static let content = Update(rawValue: 4)
        static let title = Update(rawValue: 8)
    }

    /// 이보다 크면 글자 색을 칠하지 않는다(UTF-16 길이)
    static let highlightLimit = 500_000

    let id: String
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    let language: SyntaxLanguage?

    private(set) var content: Content = .unloaded
    private(set) var storage: NSTextStorage?
    /// 문서가 쥔 배치 관리자: 뷰를 새로 만들어도 되돌리기 기록이 이어지게(뷰는 글 상자만 붙였다 뗀다)
    private(set) var layoutManager: NSLayoutManager?
    let undoManager = UndoManager()
    private(set) var lineEnding: LineEnding = .lf
    private(set) var hasBOM = false
    /// 마지막으로 읽거나 저장한 때의 디스크 상태
    private(set) var fingerprint: FileFingerprint?
    private(set) var isDirty = false {
        didSet { if isDirty != oldValue { notify(.title) } }
    }
    private(set) var diskConflict: DiskConflict? {
        didSet { if diskConflict != oldValue { notify(.banner) } }
    }
    private(set) var lines = LineIndex()
    private(set) var changes: [LineChange] = []
    private(set) var base: Base = .unknown
    /// 커서 위치(뷰를 다시 만들 때·앱을 다시 켤 때)
    var cursor: Int
    /// 읽어 들인 바이트 수(표시 제한 판단)
    private(set) var loadedBytes = 0

    /// 뷰가 듣는다(보이는 동안만)
    var onViewUpdate: ((Update) -> Void)?
    /// 글이 바뀐 범위(색 칠하기)
    var onTextEdited: ((NSRange, Int) -> Void)?
    /// 탭 제목(● 표시)이 바뀜 — 관리자가 듣는다
    var onTitleChange: (() -> Void)?
    var onError: ((String) -> Void)?

    private var savedLength = 0
    private var savedHash = 0
    /// 다시 읽는 중(디스크에서 온 변경은 "바뀜"이 아니다)
    private var applyingDiskText = false
    private var diffWork: DispatchWorkItem?
    private var generation = 0
    /// 글을 읽을 때마다 바뀐다(놓은 뒤 늦게 온 git 결과를 버린다)
    private var session = 0
    private var watcher: DispatchSourceFileSystemObject?
    private var checkWork: DispatchWorkItem?
    private(set) var isVisible = false
    private static let queue = DispatchQueue(label: "ClaudeTerm.editor", qos: .utility)

    init(id: String, path: String, cursor: Int?) {
        self.id = id
        self.path = path
        self.cursor = cursor ?? 0
        language = SyntaxLanguage.detect(path: path)
        super.init()
    }

    var isText: Bool { content == .text }
    var isLoaded: Bool { content != .unloaded }
    var highlightEnabled: Bool { (storage?.length ?? 0) <= Self.highlightLimit && language != nil }
    var markersEnabled: Bool {
        guard let storage else { return false }
        return loadedBytes <= LineDiff.maxBytes && storage.length <= LineDiff.maxBytes && lines.lineCount <= LineDiff.maxLines
    }

    private func notify(_ update: Update) {
        onViewUpdate?(update)
        if update.contains(.title) { onTitleChange?() }
    }

    // MARK: - 읽기

    /// 아직 안 읽었으면 디스크에서 읽는다(뷰를 만들 때)
    func loadIfNeeded() {
        guard content == .unloaded else { return }
        load()
    }

    private func load() {
        fingerprint = FileFingerprint.of(path)
        do {
            let result = try TextFile.read(path: path)
            switch result.kind {
            case .text:
                if let decoded = result.decoded {
                    install(decoded)
                } else {
                    content = .notice(title: "UTF-8 이 아닌 파일이라 편집기로 열지 않습니다", detail: path)
                }
            case .binary:
                content = .notice(title: "바이너리 파일이라 편집기로 열지 않습니다", detail: path)
            case .tooLarge(let size):
                content = .notice(title: "파일이 너무 커서 열지 않습니다 (\(Self.megabytes(size)), 한도 \(Self.megabytes(TextFile.maxEditableBytes)))",
                                  detail: path)
            case .notUTF8:
                content = .notice(title: "UTF-8 이 아닌 파일이라 편집기로 열지 않습니다", detail: path)
            }
        } catch {
            let missing = !FileManager.default.fileExists(atPath: path)
            content = .notice(title: missing ? "파일이 없습니다" : "파일을 읽지 못했습니다", detail: path)
        }
    }

    static func megabytes(_ bytes: Int) -> String { String(format: "%.1fMB", Double(bytes) / 1_048_576) }

    private func install(_ decoded: DecodedText) {
        let storage = NSTextStorage(string: decoded.text, attributes: EditorStyle.textAttributes)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true // 큰 파일도 보이는 곳만 배치
        layout.backgroundLayoutEnabled = false
        storage.addLayoutManager(layout)
        storage.delegate = self
        self.storage = storage
        layoutManager = layout
        lineEnding = decoded.lineEnding
        hasBOM = decoded.hasBOM
        loadedBytes = decoded.text.utf8.count
        lines = LineIndex(storage.string as NSString)
        markSaved()
        content = .text
        undoManager.removeAllActions()
        refreshBase()
    }

    private func markSaved() {
        guard let storage else { return }
        savedLength = storage.length
        savedHash = Self.hash(storage.string)
        isDirty = false
    }

    private static func hash(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    /// 글·배치 관리자를 놓는다. 글 상자를 먼저 떼어 남은 글 뷰가 사라진 배치 관리자를 가리키지 않게 한다.
    private func dropTextStack() {
        if let layoutManager {
            while !layoutManager.textContainers.isEmpty { layoutManager.removeTextContainer(at: 0) }
            storage?.removeLayoutManager(layoutManager)
        }
        storage?.delegate = nil
        storage = nil
        layoutManager = nil
    }

    /// 숨은 깨끗한 문서의 글을 놓는다(다시 보이면 디스크에서 읽는다). 바뀐 것·충돌 중인 것은 그대로.
    func releaseIfClean() {
        guard !isVisible, !isDirty, diskConflict == nil, content != .unloaded else { return }
        dropTextStack()
        undoManager.removeAllActions()
        content = .unloaded
        base = .unknown
        changes = []
        lines = LineIndex()
        generation += 1
        session += 1
        diffWork?.cancel()
    }

    // MARK: - 편집

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        lines.edit(textStorage.string as NSString, range: editedRange, delta: delta)
        onTextEdited?(editedRange, delta)
        if !applyingDiskText { isDirty = true }
        scheduleDiff()
    }

    /// 표시 다시 계산(편집 뒤 약 0.3초 모아서, 백그라운드). 저장한 내용과 같아졌으면(되돌리기) "바뀜"도 푼다.
    func scheduleDiff(delay: TimeInterval = 0.3) {
        diffWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runDiff() }
        diffWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runDiff() {
        guard let storage else { return }
        generation += 1
        let generation = self.generation
        let snapshot = NSString(string: storage.string) as String // 바뀌지 않는 사본
        let checkClean = isDirty && storage.length == savedLength
        let savedHash = self.savedHash
        let base = self.base
        let markers = markersEnabled
        Self.queue.async { [weak self] in
            let clean = checkClean && Self.hash(snapshot) == savedHash
            var result: [LineChange]?
            if markers {
                switch base {
                case .text(let bytes):
                    let ids = LineDiff.intern(LineDiff.lines(bytes), LineDiff.lines(Array(snapshot.utf8)))
                    result = LineDiff.changes(old: ids.old, new: ids.new)
                case .untracked:
                    result = LineDiff.allAdded(lineCount: LineDiff.lines(Array(snapshot.utf8)).count)
                case .none:
                    result = []
                case .unknown, .loading:
                    result = nil
                }
            } else {
                result = []
            }
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                if clean { self.isDirty = false }
                if let result, result != self.changes {
                    self.changes = result
                    self.notify(.markers)
                }
            }
        }
    }

    // MARK: - git 기준

    /// HEAD 의 내용을 한 번 읽는다(백그라운드). 저장소가 아니면 표시 없음, 새 파일이면 모두 추가.
    func refreshBase() {
        guard content == .text else { return }
        if case .loading = base { return }
        base = .loading
        let path = self.path
        let session = self.session
        Self.queue.async { [weak self] in
            let base = Self.loadBase(path: path)
            DispatchQueue.main.async {
                guard let self, self.content == .text, session == self.session else { return }
                self.base = base
                self.scheduleDiff(delay: 0)
            }
        }
    }

    static func loadBase(path: String) -> Base {
        let directory = (path as NSString).deletingLastPathComponent
        guard GitRunner.executable != nil, let location = GitWorktrees.locate(directory) else { return .none }
        let root = location.worktreeRoot
        var rel: String?
        if path.hasPrefix(root + "/") {
            rel = String(path.dropFirst(root.count + 1))
        } else {
            // /tmp ↔ /private/tmp 처럼 링크를 거친 경로
            let realRoot = FilesWatcher.realPath(root), realPath = FilesWatcher.realPath(path)
            if realPath.hasPrefix(realRoot + "/") { rel = String(realPath.dropFirst(realRoot.count + 1)) }
        }
        guard let rel else { return .none }
        if let shown = GitRunner.run(["-C", root, "show", "HEAD:" + rel], limit: LineDiff.maxBytes) {
            if shown.status == 0 {
                return shown.output.count > LineDiff.maxBytes ? .none : .text(Array(shown.output))
            }
        } else {
            return .none
        }
        // HEAD 에 없음: 무시된 파일이면 표시 없음, 아니면 새 파일
        if let ignored = GitRunner.run(["-C", root, "check-ignore", "-q", "--", rel]), ignored.status == 0 { return .none }
        return .untracked
    }

    // MARK: - 저장

    /// ⌘S. 디스크가 그사이 바뀌었으면 쓰지 않고 배너로 묻는다(force = 배너의 "내 것으로 덮어쓰기").
    @discardableResult
    func save(force: Bool = false) -> Bool {
        guard content == .text, let storage else { return false }
        let now = FileFingerprint.of(path)
        if !force, now != fingerprint {
            diskConflict = now == nil ? .deleted : .changed
            return false
        }
        let data = TextFile.encode(storage.string, lineEnding: lineEnding, hasBOM: hasBOM)
        do {
            try TextFile.writeAtomically(data, to: path)
        } catch {
            onError?("저장하지 못했습니다: \(name)\n\(error.localizedDescription)")
            return false
        }
        fingerprint = FileFingerprint.of(path)
        loadedBytes = data.count
        diskConflict = nil
        markSaved()
        startWatching() // 이름을 바꿔 끼웠으니 새 파일을 지켜본다
        return true
    }

    // MARK: - 디스크 감시(보이는 동안만)

    func becameVisible() {
        isVisible = true
        if content == .text {
            checkDisk()
            refreshBase() // 그사이 커밋했을 수 있다
        }
        startWatching()
    }

    func becameHidden() {
        isVisible = false
        stopWatching()
    }

    private func startWatching() {
        stopWatching()
        guard isVisible else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .extend, .delete, .rename, .attrib, .link],
                                                               queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            if event.contains(.delete) || event.contains(.rename) {
                // 다른 편집기는 새 파일로 바꿔 끼운다 — 잠시 뒤 같은 경로를 다시 지켜본다
                self.stopWatching()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.isVisible else { return }
                    self.startWatching()
                    self.checkDisk()
                }
            } else {
                self.scheduleCheck()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func scheduleCheck() {
        checkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkDisk() }
        checkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 디스크가 바뀌었으면: 고친 게 없으면 조용히 다시 읽고, 고쳤으면 배너로 묻는다. 절대 저장하지 않는다.
    func checkDisk() {
        guard content != .unloaded else { return }
        let now = FileFingerprint.of(path)
        guard now != fingerprint else { return }
        guard content == .text else {
            // 안내 화면(바이너리 등)은 새로 판단한다
            content = .unloaded
            load()
            notify([.content, .title])
            return
        }
        if now == nil {
            diskConflict = .deleted
        } else if !isDirty, diskConflict == nil {
            reloadFromDisk()
        } else {
            diskConflict = .changed
        }
    }

    /// 배너 "다시 읽기"·조용한 다시 읽기: 디스크 내용으로 바꾼다(되돌리기 기록은 지운다)
    func reloadFromDisk() {
        guard let storage else { return }
        let read = try? TextFile.read(path: path)
        guard let read, read.kind == .text, let decoded = read.decoded else {
            // 텍스트가 아니게 됐으면 안내로
            if read != nil {
                releaseForReload()
                load()
                notify([.content, .title, .banner])
            }
            return
        }
        fingerprint = FileFingerprint.of(path)
        applyingDiskText = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: decoded.text)
        storage.setAttributes(EditorStyle.textAttributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        applyingDiskText = false
        lineEnding = decoded.lineEnding
        hasBOM = decoded.hasBOM
        loadedBytes = decoded.text.utf8.count
        undoManager.removeAllActions()
        diskConflict = nil
        markSaved()
        notify(.content)
        scheduleDiff(delay: 0)
    }

    private func releaseForReload() {
        dropTextStack()
        undoManager.removeAllActions()
        content = .unloaded
        diskConflict = nil
        isDirty = false
        base = .unknown
        session += 1
    }

    /// 배너 "내 것으로 덮어쓰기"(지워졌으면 "내 것으로 저장")
    func overwriteDisk() {
        save(force: true)
    }

    func close() {
        stopWatching()
        diffWork?.cancel()
        checkWork?.cancel()
        generation += 1
        session += 1
        onViewUpdate = nil
        onTitleChange = nil
        onTextEdited = nil
        dropTextStack()
        undoManager.removeAllActions()
    }

    /// 시험용 한 줄 요약
    var debugSummary: String {
        let kind: String
        switch content {
        case .unloaded: kind = "unloaded"
        case .text: kind = "text"
        case .notice(let title, _): kind = "notice(\(title))"
        }
        let baseName: String
        switch base {
        case .unknown: baseName = "unknown"
        case .loading: baseName = "loading"
        case .none: baseName = "none"
        case .untracked: baseName = "untracked"
        case .text(let bytes): baseName = "HEAD(\(bytes.count)B)"
        }
        let marks = changes.map { "\($0.kind == .added ? "A" : $0.kind == .modified ? "M" : "D")\($0.start + 1)+\($0.count)" }
        return "editor \(id.suffix(6)) name=\(name) content=\(kind) dirty=\(isDirty) visible=\(isVisible) "
            + "length=\(storage?.length ?? -1) lines=\(storage == nil ? 0 : lines.lineCount) eol=\(lineEnding.label) bom=\(hasBOM) "
            + "base=\(baseName) markers=[\(marks.joined(separator: ","))] conflict=\(diskConflict.map { "\($0)" } ?? "-") "
            + "undo=\(undoManager.canUndo) lang=\(language?.rawValue ?? "-")"
    }
}

/// 열린 편집기 문서들
final class EditorManager {
    private(set) var documents: [String: EditorDocument] = [:]
    /// 탭·테두리 제목을 다시 그린다(● 표시)
    var onTitleChange: (() -> Void)?

    enum CloseAnswer: String { case save, discard, cancel }
    /// 시험용: 다음 확인 창 대신 쓸 답(창을 띄우지 않고 확인 흐름을 시험한다)
    var pendingAnswers: [CloseAnswer] = []

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            // 다른 앱(터미널의 claude 등)에서 고쳤을 수 있다 — 보이는 문서만 확인
            guard let self else { return }
            for document in self.documents.values where document.isVisible {
                document.checkDisk()
                document.refreshBase()
            }
        }
    }

    func document(id: String, recipe: EditorRecipe) -> EditorDocument {
        if let existing = documents[id] { return existing }
        let document = EditorDocument(id: id, path: recipe.path, cursor: recipe.cursor)
        document.onTitleChange = { [weak self] in self?.onTitleChange?() }
        document.onError = { message in
            let alert = NSAlert()
            alert.messageText = message
            alert.alertStyle = .warning
            if ProcessInfo.processInfo.environment["CLAUDE_TERM_DEBUG"] == "1" {
                print("editor-error \(message.replacingOccurrences(of: "\n", with: " | "))")
                fflush(stdout)
                return
            }
            alert.runModal()
        }
        documents[id] = document
        return document
    }

    func remove(_ id: String) {
        documents.removeValue(forKey: id)?.close()
    }

    func isDirty(_ id: String) -> Bool { documents[id]?.isDirty ?? false }

    var dirtyDocuments: [EditorDocument] { documents.values.filter(\.isDirty).sorted { $0.name < $1.name } }

    /// 바뀐 문서를 닫기 전에 묻는다: 저장 / 저장 안 함 / 취소. 닫아도 되면 true.
    /// 저장을 골랐는데 저장하지 못하면(디스크가 그사이 바뀜 등) 닫지 않는다.
    func confirmClose(_ documents: [EditorDocument]) -> Bool {
        let dirty = documents.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        let answer: CloseAnswer
        if !pendingAnswers.isEmpty {
            answer = pendingAnswers.removeFirst()
            print("editor-confirm files=\(dirty.map(\.name).joined(separator: ",")) answer=\(answer.rawValue)")
            fflush(stdout)
        } else {
            let alert = NSAlert()
            if dirty.count == 1 {
                alert.messageText = "\(dirty[0].name) 의 바뀐 내용을 저장할까요?"
                alert.informativeText = "저장하지 않으면 바뀐 내용은 사라집니다."
            } else {
                alert.messageText = "저장하지 않은 파일이 \(dirty.count)개 있습니다. 저장할까요?"
                alert.informativeText = dirty.map(\.name).joined(separator: ", ")
            }
            alert.addButton(withTitle: "저장")
            let discard = alert.addButton(withTitle: "저장 안 함")
            discard.keyEquivalent = "d"
            discard.keyEquivalentModifierMask = .command
            alert.addButton(withTitle: "취소")
            switch alert.runModal() {
            case .alertFirstButtonReturn: answer = .save
            case .alertSecondButtonReturn: answer = .discard
            default: answer = .cancel
            }
        }
        switch answer {
        case .cancel: return false
        case .discard: return true
        case .save:
            for document in dirty where !document.save() { return false }
            return true
        }
    }
}

/// 편집기 모양: 터미널과 같은 글꼴·바탕, IntelliJ Darcula 계열 글자 색을 #282c34 바탕에 맞춤
enum EditorStyle {
    /// 터미널과 같은 글꼴(같은 크기)에서 합자·문맥 대체만 끈다(-> 가 → 로 보이지 않게, IntelliJ 기본값처럼)
    static let font: NSFont = {
        let base = TermAppearance.font
        let off: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
        ]
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: off])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }()
    static let text = NSColor(srgbHex: 0xc9ccd3)
    static let background = TermAppearance.background
    static let gutter = NSColor(srgbHex: 0x262a31)
    static let lineNumber = NSColor(srgbHex: 0x5c6370)
    static let currentLineNumber = NSColor(srgbHex: 0xb6bac2)
    static let currentLine = NSColor(srgbHex: 0x2f343e)
    static let selection = NSColor(srgbHex: 0x3e4a5e)
    static let caret = NSColor(srgbHex: 0xdcdfe4)

    // git 변경 표시(files 도구 색과 같은 계열)
    static let added = NSColor(srgbHex: 0x5f9e4f)
    static let modified = NSColor(srgbHex: 0x4f80c4)
    static let deleted = NSColor(srgbHex: 0xd0605a)

    static func color(_ kind: SyntaxKind) -> NSColor {
        switch kind {
        case .keyword: return NSColor(srgbHex: 0xcf8e6d)   // Darcula 키워드(주황)
        case .string: return NSColor(srgbHex: 0x6aab73)    // 문자열(초록)
        case .comment: return NSColor(srgbHex: 0x7a7e85)   // 주석(회색)
        case .number: return NSColor(srgbHex: 0x2aacb8)    // 숫자(청록)
        case .type: return NSColor(srgbHex: 0xe0c58a)      // 타입(옅은 노랑)
        case .attribute: return NSColor(srgbHex: 0xb3ae60) // @속성·변수(올리브)
        case .key: return NSColor(srgbHex: 0xc77dbb)       // JSON·YAML 키(보라)
        case .heading: return NSColor(srgbHex: 0xcf8e6d)   // 제목·표 이름
        }
    }

    /// 탭 4칸
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        let width = (" " as NSString).size(withAttributes: [.font: font]).width * 4
        style.tabStops = []
        style.defaultTabInterval = width
        return style
    }()

    static var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: text, .paragraphStyle: paragraph, .ligature: 0]
    }
}
