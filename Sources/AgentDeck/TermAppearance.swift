import AppKit
import CoreText
import SwiftTerm
import TermLayout
import TermWire

/// 터미널 모양. Ghostty 기본값과 맞춘다(사용자가 Ghostty 와 나란히 쓰므로 같은 느낌이 나게).
/// - 글꼴: JetBrains Mono 13pt(Ghostty 내장 글꼴) + Nerd Font 아이콘. 앱에 넣어 두고 이 앱 안에서만 등록한다.
/// - 색: 다크는 배경 #282c34, 글자 #ffffff, 16색 Tomorrow Night(Ghostty 기본 팔레트). 라이트는 Atom One Light 계열(`TerminalTheme.light`).
/// - 화면 모드(자동·라이트·다크, `AppearanceSetting`): 앱 테두리 색은 `NSColor(name:dynamicProvider:)` 라 창의 effectiveAppearance 를 따라
///   저절로 바뀐다. CGColor 로 한 번 받아 두는 곳은 `viewDidChangeEffectiveAppearance` 에서 다시 받는다(`NSColor.cg(in:)`).
///   터미널은 색을 직접 넣으므로 모양이 바뀔 때마다 `apply(to:)` 를 다시 부른다(`ThemedTerminalView`).
enum TermAppearance {
    static let defaultFontSize: CGFloat = 13
    static let fontSizeRange: ClosedRange<CGFloat> = 8...32
    /// 글꼴 크기가 바뀌었다(터미널·편집기 화면이 받아 글꼴을 바꾼다). `ui.json` 저장도 이 알림을 받아 한다.
    static let fontSizeChanged = Notification.Name("AgentDeck.fontSizeChanged")

    /// 앱 전체 글꼴 크기(터미널·편집기 내용, 앱 테두리는 `uiScale` 로 따라간다). 처음 읽을 때 `ui.json` 에서 가져온다.
    private(set) static var fontSize: CGFloat = {
        let saved = ToolLayout.load(from: TermPaths.home.appendingPathComponent("ui.json")).fontSize
        return saved.map { clampedFontSize(CGFloat($0)) } ?? defaultFontSize
    }()

    static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size.rounded(), fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// 크기를 바꾸고 알린다(같으면 아무것도 안 한다)
    static func setFontSize(_ size: CGFloat) {
        let next = clampedFontSize(size)
        guard next != fontSize else { return }
        fontSize = next
        NotificationCenter.default.post(name: fontSizeChanged, object: nil)
    }

    /// ⌘+ ⌘− ⌘0: 한 단계 키우기·줄이기·기본
    static func adjustFontSize(_ action: String) {
        switch action {
        case "bigger": setFontSize(fontSize + 1)
        case "smaller": setFontSize(fontSize - 1)
        default: setFontSize(defaultFontSize)
        }
    }

    /// 모드(어두운지)에 맞는 터미널 색 한 벌
    static func theme(dark: Bool) -> TerminalTheme { TerminalTheme.theme(dark: dark) }

    /// 지금 앱 모양(NSApp.effectiveAppearance)의 터미널 색 — 뷰가 아직 창에 없을 때
    static var currentTheme: TerminalTheme { theme(dark: NSApp?.effectiveAppearance.isDark ?? true) }

    static let background = NSColor.palette(.background)
    static let selection = NSColor.palette(.selection)

    /// 앱에 넣은 글꼴(Resources/Fonts — JetBrains Mono, Nerd Font 아이콘, D2Coding)을 이 프로세스에만 등록한다(사용자 글꼴 폴더는 건드리지 않음).
    static func registerBundledFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// 한글을 그릴 고정폭 글꼴. D2Coding 은 앱에 들어 있어(Resources/Fonts) 설치하지 않은 PC 에서도 같은 모양이다.
    /// 앞의 것부터 쓰고, 하나도 못 찾으면 시스템이 고르는 Apple SD Gothic Neo 로 그려진다.
    static let hangulFonts = ["D2Coding", "NanumGothicCoding"]

    /// 시험용: 이름별로 실제로 잡힌 글꼴 파일(앱에 넣은 것인지 시스템 것인지 확인)
    static func debugFontSources() -> String {
        (["JetBrainsMono-Regular", "SymbolsNFM"] + hangulFonts + ["D2CodingBold"]).map { name in
            guard let font = NSFont(name: name, size: 13) else { return "\(name)=없음" }
            let url = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL
            return "\(name)=\(url?.path ?? "?")"
        }.joined(separator: " | ")
    }

    /// 지금 크기의 터미널 글꼴
    static var font: NSFont { font(size: fontSize) }

    private static var fontCache: [CGFloat: NSFont] = [:]

    /// 터미널 글꼴(크기별로 한 번만 만든다). 아이콘(Nerd Font)·한글 글자는 이어서 찾을 글꼴로 붙인다. 없으면 시스템 고정폭 글꼴.
    static func font(size: CGFloat) -> NSFont {
        if let cached = fontCache[size] { return cached }
        let made = makeFont(size: size)
        fontCache[size] = made
        return made
    }

    private static func makeFont(size: CGFloat) -> NSFont {
        guard let base = NSFont(name: "JetBrainsMono-Regular", size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        var cascade: [NSFontDescriptor] = []
        for name in ["SymbolsNFM"] + hangulFonts where NSFont(name: name, size: size) != nil {
            cascade.append(NSFontDescriptor(fontAttributes: [.name: name]))
        }
        guard !cascade.isEmpty else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascade])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    // MARK: - 앱 테두리(사이드바·탭 줄·분할 테두리). herdr 처럼 어둡고 차분하게, 상태·포커스만 색으로 드러낸다.

    /// 사이드바·탭 줄 바탕(터미널보다 한 단계 어둡게 — 라이트는 한 단계 진하게)
    static let chrome = NSColor.palette(.chrome)
    /// 고른 줄 바탕
    static let chromeRaised = NSColor.palette(.chromeRaised)
    static let textPrimary = NSColor.palette(.textPrimary)
    static let textDim = NSColor.palette(.textDim)
    /// 포커스·지금 탭
    static let accent = NSColor.palette(.accent)
    /// 포커스 없는 화면 테두리
    static let border = NSColor.palette(.border)
    static let codexColor = NSColor.palette(.codex)
    static let claudeColor = NSColor.palette(.claude)
    static let green = NSColor.palette(.green)
    static let yellow = NSColor.palette(.yellow)
    static let red = NSColor.palette(.red)
    static let cyan = NSColor.palette(.cyan)
    /// 오케스트레이션 중(포커스 테두리 강조색보다 붉은 보라 — 둘이 섞여 보이지 않게)
    static let purple = NSColor.palette(.purple)
    /// AI 표시(브라우저 탭 칩의 ●, AI 커서 이름표) — 바탕에서 또렷한 초록
    static let agentColor = green
    /// 사람이 조작 중(브라우저 "내가 조작 중")
    static let userColor = NSColor.palette(.user)
    /// 보조 글자(브라우저 창): textDim(다크 #7f848e, 바탕 대비 3.7:1)보다 진하게 — 두 모드 모두 바탕 대비 5.8:1 이상
    static let textSecondary = NSColor.palette(.textSecondary)

    /// 사이드바·탭 줄 글꼴(터미널과 같은 JetBrains Mono). 크기를 그대로 쓴다 — 글꼴 크기를 따라가려면 `scaledUIFont`.
    static func uiFont(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let name = "JetBrainsMono-" + (bold ? (italic ? "BoldItalic" : "Bold") : (italic ? "Italic" : "Regular"))
        return NSFont(name: name, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    // MARK: - 앱 테두리 배율(⌘+ ⌘− 를 도구 창·탭 줄·분할 제목·상태 줄·이동 목록도 따라간다)

    /// 지금 글꼴 크기의 배율(0.8~1.6). 크기가 바뀌면 `fontSizeChanged` 가 온다.
    static var uiScale: UIScale { UIScale(fontSize: fontSize, defaultSize: defaultFontSize) }

    /// 배율을 곱한 길이(줄 높이·여백·아이콘 크기)
    static func scaled(_ value: CGFloat) -> CGFloat { uiScale(value) }

    /// 배율을 곱한 테두리 글꼴. 테두리 뷰는 `uiFont` 대신 이것을 쓴다.
    static func scaledUIFont(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        uiFont(uiScale(size), bold: bold, italic: italic)
    }

    /// 터미널 뷰에 색을 넣는다. 모양은 뷰의 effectiveAppearance(창에 없으면 앱)를 따른다. 모양이 바뀔 때마다 다시 부른다.
    static func apply(to view: TerminalView) {
        let dark = (view.window != nil ? view.effectiveAppearance : NSApp?.effectiveAppearance ?? view.effectiveAppearance).isDark
        let theme = theme(dark: dark)
        view.nativeBackgroundColor = NSColor(srgbHex: theme.background)
        view.nativeForegroundColor = NSColor(srgbHex: theme.foreground)
        view.selectedTextBackgroundColor = NSColor(srgbHex: theme.selection)
        view.caretColor = NSColor(srgbHex: theme.caret)
        // 256색·트루컬러는 어두운 바탕용으로 고른 색이 많아(claude 상태줄의 117 하늘, 221 노랑 …) 밝은 바탕에서 안 읽힌다.
        // 라이트는 글자·바탕 대비가 이 값보다 낮으면 엔진이 색조를 두고 명도만 옮긴다. 다크는 1.0(끔) — 모양 그대로.
        view.minimumContrast = theme.minimumContrast
        view.useBrightColors = false // Ghostty 기본(bold-is-bright = false)
        // 256색은 표준 xterm 값으로. 엔진 기본값은 테마 16색에서 다시 만들어(base16Lab) claude 상태줄의
        // 256색(초록 114, 노랑 221, 하늘 117 …)이 Ghostty 와 다른 색으로 보인다.
        view.getTerminal().ansi256PaletteStrategy = .xterm
        view.installColors(theme.palette.map { rgb in
            SwiftTerm.Color(red8: UInt16(rgb >> 16 & 0xff), green8: UInt16(rgb >> 8 & 0xff), blue8: UInt16(rgb & 0xff))
        })
        // 스크롤 막대는 늘 보이게(겹쳐 보이는 기본 막대는 위치가 안 보인다). 막대 모양(밝음·어두움)은 뷰의 모양을 따라간다.
        view.scrollerStyle = .legacy
        view.needsDisplay = true
    }
}

/// 모양(라이트·다크)이 바뀌면 스스로 색을 다시 넣는 터미널 뷰 — 세션 화면·작은 터미널 모두 이것을 쓴다.
final class ThemedTerminalView: TerminalView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        TermAppearance.apply(to: self)
    }
}

extension NSAppearance {
    /// 어두운 모양인가(다크 계열 모두)
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    /// 앱 색 이름표(PaletteColor) → 모양에 따라 바뀌는 색. 그릴 때·`cg(in:)` 로 풀 때 그 뷰의 모양으로 정해진다.
    static func palette(_ color: PaletteColor) -> NSColor {
        NSColor(name: nil) { appearance in NSColor(srgbHex: color.hex(dark: appearance.isDark)) }
    }

    /// 이 뷰의 모양으로 푼 CGColor. 레이어 색(layer.backgroundColor 등)은 값으로 굳으므로 모양이 바뀔 때마다 다시 받는다.
    func cg(in view: NSView) -> CGColor {
        var result = cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { result = self.cgColor }
        return result
    }

    /// 지정한 모양으로 푼 sRGB 색(웹 CSS 같은 곳에 값으로 적을 때)
    func resolved(_ appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance { result = self.usingColorSpace(.sRGB) ?? self }
        return result
    }
}

extension NSColor {
    convenience init(srgbHex rgb: UInt32) {
        self.init(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}
