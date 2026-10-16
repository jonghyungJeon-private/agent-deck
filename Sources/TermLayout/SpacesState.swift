import Foundation

/// spaces(왼쪽 세션 목록)를 보는 방식: 접은 묶음·작업 트리, 끌어서 바꾼 순서. `term/spaces.json` 에 저장한다.
/// 순서는 목록에 보이는 순서일 뿐이다(탭 순서·⌘1~9 와 상관없다).
public struct SpacesState: Equatable, Sendable {
    /// 접은 줄(`groupKey`·`worktreeKey`)
    public var collapsed: Set<String> = []
    /// 묶음(저장소·폴더 경로) 순서. 여기 없는 묶음은 뒤에, 처음 나온 순서대로.
    public var groupOrder: [String] = []
    /// 세션(화면 ID) 순서. 같은 작업 트리 안에서만 쓴다(다른 칸과의 앞뒤는 뜻이 없다).
    public var sessionOrder: [String] = []

    /// 오래 쌓이지 않게(사라진 ID 는 옮길 때 버리지만 혹시 몰라)
    public static let maxEntries = 500

    public init() {}

    public static func groupKey(_ path: String) -> String { "g:" + path }
    public static func worktreeKey(_ path: String) -> String { "w:" + path }

    public func isCollapsed(_ key: String) -> Bool { collapsed.contains(key) }

    public mutating func setCollapsed(_ key: String, _ value: Bool) {
        if value { collapsed.insert(key) } else { collapsed.remove(key) }
    }

    public mutating func toggle(_ key: String) { setCollapsed(key, !isCollapsed(key)) }

    /// 모두 접기: 지금 보이는 묶음·작업 트리를 모두 접는다(예전에 접어 둔 사라진 줄은 버린다)
    public mutating func collapseAll(_ keys: [String]) { collapsed = Set(keys) }

    public mutating func expandAll() { collapsed = [] }

    /// 묶음 하나를 다른 묶음 자리로. displayed = 지금 보이는 묶음 순서(사라진 묶음은 이때 버린다)
    @discardableResult
    public mutating func moveGroup(_ id: String, onto target: String, displayed: [String]) -> Bool {
        guard let next = SpacesOrder.move(displayed, id, onto: target) else { return false }
        groupOrder = Array(next.prefix(Self.maxEntries))
        return true
    }

    /// 세션 하나를 같은 칸(작업 트리)의 다른 세션 자리로. siblings = 그 칸에 보이는 순서, live = 지금 있는 모든 화면
    @discardableResult
    public mutating func moveSession(_ id: String, onto target: String, siblings: [String], live: Set<String>) -> Bool {
        guard let next = SpacesOrder.move(siblings, id, onto: target) else { return false }
        sessionOrder = Array(SpacesOrder.merge(next, into: sessionOrder, keep: live).suffix(Self.maxEntries))
        return true
    }
}

/// 저장된 순서를 목록에 입히는 순수 함수들
public enum SpacesOrder {
    /// 저장된 순서대로 세운다. 순서에 없는 것(새로 생긴 것)은 뒤에, 원래 순서 그대로.
    public static func apply<T>(_ items: [T], order: [String], id: (T) -> String) -> [T] {
        guard !order.isEmpty, items.count > 1 else { return items }
        var rank: [String: Int] = [:]
        for (index, key) in order.enumerated() where rank[key] == nil { rank[key] = index }
        return items.enumerated().sorted { a, b in
            let ra = rank[id(a.element)] ?? Int.max, rb = rank[id(b.element)] ?? Int.max
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    /// 끌어 놓기: 위에서 끌어 내리면 target 뒤, 아래에서 끌어 올리면 target 앞(줄 높이를 몰라도 어디든 갈 수 있다).
    /// 같은 것이거나 둘 중 하나가 없으면 nil.
    public static func move(_ ids: [String], _ moving: String, onto target: String) -> [String]? {
        guard moving != target, let from = ids.firstIndex(of: moving), let to = ids.firstIndex(of: target) else { return nil }
        var next = ids
        next.remove(at: from)
        // 앞에서 뺐으면 target 이 한 칸 당겨졌으므로 그 자리(to)가 곧 target 뒤
        next.insert(moving, at: to)
        return next
    }

    /// 끌어 놓을 때 줄을 target 아래에 그릴지(위에서 끌어 내리는 중)
    public static func insertsAfter(_ ids: [String], _ moving: String, onto target: String) -> Bool {
        guard let from = ids.firstIndex(of: moving), let to = ids.firstIndex(of: target) else { return false }
        return from < to
    }

    /// 한 칸의 새 순서를 전체 순서에 합친다. keep 에 없는 ID(사라진 화면)는 이때 버린다.
    public static func merge(_ siblings: [String], into order: [String], keep: Set<String>) -> [String] {
        let moved = Set(siblings)
        return order.filter { !moved.contains($0) && keep.contains($0) } + siblings
    }
}

/// 접은 줄에 보일 상태 합계(안의 작업 트리·세션·하위 에이전트까지)
public struct SpacesSummary: Equatable, Sendable {
    /// 먼저 볼 것부터(입력 대기·오류가 앞)
    public enum Kind: String, CaseIterable, Sendable {
        case waiting, error, done, working, idle
    }

    /// 세션(화면) 수 — 상태가 없는 셸·꺼진 화면도 센다
    public private(set) var sessions = 0
    public private(set) var counts: [Kind: Int] = [:]
    /// 일하는 하위 에이전트 수
    public private(set) var runningAgents = 0

    public init() {}

    public mutating func add(session kind: Kind?) {
        sessions += 1
        if let kind { counts[kind, default: 0] += 1 }
    }

    public mutating func add(agentRunning: Bool) {
        if agentRunning { runningAgents += 1 }
    }

    public mutating func merge(_ other: SpacesSummary) {
        sessions += other.sessions
        runningAgents += other.runningAgents
        counts.merge(other.counts, uniquingKeysWith: +)
    }

    public func count(_ kind: Kind) -> Int { counts[kind] ?? 0 }

    /// 보일 것만 순서대로
    public var entries: [(kind: Kind, count: Int)] {
        Kind.allCases.compactMap { kind in count(kind) > 0 ? (kind, count(kind)) : nil }
    }

    /// 사람이 봐야 하는 것(입력 대기·오류)이 있는지
    public var needsAttention: Bool { count(.waiting) + count(.error) > 0 }

    public var isEmpty: Bool { sessions == 0 && runningAgents == 0 }
}

// MARK: - 파일(spaces.json)

extension SpacesState: Codable {
    /// {"version":1,"collapsed":["g:/repo","w:/repo-wt"],"groupOrder":["/repo"],"sessionOrder":["<화면 ID>"]}
    private struct File: Codable {
        var version: Int?
        var collapsed: [String]?
        var groupOrder: [String]?
        var sessionOrder: [String]?
    }

    public init(from decoder: Decoder) throws {
        // 빠진 값·모르는 열쇠는 기본값으로(예전·다른 판의 파일도 읽는다)
        let file = try File(from: decoder)
        self.init()
        func clean(_ values: [String]?) -> [String] {
            var seen = Set<String>()
            return (values ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }.suffix(Self.maxEntries).map { $0 }
        }
        collapsed = Set(clean(file.collapsed).filter { $0.hasPrefix("g:") || $0.hasPrefix("w:") })
        groupOrder = clean(file.groupOrder)
        sessionOrder = clean(file.sessionOrder)
    }

    public func encode(to encoder: Encoder) throws {
        try File(version: 1, collapsed: collapsed.sorted(), groupOrder: groupOrder, sessionOrder: sessionOrder)
            .encode(to: encoder)
    }

    /// 없거나 읽을 수 없으면 기본값
    public static func load(from url: URL) -> SpacesState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(SpacesState.self, from: data)
        else { return SpacesState() }
        return state
    }

    public func data() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }
}
