import AppKit
import SessionCore
import SwiftUI

/// 실행 파일 하나로 여러 역할을 한다.
/// - `ClaudeSessions hook`       : Claude Code hook (UI 없이 기록만 하고 바로 종료)
/// - `ClaudeSessions list`       : 기록된 세션 목록
/// - `ClaudeSessions refresh`    : 앱의 새로 고침과 같은 정리(남은 claude 로 기록 옮기기 등) 후 목록
/// - `ClaudeSessions open <id>`  : 설정된 터미널 새 탭에서 세션 이어 열기
/// - `ClaudeSessions restore-all`: 꺼진 세션을 기록된 창·탭·분할 배치대로 모두 열기
/// - `ClaudeSessions layout [--save]`: 터미널별 지금 배치와 화면별 세션(진단용). --save 면 기록도 남긴다
/// - `ClaudeSessions focus <id>` : 실행 중 세션의 탭으로 이동
/// - 그 밖 : 메뉴바 앱
@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first != "hook" {
            // Claude 세션 안에서 실행돼도 그 세션 표시를 터미널·claude 로 넘기지 않는다(대화 저장이 꺼지는 문제).
            InheritedEnvironment.reexecIfNeeded(executablePath: Bundle.main.executablePath)
        }
        switch args.first {
        case "hook":
            // 터미널 화면을 닫으면 셸이 작업 전체에 SIGHUP 을 보낸다. 그때 도는 SessionEnd hook 이 같이 죽지 않게 무시한다.
            signal(SIGHUP, SIG_IGN)
            exit(HookHandler.runFromCommandLine())
        case "list":
            exit(CLI.list())
        case "refresh":
            exit(CLI.refresh())
        case "open":
            exit(CLI.open(sessionId: args.dropFirst().first ?? ""))
        case "restore-all":
            exit(CLI.restoreAll())
        case "layout":
            exit(CLI.layout(save: args.contains("--save")))
        case "focus":
            exit(CLI.focus(sessionId: args.dropFirst().first ?? ""))
        default:
            ClaudeSessionsApp.main()
        }
    }
}

enum CLI {
    static func summary(_ record: SessionRecord) -> TranscriptSummary {
        record.transcriptPath.map { TranscriptReader.read(path: $0) } ?? TranscriptSummary()
    }

    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        return 1
    }

    static func list() -> Int32 {
        let opening = LaunchReservations().active()
        for record in SessionStore().all().sorted(by: { $0.startedAt > $1.startedAt }) {
            let summary = summary(record)
            let mark = record.isRunning ? "●" : opening[record.sessionId] != nil ? "◐" : "○"
            print("\(mark) \(record.sessionId)  \(record.termProgram ?? "-")  \(record.tty ?? "-")  \(record.cwd)  "
                + (summary.aiTitle ?? summary.customTitle ?? ""))
        }
        return 0
    }

    static func refresh() -> Int32 {
        SettingsKey.registerDefaults()
        let days = max(1, UserDefaults.standard.integer(forKey: SettingsKey.retentionDays))
        _ = SessionScanner(store: SessionStore(), reservations: LaunchReservations()).scan(retention: TimeInterval(days * 86_400))
        return list()
    }

    static func restoreAll() -> Int32 {
        SettingsKey.registerDefaults()
        let defaults = UserDefaults.standard
        let stopped = SessionStore().all()
            .filter { !$0.isRunning && FileManager.default.fileExists(atPath: $0.cwd) }
            .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
        do {
            let started = try SessionActions.restoreAll(
                stopped.map { (record: $0, request: SessionActions.request(for: $0, summary: summary($0))) },
                splitDirection: defaults.string(forKey: SettingsKey.splitDirection) ?? "right")
            print("\(started)개 세션을 열었습니다." + (started < stopped.count
                ? " (\(stopped.count - started)개는 이미 열려 있거나 여는 중이라 건너뜀)" : ""))
            return 0
        } catch {
            return fail(error.localizedDescription)
        }
    }

    static func candidates() -> [(record: SessionRecord, titles: [String])] {
        SessionStore().all().filter(\.isRunning).map { record in
            let summary = summary(record)
            return (record, [summary.aiTitle, summary.customTitle,
                             ProcessUtil.arguments(record.pid).flatMap(RunningSessionScanner.nameArgument)].compactMap { $0 })
        }
    }

    /// 지금 터미널별 배치와 화면별 세션(진단용). --save 면 앱처럼 기록도 남긴다.
    static func layout(save: Bool) -> Int32 {
        let running = candidates()
        if save {
            let changed = SessionActions.captureLayouts(running: running,
                                                        knownIds: Set(SessionStore().all().map(\.sessionId)))
            print("기록함: \(changed.keys.sorted().joined(separator: ", ").ifEmpty("바뀐 것 없음"))")
        }
        for case let launcher as LayoutTerminalLauncher in TerminalRegistry.all where launcher.isRunning {
            let mine = running.filter { SessionActions.sourceTerminal(of: $0.record).id == launcher.id }
            // 기록된 세션이 없는 터미널은 읽지 않는다(사용 중인 터미널에 불필요한 자동화 요청을 보내지 않게)
            guard !mine.isEmpty else { continue }
            do {
                let live = try launcher.liveLayout()
                let snapshot = LayoutMatcher.snapshot(of: live, candidates: mine.map {
                    LayoutMatcher.Candidate(sessionId: $0.record.sessionId, titles: $0.titles,
                                            tty: ProcessUtil.info($0.record.pid)?.tty ?? $0.record.tty)
                })
                // snapshot 은 세션 없는 창을 빼므로 창마다 따로 짝지어 보여 준다
                print("\(launcher.displayName): 창 \(live.count)개 · 세션 짝지음 \(snapshot.sessionIds.count)/\(mine.count)")
                for (w, window) in live.enumerated() {
                    let matched = LayoutMatcher.snapshot(of: [window], candidates: mine.map {
                        LayoutMatcher.Candidate(sessionId: $0.record.sessionId, titles: $0.titles,
                                                tty: ProcessUtil.info($0.record.pid)?.tty ?? $0.record.tty)
                    }).windows.first
                    for (t, tab) in window.enumerated() {
                        for (p, terminal) in tab.enumerated() {
                            let id = matched?.tabs[t].terminals[p].sessionId
                            print("  창\(w + 1) 탭\(t + 1) 화면\(p + 1)  \(terminal.tty ?? "-")  \(terminal.title)  → \(id ?? "-")")
                        }
                    }
                }
            } catch {
                return fail(error.localizedDescription)
            }
            if let saved = LayoutStore(terminal: launcher.id).load() {
                print("  기록된 배치(\(saved.capturedAt)): " + saved.windows.map { window in
                    "[" + window.tabs.map { $0.terminals.map { $0.sessionId.map { String($0.prefix(8)) } ?? "·" }.joined(separator: "|") }
                        .joined(separator: ", ") + "]"
                }.joined(separator: " "))
            }
        }
        return 0
    }

    static func focus(sessionId: String) -> Int32 {
        guard let record = SessionStore().load(sessionId),
              LiveSessions.openIds(records: [record], processes: LiveSessions.systemProcesses()).contains(sessionId)
        else { return fail("실행 중인 세션이 아닙니다: \(sessionId)") }
        let summary = summary(record)
        let found = (try? SessionActions.sourceTerminal(of: record).focus(
            titles: [summary.aiTitle, summary.customTitle].compactMap { $0 }, cwd: record.cwd,
            tty: ProcessUtil.info(record.pid)?.tty ?? record.tty)) ?? false
        print(found ? "이동했습니다." : "탭을 찾지 못했습니다.")
        return found ? 0 : 1
    }

    static func open(sessionId: String) -> Int32 {
        guard let record = SessionStore().load(sessionId) else { return fail("기록에 없는 세션입니다: \(sessionId)") }
        do {
            switch try SessionActions.open(record, request: SessionActions.request(for: record, summary: summary(record))) {
            case .opened: return 0
            case .alreadyOpen: return fail("이미 열려 있거나 여는 중인 세션입니다: \(sessionId)")
            }
        } catch {
            return fail(error.localizedDescription)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

struct ClaudeSessionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = SessionsModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.stopped.isEmpty ? "terminal" : "terminal.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

/// 메뉴바 아이콘은 노치·아이콘 넘침으로 가려질 수 있어서, 앱을 실행(또는 다시 실행)하면 목록 창을 띄운다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?
    private var sessionsWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        SettingsKey.registerDefaults()
        applyDockPolicy()
        showSessions()
        if CommandLine.arguments.contains("--settings") { showSettings() }
        // 개발용: CLAUDE_SESSIONS_SNAPSHOT=<폴더> 면 열린 창을 PNG 로 저장한다(화면 기록 권한 없이 UI 확인).
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_SESSIONS_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.snapshotWindows(to: dir) }
        }
    }

    /// Dock 에 표시(기본) 또는 메뉴바 전용.
    func applyDockPolicy() {
        let showInDock = UserDefaults.standard.bool(forKey: SettingsKey.showInDock)
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        if !showInDock {
            // 메뉴바 전용으로 바꾸면 창이 뒤로 숨으므로 다시 앞으로.
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    /// 창을 모두 닫아도 메뉴바·Dock 에서 다시 열 수 있게 앱은 계속 둔다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock 아이콘 클릭, 또는 이미 실행 중일 때 Finder·Spotlight 로 다시 열면 불린다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSessions()
        return false
    }

    func showSessions() {
        sessionsWindow = present(sessionsWindow, title: "Claude Sessions") {
            MenuContentView().environmentObject(SessionsModel.shared)
        }
    }

    func showSettings() {
        settingsWindow = present(settingsWindow, title: "Claude Sessions 설정") {
            SettingsView().environmentObject(SessionsModel.shared)
        }
    }

    private func snapshotWindows(to dir: String) {
        for (name, window) in [("sessions", sessionsWindow), ("settings", settingsWindow)] {
            guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func present<Content: View>(_ existing: NSWindow?, title: String,
                                        content: () -> Content) -> NSWindow {
        let window = existing ?? {
            let window = ClickThroughWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

/// 앱이 뒤에 있을 때 첫 클릭은 창을 앞으로 가져오는 데만 쓰인다.
/// SwiftUI 버튼은 첫 클릭도 받지만, 스크롤 목록 안의 행(onTapGesture)은 받지 않아 두 번 눌러야 했다.
/// 창이 그 클릭을 삼켰으면 같은 클릭을 한 번 더 보내 바로 눌리게 한다.
final class ClickThroughWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        let wasKey = isKeyWindow
        super.sendEvent(event)
        guard event.type == .leftMouseDown, !wasKey,
              let content = contentView, let frame = content.superview,
              let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil)),
              hit.isDescendant(of: content), // 제목 막대(창 끌기)는 건드리지 않는다
              !hit.acceptsFirstMouse(for: event) // 첫 클릭을 이미 받은 곳은 두 번 보내지 않는다
        else { return }
        super.sendEvent(event)
    }
}
