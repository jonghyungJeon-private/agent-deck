import TermLayout
import XCTest

final class TabBarFitTests: XCTestCase {
    func testReserveCoversBothPillsGapEdgeAndClearance() {
        // ⌨ 28 + 간격 8 + 🌐 28 + 오른쪽 여백 8 + 여유 8
        XCTAssertEqual(TabBarFit.reserve(pillWidths: [28, 28], gap: 8, trailing: 8, clearance: 8), 80)
    }

    func testReserveGrowsWithExpandedBrowserPill() {
        let collapsed = TabBarFit.reserve(pillWidths: [28, 28], gap: 8, trailing: 8, clearance: 8)
        let expanded = TabBarFit.reserve(pillWidths: [28, 150], gap: 8, trailing: 8, clearance: 8)
        XCTAssertEqual(expanded - collapsed, 122)
    }

    func testReserveIsZeroWithoutPills() {
        XCTAssertEqual(TabBarFit.reserve(pillWidths: [], gap: 8, trailing: 8, clearance: 8), 0)
    }

    func testTitlesUntouchedWhenTheyFit() {
        let widths = TabBarFit.titleWidths(titles: [80, 120], fixed: [60, 60], extra: 32, available: 400, minTitle: 24)
        XCTAssertEqual(widths, [80, 120])
    }

    func testLongestTitlesShrinkFirstAndTotalFits() {
        let titles = [40.0, 200, 120], fixed = [60.0, 60, 60]
        let widths = TabBarFit.titleWidths(titles: titles, fixed: fixed, extra: 32, available: 420, minTitle: 24)
        XCTAssertEqual(widths[0], 40, "short title stays whole")
        XCTAssertLessThan(widths[1], 200)
        XCTAssertLessThanOrEqual(widths[2], 120)
        XCTAssertLessThanOrEqual(widths.reduce(0, +) + fixed.reduce(0, +) + 32, 420 + 0.001)
        XCTAssertEqual(widths.reduce(0, +) + fixed.reduce(0, +) + 32, 420, accuracy: 0.01)
    }

    func testTitlesStopAtTheMinimum() {
        let widths = TabBarFit.titleWidths(titles: [100, 100, 100], fixed: [60, 60, 60], extra: 32, available: 100, minTitle: 24)
        XCTAssertEqual(widths, [24, 24, 24])
    }

    func testTitleShorterThanMinimumKeepsItsOwnWidth() {
        let widths = TabBarFit.titleWidths(titles: [10, 100], fixed: [60, 60], extra: 32, available: 100, minTitle: 24)
        XCTAssertEqual(widths, [10, 24])
    }

    func testBranchFollowsWorktreeFolderName() {
        XCTAssertTrue(GitWorktrees.branchFollowsName("side-ux-polish", name: "side-ux-polish"))
        XCTAssertTrue(GitWorktrees.branchFollowsName("side/ux-polish-20261109", name: "side-ux-polish-20261109"))
        XCTAssertFalse(GitWorktrees.branchFollowsName("feature/login", name: "scratch"))
    }
}
