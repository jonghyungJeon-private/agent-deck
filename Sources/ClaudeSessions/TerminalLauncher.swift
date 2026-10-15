import AppKit
import Foundation
import SessionCore

struct LaunchRequest {
    var cwd: String
    /// 새 탭의 셸에 입력할 명령
    var command: String
}

/// 터미널 앱별 연동(Ghostty, iTerm2).
protocol TerminalLauncher {
    var id: String { get }
    var displayName: String { get }
    var isInstalled: Bool { get }
    /// 새 탭(창이 없으면 새 창)을 열어 셸에서 명령을 실행한다.
    func open(_ request: LaunchRequest) throws
    /// 실행 중 세션의 탭으로 이동. 찾지 못하면 false. tty 를 알려주는 터미널은 tty 로, 아니면 제목으로 찾는다.
    func focus(titles: [String], cwd: String, tty: String?) throws -> Bool
}

/// 창·탭·분할 배치를 읽고 되살릴 수 있는 터미널
protocol LayoutTerminalLauncher: TerminalLauncher {
    var isRunning: Bool { get }
    /// 터미널이 되살린 빈 셸 창에 명령을 입력해 채울 수 있는가(안 되면 항상 새 창에 배치를 만든다)
    var canFillRestoredWindows: Bool { get }
    func liveLayout() throws -> LiveLayout
    /// fillInto 가 있으면 그 창(터미널이 되살린 빈 셸들)에 명령을 입력하고, 없으면 새 창에 같은 배치를 만든다.
    /// reusing: 새 창 대신 이 화면(방금 켠 터미널의 기본 빈 창)을 첫 화면으로 쓴다.
    func restore(_ window: RestorePlan.Window, fillInto: [[LiveTerminal]]?, requests: [String: LaunchRequest],
                 splitDirection: String, reusing: String?) throws
    /// 같은 탭·창의 세션이 아직 열려 있을 때, 새 창 대신 그 옆에 붙일 수 있는가
    var canAttach: Bool { get }
    /// splitting 화면 옆을 나눠 requests 를 차례로 연다. splitting 이 nil 이면 inWindowOf 화면이 있는 창에 새 탭을 만든다.
    func attach(_ requests: [LaunchRequest], splitting: String?, inWindowOf: String, splitDirection: String) throws
    /// 이미 있는 화면(빈 셸)에 명령을 입력한다.
    func write(_ request: LaunchRequest, toTerminal id: String) throws
    /// 터미널이 꺼져 있으면 켜고 되살린 창이 뜰 때까지 기다린다. 이번에 켰으면 true.
    @discardableResult
    func ensureRunning() throws -> Bool
}

/// 꺼진 세션들을 기록된 배치대로 연다(앱의 "모두 열기"와 `ClaudeSessions restore-all` 공용).
enum LayoutRestorer {
    static func run(stopped: [String], requests: [String: LaunchRequest], snapshot: LayoutSnapshot?,
                    launcher: TerminalLauncher, splitDirection: String) throws {
        guard let layoutLauncher = launcher as? LayoutTerminalLauncher else {
            for id in stopped { if let request = requests[id] { try launcher.open(request) } }
            return
        }
        // 지금 열려 있는 세션과 그 tty(같은 창·탭에 남은 세션 옆에 붙일 때 그 화면을 찾는다)
        let records = SessionStore().all()
        var openTTY: [String: String] = [:]
        for record in records where record.isRunning {
            if let tty = ProcessUtil.info(record.pid)?.tty ?? record.tty { openTTY[record.sessionId] = tty }
        }
        for process in LiveSessions.systemProcesses() {
            if let id = process.argumentSessionId, openTTY[id] == nil, let tty = process.tty { openTTY[id] = tty }
        }
        let plan = RestorePlan.make(snapshot: snapshot, stopped: stopped, open: Set(openTTY.keys))
        let launched = try layoutLauncher.ensureRunning()
        // 채울 창은 화면을 바꾸기 전에 모두 정해 둔다(새 창을 만들면 창 순서가 바뀐다).
        let live = try layoutLauncher.liveLayout()
        func liveTerminal(of sessionId: String) -> String? {
            guard let tty = openTTY[sessionId] else { return nil }
            return live.joined().joined().first { $0.tty == tty }?.id
        }
        // 셸 말고 무언가(claude, vim, ssh 등) 돌고 있는 화면에는 절대 입력하지 않는다
        let busyTTYs = ProcessUtil.busyTTYs()
        // 방금 켠 터미널이 띄운 기본 빈 창(탭 1·화면 1). 새 창을 따로 만들지 않고 이 창을 쓴다.
        var fresh: String? = nil
        if launched, layoutLauncher.canFillRestoredWindows, live.count == 1, live[0].count == 1, live[0][0].count == 1,
           live[0][0][0].tty.map({ !busyTTYs.contains($0) }) ?? TerminalTitle.isIdle(live[0][0][0].title) {
            fresh = live[0][0][0].id
        }
        var used = Set<Int>()
        var fills: [(RestorePlan.Window, [[LiveTerminal]])] = []
        var attaches: [(RestorePlan.Tab, splitting: String?, inWindowOf: String)] = []
        var builds: [RestorePlan.Window] = []
        for window in plan.windows {
            if layoutLauncher.canAttach,
               let windowAnchor = window.openSiblings.lazy.compactMap(liveTerminal(of:)).first {
                // 원래 창의 세션이 아직 열려 있다(예: 분할 A|B 중 A 만 닫힘) → 다른 창이 아니라 그 옆·그 창에 붙인다
                for tab in window.tabs {
                    attaches.append((tab, tab.openSiblings.lazy.compactMap(liveTerminal(of:)).first, windowAnchor))
                }
            } else if layoutLauncher.canFillRestoredWindows,
                      let target = RestorePlan.fillTarget(for: window, in: live, excluding: used, busyTTYs: busyTTYs) {
                used.insert(target)
                if live[target].flatMap({ $0 }).contains(where: { $0.id == fresh }) { fresh = nil }
                fills.append((window, live[target]))
            } else {
                builds.append(window)
            }
        }
        for (window, liveWindow) in fills {
            try layoutLauncher.restore(window, fillInto: liveWindow, requests: requests, splitDirection: splitDirection,
                                       reusing: nil)
        }
        for (tab, splitting, windowAnchor) in attaches {
            let tabRequests = tab.terminals.compactMap { $0.sessionId.flatMap { requests[$0] } }
            guard !tabRequests.isEmpty else { continue }
            try layoutLauncher.attach(tabRequests, splitting: splitting, inWindowOf: windowAnchor,
                                      splitDirection: splitDirection)
        }
        for window in builds {
            try layoutLauncher.restore(window, fillInto: nil, requests: requests, splitDirection: splitDirection,
                                       reusing: fresh)
            fresh = nil
        }
        for id in plan.leftovers {
            guard let request = requests[id] else { continue }
            if let reuse = fresh {
                try layoutLauncher.write(request, toTerminal: reuse)
                fresh = nil
            } else {
                try layoutLauncher.open(request)
            }
        }
    }
}

enum TerminalRegistry {
    static let all: [TerminalLauncher] = [GhosttyLauncher(), ITermLauncher()]

    static func launcher(id: String) -> TerminalLauncher {
        all.first { $0.id == id } ?? all[0]
    }

    /// 세션이 실제로 돌고 있는 터미널(hook 이 기록한 TERM_PROGRAM). 모르면 nil.
    static func launcher(termProgram: String?) -> TerminalLauncher? {
        switch termProgram {
        case "ghostty": return all.first { $0.id == "ghostty" }
        case "iTerm.app": return all.first { $0.id == "iterm2" }
        default: return nil
        }
    }
}

enum LaunchError: LocalizedError {
    case notInstalled(String)
    case script(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name): return "\(name) 이(가) 설치되어 있지 않습니다."
        case .script(let message):
            if message.contains("-1743") || message.contains("Not authorized") {
                return "터미널을 제어할 권한이 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 ClaudeSessions 의 권한을 켜 주세요."
            }
            return message
        }
    }
}

/// osascript 를 자식 프로세스로 돌린다. 인자는 argv 로 넘겨 문자열 이스케이프 문제를 피한다.
/// (자동화 권한은 osascript 가 아니라 이 앱 기준으로 묻는다.)
/// 터미널이 응답하지 않으면 기다리지 않고 timeout 뒤에 끊는다.
enum AppleScriptRunner {
    @discardableResult
    static func run(_ source: String, arguments: [String] = [], timeout: TimeInterval = 20) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] + arguments
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        // 출력은 도는 동안 함께 읽는다(끝난 뒤 읽으면 출력이 pipe 용량을 넘을 때 osascript 가 쓰기에서 멈춘다)
        var out = Data(), err = Data()
        let reads = DispatchGroup()
        for (pipe, isError) in [(output, false), (error, true)] {
            reads.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isError { err = data } else { out = data }
                reads.leave()
            }
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try input.fileHandleForWriting.close()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = reads.wait(timeout: .now() + 2)
            throw LaunchError.script("터미널이 \(Int(timeout))초 동안 응답하지 않아 중단했습니다.")
        }
        reads.wait()
        guard process.terminationStatus == 0 else {
            throw LaunchError.script(String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GhosttyLauncher: LayoutTerminalLauncher {
    static let bundleId = "com.mitchellh.ghostty"
    let id = "ghostty"
    let displayName = "Ghostty"

    private var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) }

    var isInstalled: Bool { appURL != nil }

    /// AppleScript 는 Ghostty 1.3 부터 지원한다.
    private var supportsAppleScript: Bool {
        guard let url = appURL, let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return false }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return (parts.first ?? 0, parts.dropFirst().first ?? 0) >= (1, 3)
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).isEmpty
    }

    /// 되살린 빈 셸에 input text 로 명령을 넣다가 Ghostty 가 멈춘 적이 있어(2026-10-13) 원인을 찾기 전까지 끈다.
    /// 그동안 "모두 열기"는 새 창에 같은 탭·분할 배치를 만든다.
    let canFillRestoredWindows = false
    /// 화면 tty 를 몰라 살아 있는 화면을 정확히 찾을 수 없으므로 붙이지 않고 새 창에 배치를 만든다.
    let canAttach = false

    func attach(_ requests: [LaunchRequest], splitting: String?, inWindowOf: String, splitDirection: String) throws {
        for request in requests { try open(request) }
    }

    func open(_ request: LaunchRequest) throws {
        guard let appURL else { throw LaunchError.notInstalled(displayName) }
        guard supportsAppleScript else { return try openLegacy(request, appURL: appURL) }
        if !isRunning { try launchAndWaitForWindows(appURL: appURL) }
        try AppleScriptRunner.run("""
            on run argv
                set theCwd to item 1 of argv
                set theInput to item 2 of argv
                tell application id "\(Self.bundleId)"
                    activate
                    set cfg to new surface configuration
                    set initial working directory of cfg to theCwd
                    set initial input of cfg to theInput & linefeed
                    if (count of windows) > 0 then
                        new tab in front window with configuration cfg
                    else
                        new window with configuration cfg
                    end if
                end tell
            end run
            """, arguments: [request.cwd, request.command])
    }

    func focus(titles: [String], cwd: String, tty: String?) throws -> Bool {
        guard supportsAppleScript, isRunning else { return false }
        // Claude 는 터미널 제목을 세션 제목으로 바꾼다(앞에 상태 기호가 붙음). 제목이 맞는 탭을 먼저 찾고, 없으면 폴더로 찾는다.
        let result = try AppleScriptRunner.run("""
            on run argv
                set theCwd to item 1 of argv
                set theTitles to rest of argv
                if application id "\(Self.bundleId)" is not running then return "missing"
                tell application id "\(Self.bundleId)"
                    repeat with theTitle in theTitles
                        repeat with term in terminals
                            if (name of term) contains (theTitle as text) then
                                focus term
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                    repeat with term in terminals
                        if (working directory of term) is theCwd then
                            focus term
                            activate
                            return "found"
                        end if
                    end repeat
                end tell
                return "missing"
            end run
            """, arguments: [cwd] + titles.filter { !$0.isEmpty })
        return result == "found"
    }

    // MARK: - 배치(창·탭·분할)

    @discardableResult
    func ensureRunning() throws -> Bool {
        guard let appURL else { throw LaunchError.notInstalled(displayName) }
        guard supportsAppleScript else { throw LaunchError.script("배치 복원은 Ghostty 1.3 이상에서 됩니다.") }
        guard !isRunning else { return false }
        try launchAndWaitForWindows(appURL: appURL)
        return true
    }

    func write(_ request: LaunchRequest, toTerminal id: String) throws {
        try open(request) // Ghostty 는 빈 화면 채우기를 꺼 두어 쓰이지 않는다
    }

    func liveLayout() throws -> LiveLayout {
        guard supportsAppleScript, isRunning else { return [] }
        // 한 줄에 화면 하나: 창번호 TAB 탭번호 TAB 화면ID TAB 제목
        // Ghostty 사전에도 tab 이라는 클래스가 있어 tell 안에서 상수 tab 을 쓰면 구분자가 되지 않는다. 구분자는 tell 밖에서 만든다.
        let output = try AppleScriptRunner.run("""
            set TB to character id 9
            set LF to character id 10
            set out to ""
            if application id "\(Self.bundleId)" is not running then return ""
            tell application id "\(Self.bundleId)"
                set wi to 0
                repeat with w in windows
                    set wi to wi + 1
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        repeat with term in terminals of t
                            set out to out & wi & TB & ti & TB & (id of term) & TB & (name of term) & LF
                        end repeat
                    end repeat
                end repeat
            end tell
            return out
            """)
        var layout: LiveLayout = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let w = Int(parts[0]), let t = Int(parts[1]), w >= 1, t >= 1 else { continue }
            while layout.count < w { layout.append([]) }
            while layout[w - 1].count < t { layout[w - 1].append([]) }
            layout[w - 1][t - 1].append(LiveTerminal(id: parts[2], title: parts.count > 3 ? parts[3] : ""))
        }
        return layout
    }

    func restore(_ window: RestorePlan.Window, fillInto: [[LiveTerminal]]?, requests: [String: LaunchRequest],
                 splitDirection: String, reusing: String?) throws {
        if let fillInto {
            try fill(window, liveWindow: fillInto, requests: requests)
        } else {
            try build(window, requests: requests, splitDirection: splitDirection)
        }
    }

    /// 되살린 빈 셸에 "cd <폴더> && <명령>" 을 입력한다. 분할 방향·크기는 터미널이 되살린 그대로.
    private func fill(_ window: RestorePlan.Window, liveWindow: [[LiveTerminal]], requests: [String: LaunchRequest]) throws {
        var lines: [String] = []
        for tab in window.tabs {
            for terminal in tab.terminals {
                guard let id = terminal.sessionId, let request = requests[id] else { continue }
                let target = liveWindow[tab.index][terminal.index].id
                let input = "cd \(CommandTemplate.shellQuote(request.cwd)) && \(request.command)"
                lines.append("""
                    set term to first terminal whose id is \(Self.literal(target))
                    input text \(Self.literal(input)) to term
                    send key "enter" to term
                    """)
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

    /// 새 창에 같은 탭·분할 배치를 만든다. 분할 방향은 Ghostty 가 알려주지 않아 설정값을 쓴다.
    private func build(_ window: RestorePlan.Window, requests: [String: LaunchRequest], splitDirection: String) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let direction = ["right", "down", "left", "up"].contains(splitDirection) ? splitDirection : "right"
        var lines: [String] = []
        var n = 0
        func config(_ sessionId: String?) -> String {
            n += 1
            var text = """
                set cfg\(n) to new surface configuration
                set initial working directory of cfg\(n) to \(Self.literal(sessionId.flatMap { requests[$0]?.cwd } ?? home))
                """
            if let id = sessionId, let request = requests[id] {
                text += "\nset initial input of cfg\(n) to \(Self.literal(request.command)) & linefeed"
            }
            return text
        }
        for (tabNumber, tab) in window.tabs.enumerated() {
            for (position, terminal) in tab.terminals.enumerated() {
                lines.append(config(terminal.sessionId))
                switch (tabNumber, position) {
                case (0, 0):
                    lines.append("set w to new window with configuration cfg\(n)")
                    lines.append("set lastTerm to focused terminal of (selected tab of w)")
                case (_, 0):
                    lines.append("set newTab to new tab in w with configuration cfg\(n)")
                    lines.append("set lastTerm to focused terminal of newTab")
                default:
                    lines.append("set lastTerm to split lastTerm direction \(direction) with configuration cfg\(n)")
                }
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

    /// AppleScript 문자열 리터럴
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Ghostty 가 꺼져 있으면 켜고, 지난 창이 복원될 때까지 잠깐 기다린다(window-save-state 사용자).
    private func launchAndWaitForWindows(appURL: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            guard isRunning else { continue }
            if let count = try? AppleScriptRunner.run(
                "if application id \"\(Self.bundleId)\" is running then tell application id \"\(Self.bundleId)\" to count windows"),
               (Int(count) ?? 0) > 0 {
                Thread.sleep(forTimeInterval: 0.3)
                return
            }
        }
    }

    /// AppleScript 가 없는 옛 Ghostty: 새 창으로 연다.
    private func openLegacy(_ request: LaunchRequest, appURL: URL) throws {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", appURL.path, "--args", "--working-directory=\(request.cwd)",
                             "-e", shell, "-lic", "\(request.command); exec \(shell) -l"]
        try process.run()
        process.waitUntilExit()
    }
}
