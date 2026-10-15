import AppKit
import Foundation
import SessionCore

/// iTerm2 연동. iTerm2 는 화면(session)마다 tty 를 알려줘서 Claude 세션과 정확히 짝지을 수 있다.
struct ITermLauncher: LayoutTerminalLauncher {
    static let bundleId = "com.googlecode.iterm2"
    let id = "iterm2"
    let displayName = "iTerm2"
    let canFillRestoredWindows = true
    let canAttach = true

    private var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) }

    var isInstalled: Bool { appURL != nil }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).isEmpty
    }

    /// iTerm2 사전에는 tab 이라는 클래스가 있어 AppleScript 상수 tab 을 못 쓴다. 구분자는 tell 밖에서 만든다.
    private static let prelude = """
        set TB to character id 9
        set LF to character id 10
        """

    /// iTerm2 새 화면은 기본 프로필 폴더(보통 홈)에서 열리므로 폴더 이동을 앞에 붙인다.
    private static func shellInput(_ request: LaunchRequest) -> String {
        "cd \(CommandTemplate.shellQuote(request.cwd)) && \(request.command)"
    }

    func open(_ request: LaunchRequest) throws {
        guard isInstalled else { throw LaunchError.notInstalled(displayName) }
        // 방금 켜서 iTerm2 가 기본 창(빈 셸 하나)만 띄웠으면 새 탭을 만들지 않고 그 화면을 쓴다.
        // (프로필이 자동으로 ssh 등을 띄웠을 수 있으니 그 화면에 셸만 떠 있는지 확인한다)
        if try launchIfNeeded(), let live = try? liveLayout(), live.count == 1, live[0].count == 1, live[0][0].count == 1,
           let only = live[0][0].first, let tty = only.tty, !ProcessUtil.busyTTYs().contains(tty) {
            return try write(request, toTerminal: only.id)
        }
        try AppleScriptRunner.run("""
            on run argv
                set theInput to item 1 of argv
                if application id "\(Self.bundleId)" is not running then return
                tell application id "\(Self.bundleId)"
                    activate
                    if (count of windows) = 0 then
                        set w to (create window with default profile)
                        set s to current session of w
                    else
                        set w to current window
                        if w is missing value then set w to first window
                        tell w to set t to (create tab with default profile)
                        set s to current session of t
                    end if
                    tell s to write text theInput
                end tell
            end run
            """, arguments: [Self.shellInput(request)])
    }

    func focus(titles: [String], cwd: String, tty: String?) throws -> Bool {
        guard isRunning else { return false }
        let result = try AppleScriptRunner.run("""
            on run argv
                set theTTY to item 1 of argv
                set theTitles to rest of argv
                if application id "\(Self.bundleId)" is not running then return "missing"
                tell application id "\(Self.bundleId)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                set hit to false
                                if theTTY is not "" and (tty of s) is theTTY then set hit to true
                                if not hit and theTTY is "" then
                                    repeat with theTitle in theTitles
                                        if (name of s) contains (theTitle as text) then set hit to true
                                    end repeat
                                end if
                                if hit then
                                    tell w to select
                                    tell t to select
                                    tell s to select
                                    activate
                                    return "found"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "missing"
            end run
            """, arguments: [tty ?? ""] + titles.filter { !$0.isEmpty })
        return result == "found"
    }

    // MARK: - 배치(창·탭·분할)

    @discardableResult
    func ensureRunning() throws -> Bool {
        guard isInstalled else { throw LaunchError.notInstalled(displayName) }
        return try launchIfNeeded()
    }

    func write(_ request: LaunchRequest, toTerminal id: String) throws {
        let result = try AppleScriptRunner.run("""
            \(Self.writeToHandler)

            if application id "\(Self.bundleId)" is not running then return "missing"
            tell application id "\(Self.bundleId)" to activate
            if my writeTo(\(GhosttyLauncher.literal(id)), \(GhosttyLauncher.literal(Self.shellInput(request)))) then return "ok"
            return "missing"
            """)
        guard result == "ok" else { throw LaunchError.script("입력할 iTerm2 화면이 사라졌습니다.") }
    }

    func liveLayout() throws -> LiveLayout {
        guard isRunning else { return [] }
        // 한 줄에 화면 하나: 창번호 TAB 탭번호 TAB 화면ID TAB tty TAB 제목
        let output = try AppleScriptRunner.run("""
            \(Self.prelude)
            set out to ""
            if application id "\(Self.bundleId)" is not running then return ""
            tell application id "\(Self.bundleId)"
                set wi to 0
                repeat with w in windows
                    set wi to wi + 1
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        repeat with s in sessions of t
                            set out to out & wi & TB & ti & TB & (id of s) & TB & (tty of s) & TB & (name of s) & LF
                        end repeat
                    end repeat
                end repeat
            end tell
            return out
            """)
        var layout: LiveLayout = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, let w = Int(parts[0]), let t = Int(parts[1]), w >= 1, t >= 1 else { continue }
            while layout.count < w { layout.append([]) }
            while layout[w - 1].count < t { layout[w - 1].append([]) }
            layout[w - 1][t - 1].append(LiveTerminal(
                id: parts[2], title: parts.count > 4 ? parts[4] : "", tty: parts[3].isEmpty ? nil : parts[3]))
        }
        return layout
    }

    func restore(_ window: RestorePlan.Window, fillInto: [[LiveTerminal]]?, requests: [String: LaunchRequest],
                 splitDirection: String, reusing: String?) throws {
        if let fillInto {
            try fill(window, liveWindow: fillInto, requests: requests)
        } else {
            try build(window, requests: requests, splitDirection: splitDirection, reusing: reusing)
        }
    }

    func attach(_ requests: [LaunchRequest], splitting: String?, inWindowOf windowAnchor: String,
                splitDirection: String) throws {
        let split = splitDirection == "down" ? "split horizontally with default profile" : "split vertically with default profile"
        var lines: [String] = []
        for (n, request) in requests.enumerated() {
            if n == 0 && splitting == nil {
                lines.append("tell w to set newTab to (create tab with default profile)")
                lines.append("set lastSession to current session of newTab")
            } else {
                lines.append("tell lastSession to set lastSession to (\(split))")
            }
            lines.append("tell lastSession to write text \(GhosttyLauncher.literal(Self.shellInput(request)))")
        }
        // 기준 화면을 화면 ID 로 찾는다(contents 는 iTerm2 에서 화면 글자라 창 ID·탭·화면 번호로 다시 잡는다)
        let result = try AppleScriptRunner.run("""
            if application id "\(Self.bundleId)" is not running then return "missing"
            tell application id "\(Self.bundleId)"
                set wid to missing value
                repeat with ww in windows
                    set ti to 0
                    repeat with tt in tabs of ww
                        set ti to ti + 1
                        set si to 0
                        repeat with ss in sessions of tt
                            set si to si + 1
                            if (id of ss) is \(GhosttyLauncher.literal(splitting ?? windowAnchor)) then
                                set wid to id of ww
                                set anchorTab to ti
                                set anchorSession to si
                            end if
                        end repeat
                    end repeat
                end repeat
                if wid is missing value then return "missing"
                activate
                set w to window id wid
                set lastSession to session anchorSession of tab anchorTab of w
            \(lines.joined(separator: "\n"))
            end tell
            return "ok"
            """)
        guard result == "ok" else { throw LaunchError.script("옆에 붙일 iTerm2 화면이 사라졌습니다.") }
    }

    /// 화면 ID 로 세션을 찾아 명령을 입력하는 AppleScript 핸들러
    private static let writeToHandler = """
        on writeTo(sessionId, theInput)
            tell application id "\(bundleId)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (id of s) is sessionId then
                                tell s to write text theInput
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
        end writeTo
        """

    /// 되살린 빈 셸(같은 배치)에 명령을 입력한다. 분할 방향·크기는 그대로.
    private func fill(_ window: RestorePlan.Window, liveWindow: [[LiveTerminal]], requests: [String: LaunchRequest]) throws {
        var calls: [String] = []
        for tab in window.tabs {
            for terminal in tab.terminals {
                guard let id = terminal.sessionId, let request = requests[id] else { continue }
                let target = liveWindow[tab.index][terminal.index].id
                calls.append("if not (my writeTo(\(GhosttyLauncher.literal(target)), \(GhosttyLauncher.literal(Self.shellInput(request))))) then set missed to missed + 1")
            }
        }
        guard !calls.isEmpty else { return }
        let missed = try AppleScriptRunner.run("""
            \(Self.writeToHandler)

            set missed to 0
            if application id "\(Self.bundleId)" is not running then return \(calls.count)
            tell application id "\(Self.bundleId)" to activate
            \(calls.joined(separator: "\n"))
            return missed
            """)
        if missed != "0" { throw LaunchError.script("되살린 iTerm2 화면 \(missed)개가 사라져 입력하지 못했습니다.") }
    }

    /// 새 창에 같은 탭·분할 배치를 만든다. iTerm2 도 분할 방향을 알려주지 않아 설정값을 쓴다.
    private func build(_ window: RestorePlan.Window, requests: [String: LaunchRequest], splitDirection: String,
                       reusing: String?) throws {
        let split = splitDirection == "down" ? "split horizontally with default profile" : "split vertically with default profile"
        var lines: [String] = []
        func write(_ sessionId: String?) {
            guard let id = sessionId, let request = requests[id] else { return } // 배치용 빈 셸은 그대로 둔다
            lines.append("tell lastSession to write text \(GhosttyLauncher.literal(Self.shellInput(request)))")
        }
        for (tabNumber, tab) in window.tabs.enumerated() {
            for (position, terminal) in tab.terminals.enumerated() {
                switch (tabNumber, position) {
                case (0, 0) where reusing != nil:
                    // 방금 켠 iTerm2 의 기본 빈 창을 첫 화면으로 쓴다(빈 창이 따로 남지 않게)
                    // (iTerm2 에서 contents 는 화면 글자 속성이라 참조 풀기에 못 쓴다. 창 ID·탭·화면 번호로 다시 잡는다)
                    lines.append("""
                        set wid to missing value
                        repeat with ww in windows
                            set ti to 0
                            repeat with tt in tabs of ww
                                set ti to ti + 1
                                set si to 0
                                repeat with ss in sessions of tt
                                    set si to si + 1
                                    if (id of ss) is \(GhosttyLauncher.literal(reusing!)) then
                                        set wid to id of ww
                                        set reusedTab to ti
                                        set reusedSession to si
                                    end if
                                end repeat
                            end repeat
                        end repeat
                        if wid is missing value then
                            set w to (create window with default profile)
                            set lastSession to current session of w
                        else
                            set w to window id wid
                            set lastSession to session reusedSession of tab reusedTab of w
                        end if
                        """)
                case (0, 0):
                    lines.append("set w to (create window with default profile)")
                    lines.append("set lastSession to current session of w")
                case (_, 0):
                    lines.append("tell w to set newTab to (create tab with default profile)")
                    lines.append("set lastSession to current session of newTab")
                default:
                    lines.append("tell lastSession to set lastSession to (\(split))")
                }
                write(terminal.sessionId)
            }
        }
        try AppleScriptRunner.run("""
            if application id "\(Self.bundleId)" is running then
            tell application id "\(Self.bundleId)"
                activate
            \(lines.joined(separator: "\n"))
            end tell
            end if
            """)
    }

    /// 꺼져 있으면 켜고 첫 창이 뜰 때까지 기다린다. 이번에 켰으면 true.
    private func launchIfNeeded() throws -> Bool {
        guard !isRunning else { return false }
        guard let appURL else { throw LaunchError.notInstalled(displayName) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            guard isRunning else { continue }
            if let count = try? AppleScriptRunner.run(
                "if application id \"\(Self.bundleId)\" is running then tell application id \"\(Self.bundleId)\" to count windows",
                timeout: 5), (Int(count) ?? 0) > 0 {
                Thread.sleep(forTimeInterval: 0.5)
                return true
            }
        }
        return isRunning
    }
}
