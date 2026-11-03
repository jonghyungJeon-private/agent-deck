import XCTest
@testable import BrowserCore

final class AgentCursorTests: XCTestCase {
    func testDecodesWhatAbxWrites() throws {
        let json = #"{"seq":17,"t":1793662284908,"targetId":"36CF","x":485,"y":316,"kind":"click","name":"위클리카"}"#
        let c = try JSONDecoder().decode(AgentCursor.self, from: Data(json.utf8))
        XCTAssertEqual(c, AgentCursor(seq: 17, t: 1793662284908, targetId: "36CF", x: 485, y: 316, kind: "click", name: "위클리카"))
        XCTAssertTrue(c.presses)
    }

    func testLabels() {
        func label(_ kind: String, _ name: String? = nil, key: String? = nil) -> String {
            AgentCursor(seq: 1, t: 0, targetId: "", x: 0, y: 0, kind: kind, name: name, key: key).label
        }
        XCTAssertEqual(label("click", "위클리카"), "클릭 · 위클리카")
        XCTAssertEqual(label("fill", "검색어를 입력해 주세요."), "입력 · 검색어를 입력해 주세요.")
        XCTAssertEqual(label("fill"), "입력")
        XCTAssertEqual(label("fill", "  "), "입력")
        XCTAssertEqual(label("press", key: "Enter"), "Enter 키")
        XCTAssertEqual(label("scroll", key: "down"), "스크롤 아래로")
        XCTAssertEqual(label("click", String(repeating: "가", count: 30)), "클릭 · " + String(repeating: "가", count: 23) + "…")
        XCTAssertFalse(AgentCursor(seq: 1, t: 0, targetId: "", x: 0, y: 0, kind: "fill").presses)
    }

    func testViewPointIsTheInverseOfCssPoint() {
        // 칸이 페이지보다 넓다: 위아래가 아닌 양옆에 여백
        let t = ViewportTransform(bounds: CGSize(width: 1000, height: 400), viewport: CGSize(width: 1280, height: 640))
        let view = t.viewPoint(CGPoint(x: 640, y: 320))!
        XCTAssertEqual(view.x, 500, accuracy: 0.001)
        XCTAssertEqual(view.y, 200, accuracy: 0.001)
        let back = t.cssPoint(t.viewPoint(CGPoint(x: 100, y: 50))!)!
        XCTAssertEqual(back.x, 100, accuracy: 0.001)
        XCTAssertEqual(back.y, 50, accuracy: 0.001)
        XCTAssertNil(ViewportTransform(bounds: .zero, viewport: CGSize(width: 1, height: 1)).viewPoint(.zero))
    }
}
