import Foundation

/// abx 가 흉내 낼 수 있는 기기들(`abx device list --json`): 브랜드(iPhone·iPad·Galaxy·Pixel·Desktop) → 시리즈 → 모델.
/// 목록은 abx 에만 있다(앱은 받아서 메뉴로 보인다) — abx 를 바꾸면 앱을 고치지 않아도 늘어난다.
public struct DeviceCatalog: Codable, Equatable, Sendable {
    public struct Device: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// 같은 크기의 다른 세대·참고(“M4·M5”, “unfolded”)
        public var detail: String?
        /// 세로 화면 CSS 크기
        public var width: Double
        public var height: Double
        /// 기기 픽셀 비율(0: 화면의 것 — 데스크톱 크기)
        public var scale: Double
        /// "phone" | "tablet" | "desktop"
        public var kind: String
        public init(id: String, name: String, detail: String? = nil, width: Double, height: Double, scale: Double, kind: String) {
            self.id = id; self.name = name; self.detail = detail
            self.width = width; self.height = height; self.scale = scale; self.kind = kind
        }
        public var isMobile: Bool { kind != "desktop" }
        /// 메뉴에 붙이는 크기: `402×874`
        public var sizeText: String { "\(Int(width))×\(Int(height))" }
    }
    public struct Series: Codable, Equatable, Sendable {
        public var name: String
        public var devices: [Device]
        public init(name: String, devices: [Device]) { self.name = name; self.devices = devices }
    }
    public struct Group: Codable, Equatable, Sendable {
        public var name: String
        public var series: [Series]
        public init(name: String, series: [Series]) { self.name = name; self.series = series }
    }

    public var groups: [Group]
    public init(groups: [Group]) { self.groups = groups }

    public func device(_ id: String) -> Device? {
        for group in groups { for series in group.series { if let d = series.devices.first(where: { $0.id == id }) { return d } } }
        return nil
    }

    /// 그 기기가 든 브랜드·시리즈 이름(메뉴에서 지금 기기가 있는 곳에 표시)
    public func path(_ id: String) -> (group: String, series: String)? {
        for group in groups { for series in group.series where series.devices.contains(where: { $0.id == id }) { return (group.name, series.name) } }
        return nil
    }

    /// 직접 준 크기를 abx 가 받는 꼴로: `390x844@3,mobile`
    public static func customId(width: Int, height: Int, scale: Double?, mobile: Bool) -> String {
        var id = "\(width)x\(height)"
        if let scale, scale > 0 { id += "@" + (scale == scale.rounded() ? String(Int(scale)) : String(scale)) }
        if mobile { id += ",mobile" }
        return id
    }
}

/// 최근에 고른 기기(앞이 최근). 같은 것은 하나만, 몇 개까지만.
public struct RecentDevices: Equatable, Sendable {
    public private(set) var ids: [String]
    public let limit: Int
    public init(ids: [String] = [], limit: Int = 4) { self.ids = Array(ids.prefix(limit)); self.limit = limit }
    public mutating func use(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > limit { ids.removeLast(ids.count - limit) }
    }
}
