import XCTest
@testable import TermLayout

final class BufferLineSearchTests: XCTestCase {
    struct Cell: BufferSearchCell {
        var searchCharacter: Character?
        var searchWidth: Int = 1
        init(_ ch: Character?, _ width: Int = 1) { searchCharacter = ch; searchWidth = width }
    }
    func row(_ cells: [Cell], wrapped: Bool = false, continues: Bool = false, wide: Bool = false) -> BufferLineSearch.Row {
        BufferLineSearch.extract(count: cells.count, wrapped: wrapped, continues: continues, nextStartsWide: wide, cellAt: { cells[$0] })
    }
    func match(_ row: Int, _ col: Int = 0) -> BufferLineSearch.Match {
        .init(start: .init(row: row, column: col), end: .init(row: row, column: col + 1))
    }

    func testExplicitTrailingSpacesAndInternalNulls() {
        let line = row([Cell("a"), Cell(nil), Cell("b"), Cell(" "), Cell(" "), Cell(nil), Cell(nil)])
        XCTAssertEqual(line.text, "a b  ")
        let hits = BufferSearchIndex().find("b  ", rows: [line])
        XCTAssertEqual(hits, [.init(start: .init(row: 0, column: 2), end: .init(row: 0, column: 5))])
        XCTAssertTrue(row([Cell(nil), Cell(nil)]).text.isEmpty)
    }

    func testActualColumnsForSameCharacterWithDifferentWidths() {
        let line = row([Cell("한", 2), Cell(nil, 0), Cell("한", 1), Cell("😀", 2), Cell(nil, 0), Cell("e\u{301}")])
        let index = BufferSearchIndex()
        let hits = index.find("한", rows: [line])
        XCTAssertEqual(hits, [.init(start: .init(row: 0, column: 0), end: .init(row: 0, column: 2)),
                              .init(start: .init(row: 0, column: 2), end: .init(row: 0, column: 3))])
        XCTAssertEqual(index.find("😀e\u{301}", rows: [line]).first,
                       .init(start: .init(row: 0, column: 3), end: .init(row: 0, column: 6)))
    }

    func testWrappedWidePaddingAndRightEdge() {
        let first = row([Cell("a"), Cell("b"), Cell(nil)], continues: true, wide: true)
        let second = row([Cell("한", 2), Cell(nil, 0), Cell("글", 2), Cell(nil, 0)], wrapped: true)
        XCTAssertEqual(first.text, "ab")
        let hits = BufferSearchIndex().find("b한글", rows: [first, second])
        XCTAssertEqual(hits, [.init(start: .init(row: 0, column: 1), end: .init(row: 1, column: 4))])
        XCTAssertEqual(BufferSearchIndex().find("ab", rows: [first, second]).first?.end, .init(row: 0, column: 2))
    }

    func testOutputReanchorsWithoutResettingNavigation() {
        var cursor = BufferSearchCursor()
        cursor.replace([match(0), match(50), match(51), match(52)], preferredRow: 50)
        XCTAssertEqual(cursor.current?.start.row, 50)
        cursor.move(backwards: false)
        XCTAssertEqual(cursor.currentIndex, 2)
        for i in 53...60 {
            cursor.replace([match(0)] + (50...i).map { match($0) })
            XCTAssertEqual(cursor.current?.start.row, i == 53 ? 51 : i - 2)
            cursor.move(backwards: false)
        }
        XCTAssertEqual(cursor.current?.start.row, 59)
        cursor.replace([match(0), match(58), match(60)])
        XCTAssertEqual(cursor.current?.start.row, 60)
        cursor.move(backwards: false)
        XCTAssertEqual(cursor.current?.start.row, 0)
        cursor.move(backwards: true)
        XCTAssertEqual(cursor.current?.start.row, 60)
    }

    func testTemporaryNoMatchesRetainsAnchor() {
        var cursor = BufferSearchCursor()
        cursor.replace([match(1), match(80)], preferredRow: 80)
        cursor.replace([])
        XCTAssertNil(cursor.currentIndex)
        cursor.replace([match(1), match(81), match(90)])
        XCTAssertEqual(cursor.current?.start.row, 81)
    }

    func testScrollbackTrimPreservesLogicalAnchor() {
        var cursor = BufferSearchCursor()
        cursor.replace([match(1), match(10), match(20)], preferredRow: 10)
        cursor.trimRows(3)
        XCTAssertEqual(cursor.current?.start.row, 7)
        cursor.replace([match(7), match(17), match(18)])
        XCTAssertEqual(cursor.currentIndex, 0)
        cursor.move(backwards: false)
        XCTAssertEqual(cursor.current?.start.row, 17)
    }

    func testUnchangedRowsReuseMappingAndSearchGroups() {
        let a = row([Cell("a")]), b = row([Cell("b")]), c = row([Cell("c")])
        let index = BufferSearchIndex()
        _ = index.find("a", rows: [a, b, c])
        XCTAssertEqual(index.rebuiltGroups, 3)
        _ = index.find("b", rows: [a, b, c])
        XCTAssertEqual(index.rebuiltGroups, 0)
        _ = index.find("b", rows: [a, b, row([Cell("d")])])
        XCTAssertEqual(index.rebuiltGroups, 1)
    }
}
