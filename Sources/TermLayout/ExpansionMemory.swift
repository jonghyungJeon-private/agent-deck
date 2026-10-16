import Foundation

/// 파일 트리에서 펼친 폴더를 루트(프로젝트)별로 기억한다. 메모리에만, 크기 제한(오래 안 본 루트부터 버림).
public struct ExpansionMemory: Equatable, Sendable {
    public let maxRoots: Int
    public let maxPathsPerRoot: Int
    /// 루트 → 펼친 폴더(루트 기준 상대 경로)
    private var expanded: [String: Set<String>] = [:]
    /// 최근에 쓴 루트가 뒤
    private var order: [String] = []

    public init(maxRoots: Int = 12, maxPathsPerRoot: Int = 400) {
        self.maxRoots = maxRoots
        self.maxPathsPerRoot = maxPathsPerRoot
    }

    public var rootCount: Int { expanded.count }

    /// 펼친 폴더. 위 폴더부터 펼쳐야 하므로 얕은 것 먼저.
    public mutating func paths(for root: String) -> [String] {
        touch(root)
        return (expanded[root] ?? []).sorted { a, b in
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            return da == db ? a < b : da < db
        }
    }

    public mutating func setExpanded(_ path: String, _ isExpanded: Bool, root: String) {
        touch(root)
        var set = expanded[root] ?? []
        if isExpanded {
            guard set.count < maxPathsPerRoot || set.contains(path) else { return }
            set.insert(path)
        } else {
            set.remove(path)
        }
        expanded[root] = set
    }

    /// 사라진 폴더 등을 지울 때
    public mutating func forget(_ path: String, root: String) {
        guard var set = expanded[root] else { return }
        set = set.filter { $0 != path && !$0.hasPrefix(path + "/") }
        expanded[root] = set
    }

    public mutating func collapseAll(root: String) {
        expanded[root] = []
    }

    private mutating func touch(_ root: String) {
        if let index = order.firstIndex(of: root) { order.remove(at: index) }
        order.append(root)
        if expanded[root] == nil { expanded[root] = [] }
        while order.count > maxRoots {
            expanded[order.removeFirst()] = nil
        }
    }
}
