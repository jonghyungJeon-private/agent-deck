import AppKit
@testable import SwiftTerm
import XCTest

/// 최소 대비(MinimumContrast.swift, `TerminalView.minimumContrast`) 시험
final class MinimumContrastTests: XCTestCase {
    private let lightBg = ContrastRGB(hex: 0xfafafa)
    private let darkBg = ContrastRGB(hex: 0x282c34)

    // xterm 256 표의 색(16~231 큐브: 0, 95, 135, 175, 215, 255)
    private let xterm117 = ContrastRGB(hex: 0x87d7ff)
    private let xterm221 = ContrastRGB(hex: 0xffd75f)
    private let xterm228 = ContrastRGB(hex: 0xffff87)
    private let xterm159 = ContrastRGB(hex: 0xafffff)

    private func hue(_ c: ContrastRGB) -> Double { MinimumContrast.hueChroma(c).hue }

    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    // MARK: ratio

    func testRatioMatchesWCAG() {
        XCTAssertEqual(MinimumContrast.ratio(.black, .white), 21, accuracy: 1e-9)
        XCTAssertEqual(MinimumContrast.ratio(.white, .black), 21, accuracy: 1e-9)
        XCTAssertEqual(MinimumContrast.ratio(.white, .white), 1, accuracy: 1e-12)
        // #767676 on white is the well known 4.54:1 boundary
        XCTAssertEqual(MinimumContrast.ratio(ContrastRGB(hex: 0x767676), .white), 4.54, accuracy: 0.01)
        // #87d7ff on #fafafa (the washed out status line sky blue)
        XCTAssertEqual(MinimumContrast.ratio(xterm117, lightBg), 1.52, accuracy: 0.01)
    }

    func testRatioIsSymmetricAndAtLeastOne() {
        for hex: UInt32 in [0x000000, 0x87d7ff, 0xffd75f, 0x383a42, 0xfafafa] {
            let c = ContrastRGB(hex: hex)
            XCTAssertEqual(MinimumContrast.ratio(c, lightBg), MinimumContrast.ratio(lightBg, c), accuracy: 1e-12)
            XCTAssertGreaterThanOrEqual(MinimumContrast.ratio(c, lightBg), 1)
        }
    }

    // MARK: adjusted color meets the threshold

    func testAdjustedColorMeetsThreshold() {
        for threshold in [1.5, 2.0, 3.0, 4.5, 7.0] {
            for fg in [xterm117, xterm221, xterm228, xterm159, ContrastRGB(hex: 0xa0e0ff), ContrastRGB(hex: 0xffffff)] {
                let out = MinimumContrast.adjust(fg: fg, bg: lightBg, threshold: threshold)
                XCTAssertGreaterThanOrEqual(MinimumContrast.ratio(out, lightBg), threshold - 1e-9,
                                            "fg \(fg.packed) threshold \(threshold)")
            }
        }
    }

    func testDarkBackgroundLightens() {
        // dark gray blue (#1a3a5a-ish) on the dark theme background is unreadable; it must get lighter, not darker
        let fg = ContrastRGB(hex: 0x30405a)
        let out = MinimumContrast.adjust(fg: fg, bg: darkBg, threshold: 3)
        XCTAssertGreaterThanOrEqual(MinimumContrast.ratio(out, darkBg), 3 - 1e-9)
        XCTAssertGreaterThan(MinimumContrast.luminance(out), MinimumContrast.luminance(fg))
        XCTAssertLessThan(hueDistance(hue(out), hue(fg)), 5)
    }

    func testLightBackgroundDarkens() {
        let out = MinimumContrast.adjust(fg: xterm117, bg: lightBg, threshold: 3)
        XCTAssertLessThan(MinimumContrast.luminance(out), MinimumContrast.luminance(xterm117))
    }

    func testFallsBackToBlackOrWhite() {
        // no lightness of any hue reaches 21:1 against #fafafa, black is the best it can do
        XCTAssertEqual(MinimumContrast.adjust(fg: xterm117, bg: lightBg, threshold: 21), .black)
        // mid gray background: 3:1 is unreachable in the preferred direction but fine in the other
        let mid = ContrastRGB(hex: 0x777777)
        let out = MinimumContrast.adjust(fg: ContrastRGB(hex: 0x808080), bg: mid, threshold: 4)
        XCTAssertGreaterThanOrEqual(MinimumContrast.ratio(out, mid), 4 - 1e-9)
        // nothing reaches 12:1 on mid gray: best of black and white
        let best = MinimumContrast.adjust(fg: ContrastRGB(hex: 0x808080), bg: mid, threshold: 12)
        XCTAssertEqual(best, MinimumContrast.ratio(.white, mid) > MinimumContrast.ratio(.black, mid) ? .white : .black)
    }

    // MARK: hue

    func testHuePreserved() {
        let colors: [UInt32] = [0x87d7ff, 0xffd75f, 0xffff87, 0xafffff, 0xa0e0ff, 0xffaf5f, 0xafafff, 0xff87d7, 0x87d787, 0xd7afff]
        for hex in colors {
            let fg = ContrastRGB(hex: hex)
            let out = MinimumContrast.adjust(fg: fg, bg: lightBg, threshold: 3)
            XCTAssertLessThan(hueDistance(hue(fg), hue(out)), 3, String(format: "#%06x", hex))
            XCTAssertGreaterThan(MinimumContrast.hueChroma(out).chroma, 0.05, "keeps its color, not gray: \(String(format: "#%06x", hex))")
        }
    }

    // MARK: unchanged cases

    func testAlreadyContrastingColorUnchanged() {
        for hex: UInt32 in [0x383a42, 0x000000, 0xd0473b, 0x3f8f3d, 0x4078f2, 0xa626a4] {
            let fg = ContrastRGB(hex: hex)
            XCTAssertGreaterThanOrEqual(MinimumContrast.ratio(fg, lightBg), 3)
            XCTAssertEqual(MinimumContrast.adjust(fg: fg, bg: lightBg, threshold: 3), fg)
        }
        // white text on the dark background is already fine
        XCTAssertEqual(MinimumContrast.adjust(fg: .white, bg: darkBg, threshold: 3), .white)
    }

    func testThresholdOneIsOff() {
        for fg in [xterm117, xterm228, ContrastRGB(hex: 0xfafafa), .white, .black] {
            XCTAssertEqual(MinimumContrast.adjust(fg: fg, bg: lightBg, threshold: 1.0), fg)
            XCTAssertEqual(MinimumContrast.adjust(fg: fg, bg: lightBg, threshold: 0.5), fg)
        }
    }

    // MARK: cache

    func testCacheIsBoundedAndConsistent() {
        let cache = MinimumContrastCache()
        let a = cache.adjusted(fg: xterm117, bg: lightBg, threshold: 3)
        XCTAssertEqual(a, MinimumContrast.adjust(fg: xterm117, bg: lightBg, threshold: 3))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.adjusted(fg: xterm117, bg: lightBg, threshold: 3), a)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.adjusted(fg: xterm117, bg: lightBg, threshold: 1), xterm117) // off: not stored
        XCTAssertEqual(cache.count, 1)
        for i in 0..<(MinimumContrastCache.capacity + 50) {
            _ = cache.adjusted(fg: ContrastRGB(hex: UInt32(0xc00000 + i * 7 % 0x3fffff)), bg: lightBg, threshold: 2)
        }
        XCTAssertLessThanOrEqual(cache.count, MinimumContrastCache.capacity)
    }

    // MARK: rendering path (TerminalView.getAttributes)

    private func onMain(_ body: () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.sync(execute: body) }
    }

    private func rgb(_ color: NSColor) -> ContrastRGB {
        let c = color.usingColorSpace(.sRGB)!
        return ContrastRGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }

    private func makeLightView() -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.nativeBackgroundColor = NSColor(srgbRed: 0xfa / 255, green: 0xfa / 255, blue: 0xfa / 255, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 0x38 / 255, green: 0x3a / 255, blue: 0x42 / 255, alpha: 1)
        view.useBrightColors = false
        view.getTerminal().ansi256PaletteStrategy = .xterm
        return view
    }

    private func foreground(_ view: TerminalView, _ attribute: Attribute) -> ContrastRGB {
        rgb(view.getAttributes(attribute, withUrl: false)![.foregroundColor] as! NSColor)
    }

    private func background(_ view: TerminalView, _ attribute: Attribute) -> ContrastRGB {
        rgb(view.getAttributes(attribute, withUrl: false)![.backgroundColor] as! NSColor)
    }

    func testRenderingPath256ColorOnLightBackground() {
        onMain {
            let view = makeLightView()
            let attr = Attribute(fg: .ansi256(code: 117), bg: .defaultColor, style: [])
            // off by default: the raw xterm color
            XCTAssertEqual(foreground(view, attr).packed, 0x87d7ff)
            view.minimumContrast = 3.0
            let out = foreground(view, attr)
            XCTAssertGreaterThanOrEqual(MinimumContrast.ratio(out, lightBgOf(view)), 3.0 - 1e-3)
            XCTAssertLessThan(hueDistance(hue(out), hue(xterm117)), 3)
            // back to off restores the original (cache invalidated)
            view.minimumContrast = 1.0
            XCTAssertEqual(foreground(view, attr).packed, 0x87d7ff)
        }
    }

    private func lightBgOf(_ view: TerminalView) -> ContrastRGB { rgb(view.nativeBackgroundColor) }

    func testRenderingPathTruecolorDefaultAnsiAndExplicitBackground() {
        onMain {
            let view = makeLightView()
            view.minimumContrast = 3.0
            let bg = lightBgOf(view)
            // truecolor
            let tc = Attribute(fg: .trueColor(red: 0xa0, green: 0xe0, blue: 0xff), bg: .defaultColor, style: [])
            XCTAssertGreaterThanOrEqual(MinimumContrast.ratio(foreground(view, tc), bg), 3.0 - 1e-3)
            // ANSI 16 (index 11 of the default palette is a light yellow before the app installs its theme)
            let ansi = Attribute(fg: .ansi256(code: 11), bg: .defaultColor, style: [])
            XCTAssertGreaterThanOrEqual(MinimumContrast.ratio(foreground(view, ansi), bg), 3.0 - 1e-3)
            // default foreground that is already dark is untouched
            let def = Attribute(fg: .defaultColor, bg: .defaultColor, style: [])
            XCTAssertEqual(foreground(view, def).packed, 0x383a42)
            // the ratio is measured against the cell's real background (explicit dark one): white stays white
            let onDark = Attribute(fg: .trueColor(red: 255, green: 255, blue: 255), bg: .trueColor(red: 0x28, green: 0x2c, blue: 0x34), style: [])
            XCTAssertEqual(foreground(view, onDark).packed, 0xffffff)
            XCTAssertEqual(background(view, onDark).packed, 0x282c34) // backgrounds are never adjusted
        }
    }

    func testRenderingPathInverseDimAndUnderline() {
        onMain {
            let view = makeLightView()
            view.minimumContrast = 3.0
            // inverse: pale 117 becomes the background; the (default) foreground colour is drawn on it
            let inverse = Attribute(fg: .ansi256(code: 117), bg: .defaultColor, style: .inverse)
            let attrs = view.getAttributes(inverse, withUrl: false)!
            XCTAssertEqual(rgb(attrs[.backgroundColor] as! NSColor).packed, 0x87d7ff) // background untouched
            // swapped fg is the default background #fafafa (against 117: 1.52) so it is adjusted against the 117 block
            XCTAssertGreaterThanOrEqual(MinimumContrast.ratio(rgb(attrs[.foregroundColor] as! NSColor), rgb(attrs[.backgroundColor] as! NSColor)), 3 - 1e-3)
            // dim: blended toward the background first, then raised to the minimum
            let dim = Attribute(fg: .ansi256(code: 117), bg: .defaultColor, style: .dim)
            XCTAssertGreaterThanOrEqual(MinimumContrast.ratio(foreground(view, dim), lightBgOf(view)), 3 - 1e-3)
            // explicit underline colour is adjusted too
            let underlined = Attribute(fg: .defaultColor, bg: .defaultColor, style: .underline, underlineColor: .ansi256(code: 228))
            let u = view.getAttributes(underlined, withUrl: false)!
            XCTAssertGreaterThanOrEqual(MinimumContrast.ratio(rgb(u[.underlineColor] as! NSColor), lightBgOf(view)), 3 - 1e-3)
        }
    }

    func testSelectionColorsAreNotAdjusted() {
        onMain {
            let view = makeLightView()
            view.selectedTextBackgroundColor = NSColor(srgbRed: 0xd3 / 255, green: 0xdc / 255, blue: 0xee / 255, alpha: 1)
            view.minimumContrast = 3.0
            // the selection background is a view property, applied at draw time, never routed through the adjuster
            XCTAssertEqual(rgb(view.selectedTextBackgroundColor).packed, 0xd3dcee)
        }
    }
}
