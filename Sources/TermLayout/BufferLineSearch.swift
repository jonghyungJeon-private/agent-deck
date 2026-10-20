import Foundation

/// 문자열 줄에서 찾은 범위를 터미널 칸으로 바꾼다. wrapped 는 앞줄에서 이어지는 줄 번호다.
public enum BufferLineSearch {
    public struct Point: Equatable {
        public var row: Int
        public var column: Int
        public init(row: Int, column: Int) { self.row = row; self.column = column }
    }
    public struct Match: Equatable {
        public var start: Point
        public var end: Point
    }

    public static func find(_ query: String, rows: [String], wrapped: Set<Int> = [],
                            caseSensitive: Bool = false, width: (Character) -> Int = cellWidth) -> [Match] {
        guard !query.isEmpty else { return [] }
        var groups: [(String, [Point])] = []
        for (row, text) in rows.enumerated() {
            if !wrapped.contains(row) || groups.isEmpty { groups.append(("", [])) }
            var column = 0
            for ch in text {
                let point = Point(row: row, column: column)
                groups[groups.count - 1].0.append(ch)
                groups[groups.count - 1].1 += Array(repeating: point, count: String(ch).utf16.count)
                column += max(0, width(ch))
            }
            groups[groups.count - 1].1.append(Point(row: row, column: column))
            if row + 1 < rows.count, wrapped.contains(row + 1) { groups[groups.count - 1].1.removeLast() }
        }
        var matches: [Match] = []
        for (text, points) in groups {
            let string = text as NSString
            var offset = 0
            while offset < string.length {
                let range = string.range(of: query, options: caseSensitive ? [] : [.caseInsensitive],
                                         range: NSRange(location: offset, length: string.length - offset))
                guard range.location != NSNotFound else { break }
                matches.append(Match(start: points[range.location], end: points[NSMaxRange(range)]))
                offset = NSMaxRange(range)
            }
        }
        return matches
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
