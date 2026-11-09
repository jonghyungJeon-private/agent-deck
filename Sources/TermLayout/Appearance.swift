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

/// 앱 색 이름표 — B2 · Ink refined(최종). 색 하나 = 뜻 하나:
/// - `accent*` 잉크 블루 = "지금 내 포커스"(포커스 링·포커스 분할 테두리·고른 탭 2pt 줄·하나뿐인 주 버튼). 앱 강조색이기도 하다.
/// - `type*` = 어느 에이전트인가(Claude 주황 ✻ · Codex 청록 ‹› · 셸 중립 ›_). 상태에는 쓰지 않는다.
/// - `status*` = 상태. 색을 쓰는 건 둘뿐 — 빨강 `statusAttention`(내 조작 필요: 입력 대기·오류), 초록 `statusDone`(결과가 나옴).
///   작업 중·쉼·오케스트레이션·없음은 중립 모양(작업 중은 천천히 숨 쉬는 점)이라 색으로 주의를 끌지 않는다.
/// - `warning`/`warnText` 호박색 = 경고와 사용량 70% 이상만(작업 중에는 쓰지 않는다).
/// - `danger*` 난초색(자주) = 안전장치를 약하게 하는 설정 전용(권한 확인·승인·샌드박스 건너뛰기 같은 옵션의 스위치·경고 줄·명령 미리보기).
///   빨강(내 조작 필요)·호박(경고)·종류 색과 겹치지 않는 빈 색상환 자리를 쓰며, 다른 뜻에는 쓰지 않는다.
/// - `agent` 초록 = 브라우저에서 AI 가 조작 중(테두리·알약·커서). `human` = 내가 조작 중(중립).
/// 대비 하한: 글자(12pt 이하) 4.5:1, 점·아이콘·포커스 표시 3:1 — 각 표면(chrome·chromeRaised·background)에서.
/// 어두운·밝은 값 한 쌍은 순수 데이터라 시험한다. 화면 쪽(TermAppearance)이 이 표로 `NSColor(name:dynamicProvider:)` 를 만든다.
public enum PaletteColor: String, CaseIterable, Sendable {
    // 터미널·편집기 바탕
    case background
    case selection
    // 앱 테두리(사이드바·탭 줄·분할 테두리)
    case chrome, chromeRaised, border
    case textPrimary, textDim, textSecondary
    // 포커스(잉크 블루): 링·테두리·줄 / 제목 글자 / 주 버튼 바탕 / 그 위 글자
    case accent, accentText, accentFill, onAccent
    // 세션 종류(어느 에이전트인가)
    case typeClaude, typeCodex, typeShell
    // 상태
    case statusWorking, statusAttention, statusDone, statusIdle, statusOrchestrating, statusNone
    // 경고(아이콘·막대 / 글자)
    case warning, warnText
    // 위험한 설정 전용(아이콘·표시 / 글자 / 스위치 켜짐 바탕)
    case danger, dangerText, dangerFill
    // 브라우저 조작 주체
    case agent, onAgent, human
    // 편집기
    case editorText, editorGutter, editorLineNumber, editorCurrentLineNumber, editorCurrentLine, editorSelection, editorCaret
    case diffAdded, diffModified, diffDeleted
    case syntaxKeyword, syntaxString, syntaxComment, syntaxNumber, syntaxType, syntaxAttribute, syntaxKey, syntaxHeading
    case editorBannerBackground, editorBannerText
    // files 도구(git 상태)·이동 목록 기호
    case gitModified, gitAdded, gitUntracked, gitIgnored, gitConflicted, gitChangedFolder, folderIcon
    case symbolAnnotation
    // 마크다운 미리보기
    case markdownQuote, markdownTableStripe, markdownHighlight

    /// (어두운, 밝은) 값
    private var pair: (dark: UInt32, light: UInt32) {
        switch self {
        case .background: return (0x1c1b1a, 0xfdfcfa)
        case .selection: return (0x3a3733, 0xe3ded3)
        case .chrome: return (0x141312, 0xf4f2ee)
        case .chromeRaised: return (0x292725, 0xe7e4dd)
        case .border: return (0x383530, 0xd1cdc7)
        case .textPrimary: return (0xe7e4de, 0x1c1a18)
        case .textSecondary: return (0xa8a49c, 0x585550)
        case .textDim: return (0x97938b, 0x66625d)
        case .accent: return (0x73a1dc, 0x346aac)
        case .accentText: return (0x8ab4ea, 0x285e9f)
        case .accentFill: return (0x3a6ea5, 0x255b9c)
        case .onAccent: return (0xffffff, 0xffffff)
        case .typeClaude: return (0xe3975a, 0xa04f18)
        case .typeCodex: return (0x64c3c6, 0x006f73)
        case .typeShell: return (0xa8a49c, 0x585550)
        case .statusWorking: return (0xe7e4de, 0x1c1a18)
        case .statusAttention: return (0xe56c7f, 0xb12b4c)
        case .statusDone: return (0xa3cb96, 0x29672e)
        case .statusIdle: return (0xa8a49c, 0x585550)
        case .statusOrchestrating: return (0xa8a49c, 0x585550)
        case .statusNone: return (0x97938b, 0x66625d)
        case .warning: return (0xedcf6f, 0x9e7b0b)
        case .warnText: return (0xedcf6f, 0x815c0a)
        case .danger: return (0xdb8ef2, 0x731a8a)
        case .dangerText: return (0xdb8ef2, 0x731a8a)
        case .dangerFill: return (0xb459cf, 0x8e32a7)
        case .agent: return (0x84d17c, 0x367b30)
        case .onAgent: return (0x141312, 0xffffff)
        case .human: return (0xa8a49c, 0x585550)
        case .editorText: return (0xe4e1dc, 0x2b2925)
        case .editorGutter: return (0x181716, 0xf9f7f4)
        case .editorLineNumber: return (0x97938b, 0x66625d)
        case .editorCurrentLineNumber: return (0xe7e4de, 0x1c1a18)
        case .editorCurrentLine: return (0x242322, 0xf4f3f1)
        case .editorSelection: return (0x3a3733, 0xe3ded3)
        case .editorCaret: return (0xe4e1dc, 0x2b2925)
        case .diffAdded: return (0x5f9e4f, 0x357f28)
        case .diffModified: return (0x4f80c4, 0x2c6bc4)
        case .diffDeleted: return (0xd0605a, 0xc8372e)
        case .syntaxKeyword: return (0xcf8e6d, 0x0033b3)
        case .syntaxString: return (0x6aab73, 0x067d17)
        case .syntaxComment: return (0x8a867f, 0x6e6a64)
        case .syntaxNumber: return (0x2aacb8, 0x1750eb)
        case .syntaxType: return (0xe0c58a, 0x8a5a00)
        case .syntaxAttribute: return (0xb3ae60, 0x7d7208)
        case .syntaxKey: return (0xc77dbb, 0x871094)
        case .syntaxHeading: return (0xcf8e6d, 0x0033b3)
        case .editorBannerBackground: return (0x4a3f24, 0xf6ecc6)
        case .editorBannerText: return (0xf0d58a, 0x6b5200)
        case .gitModified: return (0x6ca0dc, 0x2566b6)
        case .gitAdded: return (0x8cc47a, 0x2a741c)
        case .gitUntracked: return (0xd2826a, 0xa24b2d)
        case .gitIgnored: return (0x909068, 0x676740)
        case .gitConflicted: return (0xf0605a, 0xc42520)
        case .gitChangedFolder: return (0xa9c3e3, 0x3166a6)
        case .symbolAnnotation: return (0xb3ae60, 0x756500)
        case .folderIcon: return (0x8a9bb0, 0x5d7390)
        case .markdownQuote: return (0xa8a49c, 0x585550)
        case .markdownTableStripe: return (0x232120, 0xf2f0ec)
        case .markdownHighlight: return (0x50482f, 0xe8e0c5)
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

    /// 다크: 바탕 #1c1b1a, 글자 #e4e1dc(따뜻한 흰색), 16색은 Tomorrow Night(Ghostty 기본 — 예전 그대로)
    public static let dark = TerminalTheme(
        background: 0x1c1b1a, foreground: 0xe4e1dc, caret: 0xc5c8c6, selection: 0x3a3733,
        palette: [
            0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
            0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
        ],
        minimumContrast: 1.0) // 다크: 끔(모양 그대로)

    /// 라이트: Atom One Light 계열 16색 + 종이 바탕 #fdfcfa, 글자 #2b2925. 밝은 바탕에서 읽히도록 흰색 계열(7·15)은 어두운 회색으로 둔다.
    /// 파랑(4번)만 앱 잉크 블루와 어울리게 #2f68b8(종이 위 5.4:1).
    public static let light = TerminalTheme(
        background: 0xfdfcfa, foreground: 0x2b2925, caret: 0x526fff, selection: 0xe3ded3,
        palette: [
            0x383a42, 0xd0473b, 0x3f8f3d, 0xa57000, 0x2f68b8, 0xa626a4, 0x0184bc, 0x8a8c93,
            0x696c77, 0xc93a2f, 0x378535, 0x8a5c00, 0x3d63f0, 0xa62aa8, 0x0a85a0, 0x202226,
        ],
        // 라이트: 3.0 — 256색 117(1.5)·221(1.3)·228(1.0)·159(1.1) 같은 밝은 색이 색조는 그대로 두고 3.0 까지 진해진다.
        // (4.5 는 상태줄 회색 위계가 무너지고 노랑이 갈색이 된다.)
        minimumContrast: 3.0)

    /// 모드(어두운지)에 맞는 터미널 색
    public static func theme(dark: Bool) -> TerminalTheme { dark ? .dark : .light }
}
