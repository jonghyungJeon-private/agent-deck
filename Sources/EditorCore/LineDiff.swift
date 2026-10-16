import Foundation

/// 편집기 여백의 git 변경 표시(IntelliJ 식): 추가 = 초록 막대, 바뀜 = 파랑 막대, 지움 = 줄 사이 빨간 삼각형
public enum LineChangeKind: UInt8, Equatable, Sendable {
    case added = 1, modified = 2, deleted = 3
}

/// 바뀐 덩어리 하나. 줄 번호는 지금 글(편집 중인 글) 기준 0부터.
/// deleted 는 count 가 0 이고 start 줄 "앞"(start == 줄 수면 맨 끝)에 지워진 줄이 있었다는 뜻.
public struct LineChange: Equatable, Sendable {
    public var kind: LineChangeKind
    public var start: Int
    public var count: Int

    public init(_ kind: LineChangeKind, start: Int, count: Int) {
        self.kind = kind
        self.start = start
        self.count = count
    }
}

/// 줄 단위 diff(Myers). 앞뒤 같은 줄을 먼저 덜어 내고 가운데만 비교한다(보통 고친 곳은 한두 군데라 빠르다).
/// 다른 줄이 너무 많으면(maxEdits 초과) 가운데 전체를 "바뀜" 한 덩어리로 본다(메모리·시간 상한).
public enum LineDiff {
    /// 표시를 건너뛰는 파일(너무 커서 비교 비용이 의미 없는 것)
    public static let maxBytes = 2 << 20
    public static let maxLines = 50_000

    /// 글을 줄로 나눈다(바이트 그대로, 줄 끝 \r 은 뗀다). 마지막 줄바꿈 뒤의 빈 줄은 줄로 치지 않는다.
    /// "a\nb\n" → [a, b], "a\nb" → [a, b], "" → [].
    public static func lines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var result: [ArraySlice<UInt8>] = []
        var start = 0
        let count = bytes.count
        var index = 0
        while index < count {
            if bytes[index] == 10 {
                var end = index
                if end > start, bytes[end - 1] == 13 { end -= 1 }
                result.append(bytes[start..<end])
                start = index + 1
            }
            index += 1
        }
        if start < count {
            var end = count
            if bytes[end - 1] == 13 { end -= 1 } // 옛 Mac(\r) 끝은 줄바꿈으로 치지 않는다 — 내용 비교만 맞으면 된다
            result.append(bytes[start..<end])
        }
        return result
    }

    public static func lines(_ text: String) -> [ArraySlice<UInt8>] { lines(Array(text.utf8)) }

    /// 줄을 정수로 바꿔(같은 내용 = 같은 수) 비교를 싸게 한다
    public static func intern(_ old: [ArraySlice<UInt8>], _ new: [ArraySlice<UInt8>]) -> (old: [Int32], new: [Int32]) {
        var table: [ArraySlice<UInt8>: Int32] = [:]
        table.reserveCapacity(old.count + 16)
        func id(_ line: ArraySlice<UInt8>) -> Int32 {
            if let known = table[line] { return known }
            let next = Int32(table.count)
            table[line] = next
            return next
        }
        let a = old.map(id)
        let b = new.map(id)
        return (a, b)
    }

    /// 지금 글과 기준(HEAD) 글의 변경 덩어리
    public static func changes(base: String, current: String, maxEdits: Int = 2000) -> [LineChange] {
        let ids = intern(lines(base), lines(current))
        return changes(old: ids.old, new: ids.new, maxEdits: maxEdits)
    }

    /// 새 파일(기준 없음): 모든 줄이 추가
    public static func allAdded(lineCount: Int) -> [LineChange] {
        lineCount > 0 ? [LineChange(.added, start: 0, count: lineCount)] : []
    }

    public static func changes(old: [Int32], new: [Int32], maxEdits: Int = 2000) -> [LineChange] {
        let n = old.count, m = new.count
        var prefix = 0
        while prefix < n, prefix < m, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < n - prefix, suffix < m - prefix, old[n - 1 - suffix] == new[m - 1 - suffix] { suffix += 1 }
        let a = Array(old[prefix..<(n - suffix)])
        let b = Array(new[prefix..<(m - suffix)])
        if a.isEmpty, b.isEmpty { return [] }
        if a.isEmpty { return [LineChange(.added, start: prefix, count: b.count)] }
        if b.isEmpty { return [LineChange(.deleted, start: prefix, count: 0)] }
        guard let hunks = myers(a, b, maxEdits: maxEdits) else {
            return [LineChange(.modified, start: prefix, count: b.count)]
        }
        return hunks.map { hunk in
            let start = prefix + hunk.newStart
            if hunk.oldCount == 0 { return LineChange(.added, start: start, count: hunk.newCount) }
            if hunk.newCount == 0 { return LineChange(.deleted, start: start, count: 0) }
            return LineChange(.modified, start: start, count: hunk.newCount)
        }
    }

    struct Hunk: Equatable {
        var oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
    }

    /// Myers O((N+M)D). 단계마다 그 단계에 쓰인 대각선 띠만 저장해 메모리는 약 D² 개(Int32).
    static func myers(_ a: [Int32], _ b: [Int32], maxEdits: Int) -> [Hunk]? {
        let n = a.count, m = b.count
        let limit = min(n + m, maxEdits)
        let offset = limit + 1
        var v = [Int32](repeating: 0, count: 2 * limit + 3)
        /// trace[d] = d 단계를 시작할 때의 v(대각선 -d+1 … d-1) — 되짚을 때 쓴다
        var trace: [[Int32]] = []
        var found = -1
        search: for d in 0...limit {
            let lo = offset - max(d - 1, 0), hi = offset + max(d - 1, 0)
            trace.append(Array(v[lo...hi]))
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = Int(v[offset + k + 1]) // 아래로(넣기)
                } else {
                    x = Int(v[offset + k - 1]) + 1 // 오른쪽으로(지우기)
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = Int32(x)
                if x >= n, y >= m { found = d; break search }
            }
        }
        guard found >= 0 else { return nil }

        // 되짚기: 끝에서 처음으로. 고친 걸음마다 그 걸음을 시작한 점(옛 줄, 새 줄)과 종류를 모은다.
        var steps: [(x: Int, y: Int, insert: Bool)] = []
        var x = n, y = m
        var d = found
        while d > 0 {
            let band = trace[d]
            let radius = d - 1
            func value(_ k: Int) -> Int { Int(band[k + radius]) }
            let k = x - y
            let insert = k == -d || (k != d && value(k - 1) < value(k + 1))
            let prevK = insert ? k + 1 : k - 1
            let prevX = value(prevK)
            let prevY = prevX - prevK
            steps.append((prevX, prevY, insert))
            x = prevX
            y = prevY
            d -= 1
        }
        steps.reverse()

        // 사이에 같은 줄 없이 이어진 걸음을 한 덩어리로
        var hunks: [Hunk] = []
        for step in steps {
            if var last = hunks.last, last.oldStart + last.oldCount == step.x, last.newStart + last.newCount == step.y {
                if step.insert { last.newCount += 1 } else { last.oldCount += 1 }
                hunks[hunks.count - 1] = last
            } else {
                hunks.append(Hunk(oldStart: step.x, oldCount: step.insert ? 0 : 1, newStart: step.y, newCount: step.insert ? 1 : 0))
            }
        }
        return hunks
    }
}
