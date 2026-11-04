import Foundation
import TermLayout
import XCTest

/// 작은 창을 끄는 동안 자동 배치 보류(`FloatLayoutGate`)와, 에이전트 활동에 따른 자동 열기 설정·세션별 열림
final class FloatGateTests: XCTestCase {
    private enum Kind: Hashable { case browser, terminal }

    // MARK: 끄는 동안 자동 배치 보류

    func testAutoLayoutRunsWhenNotGesturing() {
        var gate = FloatLayoutGate<Kind>()
        XCTAssertTrue(gate.allowsAutoLayout(.terminal))
        XCTAssertFalse(gate.hasPending(.terminal))
        XCTAssertFalse(gate.end(.terminal)) // 끌기가 없었으니 미룬 것도 없다
    }

    func testAutoLayoutIsDeferredBetweenGestureStartAndEndThenRunsOnce() {
        var gate = FloatLayoutGate<Kind>()
        gate.begin(.terminal)
        // 데몬 갱신(bufferedBytes → rowsChanged → applyScratch)이 여러 번 와도 끄는 동안은 배치하지 않는다
        for _ in 0..<5 { XCTAssertFalse(gate.allowsAutoLayout(.terminal)) }
        XCTAssertTrue(gate.isGesturing(.terminal))
        XCTAssertTrue(gate.end(.terminal)) // 끝에서 한 번만
        XCTAssertFalse(gate.isGesturing(.terminal))
        XCTAssertTrue(gate.allowsAutoLayout(.terminal))
        XCTAssertFalse(gate.end(.terminal)) // 다시 끝내도 미룬 것은 없다
    }

    func testNoPendingLayoutWhenNothingRequestedDuringGesture() {
        var gate = FloatLayoutGate<Kind>()
        gate.begin(.browser)
        XCTAssertFalse(gate.end(.browser))
    }

    func testGestureOnOnePanelDoesNotBlockTheOther() {
        var gate = FloatLayoutGate<Kind>()
        gate.begin(.browser)
        XCTAssertTrue(gate.allowsAutoLayout(.terminal))
        XCTAssertFalse(gate.allowsAutoLayout(.browser))
        XCTAssertFalse(gate.end(.terminal))
        XCTAssertTrue(gate.end(.browser))
    }

    func testBothPanelsGuardedIndependently() {
        var gate = FloatLayoutGate<Kind>()
        gate.begin(.browser)
        gate.begin(.terminal)
        XCTAssertFalse(gate.allowsAutoLayout(.browser))
        XCTAssertFalse(gate.allowsAutoLayout(.terminal))
        XCTAssertTrue(gate.end(.browser))
        XCTAssertFalse(gate.allowsAutoLayout(.terminal)) // 터미널은 아직 끄는 중
        XCTAssertTrue(gate.end(.terminal))
    }

    // MARK: 자동 열기 설정(ui.json)

    private func load(_ json: String) throws -> ToolLayout { try JSONDecoder().decode(ToolLayout.self, from: Data(json.utf8)) }

    func testAutoOpenDefaultsOnAndIsTolerantWhenDecoding() throws {
        XCTAssertTrue(ToolLayout().autoOpenBrowser)
        XCTAssertTrue(try load("{}").autoOpenBrowser) // 빠짐
        XCTAssertTrue(try load(#"{"autoOpenBrowser":"nope"}"#).autoOpenBrowser) // 모르는 모양 → 켬, 파일 전체는 읽는다
        XCTAssertTrue(try load(#"{"autoOpenBrowser":7}"#).autoOpenBrowser)
        XCTAssertTrue(try load(#"{"autoOpenBrowser":null}"#).autoOpenBrowser)
        XCTAssertFalse(try load(#"{"autoOpenBrowser":false}"#).autoOpenBrowser)
        XCTAssertTrue(try load(#"{"autoOpenBrowser":true}"#).autoOpenBrowser)
        // 모르는 모양이어도 다른 값은 그대로 읽힌다
        let layout = try load(#"{"autoOpenBrowser":["x"],"floatCorner":"bottomRight","widths":{"left":300}}"#)
        XCTAssertEqual(layout.floatCorner, .bottomRight)
        XCTAssertEqual(layout.width(.left), 300)
    }

    func testAutoOpenSettingRoundTrips() throws {
        var layout = ToolLayout()
        layout.autoOpenBrowser = false
        let back = try JSONDecoder().decode(ToolLayout.self, from: XCTUnwrap(layout.data()))
        XCTAssertFalse(back.autoOpenBrowser)
        XCTAssertEqual(back, layout)
        // 켬(기본)이면 파일에 쓰지 않는다
        let on = try XCTUnwrap(String(data: XCTUnwrap(ToolLayout().data()), encoding: .utf8))
        XCTAssertFalse(on.contains("autoOpenBrowser"))
    }

    // MARK: 세션 지정 열기·닫기

    func testSetBrowserFloatOnFollowedSessionShowsAndHides() {
        var layout = ToolLayout()
        layout.follow(session: "ad-1")
        layout.setBrowserFloat(open: true, session: "ad-1")
        XCTAssertTrue(layout.browserFloat.shown)
        XCTAssertTrue(layout.browserFloat.isOpen(session: "ad-1"))
        layout.setBrowserFloat(open: false, session: "ad-1")
        XCTAssertFalse(layout.browserFloat.shown)
        XCTAssertFalse(layout.browserFloat.isOpen(session: "ad-1"))
    }

    func testSetBrowserFloatOnBackgroundSessionOnlyRecordsItsOpenFlag() {
        var layout = ToolLayout()
        layout.follow(session: "ad-1")
        layout.setBrowserFloat(open: true, session: "ad-2") // 보이지 않는 세션
        XCTAssertFalse(layout.browserFloat.shown) // 지금 보이는 세션의 창은 그대로
        XCTAssertTrue(layout.browserFloat.isOpen(session: "ad-2"))
        XCTAssertFalse(layout.browserFloat.isOpen(session: "ad-1"))
        layout.follow(session: "ad-2") // 그 세션으로 가면 열려 있다
        XCTAssertTrue(layout.browserFloat.shown)
        layout.follow(session: "ad-1")
        XCTAssertFalse(layout.browserFloat.shown)
        // 닫기도 그 세션 몫만
        layout.setBrowserFloat(open: false, session: "ad-2")
        layout.follow(session: "ad-2")
        XCTAssertFalse(layout.browserFloat.shown)
    }

    func testBackgroundOpenSurvivesSaveAndDoesNotTouchTheTerminalPanel() throws {
        var layout = ToolLayout()
        layout.follow(session: "ad-1")
        layout.setBrowserFloat(open: true, session: "ad-2")
        XCTAssertTrue(layout.terminalFloat.openSessions.isEmpty)
        let back = try JSONDecoder().decode(ToolLayout.self, from: XCTUnwrap(layout.data()))
        XCTAssertTrue(back.browserFloat.isOpen(session: "ad-2"))
    }
}
