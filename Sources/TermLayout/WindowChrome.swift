import Foundation

/// 창 제목 줄과 합친 탭 줄의 순수 계산(시험한다): 신호등 자리 비우기, 빈 곳 두 번 누르기, 창 제목.
public enum WindowChrome {
    /// 탭 줄 왼쪽에서 신호등(●●●)을 피해 비울 폭. 신호등이 사이드바 안에 있으면(내용 왼쪽 끝이 신호등 오른쪽보다 멀면) 0.
    /// `lightsMaxX` 와 `contentMinX` 는 같은 좌표(창 좌표 x). 신호등이 없으면(전체 화면) `lightsMaxX` 를 0 으로 준다.
    public static func leadingInset(lightsMaxX: Double, contentMinX: Double, gap: Double) -> Double {
        guard lightsMaxX > 0 else { return 0 }
        return max(0, lightsMaxX + gap - contentMinX)
    }

    /// 신호등 단추 윗변이 제목 줄 뷰 윗변에서 내려갈 거리: 탭 줄 높이의 가운데에 앉히되, 글꼴 배율이 커서 탭 줄이 제목 줄 뷰(높이 `containerHeight`)보다
    /// 높아져도 단추가 뷰 밖으로 나가지 않게(밖은 클릭이 탭 줄로 가서 창이 끌린다) 뷰 안에 가둔다.
    public static func lightsTop(rowHeight: Double, buttonHeight: Double, containerHeight: Double) -> Double {
        min(max(0, (rowHeight - buttonHeight) / 2), max(0, containerHeight - buttonHeight))
    }

    /// 왼쪽 도크 맨 위(신호등이 앉는 줄)의 배치. 도구 버튼 줄(spaces·files)이 있고 신호등 옆에 들어갈 만큼 도크가 넓으면 버튼 줄이 신호등 줄에 앉고
    /// (오른쪽 도크처럼 맨 위 줄이 버튼 줄), 아니면 신호등만 있는 빈 줄 아래에 버튼 줄. 전체 화면(신호등 없음)에는 빈 줄이 없다.
    /// - `lightsMaxX`: 신호등 오른쪽 끝(창 좌표 x, 신호등이 없으면 0) · `stripWidth`: 버튼 줄 칸들의 폭 · `dockWidth`: 도크 폭
    public struct DockTop: Equatable {
        /// 신호등만 있는 빈 줄의 높이(0 이면 없음)
        public var bandHeight: Double
        /// 버튼 줄 왼쪽에서 비울 폭(신호등 옆에 앉을 때만 신호등 폭 + 여유)
        public var stripLeading: Double
    }

    public static func dockTop(lightsMaxX: Double, hasStrip: Bool, stripWidth: Double, dockWidth: Double,
                               rowHeight: Double, gap: Double, margin: Double) -> DockTop {
        guard lightsMaxX > 0 else { return DockTop(bandHeight: 0, stripLeading: margin) }
        if hasStrip, dockWidth >= lightsMaxX + gap + stripWidth + margin {
            return DockTop(bandHeight: 0, stripLeading: lightsMaxX + gap)
        }
        return DockTop(bandHeight: rowHeight, stripLeading: margin)
    }

    /// 제목 줄 빈 곳을 두 번 눌렀을 때 시스템 설정("제목 막대를 두 번 클릭하면")이 정한 동작
    public enum DoubleClickAction: Equatable {
        case zoom, minimize, none
    }

    /// `AppleActionOnDoubleClick`("Maximize"·"Minimize"·"None", macOS 15 부터는 "Fill" 도 있다 — 창 맞춤(타일링)이라 앱이 따로 흉내 내지 않고
    /// 확대/축소(`zoom`)로 처리한다. 없으면 예전 `AppleMiniaturizeOnDoubleClick` 불리언, 그것도 없으면 확대)
    public static func doubleClickAction(action: String?, legacyMinimize: Bool?) -> DoubleClickAction {
        switch action?.lowercased() {
        case "maximize", "fill": return .zoom
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
