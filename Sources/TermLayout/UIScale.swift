import CoreGraphics

/// 앱 테두리(도구 창·탭 줄·분할 제목·상태 줄·이동 목록) 배율 = 글꼴 크기(⌘+ ⌘−) ÷ 기본 크기.
/// 너무 작거나 커져 줄이 깨지지 않게 범위로 묶는다.
public struct UIScale: Equatable, Sendable {
    public static let range: ClosedRange<CGFloat> = 0.8...1.6
    public static let identity = UIScale(factor: 1)

    public let factor: CGFloat

    public init(factor: CGFloat) {
        self.factor = min(max(factor, Self.range.lowerBound), Self.range.upperBound)
    }

    public init(fontSize: CGFloat, defaultSize: CGFloat) {
        self.init(factor: defaultSize > 0 ? fontSize / defaultSize : 1)
    }

    /// 배율을 곱한 길이·글꼴 크기. 0.5pt 단위로 반올림한다(글자·선이 흐려지지 않게).
    public func callAsFunction(_ value: CGFloat) -> CGFloat {
        (value * factor * 2).rounded() / 2
    }
}
