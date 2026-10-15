import AppKit
import CoreText
import SwiftTerm

/// 터미널 모양. Ghostty 기본값과 맞춘다(사용자가 Ghostty 와 나란히 쓰므로 같은 느낌이 나게).
/// - 글꼴: JetBrains Mono 13pt(Ghostty 내장 글꼴) + Nerd Font 아이콘. 앱에 넣어 두고 이 앱 안에서만 등록한다.
/// - 색: 배경 #282c34, 글자 #ffffff, 16색은 Tomorrow Night(Ghostty 기본 팔레트).
enum TermAppearance {
    static let fontSize: CGFloat = 13

    static let background = NSColor(srgbHex: 0x282c34)
    static let foreground = NSColor(srgbHex: 0xffffff)
    static let selection = NSColor(srgbHex: 0x3e4451)

    /// Ghostty 기본 palette 0~15
    static let palette: [UInt32] = [
        0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
        0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
    ]

    /// 앱에 넣은 글꼴을 이 프로세스에만 등록한다(사용자 글꼴 폴더는 건드리지 않음).
    static func registerBundledFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// 한글을 그릴 고정폭 글꼴. 설치돼 있으면 앞의 것부터 쓴다(Ghostty 도 설치된 고정폭 한글 글꼴을 고른다 — 이 PC 는 D2Coding).
    /// 하나도 없으면 시스템이 고르는 Apple SD Gothic Neo 로 그려진다.
    static let hangulFonts = ["D2Coding", "NanumGothicCoding"]

    /// 터미널 글꼴. 아이콘(Nerd Font)·한글 글자는 이어서 찾을 글꼴로 붙인다. 없으면 시스템 고정폭 글꼴.
    static let font: NSFont = {
        guard let base = NSFont(name: "JetBrainsMono-Regular", size: fontSize) else {
            return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        var cascade: [NSFontDescriptor] = []
        for name in ["SymbolsNFM"] + hangulFonts where NSFont(name: name, size: fontSize) != nil {
            cascade.append(NSFontDescriptor(fontAttributes: [.name: name]))
        }
        guard !cascade.isEmpty else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascade])
        return NSFont(descriptor: descriptor, size: fontSize) ?? base
    }()

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
