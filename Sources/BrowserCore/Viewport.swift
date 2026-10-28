import CoreGraphics

/// 칸 안에 브라우저 화면(프레임)을 비율을 지켜 놓는 계산과, 칸의 점 → 페이지의 CSS 좌표 변환.
/// 좌표는 셋을 구분한다: 칸의 점(AppKit, 아래가 0이 아니라 위가 0인 뒤집힌 좌표로 넘긴다),
/// 프레임의 픽셀, 페이지의 CSS 픽셀(`metadata.deviceWidth/Height`).
public struct ViewportTransform: Equatable {
    /// 칸 크기(점)
    public var bounds: CGSize
    /// 페이지 viewport(CSS 픽셀)
    public var viewport: CGSize

    public init(bounds: CGSize, viewport: CGSize) {
        self.bounds = bounds
        self.viewport = viewport
    }

    /// 프레임을 그릴 자리(가운데, 비율 유지, 남는 곳은 여백). 위가 0인 좌표.
    public var imageRect: CGRect {
        guard viewport.width > 0, viewport.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / viewport.width, bounds.height / viewport.height)
        let size = CGSize(width: viewport.width * scale, height: viewport.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// 칸의 점(위가 0) → CSS 좌표. 여백을 누르면 nil.
    public func cssPoint(_ point: CGPoint) -> CGPoint? {
        let rect = imageRect
        guard rect.width > 0, rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) * viewport.width / rect.width,
                       y: (point.y - rect.minY) * viewport.height / rect.height)
    }
}

/// 디코딩이 밀릴 때 프레임을 쌓지 않는다: 지금 처리 중인 것 하나 + 가장 최근 것 하나만 두고 중간은 버린다.
public struct LatestFrameQueue<Frame> {
    private var waiting: Frame?
    private(set) public var busy = false
    /// 버린 프레임 수(측정용)
    private(set) public var dropped = 0

    public init() {}

    /// 새 프레임. 바로 처리할 수 있으면 그 프레임을 돌려주고, 아니면 기다리는 자리에 둔다(있던 것은 버림).
    public mutating func offer(_ frame: Frame) -> Frame? {
        if !busy { busy = true; return frame }
        if waiting != nil { dropped += 1 }
        waiting = frame
        return nil
    }

    /// 처리가 끝났다. 기다리던 프레임이 있으면 그것을 다음으로 돌려준다.
    public mutating func finish() -> Frame? {
        if let next = waiting { waiting = nil; return next }
        busy = false
        return nil
    }
}
