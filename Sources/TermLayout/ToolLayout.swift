import Foundation

/// 창 양옆에 붙이는 도구 창(IntelliJ 의 tool window)
public enum ToolID: String, CaseIterable, Codable, Sendable {
    case spaces, files
}

public enum DockSide: String, CaseIterable, Codable, Sendable {
    case left, right, hidden
}

/// 도구 창 배치: 어느 쪽에 붙었는지, 각 쪽에서 고른 도구, 각 쪽 폭. `term/ui.json` 에 저장한다.
public struct ToolLayout: Equatable, Sendable {
    /// 도구가 붙은 쪽(hidden = 숨김)
    public var sides: [ToolID: DockSide]
    /// 숨기기 전에 붙어 있던 쪽(다시 보일 때 그쪽으로). left·right 만.
    public var lastSides: [ToolID: DockSide]
    /// 쪽마다 보이는 도구(left·right 만)
    public var selected: [DockSide: ToolID]
    /// 쪽마다 폭(pt)
    public var widths: [DockSide: Double]

    public static let defaultWidths: [DockSide: Double] = [.left: 260, .right: 280]

    /// 기본: spaces·files 둘 다 왼쪽, spaces 를 고른 채로(IntelliJ 처럼 프로젝트 도구는 왼쪽, 터미널 폭은 그대로)
    public init() {
        sides = [.spaces: .left, .files: .left]
        lastSides = [.spaces: .left, .files: .left]
        selected = [.left: .spaces]
        widths = Self.defaultWidths
    }

    public func side(of tool: ToolID) -> DockSide { sides[tool] ?? .hidden }

    /// 그쪽에 붙은 도구(ToolID 순서)
    public func tools(in side: DockSide) -> [ToolID] {
        side == .hidden ? [] : ToolID.allCases.filter { self.side(of: $0) == side }
    }

    /// 그쪽에 지금 보이는 도구(없으면 그쪽은 접힌다)
    public func visibleTool(in side: DockSide) -> ToolID? {
        let tools = tools(in: side)
        if let chosen = selected[side], tools.contains(chosen) { return chosen }
        return tools.first
    }

    public func isVisible(_ tool: ToolID) -> Bool {
        let side = side(of: tool)
        return side != .hidden && visibleTool(in: side) == tool
    }

    public func width(_ side: DockSide) -> Double { widths[side] ?? Self.defaultWidths[side] ?? 260 }

    /// 왼쪽·오른쪽으로 옮기거나 숨긴다. 옮기면 그쪽에서 이 도구를 고른다.
    public mutating func move(_ tool: ToolID, to side: DockSide) {
        let old = self.side(of: tool)
        if side == .hidden {
            if old != .hidden { lastSides[tool] = old }
        } else {
            lastSides[tool] = side
            selected[side] = tool
        }
        sides[tool] = side
        normalize()
    }

    /// ⌘⇧E·⌘⇧S: 숨김이면 마지막 쪽에 보이고 고른다 → 보이지만 고르지 않았으면 고른다 → 고른 상태면 숨긴다.
    public mutating func toggle(_ tool: ToolID) {
        let side = side(of: tool)
        if side == .hidden {
            move(tool, to: lastSides[tool].flatMap { $0 == .hidden ? nil : $0 } ?? ToolLayout().side(of: tool))
        } else if visibleTool(in: side) != tool {
            selected[side] = tool
        } else {
            move(tool, to: .hidden)
        }
    }

    /// 고른 도구가 그쪽에 없으면 그쪽 첫 도구로(없으면 비운다)
    public mutating func normalize() {
        for side in [DockSide.left, .right] {
            let tools = tools(in: side)
            if let chosen = selected[side], tools.contains(chosen) { continue }
            selected[side] = tools.first
        }
        selected[.hidden] = nil
        for tool in ToolID.allCases where sides[tool] == nil { sides[tool] = ToolLayout().side(of: tool) }
    }
}

// MARK: - 파일(ui.json)

extension ToolLayout: Codable {
    /// 사람이 읽기 쉬운 모양: {"version":1,"tools":{"spaces":"left",…},"lastSides":{…},"selected":{"left":"spaces"},"widths":{"left":260}}
    private struct File: Codable {
        var version: Int?
        var tools: [String: String]?
        var lastSides: [String: String]?
        var selected: [String: String]?
        var widths: [String: Double]?
    }

    public init(from decoder: Decoder) throws {
        // 모르는 이름·빠진 값은 기본값으로(예전·망가진 파일도 읽는다)
        let file = try File(from: decoder)
        self.init()
        for (key, value) in file.tools ?? [:] {
            if let tool = ToolID(rawValue: key), let side = DockSide(rawValue: value) { sides[tool] = side }
        }
        for (key, value) in file.lastSides ?? [:] {
            if let tool = ToolID(rawValue: key), let side = DockSide(rawValue: value), side != .hidden { lastSides[tool] = side }
        }
        selected = [:]
        for (key, value) in file.selected ?? [:] {
            if let side = DockSide(rawValue: key), side != .hidden, let tool = ToolID(rawValue: value) { selected[side] = tool }
        }
        for (key, value) in file.widths ?? [:] {
            if let side = DockSide(rawValue: key), side != .hidden, value.isFinite, value >= 120, value <= 2000 { widths[side] = value }
        }
        // 숨긴 도구의 마지막 쪽이 없으면 기본 쪽
        for tool in ToolID.allCases where side(of: tool) != .hidden { lastSides[tool] = side(of: tool) }
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        func strings<K: RawRepresentable, V: RawRepresentable>(_ map: [K: V]) -> [String: String]
            where K.RawValue == String, V.RawValue == String {
            Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value.rawValue) })
        }
        try File(version: 1, tools: strings(sides), lastSides: strings(lastSides), selected: strings(selected),
                 widths: Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, $0.value.rounded()) }))
            .encode(to: encoder)
    }

    /// 없거나 읽을 수 없으면 기본값
    public static func load(from url: URL) -> ToolLayout {
        guard let data = try? Data(contentsOf: url), let layout = try? JSONDecoder().decode(ToolLayout.self, from: data)
        else { return ToolLayout() }
        return layout
    }

    public func data() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}
