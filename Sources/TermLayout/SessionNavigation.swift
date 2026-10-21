import Foundation

public struct SessionTarget: Equatable {
    public var id: String
    public var name: String
    public var folder: String
    public var state: String
    public var stateAt: Date
    public var recentAt: Date
    public var tab: Int

    public init(id: String, name: String, folder: String, state: String = "", stateAt: Date = .distantPast,
                recentAt: Date = .distantPast, tab: Int = 1) {
        self.id = id; self.name = name; self.folder = folder; self.state = state
        self.stateAt = stateAt; self.recentAt = recentAt; self.tab = tab
    }
}

public enum SessionNavigation {
    public static func priority(_ state: String) -> Int {
        switch state {
        case "waiting": return 0
        case "error": return 1
        case "done": return 2
        case "orchestrating": return 3
        default: return 4
        }
    }

    public static func attention(_ items: [SessionTarget]) -> [SessionTarget] {
        items.filter { priority($0.state) < 4 }.sorted {
            let a = priority($0.state), b = priority($1.state)
            if a != b { return a < b }
            if $0.stateAt != $1.stateAt { return $0.stateAt > $1.stateAt }
            return $0.id < $1.id
        }
    }

    public static func ranked(_ items: [SessionTarget], query: String) -> [SessionTarget] {
        let words = query.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator: \.isWhitespace)
        func score(_ item: SessionTarget) -> Int? {
            let name = item.name.precomposedStringWithCanonicalMapping.lowercased()
            let text = name + " " + item.folder.precomposedStringWithCanonicalMapping.lowercased()
                + " " + item.state + " " + String(item.tab)
            guard words.allSatisfy({ text.contains($0) }) else { return nil }
            return words.isEmpty ? 0 : words.reduce(0) { $0 + (name.hasPrefix($1) ? 2 : name.contains($1) ? 1 : 0) }
        }
        return items.compactMap { item in score(item).map { (item, $0) } }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            let a = priority($0.0.state), b = priority($1.0.state)
            if a != b { return a < b }
            let at = a < 4 ? $0.0.stateAt : $0.0.recentAt
            let bt = b < 4 ? $1.0.stateAt : $1.0.recentAt
            if at != bt { return at > bt }
            return $0.0.id < $1.0.id
        }.map { $0.0 }
    }
}

public struct AttentionCycle {
    private var previous: [String] = []
    private var last: String?
    public init() {}

    public mutating func next(_ items: [SessionTarget], focused: String? = nil) -> String? {
        let ids = SessionNavigation.attention(items).map(\.id)
        guard !ids.isEmpty else { previous = []; last = nil; return nil }
        var target = ids[0]
        if let last, let i = ids.firstIndex(of: last) {
            target = ids[(i + 1) % ids.count]
        } else if let last, let i = previous.firstIndex(of: last) {
            // 확인한 완료가 목록에서 빠져도 그 다음 대상으로 이어 간다.
            let tail = Array(previous.dropFirst(i + 1)) + Array(previous.prefix(i))
            target = tail.first(where: { ids.contains($0) }) ?? ids[0]
        }
        if target == focused, ids.count > 1, let i = ids.firstIndex(of: target) {
            target = ids[(i + 1) % ids.count]
        }
        previous = ids; last = target
        return target
    }
}
