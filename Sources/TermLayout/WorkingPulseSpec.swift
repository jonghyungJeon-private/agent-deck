import Foundation

/// "작업 중" 점이 숨 쉬는 모양(순수 값 — 시험한다). 불투명도 1.0 → 0.55 → 1.0, 한 주기 1.6초(한쪽 0.8초), 천천히 시작·끝(ease-in-out),
/// 크기·색은 그대로. 모든 점이 같은 시계(절대 시각)에서 위상을 얻으므로 줄줄이 선 점들이 함께 숨 쉰다.
public enum WorkingPulseSpec {
    /// 한 주기(초): 1.0 → 0.55 → 1.0
    public static let period: TimeInterval = 1.6
    /// 가장 옅을 때의 불투명도(55% — 표면 위 대비 3:1 이상 유지)
    public static let minOpacity: Double = 0.55
    /// 한쪽 방향(초) = 주기의 절반
    public static var halfPeriod: TimeInterval { period / 2 }

    /// 그 시각(절대 시각, 초)의 불투명도. 주기의 0 에서 1.0, 절반에서 0.55 — 코사인이라 양 끝에서 천천히 움직인다.
    public static func opacity(at time: TimeInterval) -> Double {
        let phase = (time - (time / period).rounded(.down) * period) / period // 0..<1
        let mid = (1 + minOpacity) / 2, amplitude = (1 - minOpacity) / 2
        return mid + amplitude * cos(2 * Double.pi * phase)
    }

    /// 주기의 배수로 내린 시각: CALayer 애니메이션의 `beginTime` 을 이것으로 맞추면 모든 레이어가 같은 위상이다.
    public static func alignedBegin(now: TimeInterval) -> TimeInterval {
        (now / period).rounded(.down) * period
    }
}
