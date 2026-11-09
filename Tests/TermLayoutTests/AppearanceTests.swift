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

    /// B2 · Ink refined(최종) 값 — 순수 값 확인(PALETTE.md §5 표)
    func testFinalInkValues() {
        let expected: [(PaletteColor, UInt32, UInt32)] = [
            (.background, 0x1c1b1a, 0xfdfcfa), (.chrome, 0x141312, 0xf4f2ee), (.chromeRaised, 0x292725, 0xe7e4dd),
            (.border, 0x383530, 0xd1cdc7), (.selection, 0x3a3733, 0xe3ded3),
            (.textPrimary, 0xe7e4de, 0x1c1a18), (.textSecondary, 0xa8a49c, 0x585550), (.textDim, 0x97938b, 0x66625d),
            (.accent, 0x73a1dc, 0x346aac), (.accentText, 0x8ab4ea, 0x285e9f), (.accentFill, 0x3a6ea5, 0x255b9c), (.onAccent, 0xffffff, 0xffffff),
            (.typeClaude, 0xe3975a, 0xa04f18), (.typeCodex, 0x64c3c6, 0x006f73), (.typeShell, 0xa8a49c, 0x585550),
            (.statusWorking, 0xe7e4de, 0x1c1a18), (.statusAttention, 0xe56c7f, 0xb12b4c), (.statusDone, 0xa3cb96, 0x29672e),
            (.statusIdle, 0xa8a49c, 0x585550), (.statusOrchestrating, 0xa8a49c, 0x585550), (.statusNone, 0x97938b, 0x66625d),
            (.warning, 0xedcf6f, 0x9e7b0b), (.warnText, 0xedcf6f, 0x815c0a),
            (.danger, 0xdb8ef2, 0x731a8a), (.dangerText, 0xdb8ef2, 0x731a8a), (.dangerFill, 0xb459cf, 0x8e32a7),
            (.agent, 0x84d17c, 0x367b30), (.onAgent, 0x141312, 0xffffff), (.human, 0xa8a49c, 0x585550),
            (.editorText, 0xe4e1dc, 0x2b2925), (.syntaxKeyword, 0xcf8e6d, 0x0033b3),
            (.markdownQuote, 0xa8a49c, 0x585550), (.markdownTableStripe, 0x232120, 0xf2f0ec), (.markdownHighlight, 0x50482f, 0xe8e0c5),
        ]
        for (token, dark, light) in expected {
            XCTAssertEqual(token.hex(dark: true), dark, "\(token) dark")
            XCTAssertEqual(token.hex(dark: false), light, "\(token) light")
        }
    }

    /// 색 하나 = 뜻 하나: 중립으로 정한 상태는 보조 글자와 같은 값, 작업 중은 주 글자와 같은 값(숨 쉬는 모양으로만 구분)
    func testNeutralStatusRolesShareTextValues() {
        for dark in [true, false] {
            XCTAssertEqual(PaletteColor.statusIdle.hex(dark: dark), PaletteColor.textSecondary.hex(dark: dark))
            XCTAssertEqual(PaletteColor.statusOrchestrating.hex(dark: dark), PaletteColor.textSecondary.hex(dark: dark))
            XCTAssertEqual(PaletteColor.typeShell.hex(dark: dark), PaletteColor.textSecondary.hex(dark: dark))
            XCTAssertEqual(PaletteColor.human.hex(dark: dark), PaletteColor.textSecondary.hex(dark: dark))
            XCTAssertEqual(PaletteColor.statusNone.hex(dark: dark), PaletteColor.textDim.hex(dark: dark))
            XCTAssertEqual(PaletteColor.statusWorking.hex(dark: dark), PaletteColor.textPrimary.hex(dark: dark))
        }
    }

    /// 두 모드 값이 서로 다르다(글자 위 흰색 `onAccent` 만 두 모드 모두 흰색)
    func testLookupDiffersByModeForEveryToken() {
        for token in PaletteColor.allCases {
            if token != .onAccent {
                XCTAssertNotEqual(token.hex(dark: true), token.hex(dark: false), "\(token)")
            }
            XCTAssertLessThanOrEqual(token.hex(dark: false), 0xffffff)
        }
        XCTAssertEqual(PaletteColor.background.hex(dark: false), 0xfdfcfa)
    }

    /// 대비 하한(PALETTE.md §5): 글자 4.5:1, 점·아이콘·포커스 3:1 — 사이드바(chrome)·고른 줄(chromeRaised) 위에서, 두 모드 모두
    func testContrastFloorsOnChromeSurfaces() {
        for dark in [true, false] {
            let chrome = PaletteColor.chrome.hex(dark: dark), raised = PaletteColor.chromeRaised.hex(dark: dark)
            let background = PaletteColor.background.hex(dark: dark)
            let text: [PaletteColor] = [.textPrimary, .textSecondary, .textDim, .accentText, .typeClaude, .typeCodex, .typeShell,
                                        .statusAttention, .warnText, .dangerText, .gitModified, .gitAdded, .gitUntracked, .gitConflicted, .gitChangedFolder]
            for token in text {
                for surface in [chrome, raised] {
                    XCTAssertGreaterThanOrEqual(contrast(token.hex(dark: dark), surface), 4.5, "\(token) dark=\(dark)")
                }
            }
            let marks: [PaletteColor] = [.accent, .statusWorking, .statusDone, .statusIdle, .statusOrchestrating, .statusNone, .warning, .danger, .agent, .human]
            for token in marks {
                for surface in [chrome, raised, background] {
                    XCTAssertGreaterThanOrEqual(contrast(token.hex(dark: dark), surface), 3.0, "\(token) dark=\(dark)")
                }
            }
            XCTAssertGreaterThanOrEqual(contrast(PaletteColor.onAccent.hex(dark: dark), PaletteColor.accentFill.hex(dark: dark)), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(PaletteColor.onAgent.hex(dark: dark), PaletteColor.agent.hex(dark: dark)), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(PaletteColor.editorText.hex(dark: dark), background), 4.5)
            // 작업 중 점이 가장 옅을 때(55%)도 3:1
            for surface in [chrome, raised] {
                let low = blend(PaletteColor.statusWorking.hex(dark: dark), over: surface, alpha: WorkingPulseSpec.minOpacity)
                XCTAssertGreaterThanOrEqual(contrast(low, surface), 3.0, "pulse low dark=\(dark)")
            }
        }
    }

    private func oklab(_ hex: UInt32) -> (Double, Double, Double) {
        func lin(_ shift: UInt32) -> Double {
            let c = Double(hex >> shift & 0xff) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = (lin(16), lin(8), lin(0))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// OKLab 거리 ×100 (≈ ΔE; 10 아래는 한눈에 구분하기 어렵다)
    private func deltaE(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (oklab(a), oklab(b))
        return 100 * (pow(x.0 - y.0, 2) + pow(x.1 - y.1, 2) + pow(x.2 - y.2, 2)).squareRoot()
    }

    /// 위험한 설정 색(PALETTE.md §5 `danger*`): 글자 4.5:1·표시 3:1 을 앱 바탕과 시스템 설정 창 카드 위에서,
    /// 스위치 켜짐 바탕은 카드와 흰 손잡이 양쪽에 3:1, 그리고 다른 역할 색과 ΔE 14 이상 떨어진다(한눈에 구분).
    func testDangerRoleIsReadableAndDistinct() {
        let systemCards: [Bool: [UInt32]] = [true: [0x2b2b2b, 0x1e1e1e], false: [0xffffff, 0xececec]]
        for dark in [true, false] {
            let surfaces = [PaletteColor.chrome, .chromeRaised, .background].map { $0.hex(dark: dark) } + systemCards[dark]!
            for surface in surfaces {
                XCTAssertGreaterThanOrEqual(contrast(PaletteColor.dangerText.hex(dark: dark), surface), 4.5, "dangerText dark=\(dark)")
                XCTAssertGreaterThanOrEqual(contrast(PaletteColor.danger.hex(dark: dark), surface), 3.0, "danger dark=\(dark)")
            }
            let fill = PaletteColor.dangerFill.hex(dark: dark)
            for card in systemCards[dark]! + [PaletteColor.chrome.hex(dark: dark)] {
                XCTAssertGreaterThanOrEqual(contrast(fill, card), 3.0, "dangerFill vs surface dark=\(dark)")
            }
            XCTAssertGreaterThanOrEqual(contrast(0xffffff, fill), 3.0, "dangerFill vs white thumb dark=\(dark)")
            let others: [PaletteColor] = [.statusAttention, .warning, .warnText, .typeClaude, .typeCodex, .accent, .accentText,
                                          .agent, .statusDone, .textPrimary, .textSecondary]
            for other in others {
                for danger in [PaletteColor.danger, .dangerText] {
                    XCTAssertGreaterThanOrEqual(deltaE(danger.hex(dark: dark), other.hex(dark: dark)), 14,
                                                "\(danger) vs \(other) dark=\(dark)")
                }
            }
        }
    }

    private func blend(_ fg: UInt32, over bg: UInt32, alpha: Double) -> UInt32 {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double(v >> s & 0xff) }
        func mix(_ s: UInt32) -> UInt32 { UInt32((ch(fg, s) * alpha + ch(bg, s) * (1 - alpha)).rounded()) }
        return mix(16) << 16 | mix(8) << 8 | mix(0)
    }

    /// 숨 쉬기 곡선: 주기 0 에서 1.0, 절반에서 0.55, 주기가 끝나면 다시 1.0(시계가 같으면 모든 점이 같은 값)
    func testWorkingPulseCurve() {
        XCTAssertEqual(WorkingPulseSpec.period, 1.6)
        XCTAssertEqual(WorkingPulseSpec.opacity(at: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(WorkingPulseSpec.opacity(at: 0.8), 0.55, accuracy: 1e-9)
        XCTAssertEqual(WorkingPulseSpec.opacity(at: 1.6), 1.0, accuracy: 1e-9)
        XCTAssertEqual(WorkingPulseSpec.opacity(at: 1000.0 * 1.6 + 0.4), WorkingPulseSpec.opacity(at: 0.4), accuracy: 1e-6)
        for step in 0...160 {
            let value = WorkingPulseSpec.opacity(at: Double(step) / 100)
            XCTAssertLessThanOrEqual(value, 1.0 + 1e-9)
            XCTAssertGreaterThanOrEqual(value, 0.55 - 1e-9)
        }
        XCTAssertEqual(WorkingPulseSpec.alignedBegin(now: 5.0), 4.8, accuracy: 1e-9)
        XCTAssertEqual(WorkingPulseSpec.alignedBegin(now: 3.2), 3.2, accuracy: 1e-9)
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
        for token in [PaletteColor.textDim, .accent, .typeClaude, .typeCodex, .statusDone, .statusAttention, .agent, .warnText, .dangerText] {
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
        // 다크: 바탕·글자·선택은 B2, 16색은 Ghostty 기본(Tomorrow Night, 예전 그대로)
        XCTAssertEqual(TerminalTheme.dark.background, 0x1c1b1a)
        XCTAssertEqual(TerminalTheme.dark.foreground, 0xe4e1dc)
        XCTAssertEqual(TerminalTheme.dark.palette[1], 0xcc6666)
        // 라이트: 종이 바탕, 파랑(4번)만 잉크 블루에 맞춰 #2f68b8
        XCTAssertEqual(TerminalTheme.light.background, 0xfdfcfa)
        XCTAssertEqual(TerminalTheme.light.foreground, 0x2b2925)
        XCTAssertEqual(TerminalTheme.light.palette[4], 0x2f68b8)
        XCTAssertEqual(TerminalTheme.dark.foreground, PaletteColor.editorText.hex(dark: true))
        XCTAssertEqual(TerminalTheme.light.foreground, PaletteColor.editorText.hex(dark: false))
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
