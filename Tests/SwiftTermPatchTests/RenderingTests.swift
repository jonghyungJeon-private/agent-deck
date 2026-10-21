import AppKit
@testable import SwiftTerm
import XCTest

final class RenderingTests: XCTestCase {
    private final class View: TerminalView {
        var invalidated: [CGRect] = []
        override func setNeedsDisplay(_ rect: NSRect) {
            invalidated.append(rect)
            super.setNeedsDisplay(rect)
        }
    }

    private func onMain(_ body: () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.sync(execute: body) }
    }

    private func makeView() -> View {
        let view = View(frame: CGRect(x: 0, y: 0, width: 800, height: 360),
                        font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        view.useBrightColors = false
        view.getTerminal().ansi256PaletteStrategy = .xterm
        view.feed(text: "\u{1b}[?1049h\u{1b}[H한글 가독성 ABC\r\n\u{1b}[1;38;5;117m굵은 한글 Bold\u{1b}[0m\r\n┌─────┬─────┐\r\n│ 색상 │ 256 │\r\n└─────┴─────┘\r\n\u{1b}[4munderline\u{1b}[0m\r\n\u{1b}[9mstrike\u{1b}[0m")
        return view
    }

    private func bitmap(_ view: TerminalView) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    }

    private func paint(_ view: TerminalView, into rep: NSBitmapImageRep, rect: CGRect? = nil) {
        let graphics = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.saveGState()
        context.clip(to: rect ?? view.bounds)
        view.drawTerminalContents(dirtyRect: rect ?? view.bounds, context: context,
                                  bufferOffset: view.terminal.displayBuffer.yDisp)
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func pixels(_ rep: NSBitmapImageRep) -> Data {
        Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    func testCachedContentMatchesFreshRendering() {
        onMain {
            let view = makeView()
            let first = bitmap(view), cached = bitmap(view), fresh = bitmap(view)
            paint(view, into: first)
            TerminalView.lineCacheHits = 0
            paint(view, into: cached)
            XCTAssertGreaterThan(TerminalView.lineCacheHits, 0)
            XCTAssertEqual(pixels(first), pixels(cached))
            view.lineInfoCache.removeAll()
            paint(view, into: fresh)
            XCTAssertEqual(pixels(first), pixels(fresh))
            let glyphRect = CGRect(x: 0, y: view.bounds.height - view.cellDimension.height,
                                   width: 200, height: view.cellDimension.height)
            let glyphs = bitmap(view)
            paint(view, into: glyphs, rect: glyphRect)
            XCTAssertTrue(pixels(glyphs).contains { $0 != 0 }, "한글·Latin 글자가 실제 픽셀을 남겨야 한다")
        }
    }

    func testPartialUpdateMatchesFullRedrawIncludingEraseAndBackground() {
        onMain {
            let view = makeView()
            let partial = bitmap(view), full = bitmap(view)
            paint(view, into: partial)
            view.terminal.clearUpdateRange()
            view.invalidated.removeAll()
            view.feed(text: "\u{1b}[2;1H\u{1b}[2K\u{1b}[48;5;147m새 한글\u{1b}[0m")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.invalidated.isEmpty)
            XCTAssertLessThan(view.invalidated.map(\.height).max() ?? 0, view.bounds.height)
            for rect in view.invalidated { paint(view, into: partial, rect: rect) }
            paint(view, into: full)
            XCTAssertEqual(pixels(partial), pixels(full))
            XCTAssertEqual(view.verifyLineCache().different, 0)
        }
    }

    func testSelectionScrollbackResizeAndBlinkInvalidateGeometry() {
        onMain {
            let view = makeView()
            view.feed(text: "\u{1b}[?1049l" + (0..<70).map { "\($0) 한글 \u{1b}[5mblink\u{1b}[0m\r\n" }.joined())
            view.scrollTo(row: 12)
            let unselected = bitmap(view)
            paint(view, into: unselected)
            for step in 0..<4 {
                switch step {
                case 0: view.selection.select(row: view.terminal.displayBuffer.yDisp + 1)
                case 1: view.scrollTo(row: 14)
                case 2: view.setFrameSize(CGSize(width: 720, height: 320))
                default: view.setTextBlinkVisibleForTesting(false)
                }
                let cached = bitmap(view), fresh = bitmap(view)
                paint(view, into: cached)
                if step == 0 { XCTAssertNotEqual(pixels(cached), pixels(unselected)) }
                view.lineInfoCache.removeAll()
                paint(view, into: fresh)
                XCTAssertEqual(pixels(cached), pixels(fresh), "step \(step)")
                XCTAssertEqual(view.verifyLineCache().different, 0)
            }
        }
    }

    private func primedView() -> View {
        let view = View(frame: CGRect(x: 0, y: 0, width: 800, height: 360),
                        font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        view.feed(text: "\u{1b}[?1049h\u{1b}[Halpha\r\nbravo\r\ncharlie")
        view.updateDisplay(notifyAccessibility: false)
        paint(view, into: bitmap(view))
        view.invalidated.removeAll()
        return view
    }

    func testIdenticalResendReusesContentWithoutInvalidating() {
        onMain {
            let view = primedView()
            let line = view.terminal.displayBuffer.lines[0]
            let entry = view.lineInfoCache[ObjectIdentifier(line)]
            let generation = line.generation
            TerminalView.lineCacheHits = 0
            // 지웠다가 다시 쓴 경우도 최종 내용이 같으면 재사용한다.
            view.feed(text: "\u{1b}[H\u{1b}[2Kalpha")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertGreaterThan(line.generation, generation)
            XCTAssertTrue(view.invalidated.isEmpty)
            XCTAssertGreaterThan(TerminalView.lineCacheHits, 0)
            XCTAssertTrue(view.lineInfoCache[ObjectIdentifier(line)] === entry)
            let cached = bitmap(view), fresh = bitmap(view)
            paint(view, into: cached)
            view.lineInfoCache.removeAll()
            paint(view, into: fresh)
            XCTAssertEqual(pixels(cached), pixels(fresh))
        }
    }

    func testOneChangedCellInvalidatesOnlyItsRow() {
        onMain {
            let view = primedView()
            view.feed(text: "\u{1b}[2;2HX")
            view.updateDisplay(notifyAccessibility: false)
            let h = view.cellDimension.height
            XCTAssertEqual(view.invalidated, [CGRect(x: 0, y: view.frame.height - 2*h,
                                                     width: view.frame.width, height: h)])
        }
    }

    func testAttributeOnlyChangeInvalidatesItsRowAndRebuilds() {
        onMain {
            let view = primedView()
            let line = view.terminal.displayBuffer.lines[1]
            let entry = view.lineInfoCache[ObjectIdentifier(line)]
            view.feed(text: "\u{1b}[2;1H\u{1b}[1;38;5;117;48;5;147mb\u{1b}[0m")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertEqual(view.invalidated.count, 1)
            XCTAssertEqual(view.invalidated.first?.height, view.cellDimension.height)
            paint(view, into: bitmap(view))
            XCTAssertFalse(view.lineInfoCache[ObjectIdentifier(line)] === entry)
            XCTAssertEqual(view.verifyLineCache().different, 0)
        }
    }

    func testFindHighlightAndManualSelectionSurviveIdenticalOutput() {
        onMain {
            let view = primedView()
            view.allowMouseReporting = false
            XCTAssertTrue(view.findNext("bravo", scrollToResult: false))
            view.updateDisplay(notifyAccessibility: false)
            let highlighted = bitmap(view)
            paint(view, into: highlighted)
            XCTAssertNotNil(view.selectedColumnsRange(row: 1, cols: view.terminal.cols))
            view.invalidated.removeAll()
            view.feed(text: "\u{1b}[2;1Hbravo")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertTrue(view.invalidated.isEmpty)
            let resent = bitmap(view)
            paint(view, into: resent)
            XCTAssertEqual(pixels(highlighted), pixels(resent))
            view.selection.setSelection(start: Position(col: 1, row: 0), end: Position(col: 4, row: 0))
            let selected = bitmap(view), fresh = bitmap(view)
            paint(view, into: selected)
            view.lineInfoCache.removeAll()
            paint(view, into: fresh)
            XCTAssertEqual(pixels(selected), pixels(fresh))
            XCTAssertNotEqual(pixels(highlighted), pixels(selected))
        }
    }

    func testWideCharactersAndUnderlineAttributesArePartOfContent() {
        onMain {
            let view = primedView()
            view.feed(text: "\u{1b}[H한글\u{1b}[4:2;58;2;255;0;0mA\u{1b}[0m")
            view.updateDisplay(notifyAccessibility: false)
            paint(view, into: bitmap(view))
            view.invalidated.removeAll()
            view.feed(text: "\u{1b}[H한글\u{1b}[4:2;58;2;255;0;0mA\u{1b}[0m")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertTrue(view.invalidated.isEmpty)
            view.feed(text: "\u{1b}[1;5H\u{1b}[4:3;58;2;0;255;0mA\u{1b}[0m")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.invalidated.isEmpty)
            let cached = bitmap(view), fresh = bitmap(view)
            paint(view, into: cached)
            view.lineInfoCache.removeAll()
            paint(view, into: fresh)
            XCTAssertEqual(pixels(cached), pixels(fresh))
        }
    }
    func testOutputClearingSearchSelectionRepaintsHighlight() {
        onMain {
            let view = primedView()
            XCTAssertTrue(view.findNext("bravo", scrollToResult: false))
            let highlighted = bitmap(view)
            paint(view, into: highlighted)
            view.invalidated.removeAll()
            view.feed(text: "\u{1b}[2;1Hbravo")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.selection.active)
            XCTAssertFalse(view.invalidated.isEmpty)
            let cached = bitmap(view), fresh = bitmap(view)
            paint(view, into: cached)
            view.lineInfoCache.removeAll()
            paint(view, into: fresh)
            XCTAssertEqual(pixels(cached), pixels(fresh))
            XCTAssertNotEqual(pixels(highlighted), pixels(cached))
        }
    }
    func testScrollbackAndWrappedParagraphKeepConservativeInvalidation() {
        onMain {
            let view = primedView()
            view.feed(text: "\u{1b}[?1049l" + (0..<70).map { "row \($0) 한글\r\n" }.joined())
            view.updateDisplay(notifyAccessibility: false)
            view.scrollTo(row: 5)
            paint(view, into: bitmap(view))
            view.invalidated.removeAll()
            view.feed(text: "more output")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertTrue(view.invalidated.contains { $0.height == view.frame.height })
            let line = view.terminal.displayBuffer.lines[view.terminal.displayBuffer.yDisp]
            let snapshot = RowRenderContent(line: line)
            line.isWrapped.toggle()
            XCTAssertFalse(snapshot.matches(line))
        }
    }
    func testRenderingOptionsInvalidateContentReuse() {
        onMain {
            let view = primedView()
            for change in [{ view.customBlockGlyphs.toggle() }, { view.antiAliasCustomBlockGlyphs.toggle() },
                           { view.useBrightColors.toggle() }, { view.bidiHostPolicy = .legacyLeftToRight },
                           { view.linkHighlightMode = .always }, { view.selectedTextBackgroundColor = .orange },
                           { view.selectedTextForegroundColor = .blue }] {
                view.invalidated.removeAll()
                change()
                XCTAssertTrue(view.lineInfoCache.isEmpty)
                view.updateDisplay(notifyAccessibility: false)
                XCTAssertFalse(view.invalidated.isEmpty)
                paint(view, into: bitmap(view))
            }
        }
    }
    func testUncacheableBidiDoesNotResurrectAnOlderPaintedRow() {
        onMain {
            let view = primedView()
            let line = view.terminal.displayBuffer.lines[0]
            view.feed(text: "\u{1b}[H\u{1b}[2Kאבג")
            view.updateDisplay(notifyAccessibility: false)
            paint(view, into: bitmap(view))
            XCTAssertNil(view.lineInfoCache[ObjectIdentifier(line)])
            view.invalidated.removeAll()
            view.feed(text: "\u{1b}[H\u{1b}[2Kalpha")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.invalidated.isEmpty)
            let cached = bitmap(view), fresh = bitmap(view)
            paint(view, into: cached)
            view.lineInfoCache.removeAll()
            paint(view, into: fresh)
            XCTAssertEqual(pixels(cached), pixels(fresh))
        }
    }
    func testPartialWideCellReplacementMatchesFullPainting() {
        onMain {
            let view = primedView()
            view.feed(text: "\u{1b}[H한글\u{1b}[0m")
            view.updateDisplay(notifyAccessibility: false)
            let partial = bitmap(view)
            paint(view, into: partial)
            for text in ["\u{1b}[1;2HX", "\u{1b}[H\u{1b}[1;48;5;147m한글\u{1b}[0m"] {
                view.invalidated.removeAll()
                view.feed(text: text)
                view.updateDisplay(notifyAccessibility: false)
                XCTAssertEqual(view.invalidated.count, 1)
                for rect in view.invalidated { paint(view, into: partial, rect: rect) }
                let full = bitmap(view)
                paint(view, into: full)
                XCTAssertEqual(pixels(partial), pixels(full))
            }
        }
    }
    func testOffscreenDrawBeforeFeedFlushDoesNotSuppressOnscreenInvalidation() {
        onMain {
            let view = primedView()
            view.feed(text: "\u{1b}[2;2HX")
            // 창 캡처가 예약된 updateDisplay 보다 먼저 캐시를 채울 수 있다.
            paint(view, into: bitmap(view))
            view.invalidated.removeAll()
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.invalidated.isEmpty)
        }
    }

    func testOptionChangeStillInvalidatesAfterOffscreenCacheWarmup() {
        onMain {
            let view = primedView()
            view.customBlockGlyphs.toggle()
            paint(view, into: bitmap(view))
            view.invalidated.removeAll()
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.invalidated.isEmpty)
        }
    }
}
