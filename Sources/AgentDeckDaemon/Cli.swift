import Darwin
import Foundation
import SessionCore
import TermLayout
import TermWire

/// 사용자·에이전트용 명령줄 `agentdeck`(실행은 `AgentDeckDaemon cli …` — 앱 묶음의 Helpers/agentdeck 이 이것을 부른다).
/// list·status·send·wait·ask·read·close·new 는 앱이 꺼져 있어도 데몬과 데이터 폴더(hook 상태)만으로 동작한다.
/// 화면이 필요한 것(새 칸 배치·focus)만 앱에 요청 파일을 남긴다(`AppRequestQueue`).
enum Cli {
    struct Failure: Error {
        var message: String
        var code: Int32 = 1
    }

    static var selfPane: String? {
        AgentDeckEnv.nonEmpty("PANE_ID") ?? AgentDeckEnv.nonEmpty("PANE")
    }

    static func run(_ args: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        guard let command = args.first, command != "help", command != "--help", command != "-h" else {
            print(usage)
            return args.isEmpty || args.first == "help" || args.first == "--help" || args.first == "-h" ? 0 : 1
        }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "list", "ls": return try list(rest)
            case "status": return try status(rest)
            case "send": return try send(rest)
            case "wait": return try wait(rest)
            case "ask": return try ask(rest)
            case "read": return try read(rest)
            case "new": return try newPane(rest)
            case "close": return try close(rest)
            case "focus": return try focus(rest)
            default:
                throw Failure(message: "모르는 명령: \(command)\n\(usage)")
            }
        } catch let failure as Failure {
            if !failure.message.isEmpty { fputs(failure.message + "\n", stderr) }
            return failure.code
        } catch {
            fputs("\(error)\n", stderr)
            return 1
        }
    }

    static let usage = """
    agentdeck — AgentDeck 의 칸(터미널)을 다루는 명령. 칸 = 전체 ID · 고유한 앞부분 · 이름(정확히) · . (자기 칸)

      agentdeck list [--json]                       칸 목록(ID·이름·종류·상태·폴더·하위 에이전트, * = 자기 칸)
      agentdeck status <칸> [--json]
      agentdeck send <칸> <글> [--file <경로>] [--no-enter] [--force]   입력 대기(권한 요청·질문) 칸에는 --force 없이는 보내지 않음
      agentdeck wait <칸>... [--timeout <초|1m|10m>] [--any] [--json]
      agentdeck ask <칸> <글> [--file <경로>] [--timeout <시간>] [--json]   보내고 끝나길 기다려 답 글을 출력
      agentdeck read <칸> [--lines N]               그 칸 화면 끝 N줄(기본 40)
      agentdeck new [--claude|--codex|--shell] [--model <모델>] [--effort <수준>] [--cwd <폴더>] [--right|--down] [--of <칸>] [--name <이름>] [<처음 지시>]
      agentdeck close <칸> [--force]                작업 중·입력 대기 칸은 --force 없이는 닫지 않음
      agentdeck focus <칸>                          앱에서 그 칸으로 가기

    상태: working(작업 중) waiting(입력 대기) done(완료) idle(쉬는 중) error(오류) dormant(꺼짐) unknown(상태 hook 없음)
    wait 종료 코드: 0 끝남 · 2 입력 대기(권한 요청·질문) · 3 오류 · 124 시간 초과 · 1 그 밖의 실패
    send·new 종료 코드 2: 입력 대기라 보내지 않음 / new 의 처음 지시를 못 보냄(칸은 만들어 둠)
    """

    // MARK: - 인자

    struct Args {
        var positionals: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []

        static func parse(_ args: [String], values valueOptions: Set<String>, flags flagOptions: Set<String>) throws -> Args {
            var result = Args()
            var index = 0
            var literal = false
            while index < args.count {
                let arg = args[index]
                index += 1
                if literal || !arg.hasPrefix("--") || arg == "--" {
                    if !literal, arg == "--" { literal = true; continue }
                    result.positionals.append(arg)
                    continue
                }
                let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                if flagOptions.contains(name) {
                    result.flags.insert(name)
                } else if valueOptions.contains(name) {
                    if parts.count == 2 {
                        result.values[name] = String(parts[1])
                    } else if index < args.count {
                        result.values[name] = args[index]
                        index += 1
                    } else {
                        throw Failure(message: "\(name) 에 값이 필요합니다")
                    }
                } else {
                    throw Failure(message: "모르는 옵션: \(name)")
                }
            }
            return result
        }
    }

    // MARK: - 관찰

    /// 칸 이름을 어디까지 정할지. 이름은 대화 파일을 읽어야 정해지는 것이 있어 비싸므로 필요한 만큼만 한다.
    enum NameMode {
        /// 이름을 정하지 않는다(wait 의 반복 관찰)
        case none
        /// names.json 에 저장된 이름만(없는 claude 칸의 이름은 비어 있음 — `Observer.completeNames` 로 채운다)
        case stored
    }

    struct Snapshot {
        var panes: [CliPane]
        var readings: [PaneReading]
        /// 데몬이 알린 기능(예전 데몬은 nil)
        var features: [String]?
        /// 모든 칸의 이름이 정해졌는가(false 면 저장된 이름이 없는 claude 칸의 이름이 비어 있다)
        var namesComplete = false

        /// 이 데몬이 만든 칸에는 agentdeck 명령(AGENTDECK_PANE_ID·PATH)이 들어간다(예전 데몬은 아님)
        var supportsCli: Bool { features?.contains(DaemonState.cliFeature) ?? false }
    }

    /// 데몬에서 칸 목록을 받아 상태를 읽는다. 앱과 같은 `PaneStateReader` 라 상태가 같다.
    final class Observer {
        let link: DaemonLink
        let reader = PaneStateReader(persistBindings: false)
        let agents = AgentActivityScanner()

        init(link: DaemonLink) { self.link = link }

        /// agentInterval: 하위 에이전트 훑기 최소 간격(기다리는 동안은 길게). 데몬 목록을 못 받으면 nil(일시 실패일 수 있음 — link.isClosed 로 구분).
        /// 앱의 임시 셸(작은 터미널, ScratchPane)은 칸이 아니므로 뺀다.
        func observe(names mode: NameMode, agentInterval: TimeInterval = 0) -> Snapshot? {
            guard let state = link.state() else { return nil }
            let regular = ScratchPane.split(state.panes) { $0.id }.regular
            let readings = reader.read(regular, seen: SeenStore.load(), transcriptFallback: { TranscriptReader.locate(sessionId: $0) })
            let targets = readings.map {
                AgentScanTarget(paneId: $0.pane.id, session: $0.session, codex: $0.codexSession, codexHome: $0.codex?.home.path)
            }
            let activities = agents.scan(targets, codexReader: reader.codexScanner.reader, minInterval: agentInterval)
            let saved = mode == .none ? [:] : SavedNames.load()
            var complete = mode != .none
            var panes = CliPanes.summarize(readings, agents: activities, names: saved, selfId: selfPane, nameOf: { reading in
                guard mode == .stored else { return "" }
                let stored = PaneNaming.storedName(reading, names: saved)
                if stored == nil { complete = false }
                return stored ?? ""
            })
            panes += dormantPanes(live: Set(state.panes.map(\.id)), names: saved, existing: panes)
            return Snapshot(panes: panes, readings: readings, features: state.features, namesComplete: complete)
        }

        /// 저장된 이름이 없는 claude 칸의 이름을 대화 파일을 읽어 채운다(비싸다 — 이름이 필요할 때만). ids 가 있으면 그 칸만.
        func completeNames(_ snapshot: inout Snapshot, only ids: Set<String>? = nil) {
            guard !snapshot.namesComplete else { return }
            let saved = SavedNames.load()
            for index in snapshot.panes.indices where snapshot.panes[index].name.isEmpty {
                let id = snapshot.panes[index].id
                guard ids?.contains(id) ?? true, let reading = snapshot.readings.first(where: { $0.pane.id == id }) else { continue }
                snapshot.panes[index].name = PaneNaming.displayName(reading, names: saved)
            }
            if ids == nil { snapshot.namesComplete = true }
        }
    }

    /// 꺼진 칸(배치 파일의 되살리기 정보). 임시 셸은 거른다.
    static func dormantPanes(live: Set<String>, names: [String: SavedName], existing: [CliPane]) -> [CliPane] {
        let url = TermPaths.home.appendingPathComponent("layout.json")
        guard let data = try? Data(contentsOf: url), let workspace = try? JSONDecoder().decode(Workspace.self, from: data)
        else { return [] }
        let ids = workspace.dormant.filter { !live.contains($0) && !ScratchPane.isScratch($0) }.sorted()
        let short = PaneSelector.shortIds(existing.map(\.id) + ids)
        return ids.compactMap { id in
            guard let recipe = workspace.recipes[id] else { return nil }
            let kind: PaneKind = recipe.codexSessionId != nil ? .codex : recipe.sessionId != nil ? .claude : .shell
            let folder = (recipe.cwd as NSString).lastPathComponent
            let user = recipe.codexSessionId.flatMap { SavedNames.userTitle("codex:" + $0, in: names) }
                ?? recipe.sessionId.flatMap { SavedNames.userTitle(SavedNames.sessionKey($0), in: names) }
                ?? SavedNames.userTitle(SavedNames.paneKey(id), in: names)
            return CliPanes.dormant(id: id, shortId: short[id] ?? String(id.prefix(8)).lowercased(), name: user ?? folder,
                                    kind: kind, cwd: recipe.cwd)
        }
    }

    static func connect() throws -> Observer {
        guard let link = DaemonLink() else {
            throw Failure(message: "AgentDeck 데몬에 연결할 수 없습니다(\(TermPaths.home.path)). AgentDeck 앱을 한 번 켜 주세요.")
        }
        return Observer(link: link)
    }

    static func snapshot(_ observer: Observer, names: NameMode = .stored) throws -> Snapshot {
        guard let snapshot = observer.observe(names: names) else { throw Failure(message: "데몬이 칸 목록을 주지 않습니다") }
        return snapshot
    }

    static func lookup(_ query: String, in snapshot: Snapshot) -> PaneSelection {
        PaneSelector.resolve(query, among: snapshot.panes.map { PaneCandidate(id: $0.id, name: $0.name) }, selfId: selfPane)
    }

    /// 칸 지정 해석. 모호하거나 없으면 이유와 후보를 stderr 로 내고 실패한다(후보 표에는 이름이 필요하므로 그때 이름을 채운다).
    static func pane(for selection: PaneSelection, query: String, in snapshot: inout Snapshot, observer: Observer) throws -> CliPane {
        switch selection {
        case .found(let id):
            return snapshot.panes.first { $0.id == id }!
        case .notFound:
            observer.completeNames(&snapshot)
            throw Failure(message: "그런 칸이 없습니다: \(query)\n\(table(snapshot.panes))")
        case .noSelf:
            throw Failure(message: "자기 칸(.)을 알 수 없습니다 — AgentDeck 안의 터미널에서 불러야 합니다(AGENTDECK_PANE_ID)")
        case .ambiguous(let ids):
            observer.completeNames(&snapshot)
            let list = snapshot.panes.filter { ids.contains($0.id) }
            throw Failure(message: "'\(query)' 가 여러 칸에 맞습니다. 더 긴 ID 로 지정하세요:\n\(table(list))")
        }
    }

    /// 칸 찾기. 저장된 이름(names.json)으로 먼저 찾고, 못 찾을 때만 모든 claude 칸의 대화 파일을 읽어 이름을 채워 다시 찾는다
    /// (list·status·ask·wait·new 를 부를 때마다 모든 대화 파일을 읽지 않게).
    final class PaneFinder {
        let observer: Observer
        private(set) var snapshot: Snapshot

        init(_ observer: Observer) throws {
            self.observer = observer
            snapshot = try Cli.snapshot(observer)
        }

        func find(_ query: String) throws -> CliPane {
            var selection = Cli.lookup(query, in: snapshot)
            if selection == .notFound, !snapshot.namesComplete {
                observer.completeNames(&snapshot)
                selection = Cli.lookup(query, in: snapshot)
            }
            return try Cli.pane(for: selection, query: query, in: &snapshot, observer: observer)
        }
    }

    // MARK: - 출력

    static func table(_ panes: [CliPane]) -> String {
        let home = NSHomeDirectory()
        let rows = panes.map { pane -> [String] in
            let cwd = pane.cwd.hasPrefix(home) ? "~" + pane.cwd.dropFirst(home.count) : pane.cwd
            return [pane.isSelf ? "*" : " ", pane.shortId, pane.name, pane.kind.rawValue, stateText(pane),
                    pane.subagents > 0 ? "\(pane.subagents)" : "-", cwd]
        }
        return CliOutput.table(headers: [" ", "ID", "이름", "종류", "상태", "하위", "폴더"], rows: rows,
                               maxWidths: [nil, nil, 28, nil, nil, nil, nil])
    }

    static func stateText(_ pane: CliPane) -> String {
        pane.state.rawValue
    }

    static func emit(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    // MARK: - list · status

    static func list(_ args: [String]) throws -> Int32 {
        let options = try Args.parse(args, values: [], flags: ["--json"])
        let observer = try connect()
        var snapshot = try snapshot(observer)
        observer.completeNames(&snapshot) // 목록에는 모든 칸의 이름이 보여야 한다(저장된 이름이 없는 claude 칸만 대화 파일을 읽는다)
        if options.flags.contains("--json") {
            struct Output: Encodable { var panes: [CliPane] }
            emit(CliOutput.json(Output(panes: snapshot.panes)))
        } else if snapshot.panes.isEmpty {
            emit("칸이 없습니다")
        } else {
            emit(table(snapshot.panes))
        }
        return 0
    }

    static func status(_ args: [String]) throws -> Int32 {
        let options = try Args.parse(args, values: [], flags: ["--json"])
        guard options.positionals.count == 1 else { throw Failure(message: "사용법: agentdeck status <칸> [--json]") }
        let observer = try connect()
        let finder = try PaneFinder(observer)
        var pane = try finder.find(options.positionals[0])
        if pane.name.isEmpty { // 저장된 이름이 없는 칸(찾는 데는 이름이 필요 없었다) — 보여 줄 이름만 채운다
            var snapshot = finder.snapshot
            observer.completeNames(&snapshot, only: [pane.id])
            pane = snapshot.panes.first { $0.id == pane.id } ?? pane
        }
        if options.flags.contains("--json") {
            emit(CliOutput.json(pane))
        } else {
            emit("ID      \(pane.id)")
            emit("이름    \(pane.name)\(pane.isSelf ? "  (자기 칸)" : "")")
            emit("종류    \(pane.kind.rawValue)")
            emit("상태    \(pane.state.rawValue)\(pane.message.map { " · " + $0 } ?? "")")
            emit("폴더    \(pane.cwd)")
            if pane.subagents > 0 { emit("하위    작업 중인 하위 에이전트 \(pane.subagents)") }
            if let at = pane.stateAt { emit("상태 시각  \(ISO8601DateFormatter().string(from: at))") }
        }
        return 0
    }

    // MARK: - send

    /// 글을 칸에 보낸다(여러 줄·긴 글은 bracketed paste, 그 칸이 붙여넣기 모드를 켰을 때. claude·codex 칸은 한 줄도 붙여넣기로 —
    /// `!`·`/` 로 시작하는 글이 모드·명령으로 해석되지 않게). 보낸 글자 수를 돌려준다.
    @discardableResult
    static func deliver(_ text: String, to id: String, kind: PaneKind, link: DaemonLink, enter: Bool) throws -> Int {
        var bracketed = false
        let always = PasteEncoding.alwaysPaste(kind: kind)
        if PasteEncoding.needsPaste(text) || always {
            guard let replay = link.replay(id) else { throw Failure(message: "칸이 없습니다: \(id)") }
            var tracker = TerminalModeTracker()
            tracker.feed(replay)
            bracketed = tracker.bracketedPaste
        }
        for step in PasteEncoding.plan(text: text, bracketedPaste: bracketed, enter: enter, alwaysPaste: always) {
            guard link.input(id, step.bytes) else { throw Failure(message: "데몬에 보내지 못했습니다") }
            if step.delayAfter > 0 { Thread.sleep(forTimeInterval: step.delayAfter) }
        }
        return text.count
    }

    /// 글 인자 또는 --file 에서 보낼 글
    static func promptText(_ options: Args, textIndex: Int) throws -> String {
        let inline = options.positionals.count > textIndex ? options.positionals[textIndex] : nil
        if let path = options.values["--file"] {
            guard inline == nil else { throw Failure(message: "글과 --file 을 함께 줄 수 없습니다") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw Failure(message: "파일을 읽을 수 없습니다(UTF-8 글 파일이어야 함): \(path)")
            }
            return text
        }
        guard let inline, !inline.isEmpty else { throw Failure(message: "보낼 글이 없습니다(글 인자 또는 --file)") }
        return inline
    }

    static func send(_ args: [String]) throws -> Int32 {
        let options = try Args.parse(args, values: ["--file"], flags: ["--no-enter", "--json", "--force"])
        guard options.positionals.count >= 1 else {
            throw Failure(message: "사용법: agentdeck send <칸> <글> [--file <경로>] [--no-enter] [--force]")
        }
        let observer = try connect()
        let pane = try PaneFinder(observer).find(options.positionals[0])
        // 입력 대기(권한 요청·질문) 칸에 보내면 Enter 가 사람 대신 "Yes" 를 고른다 — --force 가 아니면 거절(종료 코드 2)
        if let refusal = SendGuard.refusal(state: pane.state, message: pane.message, shortId: pane.shortId,
                                           force: options.flags.contains("--force")) {
            throw Failure(message: refusal.message, code: refusal.code)
        }
        let text = try promptText(options, textIndex: 1)
        let count = try deliver(text, to: pane.id, kind: pane.kind, link: observer.link, enter: !options.flags.contains("--no-enter"))
        if options.flags.contains("--json") {
            struct Output: Encodable { var id: String; var characters: Int; var enter: Bool }
            emit(CliOutput.json(Output(id: pane.id, characters: count, enter: !options.flags.contains("--no-enter"))))
        } else {
            emit("보냄: \(pane.shortId)")
        }
        return 0
    }

    // MARK: - wait

    static let defaultTimeout: TimeInterval = 30 * 60
    static let pollInterval: TimeInterval = 0.4

    static func parseTimeout(_ options: Args) throws -> TimeInterval? {
        guard let text = options.values["--timeout"] else { return defaultTimeout }
        if ["0", "none", "inf", "off"].contains(text.lowercased()) { return nil }
        guard let seconds = CliOutput.parseDuration(text) else {
            throw Failure(message: "--timeout 은 초 또는 1m·10m·1h30m 형식입니다(0 = 제한 없음): \(text)")
        }
        return seconds
    }

    static func observation(of id: String, in snapshot: Snapshot?) -> WaitMachine.Observation {
        guard let pane = snapshot?.panes.first(where: { $0.id == id }) else { return .init(state: .unknown, gone: true) }
        return .init(state: pane.state, seq: pane.stateSeq, at: pane.stateAt)
    }

    /// baseline(지시를 보내기 전 관찰)을 기준으로 시작을 본 뒤 끝나기를 기다린다
    static func waitLoop(ids: [String], config: WaitMachine.Config, observer: Observer,
                         baseline: [String: WaitMachine.Observation], startedAt: Date) -> WaitMachine.Decision {
        var machine = WaitMachine(baseline: baseline, order: ids, config: config, now: startedAt)
        var guardian = ObservationGuard()
        var last = baseline
        while true {
            // 반복 관찰에서는 이름을 정하지 않는다(대화 파일을 읽지 않음)
            let snapshot = observer.observe(names: .none, agentInterval: 3)
            switch guardian.record(observed: snapshot != nil, linkClosed: observer.link.isClosed, now: Date()) {
            case .fail:
                return WaitMachine.lost(order: ids, states: last.mapValues(\.state))
            case .skip:
                // 일시 실패 — 이 회차는 건너뛴다(칸이 사라졌다고 잘못 판단하지 않음). 제한 시간만은 계속 흐른다.
                if let timeout = config.timeout, Date().timeIntervalSince(startedAt) >= timeout {
                    let decision = machine.update(last, now: Date())
                    if case .waiting = decision {} else { return decision }
                }
                Thread.sleep(forTimeInterval: pollInterval)
                continue
            case .ok:
                break
            }
            var observed: [String: WaitMachine.Observation] = [:]
            for id in ids { observed[id] = observation(of: id, in: snapshot) }
            last = observed
            let decision = machine.update(observed, now: Date())
            if case .waiting = decision {
                Thread.sleep(forTimeInterval: pollInterval)
                continue
            }
            return decision
        }
    }

    static func reasonText(_ result: WaitMachine.PaneResult, message: String?) -> String {
        switch result.reason {
        case .finished: return result.state == .waiting ? "입력 대기" + (message.map { " · " + $0 } ?? "") : result.state == .error ? "오류" + (message.map { " · " + $0 } ?? "") : "끝남"
        case .noStart: return "시작하는 것을 못 봄(이미 끝난 상태) — 지금 상태" + (message.map { " · " + $0 } ?? "")
        case .timeout: return "시간 초과"
        case .gone: return "칸이 사라짐"
        case .unknown: return "상태를 알 수 없음 — 상태 hook 이 없거나 꺼진 칸"
        case .lost: return "데몬을 읽지 못함 — 연결이 닫혔거나 \(Int(ObservationGuard.tolerance))초 넘게 응답이 없음(칸의 상태는 모름)"
        }
    }

    struct WaitOutput: Encodable {
        struct Item: Encodable {
            var id: String
            var shortId: String
            var name: String
            var state: String
            var reason: String
            var started: Bool
            var exitCode: Int32
            var message: String?
        }
        var results: [Item]
        var pending: [Item]
        var exitCode: Int32
        var timedOut: Bool
    }

    static func waitReport(_ decision: WaitMachine.Decision, panes: [CliPane], observer: Observer, json: Bool) -> Int32 {
        guard case .finished(let results, let pending, let code) = decision else { return 1 }
        var final = observer.observe(names: .stored)
        if final != nil { observer.completeNames(&final!, only: Set(results.map(\.id) + pending)) } // 결과에 나오는 칸의 이름만
        func pane(_ id: String) -> CliPane? { final?.panes.first { $0.id == id } ?? panes.first { $0.id == id } }
        let items = results.map { result -> WaitOutput.Item in
            let info = pane(result.id)
            return .init(id: result.id, shortId: info?.shortId ?? String(result.id.prefix(8)).lowercased(), name: info?.name ?? "",
                         state: result.state.rawValue, reason: result.reason.rawValue, started: result.started,
                         exitCode: result.exitCode, message: info?.message)
        }
        let pendingItems = pending.map { id -> WaitOutput.Item in
            let info = pane(id)
            return .init(id: id, shortId: info?.shortId ?? String(id.prefix(8)).lowercased(), name: info?.name ?? "",
                         state: info?.state.rawValue ?? "unknown", reason: "pending", started: true, exitCode: 1, message: info?.message)
        }
        if json {
            emit(CliOutput.json(WaitOutput(results: items, pending: pendingItems, exitCode: code, timedOut: code == 124)))
        } else {
            for (item, result) in zip(items, results) {
                emit("\(item.shortId)  \(item.name)  \(item.state)  \(reasonText(result, message: item.message))")
            }
            for item in pendingItems { emit("\(item.shortId)  \(item.name)  \(item.state)  아직 일하는 중") }
        }
        return code
    }

    static func wait(_ args: [String]) throws -> Int32 {
        let options = try Args.parse(args, values: ["--timeout"], flags: ["--any", "--json"])
        guard !options.positionals.isEmpty else {
            throw Failure(message: "사용법: agentdeck wait <칸>... [--timeout <시간>] [--any] [--json]")
        }
        let timeout = try parseTimeout(options)
        let observer = try connect()
        let finder = try PaneFinder(observer)
        var targets: [CliPane] = []
        for query in options.positionals {
            let pane = try finder.find(query)
            if !targets.contains(where: { $0.id == pane.id }) { targets.append(pane) }
        }
        let start = Date()
        let baseline = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, WaitMachine.Observation(state: $0.state, seq: $0.stateSeq, at: $0.stateAt)) })
        let decision = waitLoop(ids: targets.map(\.id),
                                config: .init(timeout: timeout, grace: 3, any: options.flags.contains("--any")),
                                observer: observer, baseline: baseline, startedAt: start)
        return waitReport(decision, panes: targets, observer: observer, json: options.flags.contains("--json"))
    }

    // MARK: - ask

    /// 이번 턴의 답: 에이전트 대화 기록에서(정확), 안 되면 화면 끝.
    /// screenFrom: 보내기 전 화면의 줄 수(화면으로 대신할 때 그 뒤에 늘어난 줄만 낸다)
    static func reply(for id: String, reading: PaneReading?, since transcript: (path: String?, offset: UInt64, codexOrdinal: Int?), state: PaneState,
                      observer: Observer, screenFrom: Int) -> (text: String, source: String) {
        func screen() -> (String, String) {
            guard let all = screenLines(id, observer: observer) else { return ("", "screen") }
            // 보내기 전 마지막 줄(프롬프트)은 입력한 글로 바뀌므로 거기서부터
            let start = screenFrom > 0 && screenFrom - 1 < all.count ? screenFrom - 1 : max(all.count - 30, 0)
            return (all[start...].suffix(60).joined(separator: "\n"), "screen")
        }
        guard let reading else { return screen() }
        switch reading.kind {
        case .claude:
            guard let path = reading.session.flatMap({ $0.transcriptPath ?? TranscriptReader.locate(sessionId: $0.sessionId) })
            else { return screen() }
            let offset = path == transcript.path ? transcript.offset : 0
            // Stop hook 과 기록 쓰기의 시차를 조금 기다려 준다
            for attempt in 0..<5 {
                if let text = TurnReply.lastClaudeText(in: TurnReply.read(path: path, from: offset)) { return (text, "transcript") }
                if attempt < 4 { Thread.sleep(forTimeInterval: 0.4) }
            }
            return screen()
        case .codex:
            if let session = reading.codexSession {
                if let path = session.transcript {
                    let offset = path == transcript.path ? transcript.offset : 0
                    for attempt in 0..<3 {
                        if let text = TurnReply.lastCodexText(in: TurnReply.read(path: path, from: offset)) { return (text, "transcript") }
                        if attempt < 2 { Thread.sleep(forTimeInterval: 0.4) }
                    }
                }
                // 새 CLI 는 대화를 SQLite 로 옮긴다. 보내기 전 기준점보다 뒤의 메시지만 이번 턴 답이다(없으면 아래 화면 끝으로 대신한다).
                if state == .done || state == .idle,
                   let ordinal = transcript.codexOrdinal,
                   let text = observer.reader.codexScanner.reader(reading.codex?.home ?? CodexSessions.defaultHome)
                    .lastAgentMessage(session.id, after: ordinal) {
                    return (text, "transcript")
                }
            }
            return screen()
        case .shell:
            return screen()
        }
    }

    /// 칸 화면의 글(지난 출력을 격자에 그려 읽는다 — ScreenText)
    static func screenLines(_ id: String, observer: Observer) -> [String]? {
        guard let replay = observer.link.replay(id), let info = observer.link.state()?.panes.first(where: { $0.id == id }) else { return nil }
        var screen = ScreenText(cols: info.cols, rows: info.rows)
        screen.feed(replay)
        return screen.lines
    }

    static func screenTail(_ id: String, observer: Observer, lines: Int) -> String? {
        screenLines(id, observer: observer).map { $0.suffix(lines).joined(separator: "\n") }
    }

    static func ask(_ args: [String]) throws -> Int32 {
        let options = try Args.parse(args, values: ["--file", "--timeout"], flags: ["--json"])
        guard options.positionals.count >= 1 else {
            throw Failure(message: "사용법: agentdeck ask <칸> <글> [--file <경로>] [--timeout <시간>] [--json]")
        }
        let timeout = try parseTimeout(options)
        let text = try promptText(options, textIndex: 1)
        let observer = try connect()
        let finder = try PaneFinder(observer)
        let pane = try finder.find(options.positionals[0])
        let before = finder.snapshot
        // 보내기 전 점검: 작업 중인 칸에 보내면 지난 턴의 끝을 이번 답으로 착각하고, 입력 대기 중이면 글이 질문·권한 답이 된다
        switch pane.state {
        case .working: throw Failure(message: "\(pane.shortId) 는 지금 작업 중입니다. agentdeck wait \(pane.shortId) 로 끝난 뒤 다시 물어보세요.")
        case .waiting: throw Failure(message: "\(pane.shortId) 가 입력을 기다리는 중입니다(\(pane.message ?? "권한 요청·질문")). 사람이 답한 뒤 다시 하세요.", code: 2)
        case .dormant: throw Failure(message: "꺼진 칸입니다 — 앱에서 그 탭을 열어 되살린 뒤 다시 하세요: \(pane.shortId)")
        case .unknown: throw Failure(message: "\(pane.shortId) 는 상태 hook 이 없어 끝나는 때를 알 수 없습니다(설정 → 연결에서 hook 연결).")
        case .done, .idle, .error: break
        }
        let reading = before.readings.first { $0.pane.id == pane.id }
        let transcriptPath: String? = reading?.session.flatMap { $0.transcriptPath ?? TranscriptReader.locate(sessionId: $0.sessionId) }
            ?? reading?.codexSession?.transcript
        let offset = TurnReply.size(of: transcriptPath)
        // codex 가 대화를 SQLite 로 옮긴 경우의 기준점(이번 턴 글만 가리려고). 못 읽으면 nil — 그때 SQLite 글은 쓰지 않고 화면으로 대신한다.
        let codexOrdinal: Int? = reading?.codexSession.flatMap {
            observer.reader.codexScanner.reader(reading?.codex?.home ?? CodexSessions.defaultHome).lastItemOrdinal($0.id)
        }
        let screenBefore = screenLines(pane.id, observer: observer)?.count ?? 0
        let start = Date()
        let baseline = [pane.id: WaitMachine.Observation(state: pane.state, seq: pane.stateSeq, at: pane.stateAt)]
        try deliver(text, to: pane.id, kind: pane.kind, link: observer.link, enter: true)
        let decision = waitLoop(ids: [pane.id], config: .init(timeout: timeout, grace: 8, any: false), observer: observer,
                                baseline: baseline, startedAt: start)
        guard case .finished(let results, _, let code) = decision, let result = results.first else { return 1 }
        if result.reason == .noStart {
            throw Failure(message: "보낸 뒤 8초 안에 \(pane.shortId) 가 일을 시작하지 않았습니다(글이 입력창에 남았거나 제출되지 않았을 수 있음). agentdeck read \(pane.shortId) 로 화면을 확인하세요.")
        }
        let json = options.flags.contains("--json")
        let final = observer.observe(names: .none)
        let finalPane = final?.panes.first { $0.id == pane.id }
        var replyText = ""
        var source = "none"
        if code == 0 || code == 3 || code == 2 {
            let found = reply(for: pane.id, reading: final?.readings.first { $0.pane.id == pane.id },
                              since: (transcriptPath, offset, codexOrdinal), state: result.state, observer: observer, screenFrom: screenBefore)
            replyText = found.text
            source = found.source
        }
        if json {
            struct Output: Encodable {
                var id: String
                var state: String
                var reason: String
                var exitCode: Int32
                var reply: String
                var source: String
                var message: String?
            }
            emit(CliOutput.json(Output(id: pane.id, state: result.state.rawValue, reason: result.reason.rawValue, exitCode: code,
                                       reply: replyText, source: source, message: finalPane?.message)))
        } else {
            if code == 0 {
                if source == "screen" { fputs("(대화 기록에서 답을 못 찾아 화면 끝을 냅니다)\n", stderr) }
                emit(replyText)
            } else {
                fputs(reasonText(result, message: finalPane?.message) + "\n", stderr)
                if !replyText.isEmpty { emit(replyText) }
            }
        }
        return code
    }

    // MARK: - read

    static func read(_ args: [String]) throws -> Int32 {
        let options = try Args.parse(args, values: ["--lines"], flags: ["--json"])
        guard options.positionals.count == 1 else { throw Failure(message: "사용법: agentdeck read <칸> [--lines N]") }
        guard let lines = options.values["--lines"].map({ Int($0) }) ?? 40, lines > 0 else {
            throw Failure(message: "--lines 는 1 이상의 정수입니다")
        }
        let observer = try connect()
        let pane = try PaneFinder(observer).find(options.positionals[0])
        guard pane.state != .dormant else { throw Failure(message: "꺼진 칸이라 화면이 없습니다: \(pane.shortId)") }
        guard let text = screenTail(pane.id, observer: observer, lines: lines) else { throw Failure(message: "칸이 없습니다: \(pane.shortId)") }
        if options.flags.contains("--json") {
            struct Output: Encodable { var id: String; var lines: [String] }
            emit(CliOutput.json(Output(id: pane.id, lines: text.isEmpty ? [] : text.components(separatedBy: "\n"))))
        } else if !text.isEmpty {
            emit(text)
        }
        return 0
    }

    // MARK: - new

    /// 새 칸을 만든다. 폴더: --cwd → --of 칸의 폴더 → 부른 칸(AGENTDECK_PANE_ID)의 폴더 → 이 명령의 현재 폴더.
    static func newPane(_ args: [String]) throws -> Int32 {
        let options = try Args.parse(args, values: ["--cwd", "--of", "--name", "--model", "--effort"],
                                     flags: ["--claude", "--codex", "--shell", "--right", "--down", "--json"])
        let kinds = ["--claude", "--codex", "--shell"].filter { options.flags.contains($0) }
        guard kinds.count <= 1 else { throw Failure(message: "--claude·--codex·--shell 은 하나만 고를 수 있습니다") }
        guard !(options.flags.contains("--right") && options.flags.contains("--down")) else {
            throw Failure(message: "--right 와 --down 은 함께 쓸 수 없습니다")
        }
        let kind: PaneKind = kinds.first == "--claude" ? .claude : kinds.first == "--codex" ? .codex : .shell
        guard options.positionals.count <= 1 else { throw Failure(message: "처음 지시는 하나의 글로 주세요(따옴표로 묶기)") }
        let instruction = options.positionals.first
        if instruction != nil, kind == .shell { throw Failure(message: "처음 지시는 --claude·--codex 칸에만 줄 수 있습니다(셸은 send 로 명령을 보내세요)") }
        let name = options.values["--name"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // 앱의 "+ claude"·"+ codex" 와 같은 방식: 설정 창의 새 세션 기본 옵션(launch.json)으로 셸에 명령을 넣는다(칸마다의 --model·--effort 를 덧씌워)
        let launch = LaunchOptions.load(from: TermPaths.home.appendingPathComponent("launch.json"))
        let command: String?
        do {
            command = try NewPaneCommand.command(kind: kind, launch: launch, model: options.values["--model"], effort: options.values["--effort"], name: name)
        } catch let invalid as NewPaneCommand.Invalid {
            throw Failure(message: invalid.message)
        }
        let observer = try connect()
        let finder = try PaneFinder(observer)
        let before = finder.snapshot
        // 붙일 곳: --of 로 지정한 칸, 없으면 부른 칸
        let caller = selfPane.flatMap { id in before.panes.first { $0.id.lowercased() == id.lowercased() } }
        let of = try options.values["--of"].map { try finder.find($0) }
        let anchor = of ?? caller
        // 폴더: --cwd → --of 칸 → 부른 칸 → 지금 폴더(칸의 폴더가 없어졌으면 다음 후보로)
        func isDirectory(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        let cwd: String
        if let explicit = options.values["--cwd"] {
            // 상대 경로는 이 명령의 현재 폴더 기준으로 절대 경로로 바꿔 준다(데몬은 자기 폴더 기준으로 읽는다)
            cwd = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath).standardizedFileURL.path
            guard isDirectory(cwd) else { throw Failure(message: "폴더가 없습니다: \(cwd)") }
        } else {
            let candidates = [of?.cwd, caller?.cwd, FileManager.default.currentDirectoryPath].compactMap { $0 }.filter { !$0.isEmpty }
            guard let found = candidates.first(where: isDirectory) else { throw Failure(message: "새 칸을 열 폴더가 없습니다(--cwd 로 지정하세요)") }
            cwd = found
        }
        if !before.supportsCli {
            fputs("알림: 세션 데몬이 예전 버전이라 이 칸에는 agentdeck 명령(PATH·AGENTDECK_PANE_ID)이 들어가지 않습니다 — "
                + "그 칸의 에이전트는 agentdeck 를 못 씁니다. 모든 세션을 닫고 앱을 끈 뒤 1분쯤 지나 다시 켜면 새 데몬이 뜹니다.\n", stderr)
        }
        let id = UUID().uuidString
        let short = PaneSelector.shortIds(before.panes.map(\.id) + [id])[id] ?? String(id.prefix(8)).lowercased()
        // 앱에 배치·이름을 부탁한다. 칸 ID 를 미리 정했으므로 요청을 칸 만들기보다 **먼저** 남긴다 — 앱이 칸을 처음 보는 목록에서
        // 바로 제자리에 붙여 새 탭에 붙었다 옮겨지는 깜빡임이 없다(앱은 칸이 목록에 나타난 뒤에야 처리). 앱이 꺼져 있으면 무시된다:
        // 칸은 데몬에 있고 앱이 켜질 때 새 탭으로 붙는다.
        let placement: AppRequest.Placement = options.flags.contains("--right") ? .right : options.flags.contains("--down") ? .down
            : anchor == nil ? .tab : .stack
        let request = AppRequest(action: .place, pane: id, anchor: anchor?.id, placement: placement, name: name)
        let requested = (anchor != nil || name != nil) && AppRequestQueue().send(request)
        do {
            try observer.link.create(CreateRequest(id: id, cwd: cwd, cols: 120, rows: 36, input: command.map { $0 + "\n" }, title: name))
        } catch {
            if requested { AppRequestQueue().discard(request) }
            throw Failure(message: "칸을 만들지 못했습니다: \(error)")
        }
        if options.flags.contains("--json") {
            struct Output: Encodable { var id: String; var shortId: String; var kind: String; var cwd: String }
            emit(CliOutput.json(Output(id: id, shortId: short, kind: kind.rawValue, cwd: cwd)))
        } else {
            emit(short)
        }
        if let instruction {
            return try sendFirstInstruction(instruction, id: id, shortId: short, kind: kind, observer: observer)
        }
        return 0
    }

    /// claude 의 상태 hook(SessionStart 등)이 설정 파일에 연결돼 있는가(옛 경로를 가리켜도 연결된 것으로 본다)
    static func claudeHookInstalled() -> Bool {
        let path = Bundle.main.executablePath ?? HookInstaller.daemonExecutable
        return ((try? HookInstaller.claude(daemonPath: path).status()) ?? .notInstalled) != .notInstalled
    }

    /// 처음 지시. 에이전트가 자기 기록을 남긴 것(claude 는 SessionStart hook 으로 세션이 짝지어짐, codex 는 세션 기록이 생김)을 본 뒤에만 보낸다 —
    /// 그 전에 보내면 셸이 받거나, 폴더 신뢰 확인 같은 창에서 Enter 가 사람 대신 "승인" 을 한다. 확인하지 못하면(hook 이 없거나 제한 시간 안에
    /// 못 봄) 보내지 않고 안내를 stderr 로 내며 종료 코드 2 를 돌려준다(칸은 남아 있다).
    static func sendFirstInstruction(_ text: String, id: String, shortId: String, kind: PaneKind, observer: Observer) throws -> Int32 {
        func unsent(_ reason: FirstInstruction.Reason) -> Int32 {
            fputs(FirstInstruction.unsentMessage(kind: kind, shortId: shortId, reason: reason) + "\n", stderr)
            return FirstInstruction.exitCode
        }
        guard FirstInstruction.canConfirm(kind: kind, claudeHookInstalled: claudeHookInstalled()) else { return unsent(.noHook) }
        var readiness = AgentReadiness(kind: kind)
        let deadline = Date().addingTimeInterval(AgentReadiness.timeout)
        while Date() < deadline {
            if let snapshot = observer.observe(names: .none, agentInterval: 3),
               let reading = snapshot.readings.first(where: { $0.pane.id == id }) {
                readiness.observe(.init(foreground: reading.pane.foreground, hasSession: reading.session != nil,
                                        hasCodexSession: reading.codexSession != nil, bufferedBytes: reading.pane.bufferedBytes, at: Date()))
                if readiness.isReady {
                    try deliver(text, to: id, kind: kind, link: observer.link, enter: true)
                    return 0
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return unsent(.notConfirmed)
    }

    // MARK: - close · focus

    static func close(_ args: [String]) throws -> Int32 {
        let options = try Args.parse(args, values: [], flags: ["--force", "--json"])
        guard options.positionals.count == 1 else { throw Failure(message: "사용법: agentdeck close <칸> [--force]") }
        let observer = try connect()
        let pane = try PaneFinder(observer).find(options.positionals[0])
        guard pane.state != .dormant else {
            throw Failure(message: "꺼진 칸은 앱에서 닫으세요(데몬에 없는 칸): \(pane.shortId)")
        }
        if !options.flags.contains("--force") {
            if pane.state == .working || pane.state == .waiting {
                throw Failure(message: "\(pane.shortId) 는 \(pane.state == .working ? "작업 중" : "입력 대기 중")이라 닫지 않았습니다. 정말 닫으려면 --force")
            }
            if pane.isSelf { throw Failure(message: "자기 칸을 닫으면 이 명령을 부른 에이전트도 끝납니다. 정말 닫으려면 --force") }
        }
        observer.link.kill(pane.id)
        let deadline = Date().addingTimeInterval(6)
        var closed = false
        while Date() < deadline {
            if observer.link.state()?.panes.contains(where: { $0.id == pane.id }) == false { closed = true; break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard closed else { throw Failure(message: "\(pane.shortId) 를 끝내라고 했지만 아직 남아 있습니다(프로그램이 신호를 무시하는 중일 수 있음)") }
        if options.flags.contains("--json") {
            struct Output: Encodable { var id: String; var closed: Bool }
            emit(CliOutput.json(Output(id: pane.id, closed: true)))
        } else {
            emit("닫음: \(pane.shortId)")
        }
        return 0
    }

    static func focus(_ args: [String]) throws -> Int32 {
        let options = try Args.parse(args, values: [], flags: [])
        guard options.positionals.count == 1 else { throw Failure(message: "사용법: agentdeck focus <칸>") }
        let pane = try PaneFinder(connect()).find(options.positionals[0])
        guard AppRequestQueue().send(AppRequest(action: .focus, pane: pane.id)) else {
            throw Failure(message: "앱에 요청을 남기지 못했습니다(\(TermPaths.home.path)/requests)")
        }
        emit("요청함: \(pane.shortId) — AgentDeck 앱이 켜져 있으면 그 칸으로 갑니다(\(Int(AppRequestQueue.ttl))초 안에 앱이 안 보면 버려집니다)")
        return 0
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
