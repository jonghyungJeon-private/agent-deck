import BrowserCore
import XCTest

final class BrowserDisplayTests: XCTestCase {
    func testDefaultsAreAWindowAtNormalLevel() {
        let prefs = BrowserDisplayPrefs()
        XCTAssertEqual(prefs.display(for: "ad-1"), BrowserDisplay(placement: .window, level: .normal))
    }

    /// 고르면 그 세션 값이자 새 세션의 기본값 — 이미 따로 고른 세션은 그대로
    func testChoosingSetsSessionAndDefault() {
        var prefs = BrowserDisplayPrefs()
        prefs.choose(BrowserDisplay(placement: .window, level: .always), for: "ad-1")
        prefs.choose(BrowserDisplay(placement: .dock, level: .normal), for: "ad-2")
        XCTAssertEqual(prefs.display(for: "ad-1").level, .always)
        XCTAssertEqual(prefs.display(for: "ad-2").placement, .dock)
        XCTAssertEqual(prefs.display(for: "ad-new").placement, .dock)
        prefs.forget("ad-1")
        XCTAssertEqual(prefs.display(for: "ad-1").placement, .dock)
    }

    func testRoundTripAndToleratesUnknownValues() throws {
        var prefs = BrowserDisplayPrefs()
        prefs.choose(BrowserDisplay(placement: .dock, level: .whileActive), for: "ad-1")
        let decoded = try JSONDecoder().decode(BrowserDisplayPrefs.self, from: XCTUnwrap(prefs.data()))
        XCTAssertEqual(decoded, prefs)
        let odd = try JSONDecoder().decode(BrowserDisplayPrefs.self,
                                           from: Data(#"{"defaults":{"placement":"moon","level":"always"},"sessions":{"ad-2":{"level":"x"}}}"#.utf8))
        XCTAssertEqual(odd.defaults, BrowserDisplay(placement: .window, level: .always))
        XCTAssertEqual(odd.display(for: "ad-2"), BrowserDisplay())
    }

    /// 도크에서 "칸에 맞춤": 넓은 도크는 칸 그대로(1:1), 좁은 도크는 폭 1024 에 칸 비율(빈 띠 없이), 고른 고정 해상도·창은 그대로
    func testDockedPageSize() {
        var options = BrowserViewOptions()
        options.resolution = .fit
        XCTAssertEqual(options.pageSize(for: CGSize(width: 1500, height: 1700), docked: true), CGSize(width: 1500, height: 1700))
        XCTAssertEqual(options.pageSize(for: CGSize(width: 640, height: 700), docked: true), CGSize(width: 1024, height: 1120))
        XCTAssertEqual(options.pageSize(for: CGSize(width: 900, height: 450), docked: true), CGSize(width: 1024, height: 512))
        // 아주 가늘고 긴 칸은 높이에 상한
        XCTAssertEqual(options.pageSize(for: CGSize(width: 200, height: 1000), docked: true).height, 4096)
        XCTAssertEqual(options.pageSize(for: CGSize(width: 1100, height: 700), docked: false), CGSize(width: 1100, height: 700))
        options.resolution = .r1440x900
        XCTAssertEqual(options.pageSize(for: CGSize(width: 500, height: 700), docked: true), CGSize(width: 1440, height: 900))
    }
}
