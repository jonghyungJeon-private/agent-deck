import Foundation

/// 창 양옆에 붙이는 도구 창(IntelliJ 의 tool window)
public enum ToolID: String, CaseIterable, Codable, Sendable {
    /// browser: 지금 고른 세션의 에이전트 브라우저(세션 창 안에서 보기). 처음엔 숨김, 꺼내면 오른쪽.
    case spaces, files, browser
}

public enum DockSide: String, CaseIterable, Codable, Sendable {
    case left, right, hidden
}

/// 작은 창(세션 창 안에 떠 있는 패널: 브라우저·작은 터미널)의 위치·크기. 호스트(터미널 영역) 크기에 대한 비율이라
/// 창 크기가 바뀌어도 비슷한 자리에 남는다. right·bottom = 오른쪽·아래 가장자리에서 떨어진 거리, 모두 아래-왼쪽 원점 기준.
/// 처음 자리·최소 크기는 창 종류·구석(`FloatCorner`)마다 다르다(`FloatSpec`).
public struct FloatFrame: Equatable, Sendable {
    public var right: Double
    public var bottom: Double
    public var width: Double
    public var height: Double

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
    public func rect(in host: CGSize, spec: FloatSpec) -> CGRect {
        let w = Double(host.width), h = Double(host.height)
        return spec.clamp(CGRect(x: w - right * w - width * w, y: bottom * h, width: width * w, height: height * h), in: host)
    }

    /// 파일에서 읽은 값이 쓸 만한가(비율은 0 이상 1 이하, 크기는 0 초과)
    fileprivate var isSane: Bool {
        [right, bottom, width, height].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } && width > 0.05 && height > 0.05
    }
}

/// 작은 창 버튼(🌐·⌨)과 작은 창의 처음 자리가 있는 구석: 기본 오른쪽 위(채팅 입력이 있는 아래를 가리지 않게)
public enum FloatCorner: String, CaseIterable, Codable, Sendable {
    case topRight, bottomRight
}

/// 작은 창 종류별 규칙: 최소 크기, 처음 자리(구석마다), "크게" 크기
public struct FloatSpec: Equatable, Sendable {
    public var minSize: CGSize
    public var widthRatio: Double
    public var heightRatio: Double
    public var largeWidthRatio: Double
    public var largeHeightRatio: Double
    /// 브라우저와 겹치지 않는 쪽(true = 오른쪽 아래 구석이면 왼쪽 아래, 오른쪽 위 구석이면 브라우저 왼쪽). false = 오른쪽
    public var anchorsLeft: Bool

    public static let margin: Double = 14

    /// 브라우저: 오른쪽 아래, 🌐 버튼 바로 위, 호스트의 45% × 65%
    public static let browser = FloatSpec(minSize: CGSize(width: 360, height: 260), widthRatio: 0.45, heightRatio: 0.65,
                                          largeWidthRatio: 0.8, largeHeightRatio: 0.88, anchorsLeft: false)
    /// 작은 터미널: 왼쪽 아래(브라우저 창의 처음 자리를 가리지 않게), 호스트의 50% × 40%(브라우저 45% 와 겹치지 않게)
    public static let terminal = FloatSpec(minSize: CGSize(width: 360, height: 200), widthRatio: 0.5, heightRatio: 0.4,
                                           largeWidthRatio: 0.8, largeHeightRatio: 0.88, anchorsLeft: true)

    /// 최소 크기 이상, 호스트 밖으로 나가지 않게(호스트가 최소 크기보다 작으면 호스트 크기까지만)
    public func clamp(_ rect: CGRect, in host: CGSize) -> CGRect {
        let width = min(max(rect.width, minSize.width), max(host.width, 0))
        let height = min(max(rect.height, minSize.height), max(host.height, 0))
        let x = min(max(rect.minX, 0), max(host.width - width, 0))
        let y = min(max(rect.minY, 0), max(host.height - height, 0))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 저장된 값이 없을 때. edgeInset = 구석 쪽 세로 가장자리(오른쪽 위면 위, 오른쪽 아래면 아래)에서 띄울 거리.
    /// 브라우저는 늘 구석에 붙는다(오른쪽 위: 버튼 줄 아래, 오른쪽 아래: 🌐 버튼 위).
    /// 작은 터미널(anchorsLeft): 브라우저가 함께 보이면(`besideBrowser`) 브라우저 자리와 겹치지 않는 쪽 — 오른쪽 위는 같은 높이에서
    /// 브라우저 처음 자리의 왼쪽(자리가 모자라면 줄이되 최소 크기까지만), 오른쪽 아래는 왼쪽 아래. 브라우저가 안 보이면
    /// 터미널 혼자 구석에 붙는다(브라우저와 같은 쪽·같은 edgeInset — 호출하는 쪽이 브라우저의 edgeInset 을 넘긴다).
    public func defaultRect(in host: CGSize, corner: FloatCorner, edgeInset: Double, besideBrowser: Bool = true) -> CGRect {
        anchored(in: host, corner: corner, edgeInset: edgeInset, widthRatio: widthRatio, heightRatio: heightRatio, large: false,
                 besideBrowser: besideBrowser)
    }

    /// "크게": 같은 구석 기준으로 더 넓게(호스트 안). 브라우저가 보이는지와 상관없이 그대로.
    public func largeRect(in host: CGSize, corner: FloatCorner, edgeInset: Double) -> CGRect {
        anchored(in: host, corner: corner, edgeInset: edgeInset, widthRatio: largeWidthRatio, heightRatio: largeHeightRatio, large: true,
                 besideBrowser: true)
    }

    /// 오른쪽 위에서 브라우저와 작은 터미널 처음 자리 사이 간격
    public static let gap: Double = 10

    private func anchored(in host: CGSize, corner: FloatCorner, edgeInset: Double, widthRatio: Double, heightRatio: Double,
                          large: Bool, besideBrowser: Bool) -> CGRect {
        let hostW = Double(host.width), hostH = Double(host.height)
        var width = hostW * widthRatio
        var height = hostH * heightRatio
        // 오른쪽 위: 버튼 줄 아래에 남는 높이까지만(아래 여백 14pt 남김, 최소 크기 아래로는 줄이지 않는다) — 크게 해도 버튼을 덮지 않게
        if corner == .topRight { height = max(min(height, hostH - edgeInset - Self.margin), minSize.height) }
        // 왼쪽에 두는 창(작은 터미널)도 브라우저가 안 보이면 혼자 오른쪽 구석에 붙는다
        let hugsRight = !anchorsLeft || (!besideBrowser && !large)
        var x = hugsRight ? hostW - Self.margin - width : Self.margin
        if corner == .topRight, anchorsLeft, besideBrowser, !large {
            // 브라우저 처음 자리의 왼쪽: 모자라면 줄인다(최소 크기 아래로는 줄이지 않는다)
            let browser = FloatSpec.browser.anchored(in: host, corner: corner, edgeInset: edgeInset,
                                                      widthRatio: FloatSpec.browser.widthRatio,
                                                      heightRatio: FloatSpec.browser.heightRatio, large: false, besideBrowser: true)
            width = max(min(width, Double(browser.minX) - Self.gap - Self.margin), minSize.width)
            x = Double(browser.minX) - Self.gap - width
        }
        let y = corner == .topRight ? hostH - edgeInset - height : edgeInset
        return clamp(CGRect(x: x, y: y, width: width, height: height), in: host)
    }
}

/// 작은 창의 지금 자리가 어디서 왔는가(시험 명령 `scratch-state`)
public enum FloatRectKind: String, Sendable {
    /// 저장된(사람이 끌거나 크기를 바꾼) 자리
    case saved
    /// 기본 자리, 브라우저가 안 보여 혼자 구석에
    case defaultAlone = "default-alone"
    /// 기본 자리, 브라우저와 나란히
    case defaultBeside = "default-beside"
}

/// 작은 창 하나의 상태. 자리·크기(`frame`)는 창 종류마다 하나를 함께 쓰고,
/// 열림·닫힘은 세션마다 따로 기억한다(`openSessions` — 세션 키는 BrowserBinding.sessionName). 새 세션은 닫힌 채로 시작한다.
/// `shown` 은 지금 고른 세션(`session`)의 열림 여부를 비추는 값이다: 세션을 따라가면(follow) 그 세션 몫으로 바뀌고,
/// 열고 닫으면(setShown) 그 세션 몫이 기록된다. 파일에는 `openSessions` 만 남는다.
public struct FloatState: Equatable, Sendable {
    /// 지금 고른 세션에서 작은 창이 떠 있음
    public private(set) var shown = false
    /// 사람이 끌거나 크기를 바꾼 자리(nil = 기본 자리)
    public var frame: FloatFrame?
    /// 작은 창을 열어 둔 세션들(세션 키)
    public private(set) var openSessions: Set<String> = []
    /// 따라가는 세션 키(에이전트 세션이 아직 없으면 nil)
    public private(set) var session: String?

    public init() {}

    /// 열고 닫음: 따라가는 세션이 있으면 그 세션 몫으로 기록한다
    public mutating func setShown(_ on: Bool) {
        shown = on
        guard let session else { return }
        if on { openSessions.insert(session) } else { openSessions.remove(session) }
    }

    /// 그 세션이 작은 창을 열어 두었나(보이는 세션이 아니어도)
    public func isOpen(session key: String) -> Bool { openSessions.contains(key) }

    /// 지정한 세션의 열림을 바꾼다(앱이 에이전트 활동에 따라 자동으로 열고 닫을 때 — 고른 세션이 아니어도 그 세션 몫만).
    /// 고른 세션이면 지금 보임도 같이 바뀐다.
    public mutating func setOpen(_ on: Bool, for key: String) {
        if on { openSessions.insert(key) } else { openSessions.remove(key) }
        if key == session { shown = on }
    }

    /// 지금 화면에서만 내린다(열림 기록은 그대로): 도크로 옮기거나 배치를 정리할 때. 사람이 닫은 것(`setShown(false)`)과 달리
    /// 세션이 열어 둔 기록을 지우지 않는다 — 구조 정리가 다음 실행에 남을 열림 기록을 지우지 않게.
    public mutating func hide() { shown = false }

    /// 세션이 바뀜: 그 세션이 열어 뒀을 때만 보인다(세션이 없으면 닫힘)
    public mutating func follow(_ session: String?) {
        self.session = session
        shown = session.map(openSessions.contains) ?? false
    }

    /// 없어진 세션의 기록을 지운다. 살아 있는 세션을 하나도 모르면(`live` 가 비어 있으면) 아직 목록을 못 받은 것이므로 지우지 않는다.
    public mutating func prune(keeping live: Set<String>) {
        guard !live.isEmpty else { return }
        openSessions.formIntersection(live)
    }

    fileprivate mutating func restore(sessions: [String]) {
        openSessions = Set(sessions.filter { !$0.isEmpty && $0.count <= 64 }.prefix(2000))
    }
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
    public var browserFloat = FloatState()
    /// 작은 터미널 창(세션마다 임시 셸 하나)
    public var terminalFloat = FloatState()
    /// 🌐·⌨ 버튼과 작은 창 처음 자리의 구석(기본 오른쪽 위)
    public var floatCorner: FloatCorner = .topRight
    /// 화면 모드(기본 자동 — 값이 없으면 자동)
    public var appearance: AppearanceMode = .default
    /// 에이전트가 브라우저를 쓰기 시작하면 작은 창을 자동으로 연다(설정 → 브라우저, 기본 켬 — 빠졌거나 모르는 값이면 켬)
    public var autoOpenBrowser = true

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

    /// 구석을 바꾼다: 두 작은 창의 저장된 자리는 지운다(새 구석의 처음 자리로 다시 열린다). 세션마다 열림 기록은 그대로.
    public mutating func setFloatCorner(_ corner: FloatCorner) {
        guard corner != floatCorner else { return }
        floatCorner = corner
        browserFloat.frame = nil
        terminalFloat.frame = nil
    }

    /// 작은 터미널이 브라우저와 나란히 놓여야 하나: 이 세션의 브라우저가 어떤 방식으로든 보이는 중
    public var terminalBesideBrowser: Bool { isBrowserShown }

    /// 작은 터미널의 지금 자리 종류: 저장된 자리가 있으면 `saved`(자동으로 옮기지 않는다), 없으면 브라우저가 보이는지에 따라
    public var terminalRectKind: FloatRectKind {
        terminalFloat.frame != nil ? .saved : (terminalBesideBrowser ? .defaultBeside : .defaultAlone)
    }

    /// 작은 터미널의 자리(아래-왼쪽 원점, 호스트 안). `browserEdgeInset`·`terminalEdgeInset` = 구석 쪽 가장자리에서 띄울 거리.
    /// 브라우저와 나란히면 터미널 몫(`terminalEdgeInset`), 혼자면 브라우저와 같은 쪽·같은 거리(`browserEdgeInset`).
    public func terminalRect(in host: CGSize, browserEdgeInset: Double, terminalEdgeInset: Double) -> CGRect {
        if let frame = terminalFloat.frame { return frame.rect(in: host, spec: .terminal) }
        let beside = terminalBesideBrowser
        return FloatSpec.terminal.defaultRect(in: host, corner: floatCorner, edgeInset: beside ? terminalEdgeInset : browserEdgeInset,
                                              besideBrowser: beside)
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
            // 숨기면 작은 창이 닫힌다(그 세션의 열림 기록도 지운다 — 사람이 닫은 것). 도크로 옮기면 화면에서만 내리고 기록은 둔다.
            if side == .hidden { browserFloat.setShown(false) } else { browserFloat.hide() }
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
        browserFloat.setShown(true)
    }

    /// 지정한 세션의 브라우저 작은 창을 열거나 닫는다(자동 열기·닫기). 고른 세션이면 지금 화면도 바뀌고, 아니면 그 세션의 열림 기록만.
    public mutating func setBrowserFloat(open: Bool, session key: String) {
        if key == browserFloat.session {
            if open { showBrowserFloat() } else { move(.browser, to: .hidden) }
        } else {
            browserFloat.setOpen(open, for: key)
        }
    }

    /// 작은 터미널 창 열기·닫기(지금 고른 세션 몫)
    public mutating func toggleTerminalFloat() { terminalFloat.setShown(!terminalFloat.shown) }

    /// 세션 창에서 고른 세션이 바뀜(세션 키, 없으면 nil): 두 작은 창 모두 그 세션이 열어 둔 것만 보인다
    public mutating func follow(session: String?) {
        browserFloat.follow(session)
        terminalFloat.follow(session)
    }

    /// 없어진 세션의 열림 기록을 지운다
    public mutating func prune(sessions live: Set<String>) {
        browserFloat.prune(keeping: live)
        terminalFloat.prune(keeping: live)
    }

    /// 고른 도구가 그쪽에 없으면 그쪽 첫 도구로(없으면 비운다)
    public mutating func normalize() {
        for side in [DockSide.left, .right] {
            let tools = tools(in: side)
            if let chosen = selected[side], tools.contains(chosen) { continue }
            selected[side] = tools.first
        }
        selected[.hidden] = nil
        if side(of: .browser) != .hidden { browserFloat.hide() } // 도크와 작은 창은 한 곳만(열림 기록은 그대로)
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
        var terminalFloat: FloatFile?
        var floatCorner: String?
        var appearance: String?
        var autoOpenBrowser: LenientBool?
    }

    /// 모양이 달라도(문자열·숫자…) 파일 전체를 못 읽게 만들지 않는 불리언: 못 읽으면 nil
    private struct LenientBool: Codable {
        var value: Bool?
        init(_ value: Bool?) { self.value = value }
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Bool.self) }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let value { try container.encode(value) } else { try container.encodeNil() }
        }
    }

    /// {"frame":{"right":0.02,"bottom":0.1,"width":0.45,"height":0.65},"sessions":["ad-0123456789ab"]}
    /// (예전 파일의 "shown" 은 세션 구분이 없던 값이라 읽지 않는다 — 세션마다 처음엔 닫힌 채로 시작한다)
    private struct FloatFile: Codable {
        var frame: [String: Double]?
        var sessions: [String]?
    }

    private static func decodeFloat(_ file: FloatFile?) -> FloatState {
        var state = FloatState()
        if let f = file?.frame, let right = f["right"], let bottom = f["bottom"], let width = f["width"], let height = f["height"] {
            let frame = FloatFrame(right: right, bottom: bottom, width: width, height: height)
            if frame.isSane { state.frame = frame }
        }
        state.restore(sessions: file?.sessions ?? [])
        return state
    }

    private static func encodeFloat(_ state: FloatState) -> FloatFile {
        FloatFile(frame: state.frame.map {
            ["right": $0.right.rounded4, "bottom": $0.bottom.rounded4, "width": $0.width.rounded4, "height": $0.height.rounded4]
        }, sessions: state.openSessions.isEmpty ? nil : state.openSessions.sorted())
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
        browserFloat = Self.decodeFloat(file.browserFloat)
        terminalFloat = Self.decodeFloat(file.terminalFloat)
        floatCorner = file.floatCorner.flatMap(FloatCorner.init(rawValue:)) ?? .topRight // 빠졌거나 모르는 값은 오른쪽 위
        appearance = AppearanceMode(stored: file.appearance) // 빠졌거나 모르는 값은 자동
        autoOpenBrowser = file.autoOpenBrowser?.value ?? true // 빠졌거나 모르는 값은 켬
        // 숨긴 도구의 마지막 쪽이 없으면 기본 쪽
        for tool in ToolID.allCases where side(of: tool) != .hidden { lastSides[tool] = side(of: tool) }
        normalize()
        // 예전에 옆 도크에 붙였던 브라우저는 이제 작은 창으로: 도크에서 내린다(열림은 세션마다 처음부터 — 🌐 로 다시 연다)
        if side(of: .browser) != .hidden {
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
                 browserFloat: Self.encodeFloat(browserFloat), terminalFloat: Self.encodeFloat(terminalFloat),
                 floatCorner: floatCorner.rawValue, appearance: appearance == .default ? nil : appearance.rawValue,
                 autoOpenBrowser: autoOpenBrowser ? nil : LenientBool(false))
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
