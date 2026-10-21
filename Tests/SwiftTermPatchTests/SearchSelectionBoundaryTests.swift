import SwiftTerm
import XCTest

final class SearchSelectionBoundaryTests: XCTestCase {
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

    func testExclusiveEndIncludesLastWideCell() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 6, rows: 2))
        terminal.feed(text: "abcd한")
        let selection = SelectionService(terminal: terminal)
        selection.setSearchSelection(start: Position(col: 4, row: 0), end: Position(col: 6, row: 0))
        XCTAssertEqual(selection.end.col, 6)
        XCTAssertEqual(selection.getSelectedText(), "한")
        selection.active = false
        selection.setSearchSelection(start: Position(col: 4, row: 0), end: Position(col: 6, row: 0))
        XCTAssertTrue(selection.active)
        XCTAssertEqual(selection.getSelectedText(), "한")
    }
}
