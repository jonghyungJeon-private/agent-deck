import XCTest
@testable import TermLayout

final class WindowChromeTests: XCTestCase {
    func testNoInsetWhenTrafficLightsSitInsideTheSidebar() {
        // 사이드바(왼쪽 도크)가 탭 줄 시작을 신호등 오른쪽보다 멀리 밀었다
        XCTAssertEqual(WindowChrome.leadingInset(lightsMaxX: 68, contentMinX: 260, gap: 12), 0)
    }

    func testInsetClearsTheLightsWhenTheSidebarIsHiddenOrOnTheRight() {
        XCTAssertEqual(WindowChrome.leadingInset(lightsMaxX: 68, contentMinX: 0, gap: 12), 80)
    }

    func testInsetShrinksWhenTheSidebarIsNarrowerThanTheLights() {
        XCTAssertEqual(WindowChrome.leadingInset(lightsMaxX: 68, contentMinX: 50, gap: 12), 30)
        XCTAssertEqual(WindowChrome.leadingInset(lightsMaxX: 68, contentMinX: 80, gap: 12), 0)
    }

    func testNoInsetInFullScreenWhereTheLightsAreGone() {
        XCTAssertEqual(WindowChrome.leadingInset(lightsMaxX: 0, contentMinX: 0, gap: 12), 0)
    }

    func testDoubleClickFollowsTheSystemSetting() {
        XCTAssertEqual(WindowChrome.doubleClickAction(action: "Maximize", legacyMinimize: nil), .zoom)
        XCTAssertEqual(WindowChrome.doubleClickAction(action: "Minimize", legacyMinimize: nil), .minimize)
        XCTAssertEqual(WindowChrome.doubleClickAction(action: "None", legacyMinimize: nil), .none)
        XCTAssertEqual(WindowChrome.doubleClickAction(action: nil, legacyMinimize: true), .minimize)
        XCTAssertEqual(WindowChrome.doubleClickAction(action: nil, legacyMinimize: false), .zoom)
        XCTAssertEqual(WindowChrome.doubleClickAction(action: nil, legacyMinimize: nil), .zoom)
        XCTAssertEqual(WindowChrome.doubleClickAction(action: "Something new", legacyMinimize: nil), .zoom)
    }

    func testFillDoubleClickIsTreatedAsZoom() {
        XCTAssertEqual(WindowChrome.doubleClickAction(action: "Fill", legacyMinimize: nil), .zoom)
        XCTAssertEqual(WindowChrome.doubleClickAction(action: "fill", legacyMinimize: true), .zoom)
    }

    func testLightsAreCentredInTheRowAtNormalScale() {
        // 탭 줄 32, 단추 16, 제목 줄 뷰 28: 위에서 8
        XCTAssertEqual(WindowChrome.lightsTop(rowHeight: 32, buttonHeight: 16, containerHeight: 28), 8)
    }

    func testLightsStayInsideTheTitleBarViewAtLargeScale() {
        // 배율 1.6: 탭 줄 51 → 가운데는 17.5 지만 뷰 안(28 − 16 = 12)에 가둔다
        XCTAssertEqual(WindowChrome.lightsTop(rowHeight: 51, buttonHeight: 16, containerHeight: 28), 12)
        for row in stride(from: 24.0, through: 64.0, by: 1.0) {
            let top = WindowChrome.lightsTop(rowHeight: row, buttonHeight: 16, containerHeight: 28)
            XCTAssertGreaterThanOrEqual(top, 0)
            XCTAssertLessThanOrEqual(top + 16, 28, "row \(row)")
        }
        XCTAssertEqual(WindowChrome.lightsTop(rowHeight: 10, buttonHeight: 16, containerHeight: 28), 0)
        XCTAssertEqual(WindowChrome.lightsTop(rowHeight: 40, buttonHeight: 16, containerHeight: 10), 0, "a view shorter than the button")
    }

    func testDockTopPutsTheToolStripBesideTheLightsWhenItFits() {
        // 신호등 오른쪽 끝 68, 버튼 줄 칸 폭 150: 도크가 68 + 12 + 150 + 4 = 234 이상이면 신호등 줄에 앉는다
        let wide = WindowChrome.dockTop(lightsMaxX: 68, hasStrip: true, stripWidth: 150, dockWidth: 260, rowHeight: 32, gap: 12, margin: 4)
        XCTAssertEqual(wide, WindowChrome.DockTop(bandHeight: 0, stripLeading: 80))
        let narrow = WindowChrome.dockTop(lightsMaxX: 68, hasStrip: true, stripWidth: 150, dockWidth: 233, rowHeight: 32, gap: 12, margin: 4)
        XCTAssertEqual(narrow, WindowChrome.DockTop(bandHeight: 32, stripLeading: 4), "too narrow: lights get their own row")
    }

    func testDockTopKeepsTheLightsRowWithoutAStrip() {
        XCTAssertEqual(WindowChrome.dockTop(lightsMaxX: 68, hasStrip: false, stripWidth: 0, dockWidth: 400, rowHeight: 32, gap: 12, margin: 4),
                       WindowChrome.DockTop(bandHeight: 32, stripLeading: 4))
    }

    func testDockTopHasNoEmptyBandInFullScreen() {
        // 전체 화면: 신호등이 없다(lightsMaxX 0) — 빈 줄을 남기지 않는다
        XCTAssertEqual(WindowChrome.dockTop(lightsMaxX: 0, hasStrip: true, stripWidth: 150, dockWidth: 260, rowHeight: 32, gap: 12, margin: 4),
                       WindowChrome.DockTop(bandHeight: 0, stripLeading: 4))
        XCTAssertEqual(WindowChrome.dockTop(lightsMaxX: 0, hasStrip: false, stripWidth: 0, dockWidth: 260, rowHeight: 32, gap: 12, margin: 4).bandHeight, 0)
    }

    func testWindowTitleIsSessionNameAndFolder() {
        let home = "/Users/me"
        XCTAssertEqual(WindowChrome.windowTitle(session: "demo", folder: "/Users/me/work/demo", home: home).title, "demo")
        XCTAssertEqual(WindowChrome.windowTitle(session: "demo", folder: "/Users/me/work/demo", home: home).subtitle, "~/work/demo")
        XCTAssertEqual(WindowChrome.windowTitle(session: "x", folder: "/Users/me", home: home).subtitle, "~")
        XCTAssertEqual(WindowChrome.windowTitle(session: "x", folder: "/Users/meow/a", home: home).subtitle, "/Users/meow/a",
                       "a sibling folder that merely shares the prefix is not under home")
        XCTAssertEqual(WindowChrome.windowTitle(session: "x", folder: "/opt/app", home: home).subtitle, "/opt/app")
    }

    func testWindowTitleFallsBackToTheAppName() {
        XCTAssertEqual(WindowChrome.windowTitle(session: nil, folder: "/a", home: "/h").title, "AgentDeck")
        XCTAssertEqual(WindowChrome.windowTitle(session: "  ", folder: "/a", home: "/h").subtitle, "")
        XCTAssertEqual(WindowChrome.windowTitle(session: "n", folder: nil, home: "/h").subtitle, "")
    }
}
