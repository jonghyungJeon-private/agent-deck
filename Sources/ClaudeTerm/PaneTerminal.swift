import AppKit
import SwiftTerm
import TermWire

/// 화면(데몬 PTY) 하나를 보여 주는 터미널 뷰. 지금 탭에 보이는 화면만 만든다.
/// 탭을 바꾸면 버리고(메모리 반납), 다시 오면 데몬이 보관한 지난 출력으로 되살린다.
final class PaneTerminal: NSObject, TerminalViewDelegate {
    /// 앱 쪽 뒤로 보기 줄 수. 줄마다 칸 정보를 들고 있어(120열 기준 1,000줄 ≈ 8MB) 메모리에 가장 크게 영향을 준다.
    /// 데몬은 따로 화면당 2MB 까지 지난 출력을 보관한다.
    static let scrollback = 2_000
    /// 터미널 안 그림(kitty) 캐시 상한. 엔진 기본값은 화면당 320MB 라 가볍게 줄인다(claude 는 그림을 거의 안 쓴다).
    static let imageCacheLimit = 16 * 1024 * 1024

    let id: String
    let view: TerminalView
    private let client: DaemonClient
    /// 붙은 직후 지난 출력을 그리는 동안엔 크기 변경을 데몬에 보내지 않는다
    private var restoring = true
    /// 지난 출력을 먹이는 중. 이때 터미널이 내는 응답(과거 질의에 대한 답)·클립보드 쓰기는 버린다.
    /// 그대로 두면 예전 출력 속 질의(DA, 커서 위치, kitty 키보드 등)의 답이 지금 돌고 있는 claude 에 입력으로 들어가고,
    /// 예전 OSC 52 가 지금 클립보드를 덮는다.
    private var replaying = false

    init(id: String, client: DaemonClient, frame: NSRect) {
        self.id = id
        self.client = client
        let options = TerminalOptions(scrollback: Self.scrollback, kittyImageCacheLimitBytes: Self.imageCacheLimit,
                                      ansi256PaletteStrategy: .xterm)
        view = TerminalView(frame: frame, font: TermAppearance.font, options: options)
        super.init()
        view.terminalDelegate = self
        view.optionAsMetaKey = false // ⌥ 로 특수 문자 입력(맥 기본)
        TermAppearance.apply(to: view)
    }

    /// 앱 글꼴 크기를 적용한다. 칸 크기가 바뀌면 엔진이 sizeChanged 로 알려 데몬에도 전해진다.
    func applyFont() {
        guard view.font.pointSize != TermAppearance.fontSize else { return }
        view.font = TermAppearance.font
    }

    func attach() { client.attach(id) }

    func detach() {
        client.detach(id)
        view.removeFromSuperview()
    }

    func receive(_ bytes: ArraySlice<UInt8>, replay: Bool) {
        guard replay else {
            view.feed(byteArray: bytes)
            return
        }
        replaying = true
        prepareAltScreen(for: bytes)
        view.feed(byteArray: bytes)
        replaying = false
        restoring = false
        // 지난 출력은 그때 화면 크기 기준이라 어긋날 수 있다. 크기를 한 번 흔들어 claude 같은 화면 프로그램이 다시 그리게 한다.
        let terminal = view.getTerminal()
        let (cols, rows) = (terminal.cols, terminal.rows)
        client.resize(id, cols: cols, rows: max(rows - 1, 2))
        // 되돌리기는 탭을 금방 떠나도 꼭 보낸다(안 보내면 다음에 붙을 때까지 한 줄 작은 크기로 남는다)
        let client = client, id = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            if let self, self.view.superview != nil {
                let terminal = self.view.getTerminal()
                client.resize(id, cols: terminal.cols, rows: terminal.rows)
            } else {
                client.resize(id, cols: cols, rows: rows)
            }
        }
    }

    /// 지난 출력이 대체 화면 안에서 시작하는지 맞춰 둔다. 데몬은 화면당 약 2MB 만 보관해서, 긴 claude 세션은
    /// 맨 앞의 `ESC[?1049h`(대체 화면 켜기)가 잘려 나간다. 그대로 먹이면 claude 화면이 보통 화면에 그려지고
    /// 끝날 때 `ESC[?1049l` 이 아무 일도 하지 않아 마지막 화면 위에 "Resume this session with:" 가 겹쳐 남는다.
    /// 새 데몬은 잘린 모드를 앞에 붙여 주지만, 예전 데몬(재시작 전 세션)에도 통하도록 여기서 한 번 더 본다.
    /// - 처음 만나는 대체 화면 켜기·끄기가 끄기면: 대체 화면 안에서 시작한 것이니 먼저 켠다.
    /// - 켜기·끄기가 전혀 없으면: 상태를 모른다고 표시한다(대체 화면이 아닌데 끄기가 오면 엔진이 화면을 지우고 시작한다).
    /// 시험용: 1 이면 이 대비책을 끈다(고치기 전 동작 재현용)
    private static let altFallbackDisabled = ProcessInfo.processInfo.environment["CLAUDE_TERM_NO_ALT_FALLBACK"] == "1"

    private func prepareAltScreen(for bytes: ArraySlice<UInt8>) {
        guard !Self.altFallbackDisabled else { return }
        let terminal = view.getTerminal()
        switch TerminalModeTracker.firstAltScreenToggle(in: bytes) {
        case false?:
            view.feed(byteArray: Array("\u{1b}[?1049h".utf8)[...])
        case nil:
            if !terminal.isCurrentBufferAlternate { terminal.altScreenStateUnknown = true }
        case true?:
            break
        }
    }

    func exited() {
        view.feed(text: "\r\n\u{1b}[2m[셸이 끝났습니다]\u{1b}[0m\r\n")
    }

    var size: (cols: Int, rows: Int) {
        let terminal = view.getTerminal()
        return (terminal.cols, terminal.rows)
    }

    // MARK: - TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard !restoring else { return }
        client.resize(id, cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !replaying else { return }
        client.input(id, data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard !replaying, let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
