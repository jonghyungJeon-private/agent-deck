import CoreGraphics
import Foundation

/// 분할 방향. horizontal = 좌우로 나란히, vertical = 위아래로.
public enum SplitAxis: String, Codable {
    case horizontal
    case vertical
}

public enum Direction: String, CaseIterable {
    case left, right, up, down

    var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
}

/// 탭 안의 분할 배치(Ghostty 처럼 두 갈래씩 나누는 나무). 잎은 데몬 화면 ID.
public indirect enum SplitNode: Codable, Equatable {
    case pane(String)
    /// first 는 왼쪽(또는 위), ratio 는 first 가 차지하는 비율
    case split(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)

    public static let minRatio = 0.1

    /// 왼쪽 위부터 차례로
    public var panes: [String] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, let first, let second): return first.panes + second.panes
        }
    }

    public func contains(_ id: String) -> Bool { panes.contains(id) }

    /// target 화면을 둘로 나눠 new 를 오른쪽(또는 아래)에 둔다
    public func splitting(_ target: String, with new: String, axis: SplitAxis) -> SplitNode {
        switch self {
        case .pane(let id):
            return id == target ? .split(axis: axis, ratio: 0.5, first: self, second: .pane(new)) : self
        case .split(let a, let r, let first, let second):
            return .split(axis: a, ratio: r, first: first.splitting(target, with: new, axis: axis),
                          second: second.splitting(target, with: new, axis: axis))
        }
    }

    /// 화면 하나를 빼고 그 짝이 자리를 채운다. 다 빠지면 nil.
    public func removing(_ target: String) -> SplitNode? {
        switch self {
        case .pane(let id):
            return id == target ? nil : self
        case .split(let a, let r, let first, let second):
            switch (first.removing(target), second.removing(target)) {
            case (nil, nil): return nil
            case (let one?, nil), (nil, let one?): return one
            case (let f?, let s?): return .split(axis: a, ratio: r, first: f, second: s)
            }
        }
    }

    /// 가르는 선 하나. path 는 뿌리에서 그 갈래까지(false = first, true = second).
    public struct Divider: Equatable {
        public var path: [Bool]
        public var axis: SplitAxis
        /// 선 자체
        public var rect: CGRect
        /// 이 갈래 전체(끌 때 비율 계산용)
        public var parent: CGRect
    }

    /// rect 안에 화면과 가르는 선을 배치한다(y 가 아래로 커지는 좌표). 선 두께만큼 화면 사이를 띄운다.
    public func layout(in rect: CGRect, divider: CGFloat) -> (panes: [String: CGRect], dividers: [Divider]) {
        var panes: [String: CGRect] = [:]
        var dividers: [Divider] = []
        func place(_ node: SplitNode, _ rect: CGRect, _ path: [Bool]) {
            switch node {
            case .pane(let id):
                panes[id] = rect
            case .split(let axis, let ratio, let first, let second):
                let total = (axis == .horizontal ? rect.width : rect.height) - divider
                let size = max(0, (total * ratio).rounded())
                let a, line, b: CGRect
                if axis == .horizontal {
                    a = CGRect(x: rect.minX, y: rect.minY, width: size, height: rect.height)
                    line = CGRect(x: a.maxX, y: rect.minY, width: divider, height: rect.height)
                    b = CGRect(x: line.maxX, y: rect.minY, width: max(0, rect.maxX - line.maxX), height: rect.height)
                } else {
                    a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: size)
                    line = CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: divider)
                    b = CGRect(x: rect.minX, y: line.maxY, width: rect.width, height: max(0, rect.maxY - line.maxY))
                }
                dividers.append(Divider(path: path, axis: axis, rect: line, parent: rect))
                place(first, a, path + [false])
                place(second, b, path + [true])
            }
        }
        place(self, rect, [])
        return (panes, dividers)
    }

    public func settingRatio(at path: [Bool], to value: Double) -> SplitNode {
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        guard let step = path.first else {
            return .split(axis: axis, ratio: min(max(value, Self.minRatio), 1 - Self.minRatio), first: first, second: second)
        }
        let rest = Array(path.dropFirst())
        return step
            ? .split(axis: axis, ratio: ratio, first: first, second: second.settingRatio(at: rest, to: value))
            : .split(axis: axis, ratio: ratio, first: first.settingRatio(at: rest, to: value), second: second)
    }

    /// direction 쪽으로 가장 가까운 화면(Ghostty goto_split 방향 이동)
    public func neighbor(of id: String, toward direction: Direction) -> String? {
        let frames = layout(in: CGRect(x: 0, y: 0, width: 1000, height: 1000), divider: 0).panes
        guard let from = frames[id] else { return nil }
        let eps: CGFloat = 0.5
        var best: (id: String, distance: CGFloat, overlap: CGFloat)?
        // 똑같이 가까우면 왼쪽 위 화면이 먼저(나무 순서)
        for other in panes where other != id {
            guard let rect = frames[other] else { continue }
            let distance: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left: distance = from.minX - rect.maxX
            case .right: distance = rect.minX - from.maxX
            case .up: distance = from.minY - rect.maxY
            case .down: distance = rect.minY - from.maxY
            }
            if direction.axis == .horizontal {
                overlap = min(from.maxY, rect.maxY) - max(from.minY, rect.minY)
            } else {
                overlap = min(from.maxX, rect.maxX) - max(from.minX, rect.minX)
            }
            guard distance >= -eps, overlap > eps else { continue }
            if let current = best, current.distance < distance - eps
                || (abs(current.distance - distance) <= eps && current.overlap >= overlap) { continue }
            best = (other, distance, overlap)
        }
        return best?.id
    }

    /// id 를 품은 가장 가까운 같은 방향 갈래의 선을 direction 쪽으로 옮긴다(Ghostty resize_split)
    public func resizing(_ id: String, toward direction: Direction, by delta: Double) -> SplitNode {
        func walk(_ node: SplitNode) -> (SplitNode, done: Bool) {
            guard case .split(let axis, let ratio, let first, let second) = node else { return (node, false) }
            let inFirst = first.contains(id)
            guard inFirst || second.contains(id) else { return (node, false) }
            let (child, done) = walk(inFirst ? first : second)
            let rebuilt = SplitNode.split(axis: axis, ratio: ratio, first: inFirst ? child : first, second: inFirst ? second : child)
            if done || axis != direction.axis { return (rebuilt, done) }
            let sign: Double = direction == .right || direction == .down ? 1 : -1
            let next = min(max(ratio + sign * delta, Self.minRatio), 1 - Self.minRatio)
            return (.split(axis: axis, ratio: next, first: first, second: second), true)
        }
        return walk(self).0
    }

    /// 같은 방향으로 이어진 화면이 같은 크기가 되게(Ghostty equalize_splits)
    public func equalized() -> SplitNode {
        func weight(_ node: SplitNode, _ axis: SplitAxis) -> Double {
            if case .split(let a, _, let first, let second) = node, a == axis {
                return weight(first, axis) + weight(second, axis)
            }
            return 1
        }
        guard case .split(let axis, _, let first, let second) = self else { return self }
        let a = weight(first, axis), b = weight(second, axis)
        return .split(axis: axis, ratio: a / (a + b), first: first.equalized(), second: second.equalized())
    }
}

/// 탭 하나
public struct TabState: Codable, Equatable, Identifiable {
    public var id: String
    public var root: SplitNode
    /// 이 탭에서 입력을 받는 화면
    public var focused: String
    /// 한 화면만 크게(Ghostty toggle_split_zoom)
    public var zoomed: Bool

    public init(id: String = UUID().uuidString, root: SplitNode, focused: String, zoomed: Bool = false) {
        self.id = id
        self.root = root
        self.focused = focused
        self.zoomed = zoomed
    }

    /// 지금 화면에 보일 배치
    public var visibleRoot: SplitNode { zoomed && root.panes.count > 1 ? .pane(focused) : root }
}

/// 화면을 다시 만들 때 필요한 것(데몬이 꺼져 화면이 사라졌을 때 같은 자리에 되살린다)
public struct PaneRecipe: Codable, Equatable {
    /// 마지막으로 본 작업 폴더
    public var cwd: String
    /// 그 화면에서 돌던 claude 세션
    public var sessionId: String?
    /// claude 를 띄웠던 실행 인자(세션 지정 인자는 빼고, 예: --dangerously-skip-permissions)
    public var claudeArgs: [String]?
    public var codexSessionId: String?
    public var codexArgs: [String]?
    public var codexHome: String?

    public init(cwd: String, sessionId: String? = nil, claudeArgs: [String]? = nil,
                codexSessionId: String? = nil, codexArgs: [String]? = nil, codexHome: String? = nil) {
        self.codexSessionId = codexSessionId
        self.codexArgs = codexArgs
        self.codexHome = codexHome
        self.cwd = cwd
        self.sessionId = sessionId
        self.claudeArgs = claudeArgs
    }
}

extension PaneRecipe {
    /// 되살릴 때 이어받는 claude 옵션(허용 목록). 세션 지정·처음 질문·--worktree·--print 처럼
    /// 다시 실행하면 뜻이 달라지는 것은 모두 뺀다(처음 질문이 인자로 남아 있으면 되살릴 때 다시 전송된다).
    static let keptFlags: Set<String> = [
        "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--ide", "--chrome", "--no-chrome",
        "--strict-mcp-config", "--verbose", "--disable-slash-commands",
    ]
    /// 값을 하나 받는 옵션
    static let keptValueFlags: Set<String> = [
        "--model", "--effort", "--permission-mode", "--fallback-model", "--agent", "--append-system-prompt",
        "--settings", "--autocompact", "--plugin-dir",
    ]
    /// 값을 여러 개 받는 옵션(다음 옵션이 나올 때까지)
    static let keptListFlags: Set<String> = [
        "--add-dir", "--mcp-config", "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools",
    ]

    /// claude 실행 인자(맨 앞 실행 파일 포함)에서 되살릴 때 쓸 옵션만 고른다
    public static func keptArgs(_ argv: [String]) -> [String] {
        var kept: [String] = []
        var index = argv.index(after: argv.startIndex)
        func takeValues(max: Int) {
            var taken = 0
            while index < argv.endIndex, taken < max, !argv[index].hasPrefix("-") {
                kept.append(argv[index])
                index += 1
                taken += 1
            }
        }
        while index < argv.endIndex {
            let arg = argv[index]
            index += 1
            guard arg.hasPrefix("-") else { continue } // 처음 질문 같은 위치 인자는 버린다
            let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            if arg.contains("=") {
                if keptValueFlags.contains(name) || keptListFlags.contains(name) { kept.append(arg) }
            } else if keptFlags.contains(arg) {
                kept.append(arg)
            } else if keptValueFlags.contains(arg) {
                kept.append(arg)
                takeValues(max: 1)
            } else if keptListFlags.contains(arg) {
                kept.append(arg)
                takeValues(max: .max)
            } else {
                // 모르는 옵션은 뒤따르는 값까지 버린다(값인지 위치 인자인지 알 수 없으므로 둘 다 버려도 안전)
                while index < argv.endIndex, !argv[index].hasPrefix("-") { index += 1 }
            }
        }
        // 값 없이 끝난 값 옵션(예: 맨 끝 --model)은 빼서 claude 가 다음 인자를 값으로 먹지 않게 한다
        if let last = kept.last, keptValueFlags.contains(last) || keptListFlags.contains(last) { kept.removeLast() }
        return kept
    }

    /// 화면을 되살릴 때 셸에 넣을 명령. claude 세션이 없으면 nil(셸만 연다).
    public var resumeCommand: String? {
        if let codexSessionId {
            let command = (["codex", "resume", codexSessionId] + (codexArgs ?? [])).map(Self.shellQuote).joined(separator: " ")
            return codexHome.map { "CODEX_HOME=" + Self.shellQuote($0) + " " + command } ?? command
        }
        guard let sessionId else { return nil }
        return (["claude", "--resume", sessionId] + (claudeArgs ?? [])).map(Self.shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ arg: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,")
        if !arg.isEmpty, arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 창 하나의 탭 묶음. 앱을 껐다 켜도 이어지도록 파일로 저장한다.
public struct Workspace: Codable, Equatable {
    public var tabs: [TabState] = []
    public var selected: String?
    /// 화면별 되살리기 정보
    public var recipes: [String: PaneRecipe] = [:]
    /// 배치를 맞춘 데몬. 다른 데몬(강제 종료·재부팅 뒤 새로 뜬 것)이면 사라진 화면을 지우지 않고 꺼진 화면으로 둔다.
    public var daemonPid: Int32?
    /// 배치를 맞춘 데몬 실행 ID(있으면 PID 대신 이것으로 데몬이 바뀌었는지 본다)
    public var daemonInstance: String?
    /// 꺼진 화면(탭을 열면 같은 자리에 되살린다)
    public var dormant: Set<String> = []

    public init(tabs: [TabState] = [], selected: String? = nil) {
        self.tabs = tabs
        self.selected = selected
    }

    enum CodingKeys: String, CodingKey { case tabs, selected, recipes, daemonPid, daemonInstance, dormant }

    // 예전 배치 파일(되살리기 정보 없음)도 읽는다
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try c.decodeIfPresent([TabState].self, forKey: .tabs) ?? []
        selected = try c.decodeIfPresent(String.self, forKey: .selected)
        recipes = try c.decodeIfPresent([String: PaneRecipe].self, forKey: .recipes) ?? [:]
        daemonPid = try c.decodeIfPresent(Int32.self, forKey: .daemonPid)
        daemonInstance = try c.decodeIfPresent(String.self, forKey: .daemonInstance)
        dormant = try c.decodeIfPresent(Set<String>.self, forKey: .dormant) ?? []
    }

    public var allPanes: [String] { tabs.flatMap { $0.root.panes } }

    public var selectedIndex: Int? {
        selected.flatMap { id in tabs.firstIndex { $0.id == id } } ?? (tabs.isEmpty ? nil : 0)
    }

    public var selectedTab: TabState? { selectedIndex.map { tabs[$0] } }

    public func tabIndex(containing pane: String) -> Int? {
        tabs.firstIndex { $0.root.contains(pane) }
    }

    /// 화면 하나를 빼고, 빈 탭은 닫는다. 포커스는 옆 화면으로.
    public mutating func remove(pane: String) {
        guard let index = tabIndex(containing: pane) else { return }
        var tab = tabs[index]
        guard let root = tab.root.removing(pane) else {
            tabs.remove(at: index)
            if selected == tab.id {
                selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            }
            return
        }
        if tab.focused == pane {
            let order = tab.root.panes
            let position = order.firstIndex(of: pane) ?? 0
            let remaining = root.panes
            tab.focused = remaining[min(max(position - 1, 0), remaining.count - 1)]
        }
        tab.root = root
        if root.panes.count == 1 { tab.zoomed = false }
        tabs[index] = tab
    }

    /// 화면을 완전히 없앤다(되살리기 정보까지)
    public mutating func forget(pane: String) {
        remove(pane: pane)
        recipes[pane] = nil
        dormant.remove(pane)
    }

    /// 데몬 화면 목록에 맞춘다. 바뀐 게 있으면 true.
    /// - 같은 데몬에서 사라진 화면(셸·claude 가 끝남)은 뺀다. keep 은 아직 만드는 중이라 둔다.
    /// - 데몬이 바뀌었으면(daemonPid 가 다름) 사라진 화면 중 되살리기 정보가 있는 것은 꺼진 화면으로 남긴다.
    /// - 어느 탭에도 없는 화면은 새 탭으로 붙인다.
    @discardableResult
    public mutating func reconcile(live: [String], keep: Set<String> = [], ignore: Set<String> = [],
                                   daemonPid: Int32? = nil, daemonInstance: String? = nil) -> Bool {
        let before = self
        let liveSet = Set(live)
        let restarted: Bool
        if let daemonInstance, let saved = self.daemonInstance {
            restarted = daemonInstance != saved
        } else {
            restarted = daemonPid != nil && self.daemonPid != nil && daemonPid != self.daemonPid
        }
        if let daemonPid { self.daemonPid = daemonPid }
        if let daemonInstance { self.daemonInstance = daemonInstance }
        for pane in allPanes where !liveSet.contains(pane) && !keep.contains(pane) {
            if dormant.contains(pane) { continue }
            if restarted, recipes[pane] != nil {
                dormant.insert(pane)
            } else {
                forget(pane: pane)
            }
        }
        dormant.subtract(liveSet) // 되살아난 화면
        let placed = Set(allPanes)
        for pane in live where !placed.contains(pane) && !ignore.contains(pane) {
            tabs.append(TabState(root: .pane(pane), focused: pane))
        }
        recipes = recipes.filter { placed.contains($0.key) || liveSet.contains($0.key) }
        if selectedIndex == nil || !tabs.contains(where: { $0.id == selected }) {
            selected = tabs.first?.id
        }
        return self != before
    }
}
