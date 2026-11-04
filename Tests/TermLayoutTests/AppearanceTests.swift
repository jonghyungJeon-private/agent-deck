import XCTest
@testable import TermLayout

final class AppearanceModeTests: XCTestCase {
    private func decode(_ json: String) throws -> ToolLayout { try JSONDecoder().decode(ToolLayout.self, from: Data(json.utf8)) }

    /// 값이 없거나 모르는 값이면 자동
    func testMissingOrUnknownValueMeansAuto() throws {
        XCTAssertEqual(AppearanceMode.default, .auto)
        XCTAssertEqual(ToolLayout().appearance, .auto)
        XCTAssertEqual(try decode(#"{"version":1}"#).appearance, .auto)
        XCTAssertEqual(try decode(#"{"version":1,"appearance":"sepia"}"#).appearance, .auto)
        XCTAssertEqual(try decode(#"{"version":1,"appearance":""}"#).appearance, .auto)
        XCTAssertEqual(AppearanceMode(stored: nil), .auto)
        XCTAssertEqual(AppearanceMode(stored: "nonsense"), .auto)
        // 이 설정이 생기기 전 파일(글꼴 크기·작은 창 정보만 있는)도 자동
        XCTAssertEqual(try decode(#"{"version":1,"fontSize":16,"floatCorner":"bottomRight"}"#).appearance, .auto)
    }

    func testStoredValuesDecodeAndRoundTrip() throws {
        XCTAssertEqual(try decode(#"{"version":1,"appearance":"light"}"#).appearance, .light)
        XCTAssertEqual(try decode(#"{"version":1,"appearance":"dark"}"#).appearance, .dark)
        XCTAssertEqual(try decode(#"{"version":1,"appearance":"auto"}"#).appearance, .auto)
        for mode in AppearanceMode.allCases {
            var layout = ToolLayout()
            layout.appearance = mode
            layout.fontSize = 15
            let back = try JSONDecoder().decode(ToolLayout.self, from: XCTUnwrap(layout.data()))
            XCTAssertEqual(back.appearance, mode)
            XCTAssertEqual(back.fontSize, 15) // 다른 설정은 그대로
        }
    }

    /// 자동은 파일에 적지 않는다(다른 판이 읽어도 그대로), 고르면 적는다
    func testAutoIsNotWrittenButLightAndDarkAre() throws {
        var layout = ToolLayout()
        XCTAssertFalse(String(decoding: try XCTUnwrap(layout.data()), as: UTF8.self).contains("appearance"))
        layout.appearance = .light
        XCTAssertTrue(String(decoding: try XCTUnwrap(layout.data()), as: UTF8.self).contains(#""appearance" : "light""#))
    }

    func testIsDarkFollowsSystemOnlyInAuto() {
        XCTAssertTrue(AppearanceMode.auto.isDark(systemIsDark: true))
        XCTAssertFalse(AppearanceMode.auto.isDark(systemIsDark: false))
        for system in [true, false] {
            XCTAssertFalse(AppearanceMode.light.isDark(systemIsDark: system))
            XCTAssertTrue(AppearanceMode.dark.isDark(systemIsDark: system))
        }
    }

    func testDebugArgumentParsing() {
        XCTAssertEqual(AppearanceMode(argument: "auto"), .auto)
        XCTAssertEqual(AppearanceMode(argument: " Light "), .light)
        XCTAssertEqual(AppearanceMode(argument: "dark"), .dark)
        XCTAssertEqual(AppearanceMode(argument: "다크"), .dark)
        XCTAssertEqual(AppearanceMode(argument: "라이트"), .light)
        XCTAssertNil(AppearanceMode(argument: ""))
        XCTAssertNil(AppearanceMode(argument: "blue"))
    }

    func testTitlesAreDistinct() {
        XCTAssertEqual(Set(AppearanceMode.allCases.map(\.title)).count, 3)
        XCTAssertTrue(AppearanceMode.auto.title.hasPrefix("자동"))
    }
}

final class PaletteTests: XCTestCase {
    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double(hex >> shift & 0xff) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// 다크 값은 이 설정이 생기기 전 색 그대로
    func testDarkValuesAreTheOriginalOnes() {
        XCTAssertEqual(PaletteColor.background.hex(dark: true), 0x282c34)
        XCTAssertEqual(PaletteColor.chrome.hex(dark: true), 0x21252b)
        XCTAssertEqual(PaletteColor.chromeRaised.hex(dark: true), 0x2c313a)
        XCTAssertEqual(PaletteColor.textPrimary.hex(dark: true), 0xdcdfe4)
        XCTAssertEqual(PaletteColor.textDim.hex(dark: true), 0x7f848e)
        XCTAssertEqual(PaletteColor.textSecondary.hex(dark: true), 0xa0a7b3)
        XCTAssertEqual(PaletteColor.accent.hex(dark: true), 0xc099ff)
        XCTAssertEqual(PaletteColor.border.hex(dark: true), 0x3e4451)
        XCTAssertEqual(PaletteColor.syntaxKeyword.hex(dark: true), 0xcf8e6d)
        XCTAssertEqual(PaletteColor.editorText.hex(dark: true), 0xc9ccd3)
    }

    func testLookupDiffersByModeForEveryToken() {
        for token in PaletteColor.allCases {
            XCTAssertNotEqual(token.hex(dark: true), token.hex(dark: false), "\(token)")
            XCTAssertLessThanOrEqual(token.hex(dark: false), 0xffffff)
        }
        XCTAssertEqual(PaletteColor.background.hex(dark: false), 0xfafafa)
    }

    /// 라이트는 바탕이 밝고, 글자는 바탕과 충분히 대비된다(다크의 반대 방향)
    func testLightPaletteIsReadableOnLightSurfaces() {
        let bg = PaletteColor.background.hex(dark: false), chrome = PaletteColor.chrome.hex(dark: false)
        XCTAssertGreaterThan(luminance(bg), 0.9)
        XCTAssertGreaterThan(luminance(chrome), 0.75)
        XCTAssertLessThan(luminance(chrome), luminance(bg)) // 사이드바·탭 줄은 터미널보다 한 단계 진하게(다크의 "한 단계 어둡게"와 같은 성격)
        XCTAssertGreaterThan(luminance(PaletteColor.chromeRaised.hex(dark: false)), 0.6)
        XCTAssertGreaterThan(contrast(PaletteColor.textPrimary.hex(dark: false), chrome), 10)
        XCTAssertGreaterThan(contrast(PaletteColor.textSecondary.hex(dark: false), chrome), 5.5)
        for token in [PaletteColor.textDim, .accent, .codex, .claude, .green, .yellow, .red, .purple, .user] {
            XCTAssertGreaterThanOrEqual(contrast(token.hex(dark: false), chrome), 4.0, "\(token)")
        }
        // 편집기: 글자·키워드·문자열·주석이 편집기 바탕에서 읽힌다
        for token in [PaletteColor.editorText, .syntaxKeyword, .syntaxString, .syntaxNumber, .syntaxType, .syntaxKey] {
            XCTAssertGreaterThanOrEqual(contrast(token.hex(dark: false), bg), 4.5, "\(token)")
        }
        XCTAssertGreaterThanOrEqual(contrast(PaletteColor.syntaxComment.hex(dark: false), bg), 3.5)
    }

    /// TermAppearance.apply(to:) 는 `theme.minimumContrast` 를 뷰에 넣는다: 라이트는 켜고(3.0) 다크는 끈다(1.0).
    func testTerminalThemeMinimumContrastByMode() {
        XCTAssertEqual(TerminalTheme.theme(dark: false).minimumContrast, 3.0)
        XCTAssertEqual(TerminalTheme.theme(dark: true).minimumContrast, 1.0)
    }

    func testTerminalThemeLookupByMode() {
        XCTAssertEqual(TerminalTheme.theme(dark: true), .dark)
        XCTAssertEqual(TerminalTheme.theme(dark: false), .light)
        XCTAssertNotEqual(TerminalTheme.dark, TerminalTheme.light)
        for theme in [TerminalTheme.dark, .light] {
            XCTAssertEqual(theme.palette.count, 16)
            XCTAssertEqual(Set(theme.palette).count, 16) // 16색이 서로 다르다
        }
        // 다크는 Ghostty 기본(예전 그대로)
        XCTAssertEqual(TerminalTheme.dark.background, 0x282c34)
        XCTAssertEqual(TerminalTheme.dark.foreground, 0xffffff)
        XCTAssertEqual(TerminalTheme.dark.palette[1], 0xcc6666)
        // 터미널 바탕은 앱 바탕과 같다(두 모드 모두)
        XCTAssertEqual(TerminalTheme.dark.background, PaletteColor.background.hex(dark: true))
        XCTAssertEqual(TerminalTheme.light.background, PaletteColor.background.hex(dark: false))
        XCTAssertEqual(TerminalTheme.dark.selection, PaletteColor.selection.hex(dark: true))
        XCTAssertEqual(TerminalTheme.light.selection, PaletteColor.selection.hex(dark: false))
    }

    /// 라이트 터미널: 글자는 진하게, 색 글자(빨강~청록·밝은 쪽)는 밝은 바탕에서 읽힌다
    func testLightTerminalIsReadable() {
        let theme = TerminalTheme.light
        XCTAssertGreaterThan(luminance(theme.background), 0.9)
        XCTAssertGreaterThanOrEqual(contrast(theme.foreground, theme.background), 7)
        XCTAssertGreaterThanOrEqual(contrast(theme.caret, theme.background), 3)
        for index in [0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15] {
            XCTAssertGreaterThanOrEqual(contrast(theme.palette[index], theme.background), 3.5, "ANSI \(index)")
        }
        XCTAssertGreaterThanOrEqual(contrast(theme.palette[7], theme.background), 3.0) // "흰색" 은 어두운 회색
        XCTAssertGreaterThan(contrast(theme.selection, theme.background), 1.05)       // 선택 영역이 바탕과 구분된다
        XCTAssertGreaterThanOrEqual(contrast(theme.foreground, theme.selection), 7)   // 선택해도 글자가 읽힌다
    }
}
