import Foundation

/// 창 양옆에 붙이는 도구 창(IntelliJ 의 tool window)
public enum ToolID: String, CaseIterable, Codable, Sendable {
    /// browser: 지금 고른 세션의 에이전트 브라우저(세션 창 안에서 보기). 처음엔 숨김, 꺼내면 오른쪽.
    case spaces, files, browser
}

public enum DockSide: String, CaseIterable, Codable, Sendable {
    case left, right, hidden
}

/// 브라우저 작은 창(세션 창 안에 떠 있는 패널)의 위치·크기. 호스트(터미널 영역) 크기에 대한 비율이라
/// 창 크기가 바뀌어도 비슷한 자리에 남는다. right·bottom = 오른쪽·아래 가장자리에서 떨어진 거리, 모두 아래-왼쪽 원점 기준.
public struct BrowserFloatFrame: Equatable, Sendable {
    public var right: Double
    public var bottom: Double
    public var width: Double
    public var height: Double

    public static let minSize = CGSize(width: 360, height: 260)
    /// 처음 자리: 오른쪽 여백·🌐 버튼 위 간격, 호스트 대비 크기
    public static let margin: Double = 14
    public static let defaultWidthRatio: Double = 0.45
    public static let defaultHeightRatio: Double = 0.65
    /// "크게" 크기
    public static let largeWidthRatio: Double = 0.8
    public static let largeHeightRatio: Double = 0.88

    public init(right: Double, bottom: Double, width: Double, height: Double) {
        self.right = right
        self.bottom = bottom
        self.width = width
        self.height = height
    }

    /// 호스트 안(아래-왼쪽 원점)의 사각형 → 비율
    public init(rect: CGRect, in host: CGSize) {
        let w = max(Double(host.width), 1), h = max(Double(host.height), 1)
        self.init(right: (w - Double(rect.maxX)) / w, bottom: Double(rect.minY) / h,
                  width: Double(rect.width) / w, height: Double(rect.height) / h)
    }

    /// 호스트 안(아래-왼쪽 원점)의 사각형. 항상 호스트 안으로 맞춘다.
    public func rect(in host: CGSize) -> CGRect {
        let w = Double(host.width), h = Double(host.height)
        return Self.clamp(CGRect(x: w - right * w - width * w, y: bottom * h, width: width * w, height: height * h), in: host)
    }

    /// 최소 크기 이상, 호스트 밖으로 나가지 않게(호스트가 최소 크기보다 작으면 호스트 크기까지만)
    public static func clamp(_ rect: CGRect, in host: CGSize) -> CGRect {
        let width = min(max(rect.width, minSize.width), max(host.width, 0))
        let height = min(max(rect.height, minSize.height), max(host.height, 0))
        let x = min(max(rect.minX, 0), max(host.width - width, 0))
        let y = min(max(rect.minY, 0), max(host.height - height, 0))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 저장된 값이 없을 때: 오른쪽 아래, 🌐 버튼 바로 위(bottomInset = 버튼 윗선까지), 호스트의 45% × 65%
    public static func defaultRect(in host: CGSize, bottomInset: Double) -> CGRect {
        anchored(in: host, bottomInset: bottomInset, widthRatio: defaultWidthRatio, heightRatio: defaultHeightRatio)
    }

    /// "크게": 같은 오른쪽 아래 기준으로 더 넓게
    public static func largeRect(in host: CGSize, bottomInset: Double) -> CGRect {
        anchored(in: host, bottomInset: bottomInset, widthRatio: largeWidthRatio, heightRatio: largeHeightRatio)
    }

    private static func anchored(in host: CGSize, bottomInset: Double, widthRatio: Double, heightRatio: Double) -> CGRect {
        let width = Double(host.width) * widthRatio, height = Double(host.height) * heightRatio
        return clamp(CGRect(x: Double(host.width) - margin - width, y: bottomInset, width: width, height: height), in: host)
    }

    /// 파일에서 읽은 값이 쓸 만한가(비율은 0 이상 1 이하, 크기는 0 초과)
    fileprivate var isSane: Bool {
        [right, bottom, width, height].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } && width > 0.05 && height > 0.05
    }
}

/// 브라우저 도구의 "작은 창" 상태. 작은 창이 떠 있는 동안 도크 쪽(`sides[.browser]`)은 hidden 이다(둘 중 한 곳).
/// 브라우저는 UI 에서 늘 작은 창으로만 뜬다(옆 도크는 시험 명령 `dock browser left|right` 로만 남아 있다).
public struct BrowserFloat: Equatable, Sendable {
    /// 작은 창이 떠 있음
    public var shown = false
    /// 사람이 끌거나 크기를 바꾼 자리(nil = 기본 자리)
    public var frame: BrowserFloatFrame?

    public init() {}
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
    /// 터미널·편집기 글꼴 크기(pt). nil = 기본(13)
    public var fontSize: Double?
    /// 브라우저 작은 창(세션 창 안에 떠 있는 패널)
    public var browserFloat = BrowserFloat()

    public static let defaultWidths: [DockSide: Double] = [.left: 260, .right: 280]
    /// 브라우저가 보이는 도크의 처음 폭(페이지가 읽힐 만큼) — 사람이 넓히거나 줄이면 그 폭을 기억한다
    public static let browserWidth: Double = 640
    /// 저장된 도크 폭의 상한 — 브라우저 도크는 2400pt 까지 넓힐 수 있다(ToolWindows 도크 상한과 같게)
    public static let maxWidth: Double = 2400

    /// 기본: spaces·files 둘 다 왼쪽, spaces 를 고른 채로(IntelliJ 처럼 프로젝트 도구는 왼쪽, 터미널 폭은 그대로).
    /// browser 는 숨김(브라우저를 세션 창 안에서 보기로 하면 오른쪽에 나온다).
    public init() {
        sides = [.spaces: .left, .files: .left, .browser: .hidden]
        lastSides = [.spaces: .left, .files: .left, .browser: .right]
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

    /// 브라우저가 어떤 방식으로든 보이는 중(옆 도크 또는 작은 창)
    public var isBrowserShown: Bool { isVisible(.browser) || browserFloat.shown }

    public func width(_ side: DockSide) -> Double { widths[side] ?? Self.defaultWidths[side] ?? 260 }

    /// 왼쪽·오른쪽으로 옮기거나 숨긴다. 옮기면 그쪽에서 이 도구를 고른다.
    /// 브라우저를 처음 꺼내는 도크는 기본 폭(280)이 좁아 페이지가 읽히지 않으니 넓힌다(사람이 정한 폭은 그대로).
    public mutating func move(_ tool: ToolID, to side: DockSide) {
        if tool == .browser {
            // 도크로 가거나 숨기면 작은 창은 닫힌다
            browserFloat.shown = false
        }
        let old = self.side(of: tool)
        if tool == .browser, side != .hidden, widths[side] == nil || widths[side] == Self.defaultWidths[side] {
            widths[side] = Self.browserWidth
        }
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
        if tool == .browser, browserFloat.shown {
            move(.browser, to: .hidden)
        } else if tool == .browser, side == .hidden {
            showBrowserFloat() // 브라우저는 늘 작은 창으로
        } else if side == .hidden {
            move(tool, to: lastSides[tool].flatMap { $0 == .hidden ? nil : $0 } ?? ToolLayout().side(of: tool))
        } else if visibleTool(in: side) != tool {
            selected[side] = tool
        } else {
            move(tool, to: .hidden)
        }
    }

    /// 브라우저를 작은 창으로 띄운다(옆 도크에 붙어 있었으면 거기서 내리고, 그 쪽은 다시 꺼낼 때를 위해 기억해 둔다)
    public mutating func showBrowserFloat() {
        move(.browser, to: .hidden)
        browserFloat.shown = true
    }

    /// 고른 도구가 그쪽에 없으면 그쪽 첫 도구로(없으면 비운다)
    public mutating func normalize() {
        for side in [DockSide.left, .right] {
            let tools = tools(in: side)
            if let chosen = selected[side], tools.contains(chosen) { continue }
            selected[side] = tools.first
        }
        selected[.hidden] = nil
        if side(of: .browser) != .hidden { browserFloat.shown = false } // 도크와 작은 창은 한 곳만
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
        var fontSize: Double?
        var browserFloat: FloatFile?
    }

    /// {"shown":true,"frame":{"right":0.02,"bottom":0.1,"width":0.45,"height":0.65}}
    private struct FloatFile: Codable {
        var shown: Bool?
        var frame: [String: Double]?
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
            if let side = DockSide(rawValue: key), side != .hidden, value.isFinite, value >= 120, value <= Self.maxWidth { widths[side] = value }
        }
        if let size = file.fontSize, size.isFinite, size >= 4, size <= 100 { fontSize = size }
        browserFloat.shown = file.browserFloat?.shown ?? false
        if let f = file.browserFloat?.frame, let right = f["right"], let bottom = f["bottom"], let width = f["width"], let height = f["height"] {
            let frame = BrowserFloatFrame(right: right, bottom: bottom, width: width, height: height)
            if frame.isSane { browserFloat.frame = frame }
        }
        // 숨긴 도구의 마지막 쪽이 없으면 기본 쪽
        for tool in ToolID.allCases where side(of: tool) != .hidden { lastSides[tool] = side(of: tool) }
        normalize()
        // 예전에 옆 도크에 붙였던 브라우저는 이제 작은 창으로: 도크에서 내리고, 보이고 있었으면 작은 창을 띄운다
        if side(of: .browser) != .hidden {
            browserFloat.shown = isVisible(.browser) || file.browserFloat?.shown == true
            sides[.browser] = .hidden
            normalize()
        }
    }

    public func encode(to encoder: Encoder) throws {
        func strings<K: RawRepresentable, V: RawRepresentable>(_ map: [K: V]) -> [String: String]
            where K.RawValue == String, V.RawValue == String {
            Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value.rawValue) })
        }
        try File(version: 1, tools: strings(sides), lastSides: strings(lastSides), selected: strings(selected),
                 widths: Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, $0.value.rounded()) }),
                 fontSize: fontSize,
                 browserFloat: FloatFile(shown: browserFloat.shown,
                                         frame: browserFloat.frame.map {
                                             ["right": $0.right.rounded4, "bottom": $0.bottom.rounded4,
                                              "width": $0.width.rounded4, "height": $0.height.rounded4]
                                         }))
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

private extension Double {
    /// 파일에 짧게 남기려고 소수 넷째 자리까지
    var rounded4: Double { (self * 10_000).rounded() / 10_000 }
}
