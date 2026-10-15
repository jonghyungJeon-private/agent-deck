import Foundation
import SessionCore

/// 세션 열기·모두 열기·배치 기록. 앱과 CLI 가 같은 절차를 쓴다.
/// 열기 전에는 항상 LaunchGate 로 "지금 정말 꺼져 있고, 방금 연 세션도 아닌가"를 다시 확인한다.
enum SessionActions {
    /// 꺼진 세션을 어느 터미널에서 다시 열지
    enum ReopenTarget: String {
        /// 세션이 돌던 터미널(모르면 설정된 터미널)
        case original
        /// 항상 설정된 터미널
        case configured
    }

    static var configuredLauncher: TerminalLauncher {
        SettingsKey.registerDefaults()
        return TerminalRegistry.launcher(id: UserDefaults.standard.string(forKey: SettingsKey.terminal) ?? "ghostty")
    }

    static var reopenTarget: ReopenTarget {
        SettingsKey.registerDefaults()
        return ReopenTarget(rawValue: UserDefaults.standard.string(forKey: SettingsKey.reopenTarget) ?? "") ?? .original
    }

    /// 세션이 돌던 터미널(배치 기록의 출처). 모르는 터미널이면 설정된 터미널로 본다.
    static func sourceTerminal(of record: SessionRecord) -> TerminalLauncher {
        TerminalRegistry.launcher(termProgram: record.termProgram) ?? configuredLauncher
    }

    /// 다시 열 터미널
    static func targetTerminal(of record: SessionRecord) -> TerminalLauncher {
        let source = sourceTerminal(of: record)
        return reopenTarget == .original && source.isInstalled ? source : configuredLauncher
    }

    static func request(for record: SessionRecord, summary: TranscriptSummary, skipPermissions: Bool? = nil) -> LaunchRequest {
        SettingsKey.registerDefaults()
        let defaults = UserDefaults.standard
        let template = defaults.string(forKey: SettingsKey.commandTemplate) ?? CommandTemplate.defaultTemplate
        let name = summary.customTitle ?? summary.aiTitle ?? (record.cwd as NSString).lastPathComponent
        return LaunchRequest(
            cwd: record.cwd,
            command: CommandTemplate.render(template, sessionId: record.sessionId, name: name, cwd: record.cwd,
                                            skipPermissions: skipPermissions ?? defaults.bool(forKey: SettingsKey.skipPermissions)))
    }

    enum OpenResult {
        case opened
        /// 이미 열려 있거나 방금 열라고 보낸 세션
        case alreadyOpen
    }

    /// 세션 하나를 새 탭에서 연다.
    static func open(_ record: SessionRecord, request: LaunchRequest, store: SessionStore = SessionStore(),
                     reservations: LaunchReservations = LaunchReservations()) throws -> OpenResult {
        guard LaunchGate.claim([record.sessionId], store: store, reservations: reservations) == [record.sessionId]
        else { return .alreadyOpen }
        do {
            try targetTerminal(of: record).open(request)
        } catch {
            reservations.release([record.sessionId]) // 열지 못했으니 다시 시도할 수 있게
            throw error
        }
        return .opened
    }

    /// 꺼진 세션을 터미널별로 기록된 배치대로 연다. 실제로 열라고 보낸 세션 수를 돌려준다.
    static func restoreAll(_ items: [(record: SessionRecord, request: LaunchRequest)], splitDirection: String,
                           store: SessionStore = SessionStore(),
                           reservations: LaunchReservations = LaunchReservations()) throws -> Int {
        let granted = Set(LaunchGate.claim(items.map(\.record.sessionId), store: store, reservations: reservations))
        let items = items.filter { granted.contains($0.record.sessionId) }
        guard !items.isEmpty else { return 0 }
        // 배치 기록은 세션이 돌던 터미널 것을 쓰고, 여는 곳은 설정(원래 터미널 / 설정된 터미널)을 따른다.
        var groups: [(source: String, target: TerminalLauncher, items: [(record: SessionRecord, request: LaunchRequest)])] = []
        for item in items {
            let source = sourceTerminal(of: item.record).id
            let target = targetTerminal(of: item.record)
            if let index = groups.firstIndex(where: { $0.source == source && $0.target.id == target.id }) {
                groups[index].items.append(item)
            } else {
                groups.append((source, target, [item]))
            }
        }
        var started = 0
        for (index, group) in groups.enumerated() {
            do {
                try LayoutRestorer.run(
                    stopped: group.items.map(\.record.sessionId),
                    requests: Dictionary(uniqueKeysWithValues: group.items.map { ($0.record.sessionId, $0.request) }),
                    snapshot: LayoutStore(terminal: group.source).load(),
                    launcher: group.target, splitDirection: splitDirection)
                started += group.items.count
            } catch {
                // 아직 손대지 않은 묶음은 다시 열 수 있게 풀어 준다. 도중에 실패한 묶음은 일부가 열렸을 수 있어
                // 잠시(LaunchReservations.ttl) 잡아 둔다(다시 눌러도 같은 세션이 두 번 열리지 않게).
                reservations.release(groups[(index + 1)...].flatMap { $0.items.map(\.record.sessionId) })
                throw error
            }
        }
        return started
    }

    /// 실행 중 세션의 화면 위치를 터미널별로 기록한다. 바뀐 터미널의 새 기록을 돌려준다.
    /// running: 실행 중 세션과 터미널 제목 후보. knownIds: 기록이 남아 있는 모든 세션(닫힌 창 기록을 남길지 판단).
    /// (창을 닫은 직후엔 claude 가 끝나는 데 몇 초 걸려 아직 "실행 중"일 수 있으므로 꺼진 세션만 보지 않는다)
    static func captureLayouts(running: [(record: SessionRecord, titles: [String])], knownIds: Set<String>)
        -> [String: LayoutSnapshot] {
        var changed: [String: LayoutSnapshot] = [:]
        for case let launcher as LayoutTerminalLauncher in TerminalRegistry.all where launcher.isRunning {
            let mine = running.filter { sourceTerminal(of: $0.record).id == launcher.id }
            guard !mine.isEmpty else { continue }
            let candidates = mine.map { item in
                LayoutMatcher.Candidate(sessionId: item.record.sessionId, titles: item.titles,
                                        tty: ProcessUtil.info(item.record.pid)?.tty ?? item.record.tty)
            }
            let live: LiveLayout
            do {
                live = try launcher.liveLayout()
            } catch {
                AppLog.write("배치 읽기 실패(\(launcher.displayName)): \(error.localizedDescription)")
                continue
            }
            let store = LayoutStore(terminal: launcher.id)
            let previous = store.load()
            let current = LayoutMatcher.snapshot(of: live, candidates: candidates)
            // 실행 중 세션이 하나도 안 잡히면(모두 닫히는 중 등) 이전 기록을 그대로 둔다.
            guard !current.sessionIds.isEmpty else { continue }
            let snapshot = current.merging(previous: previous, keep: knownIds)
            // 배치가 그대로면 파일·로그를 다시 쓰지 않는다
            if let previous, previous.hasSameArrangement(as: snapshot) { continue }
            let panes = live.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
            AppLog.write("배치 바뀜(\(launcher.displayName)): 창 \(live.count) · 화면 \(panes) · 세션 짝지음 "
                + "\(current.sessionIds.count)/\(candidates.count) · 닫힌 창 보존 \(snapshot.windows.count - current.windows.count)")
            do {
                try store.save(snapshot)
                changed[launcher.id] = snapshot
            } catch {
                AppLog.write("배치 저장 실패: \(error.localizedDescription)")
            }
        }
        return changed
    }

    static func loadLayouts() -> [String: LayoutSnapshot] {
        var layouts: [String: LayoutSnapshot] = [:]
        for launcher in TerminalRegistry.all {
            if let snapshot = LayoutStore(terminal: launcher.id).load() { layouts[launcher.id] = snapshot }
        }
        return layouts
    }
}
