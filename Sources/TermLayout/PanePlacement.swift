import Foundation

/// `agentdeck new` 가 만든 칸을 어디에 붙일지
public enum NewPanePlacement: Equatable {
    /// 지정이 없을 때: `right` 와 같다(anchor 의 오른쪽 줄 맨 아래로 쌓기 — 하위 에이전트 칸과 같은 규칙)
    case stack
    /// anchor 의 오른쪽. 이미 오른쪽 줄(앞서 만든 칸·하위 에이전트 칸)이 있으면 그 줄 맨 아래로 쌓는다(anchor | (첫째 / 둘째)) — 둘째가 anchor 와 첫째 사이에 끼지 않는다
    case right
    /// anchor 의 아래. 이미 아래 줄이 있으면 그 줄 맨 오른쪽으로 쌓는다(anchor / (첫째 | 둘째)) — `right` 를 가로·세로 바꾼 같은 규칙
    case down
}

extension Workspace {
    /// 새 칸을 anchor 칸이 있는 탭에 붙인다(배치만 — 칸은 데몬에 이미 있다). 포커스와 보고 있는 탭은 그대로 둔다:
    /// 지휘하는 칸에서 일을 시킬 때 입력하던 칸이 바뀌면 안 된다.
    /// 새 칸이 이미 다른 자리(앱이 먼저 새 탭으로 붙였을 때)에 있으면 거기서 빼서 옮긴다. anchor 가 어느 탭에도 없으면 false(그대로).
    @discardableResult
    public mutating func place(newPane id: String, beside anchor: String, _ placement: NewPanePlacement) -> Bool {
        guard id != anchor, tabIndex(containing: anchor) != nil else { return false }
        if tabIndex(containing: id) != nil { remove(pane: id) }
        guard let index = tabIndex(containing: anchor) else { return false }
        var tab = tabs[index]
        switch placement {
        case .right, .stack:
            tab.root = tab.root.addingToLine(id, beside: anchor, toward: .right)
        case .down:
            tab.root = tab.root.addingToLine(id, beside: anchor, toward: .down)
        }
        tab.zoomed = false
        tabs[index] = tab
        return true
    }
}

extension SplitNode {
    /// anchor 의 toward(오른쪽·아래) 쪽에 새 칸을 붙인다. 그쪽에 이미 줄이 있으면(오른쪽이면 세로 줄, 아래면 가로 줄) 그 줄의 끝 칸을 나눠 쌓고
    /// 줄 전체를 같은 크기로 맞춘다(1/2·1/4·1/4 가 아니라 1/3씩 — 줄이 흩어져 있어 한 덩어리가 아니면 크기는 그대로). 없으면 anchor 를 나눈다.
    func addingToLine(_ id: String, beside anchor: String, toward: Direction) -> SplitNode {
        let along: Direction = toward == .right ? .down : .right // 줄이 늘어나는 방향
        let back: Direction = toward == .right ? .left : .up // 줄의 칸에서 anchor 쪽
        guard let near = neighbor(of: anchor, toward: toward) else {
            return splitting(anchor, with: id, axis: toward.axis)
        }
        // 줄의 칸 = anchor 와 맞닿은 칸들(같은 줄에서 along 방향으로 이어지며 뒤쪽 이웃이 anchor 인 것)
        func adjacent(_ pane: String) -> Bool { neighbor(of: pane, toward: back) == anchor }
        var line = [near]
        var cursor = near
        while let before = neighbor(of: cursor, toward: along == .down ? .up : .left), adjacent(before) {
            line.insert(before, at: 0)
            cursor = before
        }
        cursor = near
        while let after = neighbor(of: cursor, toward: along), adjacent(after) {
            line.append(after)
            cursor = after
        }
        let last = line[line.count - 1]
        return splitting(last, with: id, axis: along.axis)
            .equalizing(exactly: Set(line + [id]))
    }
}
