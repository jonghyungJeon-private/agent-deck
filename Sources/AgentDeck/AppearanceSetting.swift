import AppKit
import Combine
import TermLayout
import TermWire

/// 화면 모드(설정 → 화면 → 화면 모드): 자동(macOS 를 따라감)·라이트·다크. 기본은 자동.
/// 값은 `term/ui.json` 의 "appearance" 에 저장한다(도구 창 관리자가 저장 — 글꼴 크기·작은 창 구석과 같은 파일).
/// 바꾸면 `NSApp.appearance`(자동 = nil, 라이트 = .aqua, 다크 = .darkAqua)로 바로 적용한다. 창마다 모양을 따로 고정하지 않으므로
/// 모든 창·뷰의 effectiveAppearance 가 따라 바뀌고, 터미널(`ThemedTerminalView`)·레이어 색을 받아 둔 뷰는 그 알림으로 색을 다시 넣는다.
final class AppearanceSetting: ObservableObject {
    static let shared = AppearanceSetting()

    @Published var mode: AppearanceMode {
        didSet { if mode != oldValue { apply() } }
    }

    private init() {
        // 처음 읽을 때 ui.json 에서(글꼴 크기와 같은 방식). 없거나 모르는 값이면 자동.
        mode = ToolLayout.load(from: TermPaths.home.appendingPathComponent("ui.json")).appearance
    }

    /// 지금 모드를 앱에 적용한다(앱을 켤 때 한 번, 바뀔 때마다)
    func apply() {
        NSApp?.appearance = Self.appearance(for: mode)
    }

    /// 모드 → NSApp.appearance 값(nil = macOS 를 따라감)
    static func appearance(for mode: AppearanceMode) -> NSAppearance? {
        switch mode {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// 시험 명령 `settings`·`appearance`: 모드와 지금 실제로 그려지는 모양
    var debugSummary: String {
        let effective = NSApp?.effectiveAppearance.isDark == true ? "dark" : "light"
        return "appearance=\(mode.rawValue) effective=\(effective)"
    }
}
