import Foundation

/// `agentdeck <명령> <칸>` 의 칸 지정 해석. 전체 ID·고유한 앞부분·이름(정확히 일치)·`.`(자기 칸).
public struct PaneCandidate: Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum PaneSelection: Equatable {
    case found(String)
    case notFound
    /// 후보가 여럿(ID)
    case ambiguous([String])
    /// `.` 인데 자기 칸이 없다(AgentDeck 밖에서 불렀거나 그 칸이 사라짐)
    case noSelf
}

public enum PaneSelector {
    /// 우선순위: `.` → 전체 ID → 이름 정확히 일치 → ID 앞부분(고유할 때). 같은 단계에서 둘 이상이면 모호.
    public static func resolve(_ query: String, among panes: [PaneCandidate], selfId: String?) -> PaneSelection {
        let query = query.trimmingCharacters(in: .whitespaces)
        if query == "." {
            guard let selfId, panes.contains(where: { $0.id.lowercased() == selfId.lowercased() }) else { return .noSelf }
            return .found(panes.first { $0.id.lowercased() == selfId.lowercased() }!.id)
        }
        guard !query.isEmpty else { return .notFound }
        let lowered = normalize(query)
        let exactId = panes.filter { normalize($0.id) == lowered }
        if exactId.count == 1 { return .found(exactId[0].id) }
        let byName = panes.filter { $0.name == query }
        if byName.count == 1 { return .found(byName[0].id) }
        if byName.count > 1 { return .ambiguous(byName.map(\.id)) }
        let byPrefix = panes.filter { normalize($0.id).hasPrefix(lowered) }
        if byPrefix.count == 1 { return .found(byPrefix[0].id) }
        if byPrefix.count > 1 { return .ambiguous(byPrefix.map(\.id)) }
        return .notFound
    }

    /// 소문자, 대시 없이(UUID 를 대시 없이 쳐도 맞는다)
    static func normalize(_ text: String) -> String { text.lowercased().replacingOccurrences(of: "-", with: "") }

    /// 칸마다 짧은 ID: 앞 8자, 겹치면 안 겹칠 때까지 길게
    public static func shortIds(_ ids: [String], minimum: Int = 8) -> [String: String] {
        var result: [String: String] = [:]
        let lowered = ids.map { (id: $0, key: $0.lowercased()) }
        for item in lowered {
            var length = min(minimum, item.key.count)
            while length < item.key.count {
                let prefix = item.key.prefix(length)
                if !lowered.contains(where: { $0.id != item.id && $0.key.hasPrefix(prefix) }) { break }
                length += 1
            }
            result[item.id] = String(item.key.prefix(length))
        }
        return result
    }
}
