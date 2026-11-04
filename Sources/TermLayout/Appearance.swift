import Foundation

/// 화면 모드(설정 → 화면 → 화면 모드): 자동(macOS 를 따라감)·라이트·다크. 값이 없거나 모르는 값이면 자동.
/// `term/ui.json` 의 "appearance" 에 저장한다(자동이면 적지 않는다).
public enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case auto, light, dark

    /// 기본값 — 값이 없을 때
    public static let `default`: AppearanceMode = .auto

    /// 저장된 값 → 모드. 없거나 모르는 값이면 자동
    public init(stored: String?) {
        self = stored.flatMap(AppearanceMode.init(rawValue:)) ?? .default
    }

    /// 설정 창 표시 이름
    public var title: String {
        switch self {
        case .auto: return "자동 (시스템 따라가기)"
        case .light: return "라이트"
        case .dark: return "다크"
        }
    }

    /// 지금 어두운 모양으로 그리나: 자동이면 macOS 의 지금 모양(`systemIsDark`)을 따른다
    public func isDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .auto: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }

    /// 시험 명령 `appearance <auto|light|dark>` 의 인자(한글 제목·영문 모두)
    public init?(argument: String) {
        let text = argument.trimmingCharacters(in: .whitespaces).lowercased()
        if let mode = Self.allCases.first(where: { $0.rawValue == text }) {
            self = mode
        } else if let mode = Self.allCases.first(where: { $0.title.lowercased().hasPrefix(text) && !text.isEmpty }) {
            self = mode
        } else {
            return nil
        }
    }
}

/// 앱 색 이름표. 어두운 값은 예전 그대로, 밝은 값은 같은 성격(차분한 바탕, 포커스·상태만 색)으로 고른 짝.
/// 화면 쪽(TermAppearance)이 이 표로 `NSColor(name:dynamicProvider:)` 를 만든다.
public enum PaletteColor: String, CaseIterable, Sendable {
    // 터미널·편집기 바탕
    case background
    case selection
    // 앱 테두리(사이드바·탭 줄·분할 테두리)
    case chrome, chromeRaised, border
    case textPrimary, textDim, textSecondary
    case accent
    // 상태·에이전트 색
    case codex, claude, green, yellow, red, cyan, purple, user
    // 편집기
    case editorText, editorGutter, editorLineNumber, editorCurrentLineNumber, editorCurrentLine, editorSelection, editorCaret
    case diffAdded, diffModified, diffDeleted
    case syntaxKeyword, syntaxString, syntaxComment, syntaxNumber, syntaxType, syntaxAttribute, syntaxKey, syntaxHeading
    case editorBannerBackground, editorBannerText
    // files 도구(git 상태)·이동 목록 기호
    case gitModified, gitAdded, gitUntracked, gitIgnored, gitConflicted, gitChangedFolder, folderIcon
    case symbolAnnotation

    /// (어두운, 밝은) 값
    private var pair: (dark: UInt32, light: UInt32) {
        switch self {
        case .background: return (0x282c34, 0xfafafa)
        case .selection: return (0x3e4451, 0xd3dcee)
        case .chrome: return (0x21252b, 0xeceef1)
        case .chromeRaised: return (0x2c313a, 0xdfe2e8)
        case .border: return (0x3e4451, 0xc9ced8)
        case .textPrimary: return (0xdcdfe4, 0x2b2f36)
        case .textDim: return (0x7f848e, 0x6a707c)
        case .textSecondary: return (0xa0a7b3, 0x525967)
        case .accent: return (0xc099ff, 0x7449d6)
        case .codex: return (0x56b6c2, 0x087985)
        case .claude: return (0xd7875f, 0xb04e1e)
        case .green: return (0x98c379, 0x2a7d36)
        case .yellow: return (0xe5c07b, 0x946300)
        case .red: return (0xe06c75, 0xca1243)
        case .cyan: return (0x56b6c2, 0x0b7f9a)
        case .purple: return (0xc678dd, 0xa026a8)
        case .user: return (0x61afef, 0x2a64c8)
        case .editorText: return (0xc9ccd3, 0x383a42)
        case .editorGutter: return (0x262a31, 0xf0f1f4)
        case .editorLineNumber: return (0x5c6370, 0x8a909c)
        case .editorCurrentLineNumber: return (0xb6bac2, 0x474c58)
        case .editorCurrentLine: return (0x2f343e, 0xeff1f6)
        case .editorSelection: return (0x3e4a5e, 0xc2d2ee)
        case .editorCaret: return (0xdcdfe4, 0x383a42)
        case .diffAdded: return (0x5f9e4f, 0x357f28)
        case .diffModified: return (0x4f80c4, 0x2c6bc4)
        case .diffDeleted: return (0xd0605a, 0xc8372e)
        case .syntaxKeyword: return (0xcf8e6d, 0x0033b3)
        case .syntaxString: return (0x6aab73, 0x067d17)
        case .syntaxComment: return (0x7a7e85, 0x7a7f88)
        case .syntaxNumber: return (0x2aacb8, 0x1750eb)
        case .syntaxType: return (0xe0c58a, 0x8a5a00)
        case .syntaxAttribute: return (0xb3ae60, 0x7d7208)
        case .syntaxKey: return (0xc77dbb, 0x871094)
        case .syntaxHeading: return (0xcf8e6d, 0x0033b3)
        case .editorBannerBackground: return (0x4a3f24, 0xf6ecc6)
        case .editorBannerText: return (0xf0d58a, 0x6b5200)
        case .gitModified: return (0x6ca0dc, 0x2f6fc0)
        case .gitAdded: return (0x8cc47a, 0x357f28)
        case .gitUntracked: return (0xd2826a, 0xb35a3c)
        case .gitIgnored: return (0x8b8b64, 0x7a7a52)
        case .gitConflicted: return (0xf0605a, 0xd0342c)
        case .gitChangedFolder: return (0xa9c3e3, 0x3a6fb0)
        case .folderIcon: return (0x8a9bb0, 0x5d7390)
        case .symbolAnnotation: return (0xb3ae60, 0x8a7a0a)
        }
    }

    /// 모드에 맞는 색(0xRRGGBB)
    public func hex(dark: Bool) -> UInt32 { dark ? pair.dark : pair.light }
}

/// 터미널 색 한 벌: 바탕·글자·커서·선택 + 16색 ANSI(0~15). 256색의 나머지는 표준 xterm 값을 쓴다.
public struct TerminalTheme: Equatable, Sendable {
    public var background: UInt32
    public var foreground: UInt32
    public var caret: UInt32
    public var selection: UInt32
    public var palette: [UInt32]
    /// 글자와 바탕의 최소 대비(WCAG 비율, 1.0 = 끔). 256색·트루컬러처럼 어두운 바탕을 가정해 고른 색이 이 아래로 읽히지 않으면
    /// 엔진(SwiftTerm `minimumContrast`)이 같은 색조에서 명도만 옮겨 맞춘다.
    public var minimumContrast: Double = 1.0

    /// 다크: 바탕 #282c34, 글자 #ffffff, 16색은 Tomorrow Night(Ghostty 기본 — 예전 그대로)
    public static let dark = TerminalTheme(
        background: 0x282c34, foreground: 0xffffff, caret: 0xc5c8c6, selection: 0x3e4451,
        palette: [
            0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
            0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
        ],
        minimumContrast: 1.0) // 다크: 끔(모양 그대로)

    /// 라이트: Atom One Light 계열 — 바탕 #fafafa, 글자 #383a42. 밝은 바탕에서 읽히도록 흰색 계열(7·15)은 어두운 회색으로 둔다.
    public static let light = TerminalTheme(
        background: 0xfafafa, foreground: 0x383a42, caret: 0x526fff, selection: 0xd3dcee,
        palette: [
            0x383a42, 0xd0473b, 0x3f8f3d, 0xa57000, 0x4078f2, 0xa626a4, 0x0184bc, 0x8a8c93,
            0x696c77, 0xc93a2f, 0x378535, 0x8a5c00, 0x3d63f0, 0xa62aa8, 0x0a85a0, 0x202226,
        ],
        // 라이트: 3.0 — 256색 117(1.5)·221(1.3)·228(1.0)·159(1.1) 같은 밝은 색이 색조는 그대로 두고 3.0 까지 진해진다.
        // (4.5 는 상태줄 회색 위계가 무너지고 노랑이 갈색이 된다.)
        minimumContrast: 3.0)

    /// 모드(어두운지)에 맞는 터미널 색
    public static func theme(dark: Bool) -> TerminalTheme { dark ? .dark : .light }
}
