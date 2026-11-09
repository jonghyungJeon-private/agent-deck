import Foundation

/// 탭 줄 오른쪽 여백과 제목 폭 맞추기(순수 값 — 시험한다).
/// 🌐·⌨ 알약이 탭 줄 안 오른쪽에 있으면 그 폭만큼 탭 줄 오른쪽을 비워 탭과 "+" 가 알약 아래로 들어가지 않게 한다.
public enum TabBarFit {
    /// 알약 묶음이 차지하는 폭: 보이는 알약들의 폭 + 사이 간격 + 오른쪽 가장자리 여백 + 탭 줄과의 사이 여유.
    /// 알약이 없으면 0(여백을 두지 않는다).
    public static func reserve(pillWidths: [Double], gap: Double, trailing: Double, clearance: Double) -> Double {
        guard !pillWidths.isEmpty else { return 0 }
        return pillWidths.reduce(0, +) + gap * Double(pillWidths.count - 1) + trailing + clearance
    }

    /// 탭이 `available` 폭에 안 들어갈 때 제목 폭을 줄인다. `titles` = 줄이지 않은 제목 폭, `fixed` = 탭마다 제목 밖 폭(여백·아이콘·⌘숫자…),
    /// `extra` = 탭 말고 차지하는 폭("+"). 긴 제목부터 같은 한도로 깎고, 제목마다 `minTitle`(제목이 더 짧으면 그 폭) 밑으로는 줄이지 않는다.
    /// 다 줄여도 안 들어가면 최소 폭 그대로 돌려준다(넘친 쪽은 그리는 쪽이 자른다).
    public static func titleWidths(titles: [Double], fixed: [Double], extra: Double, available: Double, minTitle: Double) -> [Double] {
        precondition(titles.count == fixed.count)
        let total = titles.reduce(0, +) + fixed.reduce(0, +) + extra
        guard available > 0, total > available else { return titles }
        let floors = titles.map { min($0, minTitle) }
        let target = available - fixed.reduce(0, +) - extra
        if target <= floors.reduce(0, +) { return floors }
        // 한도 c 를 이분법으로: 제목마다 max(바닥, min(제목, c))
        var low = 0.0, high = titles.max() ?? 0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            let sum = zip(titles, floors).reduce(0.0) { $0 + max($1.1, min($1.0, mid)) }
            if sum > target { high = mid } else { low = mid }
        }
        return zip(titles, floors).map { max($0.1, min($0.0, low)) }
    }

    /// 탭 줄에 다 안 들어갈 때 보일 탭의 이어진 구간(탭마다 제목을 최소로 줄인 폭 `minWidths`, 둘 수 있는 폭 `available`).
    /// 다 들어가면 전부. 아니면 맨 앞부터 채우고, 고른 탭이 밖이면 고른 탭이 들어올 때까지 구간을 오른쪽으로 민다(고른 탭은 늘 보인다).
    /// 한 탭도 안 들어가는 좁은 폭에서도 고른 탭 하나는 둔다.
    /// `previousStart`(지난번 구간의 첫 탭)가 있으면 구간이 가만히 있는다: 고른 탭이 지난 구간 안이면 그대로, 밖이면 고른 탭이 보일 만큼만
    /// 민다(왼쪽 밖이면 고른 탭이 맨 앞, 오른쪽 밖이면 고른 탭이 들어올 때까지 오른쪽으로). 오른쪽 끝에 빈자리가 남으면 그만큼만 왼쪽으로 당긴다.
    /// 없으면(처음) 맨 앞부터.
    public static func visibleRange(minWidths: [Double], selected: Int?, available: Double, previousStart: Int? = nil) -> Range<Int> {
        let count = minWidths.count
        guard count > 0 else { return 0..<0 }
        guard minWidths.reduce(0, +) > available else { return 0..<count }
        let target = min(max(selected ?? 0, 0), count - 1)
        func lastFit(from start: Int) -> Int {
            var end = start, used = minWidths[start]
            while end + 1 < count, used + minWidths[end + 1] <= available {
                end += 1
                used += minWidths[end]
            }
            return end
        }
        var start = min(max(previousStart ?? 0, 0), count - 1)
        if target < start { start = target }
        while lastFit(from: start) < target, start < target { start += 1 }
        let end = lastFit(from: start)
        // 오른쪽 끝(마지막 탭까지 보임)에 빈자리가 남으면 왼쪽 탭을 더 보인다
        if end == count - 1 {
            var used = minWidths[start...end].reduce(0, +)
            while start > 0, used + minWidths[start - 1] <= available {
                start -= 1
                used += minWidths[start]
            }
        }
        return start..<(max(end, start) + 1)
    }
}
