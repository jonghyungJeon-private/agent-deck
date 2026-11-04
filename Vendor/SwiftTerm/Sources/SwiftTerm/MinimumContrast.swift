//
// MinimumContrast.swift
//
// AgentDeck patch: "minimum contrast" (like Ghostty's `minimum-contrast` and iTerm's "Minimum contrast").
// Pure color math with no UI dependency so it can be unit tested (Tests/SwiftTermPatchTests).
//
// When the WCAG contrast ratio of a foreground against its background is below the threshold, the
// foreground's lightness is moved (OKLab L, keeping its hue and chroma, chroma only reduced when the
// result would leave the sRGB gamut) the shortest distance that reaches the threshold: darker on a
// light background, lighter on a dark one. If that cannot reach it, black or white is used.
//

import Foundation

/// An sRGB color, each channel 0...1 (gamma encoded).
struct ContrastRGB: Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// 0xRRGGBB
    init(hex: UInt32) {
        self.init(r: Double(hex >> 16 & 0xff) / 255, g: Double(hex >> 8 & 0xff) / 255, b: Double(hex & 0xff) / 255)
    }

    static let black = ContrastRGB(r: 0, g: 0, b: 0)
    static let white = ContrastRGB(r: 1, g: 1, b: 1)

    /// Packed 8 bits per channel (cache key)
    var packed: UInt32 {
        func q(_ v: Double) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return q(r) << 16 | q(g) << 8 | q(b)
    }
}

enum MinimumContrast {
    /// WCAG 2.x maximum (black on white)
    static let maximumRatio = 21.0

    // MARK: WCAG contrast

    static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encode(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// WCAG relative luminance
    static func luminance(_ c: ContrastRGB) -> Double {
        0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// WCAG contrast ratio, 1...21 (the order of the arguments does not matter)
    static func ratio(_ a: ContrastRGB, _ b: ContrastRGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: OKLab / OKLCH

    struct OKLab { var L: Double; var a: Double; var b: Double }

    static func oklab(_ c: ContrastRGB) -> OKLab {
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return OKLab(L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Linear-light RGB (may be outside 0...1)
    static func linearRGB(_ lab: OKLab) -> (Double, Double, Double) {
        let l_ = lab.L + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m_ = lab.L - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s_ = lab.L - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// Hue in degrees (0..<360) and chroma
    static func hueChroma(_ c: ContrastRGB) -> (hue: Double, chroma: Double) {
        let lab = oklab(c)
        var h = atan2(lab.b, lab.a) * 180 / .pi
        if h < 0 { h += 360 }
        return (h, (lab.a * lab.a + lab.b * lab.b).squareRoot())
    }

    /// The color with lightness `L` and the hue/chroma of (`a`, `b`). When that is outside the sRGB gamut the chroma is
    /// reduced (hue kept) until it fits, so only saturation is lost, not hue.
    static func color(L: Double, a: Double, b: Double) -> ContrastRGB {
        func inGamut(_ t: Double) -> Bool {
            let (r, g, bl) = linearRGB(OKLab(L: L, a: a * t, b: b * t))
            let e = 1e-6
            return r >= -e && r <= 1 + e && g >= -e && g <= 1 + e && bl >= -e && bl <= 1 + e
        }
        var t = 1.0
        if !inGamut(1) {
            var lo = 0.0, hi = 1.0
            for _ in 0..<18 {
                let mid = (lo + hi) / 2
                if inGamut(mid) { lo = mid } else { hi = mid }
            }
            t = lo
        }
        let (r, g, bl) = linearRGB(OKLab(L: L, a: a * t, b: b * t))
        func clamp(_ v: Double) -> Double { encode(max(0, min(1, v))) }
        return ContrastRGB(r: clamp(r), g: clamp(g), b: clamp(bl))
    }

    // MARK: adjustment

    /// `fg` unchanged when its ratio against `bg` is already at least `threshold` (or the threshold is 1 or less);
    /// otherwise the nearest lightness (same hue, same chroma where the gamut allows) that meets it.
    /// Falls back to black or white (whichever contrasts more) when no lightness of that hue does.
    static func adjust(fg: ContrastRGB, bg: ContrastRGB, threshold: Double) -> ContrastRGB {
        guard threshold > 1, ratio(fg, bg) < threshold else { return fg }
        let target = min(threshold, maximumRatio)
        // Light backgrounds are darkened, dark ones lightened. 0.179 is where black and white contrast equally.
        let preferDarker = luminance(bg) > 0.179
        let blackRatio = ratio(.black, bg), whiteRatio = ratio(.white, bg)
        var darker = preferDarker
        if darker ? blackRatio < target : whiteRatio < target {
            // The preferred direction cannot reach it; use the other one if it can, else the best of the two.
            if darker ? whiteRatio >= target : blackRatio >= target {
                darker.toggle()
            } else {
                return blackRatio >= whiteRatio ? .black : .white
            }
        }
        let lab = oklab(fg)
        // Bisect lightness between the original (fails) and the extreme (passes); `pass` always meets the threshold.
        var pass = darker ? 0.0 : 1.0
        var fail = lab.L
        if (darker && fail <= pass) || (!darker && fail >= pass) {
            // fg is already at the extreme in that direction (e.g. dark text on a dark background wanting darker):
            // not reachable by lightness in the chosen direction; use the extreme.
            return darker ? .black : .white
        }
        var best: ContrastRGB = darker ? .black : .white
        for _ in 0..<24 {
            let mid = (pass + fail) / 2
            let candidate = color(L: mid, a: lab.a, b: lab.b)
            if ratio(candidate, bg) >= target {
                pass = mid
                best = candidate
            } else {
                fail = mid
            }
        }
        return best
    }
}

/// Bounded memo of `MinimumContrast.adjust`, keyed by (fg, bg, threshold). One per view; the renderer asks while
/// building attributes, and the attribute cache already avoids per glyph work, this avoids repeating the search for
/// the same pair across attributes (bold/italic/underline variants of one color pair).
final class MinimumContrastCache {
    private struct Key: Hashable {
        var fg: UInt32
        var bg: UInt32
        var threshold: Double
    }

    private var storage: [Key: ContrastRGB] = [:]
    static let capacity = 4096

    var count: Int { storage.count }

    func removeAll() { storage.removeAll(keepingCapacity: true) }

    func adjusted(fg: ContrastRGB, bg: ContrastRGB, threshold: Double) -> ContrastRGB {
        guard threshold > 1 else { return fg }
        let key = Key(fg: fg.packed, bg: bg.packed, threshold: threshold)
        if let hit = storage[key] { return hit }
        let result = MinimumContrast.adjust(fg: fg, bg: bg, threshold: threshold)
        if storage.count >= Self.capacity { storage.removeAll(keepingCapacity: true) }
        storage[key] = result
        return result
    }
}
