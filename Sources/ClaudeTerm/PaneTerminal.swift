import AppKit
import SwiftTerm
import TermWire

/// 화면(데몬 PTY) 하나를 보여 주는 터미널 뷰. 지금 탭에 보이는 화면만 만든다.
/// 탭을 바꾸면 버리고(메모리 반납), 다시 오면 데몬이 보관한 지난 출력으로 되살린다.
final class PaneTerminal: NSObject, TerminalViewDelegate {
    /// 앱 쪽 뒤로 보기 줄 수. 줄마다 칸 정보를 들고 있어(120열 기준 1,000줄 ≈ 8MB) 메모리에 가장 크게 영향을 준다.
    /// 데몬은 따로 화면당 2MB 까지 지난 출력을 보관한다.
    static let scrollback = 2_000

    let id: String
    let view: TerminalView
    private let client: DaemonClient
    /// 붙은 직후 지난 출력을 그리는 동안엔 크기 변경을 데몬에 보내지 않는다
    private var restoring = true

    init(id: String, client: DaemonClient, frame: NSRect) {
        self.id = id
        self.client = client
        let options = TerminalOptions(scrollback: Self.scrollback, ansi256PaletteStrategy: .xterm)
        view = TerminalView(frame: frame, font: TermAppearance.font, options: options)
        super.init()
        view.terminalDelegate = self
        view.optionAsMetaKey = false // ⌥ 로 특수 문자 입력(맥 기본)
        TermAppearance.apply(to: view)
    }

    func attach() { client.attach(id) }

    func detach() {
        client.detach(id)
        view.removeFromSuperview()
    }

    func receive(_ bytes: ArraySlice<UInt8>, replay: Bool) {
        view.feed(byteArray: bytes)
        guard replay else { return }
        restoring = false
        // 지난 출력은 그때 화면 크기 기준이라 어긋날 수 있다. 크기를 한 번 흔들어 claude 같은 화면 프로그램이 다시 그리게 한다.
        let terminal = view.getTerminal()
        let (cols, rows) = (terminal.cols, terminal.rows)
        client.resize(id, cols: cols, rows: max(rows - 1, 2))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.view.superview != nil else { return }
            let terminal = self.view.getTerminal()
            self.client.resize(self.id, cols: terminal.cols, rows: terminal.rows)
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
        client.input(id, data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
