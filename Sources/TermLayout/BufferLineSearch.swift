import Foundation

public protocol BufferSearchCell {
    /// 비어 있는 칸은 nil, 직접 출력한 공백은 " "이다.
    var searchCharacter: Character? { get }
    var searchWidth: Int { get }
}

public enum BufferLineSearch {
    public struct Point: Equatable, Comparable {
        public var row: Int
        public var column: Int
        public init(row: Int, column: Int) { self.row = row; self.column = column }
        public static func < (lhs: Point, rhs: Point) -> Bool {
            lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
        }
    }
    public struct Match: Equatable {
        public var start: Point
        public var end: Point
        public init(start: Point, end: Point) { self.start = start; self.end = end }
    }

    /// UTF-16 위치마다 실제 셀의 시작·끝 열을 기억한다(같은 글자도 셀 폭이 다를 수 있다).
    public final class Row {
        public let text: String
        public let starts: [Int]
        public let ends: [Int]
        public let wrapped: Bool
        public init(text: String, starts: [Int], ends: [Int], wrapped: Bool) {
            precondition(text.utf16.count == starts.count && starts.count == ends.count)
            self.text = text; self.starts = starts; self.ends = ends; self.wrapped = wrapped
        }
    }

    public static func extract<Cell: BufferSearchCell>(count: Int, wrapped: Bool, continues: Bool,
                                                       nextStartsWide: Bool, cellAt: (Int) -> Cell) -> Row {
        var limit = count
        if !continues {
            // SwiftTerm getTrimmedLength와 같이 null만 뺀다. 출력한 공백은 검색할 수 있다.
            limit = 0
            for col in (0..<count).reversed() {
                let cell = cellAt(col)
                if cell.searchCharacter != nil { limit = min(count, col + max(1, cell.searchWidth)); break }
            }
        }
        var text = ""
        var starts: [Int] = [], ends: [Int] = []
        text.reserveCapacity(limit * 3)
        starts.reserveCapacity(limit * 2); ends.reserveCapacity(limit * 2)
        for col in 0..<limit {
            let cell = cellAt(col)
            guard cell.searchWidth > 0 else { continue }
            let character = cell.searchCharacter
            if col == count - 1, character == nil, continues, nextStartsWide { continue }
            let ch: Character = character ?? " "
            text.append(ch)
            for _ in 0..<ch.utf16.count {
                starts.append(col); ends.append(col + cell.searchWidth)
            }
        }
        return Row(text: text, starts: starts, ends: ends, wrapped: wrapped)
    }

    public static func find(_ query: String, rows: [String], wrapped: Set<Int> = [],
                            caseSensitive: Bool = false, width: (Character) -> Int = cellWidth) -> [Match] {
        var mapped: [Row] = []
        mapped.reserveCapacity(rows.count)
        for (row, text) in rows.enumerated() {
            var starts: [Int] = [], ends: [Int] = []
            starts.reserveCapacity(text.utf16.count); ends.reserveCapacity(text.utf16.count)
            var col = 0
            for ch in text {
                let next = col + max(0, width(ch))
                for _ in 0..<ch.utf16.count { starts.append(col); ends.append(next) }
                col = next
            }
            mapped.append(Row(text: text, starts: starts, ends: ends, wrapped: wrapped.contains(row)))
        }
        return BufferSearchIndex().find(query, rows: mapped, caseSensitive: caseSensitive)
    }

    public static func cellWidth(_ character: Character) -> Int {
        guard let value = character.unicodeScalars.first?.value else { return 0 }
        if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return 2 }
        if (0x1100...0x115f).contains(value) || (0x2e80...0xa4cf).contains(value)
            || (0xac00...0xd7a3).contains(value) || (0xf900...0xfaff).contains(value)
            || (0xfe10...0xfe6f).contains(value) || (0xff01...0xff60).contains(value)
            || (0x20000...0x3ffff).contains(value) { return 2 }
        return character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark } ? 0 : 1
    }
}

/// 바뀌지 않은 논리 줄은 문자열·열 매핑·검색 결과까지 다시 쓴다.
public final class BufferSearchIndex {
    private struct Group {
        var rows: [BufferLineSearch.Row]
        var text: NSString
        var starts: [BufferLineSearch.Point]
        var ends: [BufferLineSearch.Point]
        var query: String?
        var caseSensitive = false
        var matches: [BufferLineSearch.Match] = []
    }
    private var groups: [ObjectIdentifier: Group] = [:]
    public private(set) var rebuiltGroups = 0
    public init() {}

    public func find(_ query: String, rows: [BufferLineSearch.Row], caseSensitive: Bool = false) -> [BufferLineSearch.Match] {
        var next: [ObjectIdentifier: Group] = [:]
        next.reserveCapacity(rows.count)
        var result: [BufferLineSearch.Match] = []
        rebuiltGroups = 0
        var first = 0
        while first < rows.count {
            var end = first + 1
            while end < rows.count && rows[end].wrapped { end += 1 }
            let key = ObjectIdentifier(rows[first])
            var group: Group
            if let old = groups[key], old.rows.count == end - first,
               old.rows.enumerated().allSatisfy({ $0.element === rows[first + $0.offset] }) {
                group = old
            } else {
                var text = "", starts: [BufferLineSearch.Point] = [], ends: [BufferLineSearch.Point] = []
                var capacity = 0
                for row in first..<end { capacity += rows[row].starts.count }
                text.reserveCapacity(capacity * 2); starts.reserveCapacity(capacity); ends.reserveCapacity(capacity)
                for row in first..<end {
                    let line = rows[row]
                    text += line.text
                    for i in line.starts.indices {
                        starts.append(.init(row: row - first, column: line.starts[i]))
                        ends.append(.init(row: row - first, column: line.ends[i]))
                    }
                }
                group = Group(rows: Array(rows[first..<end]), text: text as NSString, starts: starts, ends: ends)
                rebuiltGroups += 1
            }
            if group.query != query || group.caseSensitive != caseSensitive {
                group.matches.removeAll(keepingCapacity: true)
                if !query.isEmpty {
                    var offset = 0
                    while offset < group.text.length {
                        let range = group.text.range(of: query, options: caseSensitive ? [] : [.caseInsensitive],
                                                     range: NSRange(location: offset, length: group.text.length - offset))
                        guard range.location != NSNotFound, range.length > 0 else { break }
                        group.matches.append(.init(start: group.starts[range.location], end: group.ends[NSMaxRange(range) - 1]))
                        offset = NSMaxRange(range)
                    }
                }
                group.query = query; group.caseSensitive = caseSensitive
            }
            for match in group.matches {
                result.append(.init(start: .init(row: match.start.row + first, column: match.start.column),
                                    end: .init(row: match.end.row + first, column: match.end.column)))
            }
            next[key] = group
            first = end
        }
        groups = next
        return result
    }
}

public struct BufferSearchCursor {
    public private(set) var matches: [BufferLineSearch.Match] = []
    public private(set) var currentIndex: Int?
    public private(set) var anchor: BufferLineSearch.Point?
    public var current: BufferLineSearch.Match? { currentIndex.map { matches[$0] } }
    public init() {}

    public mutating func replace(_ matches: [BufferLineSearch.Match], preferredRow: Int? = nil) {
        let target = preferredRow.map { BufferLineSearch.Point(row: $0, column: 0) } ?? current?.start ?? anchor
        anchor = target
        self.matches = matches
        guard !matches.isEmpty else { currentIndex = nil; return }
        if let target { currentIndex = matches.firstIndex { $0.start >= target } ?? matches.count - 1 }
        else { currentIndex = 0 }
        anchor = current?.start
    }

    public mutating func move(backwards: Bool) {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? 0) + (backwards ? matches.count - 1 : 1)) % matches.count
        anchor = current?.start
    }

    public mutating func trimRows(_ count: Int) {
        guard count > 0 else { return }
        anchor = (current?.start ?? anchor).map { BufferLineSearch.Point(row: max(0, $0.row - count), column: $0.column) }
        matches = matches.compactMap { match in
            guard match.start.row >= count else { return nil }
            return .init(start: .init(row: match.start.row - count, column: match.start.column),
                         end: .init(row: match.end.row - count, column: match.end.column))
        }
        currentIndex = anchor.flatMap { anchor in matches.firstIndex { $0.start >= anchor } }
        if currentIndex == nil, !matches.isEmpty { currentIndex = matches.count - 1 }
    }
}
