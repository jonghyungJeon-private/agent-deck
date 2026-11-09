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
