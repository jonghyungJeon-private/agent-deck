import Foundation

/// 창 제목 줄과 합친 탭 줄의 순수 계산(시험한다): 신호등 자리 비우기, 빈 곳 두 번 누르기, 창 제목.
public enum WindowChrome {
    /// 탭 줄 왼쪽에서 신호등(●●●)을 피해 비울 폭. 신호등이 사이드바 안에 있으면(내용 왼쪽 끝이 신호등 오른쪽보다 멀면) 0.
    /// `lightsMaxX` 와 `contentMinX` 는 같은 좌표(창 좌표 x). 신호등이 없으면(전체 화면) `lightsMaxX` 를 0 으로 준다.
    public static func leadingInset(lightsMaxX: Double, contentMinX: Double, gap: Double) -> Double {
        guard lightsMaxX > 0 else { return 0 }
        return max(0, lightsMaxX + gap - contentMinX)
    }

    /// 제목 줄 빈 곳을 두 번 눌렀을 때 시스템 설정("제목 막대를 두 번 클릭하면")이 정한 동작
    public enum DoubleClickAction: Equatable {
        case zoom, minimize, none
    }

    /// `AppleActionOnDoubleClick`("Maximize"·"Minimize"·"None", 없으면 예전 `AppleMiniaturizeOnDoubleClick` 불리언, 그것도 없으면 확대)
    public static func doubleClickAction(action: String?, legacyMinimize: Bool?) -> DoubleClickAction {
        switch action?.lowercased() {
        case "maximize": return .zoom
        case "minimize": return .minimize
        case "none": return .none
        default: return legacyMinimize == true ? .minimize : .zoom
        }
    }

    /// 창 제목(= 고른 세션 이름)과 부제(= 그 폴더, 홈은 ~). 세션이 없으면 앱 이름만.
    public static func windowTitle(session: String?, folder: String?, home: String, appName: String = "AgentDeck")
        -> (title: String, subtitle: String)
    {
        let name = session?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return (appName, "") }
        guard let folder, !folder.isEmpty else { return (name, "") }
        var shown = folder
        if !home.isEmpty, home != "/" {
            if folder == home {
                shown = "~"
            } else if folder.hasPrefix(home + "/") {
                shown = "~" + folder.dropFirst(home.count)
            }
        }
        return (name, shown)
    }
}
