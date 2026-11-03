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

    /// 페이지 해상도(CSS 픽셀): 칸에 맞춤이거나, 정한 크기로 그리고 칸에 맞게 줄여(비율 유지) 보인다
    public enum Resolution: String, Codable, CaseIterable {
        case fit
        case r1280x800 = "1280x800"
        case r1440x900 = "1440x900"
        case r1920x1080 = "1920x1080"

        public var size: CGSize? {
            switch self {
            case .fit: return nil
            case .r1280x800: return CGSize(width: 1280, height: 800)
            case .r1440x900: return CGSize(width: 1440, height: 900)
            case .r1920x1080: return CGSize(width: 1920, height: 1080)
            }
        }
    }

    public var sharpness: Sharpness = .sharp
    public var resolution: Resolution = .fit
    /// 칸이 좁아도 데스크톱 화면(폭 1024 이상)으로 그리고 그림을 줄여 보인다(좁으면 사이트가 모바일 화면으로 바뀌므로)
    public var keepDesktop = false

    public init(sharpness: Sharpness = .sharp, resolution: Resolution = .fit, keepDesktop: Bool = false) {
        self.sharpness = sharpness
        self.resolution = resolution
        self.keepDesktop = keepDesktop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 모르는 값(새 판에서 쓴 것)은 기본값으로
        sharpness = (try? c.decode(Sharpness.self, forKey: .sharpness)) ?? .sharp
        resolution = (try? c.decode(Resolution.self, forKey: .resolution)) ?? .fit
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

    /// 칸 크기(점) → 브라우저 페이지 크기(CSS 픽셀). 해상도를 정했으면 그 크기, 아니면 칸 크기 — 아주 작은 칸은 최소 크기로,
    /// 데스크톱 유지면 폭 1024 까지 칸 비율 그대로 키운다(여백 없이 줄여 보이게).
    /// 세션 창 안(도크)에서 볼 때 "칸에 맞춤"이면 폭은 데스크톱 폭(1280)으로 고정하고 높이만 칸 비율을 따른다:
    /// 도크 폭은 터미널과 나눠 쓰며 자주 바뀌는데, 폭을 칸에 맞추면 사이트가 모바일 배치로 바뀌는 등 AI 가 쓰는 페이지가
    /// 흔들린다. 폭이 고정이면 배치는 그대로이고, 높이를 맞춰 세로로 긴 도크에도 빈 띠 없이 채운다. 고른 고정 해상도는 그대로.
    public static let dockedWidth: CGFloat = 1280

    public func pageSize(for pane: CGSize, docked: Bool) -> CGSize {
        guard docked, resolution == .fit else { return pageSize(for: pane) }
        guard pane.width > 0, pane.height > 0 else { return CGSize(width: Self.dockedWidth, height: 800) }
        let height = (Self.dockedWidth * pane.height / pane.width).rounded()
        return CGSize(width: Self.dockedWidth, height: min(max(height, Self.minimumSize.height), Self.dockedWidth * 2))
    }

    public func pageSize(for pane: CGSize) -> CGSize {
        if let fixed = resolution.size { return fixed }
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
