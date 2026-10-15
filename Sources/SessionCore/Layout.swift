import Foundation

// 터미널 창 → 탭 → 분할 화면 배치를 기록해 두었다가, 꺼진 세션을 같은 배치로 다시 연다.

public struct LayoutTerminal: Codable, Equatable {
    /// 이 화면에서 돌던 Claude 세션. Claude 가 아닌 화면(일반 셸 등)은 nil.
    public var sessionId: String?
    public var title: String

    public init(sessionId: String?, title: String) {
        self.sessionId = sessionId
        self.title = title
    }
}

public struct LayoutTab: Codable, Equatable {
    public var terminals: [LayoutTerminal]

    public init(terminals: [LayoutTerminal]) {
        self.terminals = terminals
    }
}

public struct LayoutWindow: Codable, Equatable {
    public var tabs: [LayoutTab]

    public init(tabs: [LayoutTab]) {
        self.tabs = tabs
    }

    /// 탭마다 화면 개수. 터미널이 되살린 창과 모양이 같은지 비교할 때 쓴다.
    public var shape: [Int] { tabs.map { $0.terminals.count } }
}

public struct LayoutSnapshot: Codable, Equatable {
    public var capturedAt: Date
    public var windows: [LayoutWindow]

    public init(capturedAt: Date, windows: [LayoutWindow]) {
        self.capturedAt = capturedAt
        self.windows = windows
    }

    public var sessionIds: [String] {
        windows.flatMap { $0.tabs.flatMap { $0.terminals.compactMap(\.sessionId) } }
    }

    /// 지금 화면 배치(self)에 이전 기록의 창 중 통째로 닫힌 창을 이어 붙인다.
    /// 창을 하나씩 닫거나 터미널을 끄는 도중에 기록해도, 닫힌 창의 꺼진 세션 자리를 잃지 않는다.
    /// keep: 기록이 남아 있는 세션. 이런 세션이 하나도 없는 옛 창(모두 /exit 등으로 지워짐)은 버린다.
    public func merging(previous: LayoutSnapshot?, keep: Set<String>) -> LayoutSnapshot {
        guard let previous else { return self }
        let present = Set(sessionIds)
        let kept = previous.windows.filter { window in
            let ids = window.tabs.flatMap { $0.terminals.compactMap(\.sessionId) }
            return !ids.contains(where: present.contains) && ids.contains(where: keep.contains)
        }
        return LayoutSnapshot(capturedAt: capturedAt, windows: windows + kept)
    }

    /// 창·탭·화면 구조와 화면별 세션이 같은가. 화면 제목(Claude 가 상태 기호를 계속 바꾼다)은 보지 않는다.
    public func hasSameArrangement(as other: LayoutSnapshot) -> Bool {
        func key(_ s: LayoutSnapshot) -> [[[String?]]] { s.windows.map { $0.tabs.map { $0.terminals.map(\.sessionId) } } }
        return key(self) == key(other)
    }
}

/// 지금 터미널에 떠 있는 화면 하나(터미널 앱이 알려주는 그대로)
public struct LiveTerminal: Equatable {
    public var id: String
    public var title: String
    /// 화면의 tty. 알려주는 터미널(iTerm2)만 채운다.
    public var tty: String?

    public init(id: String, title: String, tty: String? = nil) {
        self.id = id
        self.title = title
        self.tty = tty
    }
}

/// window → tab → terminal
public typealias LiveLayout = [[[LiveTerminal]]]

public enum TerminalTitle {
    /// Claude 는 터미널 제목을 "<상태 기호> <세션 제목>" 으로 바꾼다(예: "✳ 캐시 개선", "◐ repo@main").
    /// 상태 기호로 시작하면 기호를 뗀 제목을, 아니면(셸 등) nil 을 돌려준다.
    public static func claudeTitle(_ name: String) -> String? {
        guard let first = name.unicodeScalars.first, isStatusGlyph(first) else { return nil }
        let rest = name.unicodeScalars.drop { isStatusGlyph($0) || $0 == " " }
        return String(String.UnicodeScalarView(rest))
    }

    static func isStatusGlyph(_ scalar: Unicode.Scalar) -> Bool {
        if (0x2800...0x28FF).contains(scalar.value) { return true } // 점자 스피너
        switch scalar.properties.generalCategory {
        case .otherSymbol, .mathSymbol: return true
        default: return false
        }
    }

    /// Claude 가 돌고 있지 않은 화면(빈 셸)인가
    public static func isIdle(_ name: String) -> Bool { claudeTitle(name) == nil }
}

public enum LayoutMatcher {
    public struct Candidate {
        public var sessionId: String
        /// 이 세션이 터미널 제목으로 쓸 수 있는 이름들(ai 제목, -n 이름 등)
        public var titles: [String]
        /// claude 의 tty. 터미널이 화면 tty 를 알려주면 제목보다 우선해 정확히 짝짓는다.
        public var tty: String?

        public init(sessionId: String, titles: [String], tty: String? = nil) {
            self.sessionId = sessionId
            self.titles = titles.filter { !$0.isEmpty }
            self.tty = tty
        }
    }

    /// 지금 화면 배치에서 실행 중 세션의 화면을 찾아 기록한다. 세션이 하나도 없는 창은 뺀다.
    /// 화면 tty 를 알려주는 터미널(iTerm2)은 tty 로만 짝짓는다. 제목은 모르는 터미널(Ghostty)에서만,
    /// 그것도 후보가 딱 하나일 때만 쓴다(같은 제목이 여럿이면 자리를 바꿔 기록할 수 있어 비워 둔다).
    public static func snapshot(of live: LiveLayout, candidates: [Candidate], now: Date = Date()) -> LayoutSnapshot {
        var unassigned = candidates
        var panesByTitle: [String: Int] = [:], candidatesByTitle: [String: Int] = [:]
        for terminal in live.joined().joined() where terminal.tty == nil {
            if let title = TerminalTitle.claudeTitle(terminal.title) { panesByTitle[title, default: 0] += 1 }
        }
        for candidate in candidates { for title in Set(candidate.titles) { candidatesByTitle[title, default: 0] += 1 } }
        func isAmbiguous(_ title: String) -> Bool { panesByTitle[title, default: 0] > 1 || candidatesByTitle[title, default: 0] > 1 }
        var windows: [LayoutWindow] = []
        for window in live {
            let tabs = window.map { tab in
                LayoutTab(terminals: tab.map { terminal -> LayoutTerminal in
                    if let tty = terminal.tty {
                        guard let index = unassigned.firstIndex(where: { $0.tty == tty })
                        else { return LayoutTerminal(sessionId: nil, title: terminal.title) }
                        return LayoutTerminal(sessionId: unassigned.remove(at: index).sessionId, title: terminal.title)
                    }
                    guard let title = TerminalTitle.claudeTitle(terminal.title), !isAmbiguous(title),
                          let index = unassigned.firstIndex(where: { $0.titles.contains(title) })
                    else { return LayoutTerminal(sessionId: nil, title: terminal.title) }
                    return LayoutTerminal(sessionId: unassigned.remove(at: index).sessionId, title: terminal.title)
                })
            }
            if tabs.contains(where: { $0.terminals.contains { $0.sessionId != nil } }) {
                windows.append(LayoutWindow(tabs: tabs))
            }
        }
        return LayoutSnapshot(capturedAt: now, windows: windows)
    }
}

/// 꺼진 세션을 기록된 배치대로 여는 계획
public struct RestorePlan: Equatable {
    public struct Terminal: Equatable {
        /// 원래 탭 안에서의 위치(0부터)
        public var index: Int
        /// nil 이면 배치를 지키기 위한 빈 셸
        public var sessionId: String?
    }

    public struct Tab: Equatable {
        public var index: Int
        public var terminals: [Terminal]
        /// 이 탭에서 지금도 열려 있는 세션(원래 위치 순). 있으면 새 창 대신 그 화면 옆을 나눠 붙인다.
        public var openSiblings: [String] = []
    }

    public struct Window: Equatable {
        /// 원래 창 모양(탭마다 화면 개수)
        public var shape: [Int]
        public var tabs: [Tab]
        /// 이 창(다른 탭 포함)에서 지금도 열려 있는 세션. 있으면 그 창에 새 탭으로 붙인다.
        public var openSiblings: [String] = []
    }

    public var windows: [Window]
    /// 배치 기록에 없는 꺼진 세션(새 탭으로 연다)
    public var leftovers: [String]

    /// stopped: 지금 꺼져 있는 세션. 기록에 있어도 이미 다시 열린 세션은 건너뛴다.
    /// open: 지금 열려 있는 세션(같은 창·탭에 남아 있으면 그 옆에 붙이려고 표시해 둔다).
    public static func make(snapshot: LayoutSnapshot?, stopped: [String], open: Set<String> = []) -> RestorePlan {
        let stoppedSet = Set(stopped)
        var placed = Set<String>()
        var windows: [Window] = []
        for window in snapshot?.windows ?? [] {
            var tabs: [Tab] = []
            var windowSiblings: [String] = []
            for (tabIndex, tab) in window.tabs.enumerated() {
                let siblings = tab.terminals.compactMap(\.sessionId).filter { open.contains($0) }
                windowSiblings += siblings
                guard tab.terminals.contains(where: { $0.sessionId.map(stoppedSet.contains) == true }) else { continue }
                let terminals = tab.terminals.enumerated().compactMap { index, terminal -> Terminal? in
                    guard let id = terminal.sessionId else { return Terminal(index: index, sessionId: nil) }
                    guard stoppedSet.contains(id), !placed.contains(id) else { return nil } // 이미 열려 있는 세션
                    placed.insert(id)
                    return Terminal(index: index, sessionId: id)
                }
                tabs.append(Tab(index: tabIndex, terminals: terminals, openSiblings: siblings))
            }
            if !tabs.isEmpty { windows.append(Window(shape: window.shape, tabs: tabs, openSiblings: windowSiblings)) }
        }
        return RestorePlan(windows: windows, leftovers: stopped.filter { !placed.contains($0) })
    }

    /// 터미널이 되살린 창(window-save-state) 중 이 계획 창과 모양이 같고, 채울 자리가 모두 빈 셸인 창을 찾는다.
    /// busyTTYs: claude 가 돌고 있는 tty. 화면 tty 를 알면 그것으로, 모르면 제목으로 빈 셸인지 판단한다.
    public static func fillTarget(for window: Window, in live: LiveLayout, excluding used: Set<Int>,
                                  busyTTYs: Set<String> = []) -> Int? {
        func isIdle(_ terminal: LiveTerminal) -> Bool {
            if let tty = terminal.tty { return !busyTTYs.contains(tty) }
            return TerminalTitle.isIdle(terminal.title)
        }
        return live.indices.first { index in
            guard !used.contains(index), live[index].map(\.count) == window.shape else { return false }
            return window.tabs.allSatisfy { tab in
                tab.terminals.allSatisfy { terminal in
                    terminal.sessionId == nil || isIdle(live[index][tab.index][terminal.index])
                }
            }
        }
    }
}

/// 터미널마다 따로 저장한다(layout-iterm2.json, layout-ghostty.json).
public struct LayoutStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(terminal: String, dir: URL = Paths.appSupport) {
        self.url = dir.appendingPathComponent("layout-\(terminal).json")
    }

    /// 예전 판의 layout.json(터미널 구분 없음)을 그때 설정된 터미널의 기록으로 옮긴다.
    public static func migrateLegacy(toTerminal terminal: String, dir: URL = Paths.appSupport) {
        let legacy = dir.appendingPathComponent("layout.json")
        let target = LayoutStore(terminal: terminal, dir: dir).url
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: legacy)
        } else {
            try? FileManager.default.moveItem(at: legacy, to: target)
        }
    }

    public func load() -> LayoutSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LayoutSnapshot.self, from: data)
    }

    public func save(_ snapshot: LayoutSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
