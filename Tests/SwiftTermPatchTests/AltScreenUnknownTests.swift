import SwiftTerm
import XCTest

/// Vendor/SwiftTerm 의 ClaudeTerm patch(`Terminal.altScreenStateUnknown`) 시험. 화면 없이 Terminal 만 돌린다.
final class AltScreenUnknownTests: XCTestCase {
    private final class Delegate: TerminalDelegate {
        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {}
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
        func selectionChanged(source: Terminal) {}
        func isProcessTrusted(source: Terminal) -> Bool { true }
        func mouseModeChanged(source: Terminal) {}
        func hostCurrentDirectoryUpdated(source: Terminal) {}
        func hostCurrentDocumentUpdated(source: Terminal) {}
        func colorChanged(source: Terminal, idx: Int?) {}
        func setForegroundColor(source: Terminal, color: Color) {}
        func setBackgroundColor(source: Terminal, color: Color) {}
        func setCursorColor(source: Terminal, color: Color?) {}
        func getColors(source: Terminal) -> (foreground: Color, background: Color) {
            (Color(red: 0, green: 0, blue: 0), Color(red: 0xffff, green: 0xffff, blue: 0xffff))
        }
        func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
        func clipboardCopy(source: Terminal, content: Data) {}
        func notify(source: Terminal, title: String, body: String) {}
    }

    private let delegate = Delegate()

    private func makeTerminal() -> Terminal {
        Terminal(delegate: delegate, options: TerminalOptions(cols: 40, rows: 6, scrollback: 100))
    }

    private func rows(_ terminal: Terminal) -> [String] {
        (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? "" }
    }

    /// 앞부분이 잘린 claude 출력(대체 화면 켜기 없이 그림)
    private let trimmedDrawing = "\u{1b}[H\u{1b}[2J╭─ claude ─╮\r\n│ 그림 줄 │\r\n╰──────────╯\r\n\u{1b}[5;3H> 입력"

    func testMissedEnterClearsScreenWhenFlagged() {
        let terminal = makeTerminal()
        terminal.altScreenStateUnknown = true
        terminal.feed(text: trimmedDrawing)
        XCTAssertFalse(terminal.isCurrentBufferAlternate)
        terminal.feed(text: "\u{1b}[?1049lResume this session with: test\r\n")
        XCTAssertFalse(terminal.altScreenStateUnknown)
        XCTAssertEqual(rows(terminal), ["Resume this session with: test", "", "", "", "", ""])
    }

    func testUnflaggedResetKeepsOriginalBehavior() {
        let terminal = makeTerminal()
        terminal.feed(text: trimmedDrawing)
        terminal.feed(text: "\u{1b}[?1049lResume")
        // 원래 동작: 보통 화면 그대로, 저장된 커서(0,0)로 돌아가 그 위에 덮어 쓴다
        let screen = rows(terminal)
        XCTAssertEqual(screen[0], "Resumeude ─╮")
        XCTAssertEqual(screen[1], "│ 그림 줄 │")
    }

    func testEnterClearsFlag() {
        let terminal = makeTerminal()
        terminal.altScreenStateUnknown = true
        terminal.feed(text: "\u{1b}[?1049h")
        XCTAssertFalse(terminal.altScreenStateUnknown)
        XCTAssertTrue(terminal.isCurrentBufferAlternate)
        terminal.feed(text: "alt 그림\u{1b}[?1049lback")
        XCTAssertFalse(terminal.isCurrentBufferAlternate)
        XCTAssertEqual(rows(terminal)[0], "back")
    }

    func testResetInsideAltScreenWithFlagBehavesNormally() {
        let terminal = makeTerminal()
        terminal.feed(text: "$ prompt\r\n\u{1b}[?1049h")
        terminal.altScreenStateUnknown = true
        terminal.feed(text: "alt\u{1b}[?1049l")
        XCTAssertFalse(terminal.altScreenStateUnknown)
        // 실제로 대체 화면에 있었으니 보통 화면(프롬프트)이 그대로 돌아온다
        XCTAssertEqual(rows(terminal)[0], "$ prompt")
    }

    func testOtherAltModesAlsoClearFlag() {
        for mode in ["47", "1047"] {
            let terminal = makeTerminal()
            terminal.altScreenStateUnknown = true
            terminal.feed(text: "keep\u{1b}[?\(mode)h")
            XCTAssertFalse(terminal.altScreenStateUnknown, mode)
            terminal.feed(text: "\u{1b}[?\(mode)l")
            XCTAssertEqual(rows(terminal)[0], "keep", mode)
        }
        let terminal = makeTerminal()
        terminal.altScreenStateUnknown = true
        terminal.feed(text: "gone\u{1b}[?47lnew")
        XCTAssertEqual(rows(terminal)[0], "new")
    }
}
