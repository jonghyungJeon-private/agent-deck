import AppKit
import SwiftUI
import TermLayout

/// SwiftUI 테두리 뷰(spaces·상태 줄)가 글꼴 크기 배율을 따라가게 한다.
/// 뿌리 뷰가 이것을 지켜보다 `\.uiScale` 로 내려 주고, 안쪽 뷰는 `.uiFont(11)`·`ui(6)` 로 쓴다(글자 크기·간격·움직임 눈금은 아래 `TypeSize`·`Space`·`Motion`).
final class UIScaleModel: ObservableObject {
    static let shared = UIScaleModel()
    @Published private(set) var scale = TermAppearance.uiScale

    private init() {
        NotificationCenter.default.addObserver(forName: TermAppearance.fontSizeChanged, object: nil, queue: .main) { [weak self] _ in
            let next = TermAppearance.uiScale
            if self?.scale != next { self?.scale = next }
        }
    }
}

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue = UIScale.identity
}

extension EnvironmentValues {
    var uiScale: UIScale {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

private struct ScaledUIFont: ViewModifier {
    @Environment(\.uiScale) private var scale
    let size: CGFloat
    let bold: Bool

    func body(content: Content) -> some View {
        content.font(Font(TermAppearance.uiFont(scale(size), bold: bold)))
    }
}

private struct ScaledUITextFont: ViewModifier {
    @Environment(\.uiScale) private var scale
    let size: CGFloat
    let weight: NSFont.Weight

    func body(content: Content) -> some View {
        content.font(Font(TermAppearance.uiTextFont(scale(size), weight: weight)))
    }
}

extension View {
    /// 배율을 따라가는 테두리 글꼴(JetBrains Mono) — 이름·경로·tty·숫자 같은 데이터
    func uiFont(_ size: CGFloat, bold: Bool = false) -> some View {
        modifier(ScaledUIFont(size: size, bold: bold))
    }

    /// 배율을 따라가는 시스템 글꼴 — 문장·버튼·안내 글(언어)
    func uiTextFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> some View {
        modifier(ScaledUITextFont(size: size, weight: weight))
    }
}

/// 간격 눈금(4pt 격자). 길이는 늘 `ui(Space.md)` 처럼 배율을 곱해 쓴다.
enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
}

/// 글자 크기 눈금(배율을 곱하기 전 값): 10 보조·11 둘째·12 줄 제목·13 강조. 이보다 작은 글은 쓰지 않는다.
enum TypeSize {
    static let caption: CGFloat = 10
    static let secondary: CGFloat = 11
    static let row: CGFloat = 12
    static let emphasis: CGFloat = 13
}

/// 움직임 눈금: 짧고 감속하는 곡선(ease-out)만, 튀거나 되튕기지 않는다. 동작은 바로 일어나고 보이는 것만 움직인다.
/// 손쉬운 사용의 "동작 줄이기"가 켜져 있으면 움직임 없이 바로 바뀐다(ToolWindows 와 같은 기준).
enum Motion {
    /// 바로 알려 주는 반응(눌림·마우스 올림·화살표)
    static let fast: Double = 0.12
    /// 사라지는 줄(아래 줄이 올라오며 겹치기 전에 걷히도록 더 짧게)
    static let exit: Double = 0.08
    /// 보통 상태 바뀜(접기·펼치기·줄 생김/사라짐·막대)
    static let standard: Double = 0.2

    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `.animation(_:value:)`·`withAnimation` 에 넘기는 곡선. 동작 줄이기면 nil(움직임 없음).
    static func ease(_ duration: Double = Motion.standard) -> Animation? {
        ease(duration, reduceMotion: reduced)
    }

    static func ease(_ duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }
}
