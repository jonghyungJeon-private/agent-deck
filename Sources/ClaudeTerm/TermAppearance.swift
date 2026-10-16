import AppKit
import CoreText
import SwiftTerm
import TermLayout
import TermWire

/// 터미널 모양. Ghostty 기본값과 맞춘다(사용자가 Ghostty 와 나란히 쓰므로 같은 느낌이 나게).
/// - 글꼴: JetBrains Mono 13pt(Ghostty 내장 글꼴) + Nerd Font 아이콘. 앱에 넣어 두고 이 앱 안에서만 등록한다.
/// - 색: 배경 #282c34, 글자 #ffffff, 16색은 Tomorrow Night(Ghostty 기본 팔레트).
enum TermAppearance {
    static let defaultFontSize: CGFloat = 13
    static let fontSizeRange: ClosedRange<CGFloat> = 8...32
    /// 글꼴 크기가 바뀌었다(터미널·편집기 화면이 받아 글꼴을 바꾼다). `ui.json` 저장도 이 알림을 받아 한다.
    static let fontSizeChanged = Notification.Name("ClaudeTerm.fontSizeChanged")

    /// 앱 전체 글꼴 크기(터미널·편집기 내용만, 사이드바·탭 줄은 그대로). 처음 읽을 때 `ui.json` 에서 가져온다.
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

    static let background = NSColor(srgbHex: 0x282c34)
    static let foreground = NSColor(srgbHex: 0xffffff)
    static let selection = NSColor(srgbHex: 0x3e4451)

    /// Ghostty 기본 palette 0~15
    static let palette: [UInt32] = [
        0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
        0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
    ]

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

    /// 사이드바·탭 줄 바탕(터미널보다 한 단계 어둡게)
    static let chrome = NSColor(srgbHex: 0x21252b)
    /// 고른 줄 바탕
    static let chromeRaised = NSColor(srgbHex: 0x2c313a)
    static let textPrimary = NSColor(srgbHex: 0xdcdfe4)
    static let textDim = NSColor(srgbHex: 0x7f848e)
    /// 포커스·지금 탭
    static let accent = NSColor(srgbHex: 0xc099ff)
    /// 포커스 없는 화면 테두리
    static let border = NSColor(srgbHex: 0x3e4451)
    static let codexColor = NSColor(srgbHex: 0x56b6c2)
    static let claudeColor = NSColor(srgbHex: 0xd7875f)
    static let green = NSColor(srgbHex: 0x98c379)
    static let yellow = NSColor(srgbHex: 0xe5c07b)
    static let red = NSColor(srgbHex: 0xe06c75)
    static let cyan = NSColor(srgbHex: 0x56b6c2)

    /// 사이드바·탭 줄 글꼴(터미널과 같은 JetBrains Mono)
    static func uiFont(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    static func apply(to view: TerminalView) {
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.selectedTextBackgroundColor = selection
        view.caretColor = NSColor(srgbHex: 0xc5c8c6)
        view.useBrightColors = false // Ghostty 기본(bold-is-bright = false)
        // 256색은 표준 xterm 값으로. 엔진 기본값은 테마 16색에서 다시 만들어(base16Lab) claude 상태줄의
        // 256색(초록 114, 노랑 221, 하늘 117 …)이 Ghostty 와 다른 색으로 보인다.
        view.getTerminal().ansi256PaletteStrategy = .xterm
        view.installColors(palette.map { rgb in
            SwiftTerm.Color(red8: UInt16(rgb >> 16 & 0xff), green8: UInt16(rgb >> 8 & 0xff), blue8: UInt16(rgb & 0xff))
        })
        // 어두운 배경에 맞는 스크롤 막대, 늘 보이게(겹쳐 보이는 기본 막대는 위치가 안 보인다)
        view.appearance = NSAppearance(named: .darkAqua)
        view.scrollerStyle = .legacy
    }
}

extension NSColor {
    convenience init(srgbHex rgb: UInt32) {
        self.init(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}
