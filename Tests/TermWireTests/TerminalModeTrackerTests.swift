import TermWire
import XCTest

final class TerminalModeTrackerTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    private func prefix(_ tracker: TerminalModeTracker) -> String { String(decoding: tracker.prefix(), as: UTF8.self) }

    func testDefaultHasNoPrefix() {
        var tracker = TerminalModeTracker()
        tracker.feed(bytes("hello 한글\r\n\u{1b}[1;31mred\u{1b}[0m\r\n"))
        XCTAssertEqual(tracker.prefix(), [])
    }

    func testAltScreenKeptAcrossTrim() {
        var tracker = TerminalModeTracker()
        tracker.feed(bytes("$ claude\r\n\u{1b}[?1049h\u{1b}[?25l\u{1b}[?2004h\u{1b}[H\u{1b}[2J그림 1\r\n"))
        tracker.feed(bytes("그림 2\r\n")) // 다음에 버린 부분 — 모드 변화 없음
        XCTAssertTrue(tracker.altScreen)
        XCTAssertEqual(prefix(tracker), "\u{1b}[?1049h\u{1b}[?25l\u{1b}[?2004h")
    }

    func testEnterAndLeaveInsideTrimmedPartGivesNoPrefix() {
        var tracker = TerminalModeTracker()
        tracker.feed(bytes("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?2004hvim\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l$ "))
        XCTAssertFalse(tracker.altScreen)
        XCTAssertEqual(tracker.prefix(), [])
    }

    func testSequencesSplitAcrossChunks() {
        let stream = bytes("abc\u{1b}[?1049h\u{1b}[?1;1000;1006hxyz\u{1b}]0;제목\u{07}\u{1b}[>1u")
        // 모든 위치·1바이트씩 잘라 먹여도 결과가 같아야 한다
        var whole = TerminalModeTracker()
        whole.feed(stream)
        for cut in 0...stream.count {
            var split = TerminalModeTracker()
            split.feed(stream[0..<cut])
            split.feed(stream[cut...])
            XCTAssertEqual(split.prefix(), whole.prefix(), "cut at \(cut)")
        }
        var bytewise = TerminalModeTracker()
        for byte in stream { bytewise.feed([byte]) }
        XCTAssertEqual(bytewise.prefix(), whole.prefix())
        XCTAssertEqual(prefix(whole), "\u{1b}[?1049h\u{1b}[>1u\u{1b}[?1h\u{1b}[?1000h\u{1b}[?1006h")
    }

    func testStringContentsAreIgnored() {
        var tracker = TerminalModeTracker()
        // OSC(BEL 로 끝남)·OSC(ST 로 끝남)·DCS·APC 안의 "[?1049h" 글은 무시
        tracker.feed(bytes("\u{1b}]0;[?1049h title\u{07}"))
        tracker.feed(bytes("\u{1b}]2;x [?1049h y\u{1b}\\"))
        tracker.feed(bytes("\u{1b}Pq[?25l\u{1b}\\"))
        tracker.feed(bytes("\u{1b}_G[?2004h;payload\u{1b}\\"))
        XCTAssertEqual(tracker.prefix(), [])
        XCTAssertNil(TerminalModeTracker.firstAltScreenToggle(in: bytes("\u{1b}]0;[?1049l\u{07}text")[...]))
        // 문자열이 끝난 뒤는 다시 읽는다
        tracker.feed(bytes("\u{1b}[?1049h"))
        XCTAssertTrue(tracker.altScreen)
    }

    func testIntermediateAndOtherMarkersIgnored() {
        var tracker = TerminalModeTracker()
        tracker.feed(bytes("\u{1b}[?1049$p"))   // DECRQM 질의 — 바꾸지 않음
        tracker.feed(bytes("\u{1b}[1049h"))     // ? 없는 SM — DEC 모드 아님
        tracker.feed(bytes("\u{1b}[?u"))        // kitty 질의
        XCTAssertEqual(tracker.prefix(), [])
    }

    func testCursorHiddenAndShownAgain() {
        var tracker = TerminalModeTracker()
        tracker.feed(bytes("\u{1b}[?25l"))
        XCTAssertEqual(prefix(tracker), "\u{1b}[?25l")
        tracker.feed(bytes("\u{1b}[?25h"))
        XCTAssertEqual(tracker.prefix(), [])
    }

    func testKittyPushPop() {
        var tracker = TerminalModeTracker()
        tracker.feed(bytes("\u{1b}[>1u\u{1b}[>3u"))
        XCTAssertEqual(tracker.kittyNormal, .init(flags: 3, stack: [0, 1]))
        XCTAssertEqual(prefix(tracker), "\u{1b}[>1u\u{1b}[>3u")
        tracker.feed(bytes("\u{1b}[<u"))
        XCTAssertEqual(prefix(tracker), "\u{1b}[>1u")
        tracker.feed(bytes("\u{1b}[=5;2u")) // 비트 더하기: 1|5
        XCTAssertEqual(tracker.kittyNormal.flags, 5)
        tracker.feed(bytes("\u{1b}[<5u"))   // 스택보다 많이 빼면 모두 비움
        XCTAssertEqual(tracker.prefix(), [])
        // 스택 상한
        for n in 1...20 { tracker.feed(bytes("\u{1b}[>\(n)u")) }
        XCTAssertEqual(tracker.kittyNormal.stack.count, TerminalModeTracker.kittyStackLimit)
        XCTAssertEqual(tracker.kittyNormal.flags, 20)
    }

    func testKittyStacksPerScreen() {
        var tracker = TerminalModeTracker()
        tracker.feed(bytes("\u{1b}[=2u\u{1b}[?1049h\u{1b}[>1u\u{1b}[?25l"))
        XCTAssertEqual(prefix(tracker), "\u{1b}[=2;1u\u{1b}[?1049h\u{1b}[>1u\u{1b}[?25l")
        // 대체 화면을 나가면 대체 화면 스택은 되살리지 않는다
        tracker.feed(bytes("\u{1b}[?1049l\u{1b}[?25h"))
        XCTAssertEqual(prefix(tracker), "\u{1b}[=2;1u")
    }

    func testMouseModes() {
        var tracker = TerminalModeTracker()
        tracker.feed(bytes("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?1004h"))
        XCTAssertEqual(prefix(tracker), "\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?1004h")
        tracker.feed(bytes("\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?1004l"))
        XCTAssertEqual(tracker.prefix(), [])
    }

    func testSynchronizedOutputNotRestored() {
        var tracker = TerminalModeTracker()
        tracker.feed(bytes("\u{1b}[?2026h"))
        XCTAssertEqual(tracker.prefix(), [])
    }

    func testFullResetClearsModes() {
        var tracker = TerminalModeTracker()
        tracker.feed(bytes("\u{1b}[?1049h\u{1b}[?25l\u{1b}[>1u\u{1b}c"))
        XCTAssertEqual(tracker.prefix(), [])
    }

    func testFirstAltScreenToggle() {
        XCTAssertNil(TerminalModeTracker.firstAltScreenToggle(in: bytes("plain 출력\r\n")[...]))
        XCTAssertEqual(TerminalModeTracker.firstAltScreenToggle(in: bytes("draw\u{1b}[?1049l\u{1b}[?1049h")[...]), false)
        XCTAssertEqual(TerminalModeTracker.firstAltScreenToggle(in: bytes("x\u{1b}[?47h\u{1b}[?1049l")[...]), true)
        XCTAssertEqual(TerminalModeTracker.firstAltScreenToggle(in: bytes("\u{1b}[?25;1047l")[...]), false)
    }

    func testLargeTrimIsCheap() {
        var chunk: [UInt8] = []
        for i in 0..<20_000 { chunk += bytes("\u{1b}[\(i % 40 + 1);1H\u{1b}[38;5;117m줄 \(i) 한글 출력\u{1b}[0m\r\n") }
        var tracker = TerminalModeTracker()
        tracker.feed(bytes("\u{1b}[?1049h"))
        let started = Date()
        tracker.feed(chunk)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(tracker.altScreen)
        XCTAssertLessThan(elapsed, 1.0, "\(chunk.count) bytes took \(elapsed)s")
    }
}
