import XCTest
@testable import BrowserCore

final class PageCursorTests: XCTestCase {
    func testExplicitCursorNames() {
        XCTAssertEqual(PageCursor.parse("pointer|0|0|1"), .pointer)
        XCTAssertEqual(PageCursor.parse("text|0|0|0"), .text)
        XCTAssertEqual(PageCursor.parse("not-allowed|0|0|0"), .notAllowed)
        XCTAssertEqual(PageCursor.parse("grab|0|0|0"), .openHand)
        XCTAssertEqual(PageCursor.parse("grabbing|0|0|0"), .closedHand)
        XCTAssertEqual(PageCursor.parse("col-resize|0|0|0"), .resizeHorizontal)
        XCTAssertEqual(PageCursor.parse("row-resize|0|0|0"), .resizeVertical)
        XCTAssertEqual(PageCursor.parse("progress|0|0|0"), .arrow) // 모르는 이름은 화살표
    }

    func testAutoDependsOnElementKind() {
        XCTAssertEqual(PageCursor.parse("auto|1|0|0"), .text) // 입력칸
        XCTAssertEqual(PageCursor.parse("auto|0|1|0"), .text) // 글자 위
        XCTAssertEqual(PageCursor.parse("auto|0|0|1"), .pointer) // 링크
        XCTAssertEqual(PageCursor.parse("auto|0|0|0"), .arrow)
        XCTAssertEqual(PageCursor.parse("default|1|1|1"), .arrow) // default 는 그대로 화살표
    }

    func testGarbageFallsBackToArrow() {
        XCTAssertEqual(PageCursor.parse(nil), .arrow)
        XCTAssertEqual(PageCursor.parse(""), .arrow)
        XCTAssertEqual(PageCursor.parse("pointer"), .arrow)
        XCTAssertEqual(PageCursor.parse("a|b|c|d|e"), .arrow)
    }

    func testQueryScriptEmbedsRoundedPoint() {
        let script = PageCursor.queryScript(x: 10.6, y: 20.2)
        XCTAssertTrue(script.contains("x = 11, y = 20"))
    }
}
