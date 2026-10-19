import AppKit
import SwiftUI
import TermLayout

/// SwiftUI 테두리 뷰(spaces·상태 줄)가 글꼴 크기 배율을 따라가게 한다.
/// 뿌리 뷰가 이것을 지켜보다 `\.uiScale` 로 내려 주고, 안쪽 뷰는 `.uiFont(11)`·`ui(6)` 로 쓴다.
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

extension View {
    /// 배율을 따라가는 테두리 글꼴(JetBrains Mono)
    func uiFont(_ size: CGFloat, bold: Bool = false) -> some View {
        modifier(ScaledUIFont(size: size, bold: bold))
    }
}
