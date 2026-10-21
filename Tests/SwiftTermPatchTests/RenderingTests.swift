import AppKit
@testable import SwiftTerm
import XCTest

final class RenderingTests: XCTestCase {
    private final class View: TerminalView {
        var invalidated: [CGRect] = []
        // 화면 전체 다시 그리기(needsDisplay = true)도 따로 기록한다.
        var fullRepaint = false
        var repainted: Bool { fullRepaint || !invalidated.isEmpty }
        override func setNeedsDisplay(_ rect: NSRect) {
            invalidated.append(rect)
            super.setNeedsDisplay(rect)
        }
        override var needsDisplay: Bool {
            get { super.needsDisplay }
            set {
                if newValue { fullRepaint = true }
                super.needsDisplay = newValue
            }
        }
        func resetRepaints() {
            invalidated.removeAll()
            fullRepaint = false
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
            view.resetRepaints()
            view.feed(text: "\u{1b}[2;1H\u{1b}[2K\u{1b}[48;5;147m새 한글\u{1b}[0m")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.invalidated.isEmpty)
            XCTAssertFalse(view.fullRepaint)
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
        view.resetRepaints()
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
            XCTAssertFalse(view.repainted)
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
            // 바뀐 행과 그 아래 한 행(넘친 글자 잔상 정리)
            XCTAssertEqual(view.invalidated, [CGRect(x: 0, y: view.frame.height - 3*h,
                                                     width: view.frame.width, height: 2*h)])
            XCTAssertFalse(view.fullRepaint)
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
            XCTAssertEqual(view.invalidated.first?.height, 2 * view.cellDimension.height)
            XCTAssertFalse(view.fullRepaint)
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
            view.resetRepaints()
            view.feed(text: "\u{1b}[2;1Hbravo")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.repainted)
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
            view.resetRepaints()
            view.feed(text: "\u{1b}[H한글\u{1b}[4:2;58;2;255;0;0mA\u{1b}[0m")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.repainted)
            view.feed(text: "\u{1b}[1;5H\u{1b}[4:3;58;2;0;255;0mA\u{1b}[0m")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertTrue(view.repainted)
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
            view.resetRepaints()
            view.feed(text: "\u{1b}[2;1Hbravo")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.selection.active)
            XCTAssertTrue(view.repainted)
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
            view.resetRepaints()
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
                view.resetRepaints()
                change()
                XCTAssertTrue(view.lineInfoCache.isEmpty)
                view.updateDisplay(notifyAccessibility: false)
                XCTAssertTrue(view.repainted)
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
            view.resetRepaints()
            view.feed(text: "\u{1b}[H\u{1b}[2Kalpha")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertTrue(view.repainted)
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
                view.resetRepaints()
                view.feed(text: text)
                view.updateDisplay(notifyAccessibility: false)
                XCTAssertEqual(view.invalidated.count, 1)
                XCTAssertFalse(view.fullRepaint)
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
            view.resetRepaints()
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.invalidated.isEmpty)
        }
    }

    func testOptionChangeStillInvalidatesAfterOffscreenCacheWarmup() {
        onMain {
            let view = primedView()
            view.customBlockGlyphs.toggle()
            paint(view, into: bitmap(view))
            view.resetRepaints()
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.invalidated.isEmpty)
        }
    }

    /// 화면에 실제로 반영될 무효화(전체 또는 rect)만 다시 칠한다.
    private func flush(_ view: View, into rep: NSBitmapImageRep) {
        if view.fullRepaint {
            paint(view, into: rep)
        } else {
            for rect in view.invalidated { paint(view, into: rep, rect: rect) }
        }
        view.resetRepaints()
    }

    private func freshPixels(_ view: TerminalView) -> Data {
        let rep = bitmap(view)
        view.lineInfoCache.removeAll()
        paint(view, into: rep)
        return pixels(rep)
    }

    private func rowRect(_ view: TerminalView, _ row: Int) -> CGRect {
        let h = view.cellDimension.height
        return CGRect(x: 0, y: view.frame.height - CGFloat(row + 1) * h, width: view.frame.width, height: h)
    }

    /// 화면 행 row 의 픽셀 중 그려진(alpha > 0) 것이 있는지
    private func hasInk(_ rep: NSBitmapImageRep, row: Int, cellHeight: CGFloat) -> Bool {
        let data = rep.bitmapData!
        let top = Int(ceil(CGFloat(row) * cellHeight)), bottom = Int(floor(CGFloat(row + 1) * cellHeight))
        for y in top..<min(bottom, rep.pixelsHigh) {
            for x in 0..<rep.pixelsWide where data[y * rep.bytesPerRow + x * 4 + 3] != 0 { return true }
        }
        return false
    }

    func testChangedRowRepaintsGlyphOverflowIntoUnchangedRowBelow() {
        onMain {
            let view = primedView()
            // 아래로 쌓이는 티베트 자모와 결합 부호: 행 2 의 글자가 빈 행 3 까지 내려온다.
            view.feed(text: "\u{1b}[3;1H\u{1b}[2K\u{0F40}\u{0F90}\u{0F91}\u{0F92} x\u{0323}\u{0324}\u{0325}\u{0326}")
            view.updateDisplay(notifyAccessibility: false)
            let screen = bitmap(view)
            paint(view, into: screen)
            XCTAssertTrue(hasInk(screen, row: 3, cellHeight: view.cellDimension.height), "넘친 글자가 아래 행에 그려져야 시험이 의미 있다")
            view.resetRepaints()
            view.feed(text: "\u{1b}[3;1H\u{1b}[2Kplain")
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.fullRepaint)
            XCTAssertFalse(view.invalidated.isEmpty)
            flush(view, into: screen)
            XCTAssertFalse(hasInk(screen, row: 3, cellHeight: view.cellDimension.height), "잔상")
            XCTAssertEqual(pixels(screen), freshPixels(view))
        }
    }

    func testFindBarReappliedSearchSelectionRepaintsHighlightRow() {
        onMain {
            let view = primedView()
            // TerminalFindBar.applyHighlight 와 같은 API·배타적 끝 열
            let highlight = { view.selection.setSearchSelection(start: Position(col: 0, row: 1), end: Position(col: 5, row: 1)) }
            highlight()
            view.updateDisplay(notifyAccessibility: false)
            let screen = bitmap(view)
            paint(view, into: screen)
            let highlighted = pixels(screen)
            view.resetRepaints()
            // 출력(feedPrepare)이 선택을 지우고, 그 사이 한 번 그려진다.
            view.feed(text: "\u{1b}[3;1Hcharlie")
            XCTAssertFalse(view.selection.active)
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertFalse(view.fullRepaint)
            flush(view, into: screen)
            XCTAssertEqual(pixels(screen), freshPixels(view))
            XCTAssertNotEqual(pixels(screen), highlighted)
            // 찾기 막대가 같은 범위를 다시 적용한다.
            highlight()
            view.updateDisplay(notifyAccessibility: false)
            XCTAssertTrue(view.fullRepaint || view.invalidated.contains { $0.contains(rowRect(view, 1)) })
            flush(view, into: screen)
            XCTAssertEqual(pixels(screen), highlighted)
            XCTAssertEqual(pixels(screen), freshPixels(view))
        }
    }

    func testSelectionMoveInvalidatesOnlyOldAndNewRows() {
        onMain {
            let view = primedView()
            let yDisp = view.terminal.displayBuffer.yDisp
            view.selection.select(row: yDisp + 1)
            let screen = bitmap(view)
            paint(view, into: screen)
            view.resetRepaints()
            view.selection.select(row: yDisp + 5)
            XCTAssertFalse(view.fullRepaint)
            XCTAssertTrue(view.invalidated.contains { $0.contains(rowRect(view, 1)) })
            XCTAssertTrue(view.invalidated.contains { $0.contains(rowRect(view, 5)) })
            XCTAssertFalse(view.invalidated.contains { $0.intersects(rowRect(view, 3)) })
            flush(view, into: screen)
            XCTAssertEqual(pixels(screen), freshPixels(view))
        }
    }

    func testClearingSelectionInvalidatesOldRows() {
        onMain {
            let view = primedView()
            view.selection.setSelection(start: Position(col: 1, row: 0), end: Position(col: 3, row: 2))
            let screen = bitmap(view)
            paint(view, into: screen)
            let selected = pixels(screen)
            view.resetRepaints()
            view.selection.selectNone()
            XCTAssertFalse(view.fullRepaint)
            for row in 0...2 { XCTAssertTrue(view.invalidated.contains { $0.contains(rowRect(view, row)) }) }
            XCTAssertFalse(view.invalidated.contains { $0.intersects(rowRect(view, 5)) })
            flush(view, into: screen)
            XCTAssertNotEqual(pixels(screen), selected)
            XCTAssertEqual(pixels(screen), freshPixels(view))
        }
    }
}
