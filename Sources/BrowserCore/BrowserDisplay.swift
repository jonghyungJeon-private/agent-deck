import Foundation

/// 세션 브라우저를 어디서·어떻게 보는지. 머리 줄 "표시 ▾" 메뉴에서 고른다.
public struct BrowserDisplay: Codable, Equatable, Sendable {
    public enum Placement: String, Codable, CaseIterable, Sendable {
        /// 세션마다 따로 뜨는 브라우저 창
        case window
        /// 세션 창 안(도구 도크의 browser) — 지금 고른 세션의 브라우저를 보여 준다
        case dock
    }

    /// 별도 창의 높이(다른 창과의 앞뒤)
    public enum Level: String, Codable, CaseIterable, Sendable {
        /// 보통 창
        case normal
        /// AgentDeck 을 쓰는 동안만 위(다른 앱으로 가면 보통 창)
        case whileActive
        /// 다른 앱 위에도
        case always
    }

    public var placement: Placement
    public var level: Level

    public init(placement: Placement = .window, level: Level = .normal) {
        self.placement = placement
        self.level = level
    }

    public init(from decoder: Decoder) throws {
        // 모르는 값은 기본값으로(앞 판이 쓴 파일·망가진 값도 읽는다)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        placement = (try? c.decode(Placement.self, forKey: .placement)) ?? .window
        level = (try? c.decode(Level.self, forKey: .level)) ?? .normal
    }
}

/// 표시 설정: 모든 세션의 기본값 + 세션마다 고른 값. 메뉴에서 고르면 그 세션 값이 되고, 새 세션의 기본값도 된다.
/// `term/browser-display.json` 에 둔다.
public struct BrowserDisplayPrefs: Codable, Equatable, Sendable {
    public var defaults: BrowserDisplay
    /// abx 세션 이름(`ad-…`)별 — 화면 ID 가 바뀌지 않는 한 그대로
    public var sessions: [String: BrowserDisplay]

    public init(defaults: BrowserDisplay = BrowserDisplay(), sessions: [String: BrowserDisplay] = [:]) {
        self.defaults = defaults
        self.sessions = sessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaults = (try? c.decode(BrowserDisplay.self, forKey: .defaults)) ?? BrowserDisplay()
        sessions = (try? c.decode([String: BrowserDisplay].self, forKey: .sessions)) ?? [:]
    }

    public func display(for session: String) -> BrowserDisplay { sessions[session] ?? defaults }

    /// 한 세션에서 고름: 그 세션 값 + 기본값(새 세션도 마지막으로 고른 방식으로)
    public mutating func choose(_ display: BrowserDisplay, for session: String) {
        sessions[session] = display
        defaults = display
    }

    /// 닫힌 세션의 기록은 지운다(파일이 끝없이 자라지 않게)
    public mutating func forget(_ session: String) { sessions[session] = nil }

    public static func load(from url: URL) -> BrowserDisplayPrefs {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? BrowserDisplayPrefs()
    }

    public func data() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}
