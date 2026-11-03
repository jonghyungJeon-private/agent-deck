import Foundation

/// AI 커서: abx 가 클릭·입력 같은 단계를 하기 직전에 그 요소 자리와 할 일을 `<세션>.cursor.json` 에 적는다
/// (앱이 그 탭을 보여 줄 때만 — `watch.json`). 칸은 그 자리로 커서를 옮기고 할 일을 이름표로 붙인다.
/// 입력한 값은 적지 않는다(비밀번호일 수 있다) — 단계 종류와 요소 이름만.
public struct AgentCursor: Decodable, Equatable, Sendable {
    public var seq: Int
    /// abx 가 적은 때(ms, 1970 기준)
    public var t: Double
    public var targetId: String
    /// 페이지 viewport 의 CSS 좌표
    public var x: Double
    public var y: Double
    /// 단계 동사(click·fill·press …)
    public var kind: String
    /// 요소의 접근성 이름(없으면 역할)
    public var name: String?
    /// press: 키, scroll: 방향
    public var key: String?

    public init(seq: Int, t: Double, targetId: String, x: Double, y: Double, kind: String, name: String? = nil, key: String? = nil) {
        self.seq = seq
        self.t = t
        self.targetId = targetId
        self.x = x
        self.y = y
        self.kind = kind
        self.name = name
        self.key = key
    }

    public static func read(_ url: URL) -> AgentCursor? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentCursor.self, from: data)
    }

    /// 누르는 동작(도착하면 퍼지는 원)
    public var presses: Bool { ["click", "dblclick", "check", "uncheck", "select"].contains(kind) }

    /// 이름표: "클릭 · 위클리카", "입력 · 검색어", "Enter 키"
    public var label: String {
        let verb: String
        switch kind {
        case "click": verb = "클릭"
        case "dblclick": verb = "더블클릭"
        case "hover": verb = "가리키기"
        case "fill", "type": verb = "입력"
        case "select": verb = "선택"
        case "check": verb = "체크"
        case "uncheck": verb = "체크 해제"
        case "focus": verb = "포커스"
        case "drag": verb = "끌기"
        case "press": return [key ?? "", "키"].filter { !$0.isEmpty }.joined(separator: " ")
        case "scroll":
            let dir = ["down": "아래로", "up": "위로", "left": "왼쪽으로", "right": "오른쪽으로"][key ?? ""] ?? ""
            return ["스크롤", dir].filter { !$0.isEmpty }.joined(separator: " ")
        default: verb = kind
        }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return verb }
        return "\(verb) · \(name.count > 24 ? String(name.prefix(23)) + "…" : name)"
    }
}

extension ViewportTransform {
    /// CSS 좌표 → 칸의 점(위가 0). `cssPoint` 의 반대.
    public func viewPoint(_ css: CGPoint) -> CGPoint? {
        let rect = imageRect
        guard rect.width > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        return CGPoint(x: rect.minX + css.x * rect.width / viewport.width,
                       y: rect.minY + css.y * rect.height / viewport.height)
    }
}
