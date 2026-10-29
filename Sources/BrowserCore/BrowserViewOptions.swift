import Foundation

/// 브라우저 화면을 어떻게 보여 줄지(설정 창 → 브라우저). `term/browser-view.json` 에 저장한다.
public struct BrowserViewOptions: Codable, Equatable {
    /// 받는 그림의 선명도. 브라우저는 화면 배율(레티나 2배)로 그리고, 여기서 정한 크기까지만 줄여 받는다.
    public enum Sharpness: String, Codable, CaseIterable {
        /// 예전 크기(1440×900) — 가장 가볍다
        case standard
        /// 2560×1600 까지(기본) — 큰 칸에서도 또렷하고 부담은 적다
        case sharp
        /// 3840×2400 까지 — 레티나 칸을 거의 그대로(프레임이 2배 가까이 크다)
        case max
    }

    public var sharpness: Sharpness = .sharp
    /// 칸이 좁아도 데스크톱 화면(폭 1024 이상)으로 그리고 그림을 줄여 보인다(좁으면 사이트가 모바일 화면으로 바뀌므로)
    public var keepDesktop = false

    public init(sharpness: Sharpness = .sharp, keepDesktop: Bool = false) {
        self.sharpness = sharpness
        self.keepDesktop = keepDesktop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 모르는 값(새 판에서 쓴 것)은 기본값으로
        sharpness = (try? c.decode(Sharpness.self, forKey: .sharpness)) ?? .sharp
        keepDesktop = (try? c.decode(Bool.self, forKey: .keepDesktop)) ?? false
    }

    /// screencast 요청(가로세로 상한·JPEG 품질). 측정(레티나, 1937×1083 칸, 스크롤 중):
    /// 1440 상한 118KB·21fps, 2560 상한 360KB·16fps, 원본(3874) 640KB·14fps.
    public var screencast: ScreencastSettings {
        switch sharpness {
        case .standard: return ScreencastSettings(quality: 75, maxWidth: 1440, maxHeight: 900)
        case .sharp: return ScreencastSettings(quality: 85, maxWidth: 2560, maxHeight: 1600)
        case .max: return ScreencastSettings(quality: 85, maxWidth: 3840, maxHeight: 2400)
        }
    }

    public static let minimumSize = CGSize(width: 320, height: 240)
    public static let desktopWidth: CGFloat = 1024

    /// 칸 크기(점) → 브라우저 페이지 크기(CSS 픽셀). 아주 작은 칸은 최소 크기로, 데스크톱 유지면 폭 1024 까지
    /// 칸 비율 그대로 키운다(여백 없이 줄여 보이게).
    public func pageSize(for pane: CGSize) -> CGSize {
        var size = pane
        if keepDesktop, size.width > 0, size.width < Self.desktopWidth {
            size = CGSize(width: Self.desktopWidth, height: (size.height * Self.desktopWidth / size.width).rounded())
        }
        return CGSize(width: max(size.width, Self.minimumSize.width), height: max(size.height, Self.minimumSize.height))
    }

    public static func load(from url: URL) -> BrowserViewOptions {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? BrowserViewOptions()
    }

    public func data() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}
