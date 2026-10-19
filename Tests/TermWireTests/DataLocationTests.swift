import Darwin
import TermWire
import XCTest

/// 데이터 위치 정하기(예전 ClaudeSessions → AgentDeck)와 환경 변수 예전 이름
final class DataLocationTests: XCTestCase {
    typealias Facts = DataLocation.Facts

    // MARK: 정하기(순수 함수)

    /// 표: 새 데몬 → 예전 데몬 → 안 옮긴 예전 데이터 → 새 위치. 새 폴더에 무엇이 있든 판단은 같다(옮기기가 합친다).
    func testAppPlanDecisionTable() {
        let cases: [(Facts, DataLocation.Plan, String)] = [
            (Facts(), .standard, "처음 설치(둘 다 없음)"),
            (Facts(standardHasData: true), .standard, "이미 새 위치"),
            (Facts(legacyHasData: true), .migrate, "예전 데이터만, 데몬 없음 → 옮김"),
            (Facts(legacyDaemon: true, legacyHasData: true), .legacy, "예전 데몬이 살아 있음 → 붙음"),
            (Facts(standardDaemon: true, legacyDaemon: true, standardHasData: true, legacyHasData: true), .standard, "둘 다 살아 있으면 새 것"),
            (Facts(legacyHasData: true, legacyMigrated: true), .standard, "표식 있음 → 다시 옮기지 않음"),
            (Facts(standardHasData: true, legacyHasData: true), .migrate, "둘 다 있고 표식 없음 → 합치기"),
            (Facts(standardDaemon: true, legacyHasData: true), .standard, "새 데몬이 살아 있으면 옮기지 않음"),
            (Facts(legacyDaemon: true, legacyMigrated: true), .legacy, "옮긴 뒤 예전 앱이 다시 데몬을 띄움 → 붙음"),
        ]
        for (facts, plan, label) in cases {
            XCTAssertEqual(DataLocation.appPlan(facts), plan, label)
        }
    }

    /// 64가지 모두: 규칙을 그대로 다시 적어 맞춰 보고, hook 은 앱이 지금(또는 곧) 읽는 곳에 적는지
    func testAllCombinations() {
        for bits in 0..<64 {
            let facts = Facts(standardDaemon: bits & 1 != 0, legacyDaemon: bits & 2 != 0, standardHasData: bits & 4 != 0,
                              legacyHasData: bits & 8 != 0, legacyMigrated: bits & 16 != 0, legacyPending: bits & 32 != 0)
            let plan = DataLocation.appPlan(facts)
            let expected: DataLocation.Plan = facts.standardDaemon ? (facts.legacyPending && !facts.legacyDaemon ? .retry : .standard)
                : facts.legacyDaemon ? .legacy
                : facts.legacyPending ? .retry
                : (facts.legacyHasData && !facts.legacyMigrated) ? .migrate : .standard
            XCTAssertEqual(plan, expected, "\(facts)")
            // hook: 앱이 예전 폴더를 쓰거나(legacy) 곧 옮길(migrate) 때만 예전 폴더에. 옮기다 남은 것이 있으면(retry) 새 위치가 기준.
            XCTAssertEqual(DataLocation.helperUsesLegacy(facts), plan == .legacy || plan == .migrate, "\(facts)")
            if facts.standardDaemon { XCTAssertFalse(DataLocation.helperUsesLegacy(facts)) }
        }
    }

    // MARK: 환경 변수

    func testEnvFallbackToLegacyNames() {
        XCTAssertEqual(AgentDeckEnv.value("DEBUG", in: ["CLAUDE_TERM_DEBUG": "1"]), "1")
        XCTAssertEqual(AgentDeckEnv.value("DEBUG", in: ["AGENTDECK_DEBUG": "0", "CLAUDE_TERM_DEBUG": "1"]), "0", "새 이름이 먼저")
        XCTAssertNil(AgentDeckEnv.value("DEBUG", in: [:]))
        XCTAssertTrue(AgentDeckEnv.isOn("NO_NOTIFY", in: ["CLAUDE_TERM_NO_NOTIFY": "1"]))
        XCTAssertFalse(AgentDeckEnv.isOn("NO_NOTIFY", in: ["AGENTDECK_NO_NOTIFY": "0", "CLAUDE_TERM_NO_NOTIFY": "1"]))
        XCTAssertEqual(AgentDeckEnv.value("PANE", in: ["CLAUDE_SESSIONS_PANE": "P1"]), "P1")
        XCTAssertEqual(AgentDeckEnv.value("PANE", in: ["AGENTDECK_PANE": "P2", "CLAUDE_SESSIONS_PANE": "P1"]), "P2")
        XCTAssertNil(AgentDeckEnv.nonEmpty("SNAPSHOT", in: ["AGENTDECK_SNAPSHOT": ""]))
        XCTAssertEqual(AgentDeckEnv.legacyName("HOME"), "CLAUDE_SESSIONS_HOME")
        XCTAssertEqual(AgentDeckEnv.legacyName("TERM_HOME"), "CLAUDE_TERM_HOME")
        XCTAssertEqual(AgentDeckEnv.legacyName("DEBUG_NAME"), "CLAUDE_TERM_DEBUG_NAME")
    }

    func testExplicitLocations() {
        XCTAssertEqual(DataLocation.explicitRoot(["AGENTDECK_HOME": "/a"])?.path, "/a")
        XCTAssertEqual(DataLocation.explicitRoot(["CLAUDE_SESSIONS_HOME": "/old"])?.path, "/old")
        XCTAssertEqual(DataLocation.explicitRoot(["AGENTDECK_HOME": "/a", "CLAUDE_SESSIONS_HOME": "/old"])?.path, "/a")
        XCTAssertNil(DataLocation.explicitRoot(["AGENTDECK_HOME": ""]))
        XCTAssertEqual(DataLocation.explicitTerm(["CLAUDE_TERM_HOME": "/t"])?.path, "/t")
        XCTAssertEqual(DataLocation.explicitTerm(["AGENTDECK_TERM_HOME": "/n", "CLAUDE_TERM_HOME": "/t"])?.path, "/n")
        let env = ["AGENTDECK_APP_SUPPORT": "/fake/Library/Application Support"]
        XCTAssertEqual(DataLocation.standardRoot(env).path, "/fake/Library/Application Support/AgentDeck")
        XCTAssertEqual(DataLocation.legacyRoot(env).path, "/fake/Library/Application Support/ClaudeSessions")
        XCTAssertTrue(DataLocation.standardRoot([:]).path.hasSuffix("/Library/Application Support/AgentDeck"))
    }

    // MARK: 옮기기·살펴보기(임시 폴더)

    var base: URL!
    var env: [String: String] { ["AGENTDECK_APP_SUPPORT": base.path] }
    var legacy: URL { base.appendingPathComponent("ClaudeSessions") }
    var standard: URL { base.appendingPathComponent("AgentDeck") }

    override func setUpWithError() throws {
        // 소켓 경로가 104바이트를 넘지 않게 짧게
        base = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String, in root: URL) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func seedLegacy() throws {
        try write(#"{"sessionId":"s1"}"#, "sessions/s1.json", in: legacy)
        try write(#"{"tabs":[]}"#, "term/layout.json", in: legacy)
        try write(#"{"pane:a":{"title":"x"}}"#, "term/names.json", in: legacy)
        try write("{}", "codex-sessions/c1.json", in: legacy)
    }

    func testMigrateRenamesWholeFolderAndLeavesMarker() throws {
        try seedLegacy()
        XCTAssertEqual(DataLocation.appPlan(DataLocation.probe(env)), .migrate)
        let result = try DataLocation.migrate(from: legacy, to: standard)
        XCTAssertTrue(result.renamed)
        XCTAssertEqual(read("sessions/s1.json", in: standard), #"{"sessionId":"s1"}"#)
        XCTAssertEqual(read("term/layout.json", in: standard), #"{"tabs":[]}"#)
        XCTAssertEqual(read("codex-sessions/c1.json", in: standard), "{}")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: legacy.path), [DataLocation.markerName])
        XCTAssertEqual(read(DataLocation.markerName, in: legacy)?.split(separator: "\n").first.map(String.init), standard.path)

        let after = DataLocation.probe(env)
        XCTAssertEqual(after, Facts(standardHasData: true, legacyHasData: false, legacyMigrated: true))
        XCTAssertEqual(DataLocation.appPlan(after), .standard)
        XCTAssertFalse(DataLocation.helperUsesLegacy(after))

        // 다시 불러도 아무것도 옮기지 않는다
        let again = try DataLocation.migrate(from: legacy, to: standard)
        XCTAssertEqual(again, DataLocation.Migration())
        XCTAssertEqual(read("term/layout.json", in: standard), #"{"tabs":[]}"#)
    }

    func testMigrateMergesIntoExistingFolderWithoutOverwriting() throws {
        try seedLegacy()
        try write("new-ui", "term/ui.json", in: standard)
        try write("old-ui", "term/ui.json", in: legacy)
        try write("new-names", "term/names.json", in: standard)
        let result = try DataLocation.migrate(from: legacy, to: standard)
        XCTAssertFalse(result.renamed)
        XCTAssertEqual(Set(result.moved), ["codex-sessions", "sessions", "term/layout.json"])
        XCTAssertEqual(Set(result.kept), ["term/names.json", "term/ui.json"])
        XCTAssertEqual(read("term/ui.json", in: standard), "new-ui", "새 쪽을 덮어쓰지 않는다")
        XCTAssertEqual(read("term/ui.json", in: legacy), "old-ui", "겹친 예전 파일은 지우지 않고 남긴다")
        XCTAssertEqual(read("term/layout.json", in: standard), #"{"tabs":[]}"#)
        XCTAssertNotNil(read(DataLocation.markerName, in: legacy))
        XCTAssertEqual(DataLocation.appPlan(DataLocation.probe(env)), .standard, "표식이 있어 다시 옮기지 않는다")
    }

    func testMigrateWithoutLegacyIsNoOp() throws {
        XCTAssertEqual(try DataLocation.migrate(from: legacy, to: standard), DataLocation.Migration())
        XCTAssertFalse(FileManager.default.fileExists(atPath: standard.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(DataLocation.probe(env), Facts())
    }

    /// 예전 폴더의 데몬 소켓이 받으면 살아 있는 것(→ 앱은 붙고, hook 은 예전 폴더에)
    func testProbeSeesLegacyDaemonSocket() throws {
        try seedLegacy()
        let term = DataLocation.termDir(of: legacy)
        let cwd = FileManager.default.currentDirectoryPath
        let fd = try UnixSocket.listen(in: term)
        defer {
            close(fd)
            FileManager.default.changeCurrentDirectoryPath(cwd)
        }
        let facts = DataLocation.probe(env)
        XCTAssertTrue(facts.legacyDaemon)
        XCTAssertFalse(facts.standardDaemon)
        XCTAssertEqual(DataLocation.appPlan(facts), .legacy)
        XCTAssertTrue(DataLocation.helperUsesLegacy(facts))
    }

    /// 남은 소켓 파일·다른 프로세스를 가리키는 daemon.pid 에는 속지 않는다
    func testStaleSocketAndForeignPidAreNotAlive() throws {
        let term = DataLocation.termDir(of: legacy)
        try FileManager.default.createDirectory(at: term, withIntermediateDirectories: true)
        let cwd = FileManager.default.currentDirectoryPath
        let fd = try UnixSocket.listen(in: term)
        close(fd) // 듣던 프로세스가 끝나고 소켓 파일만 남음
        FileManager.default.changeCurrentDirectoryPath(cwd)
        try write("\(getpid())\n", "term/daemon.pid", in: legacy) // 살아 있지만 데몬 실행 파일이 아님(xctest)
        XCTAssertFalse(DataLocation.daemonAlive(termDir: term))
        try write("999999\n", "term/daemon.pid", in: legacy)
        XCTAssertFalse(DataLocation.daemonAlive(termDir: term))
    }

    func testHasDataIgnoresMarkerAndDSStore() throws {
        try write("x", DataLocation.markerName, in: legacy)
        try write("", ".DS_Store", in: legacy)
        XCTAssertFalse(DataLocation.hasData(legacy))
        try write("{}", "sessions/a.json", in: legacy)
        XCTAssertTrue(DataLocation.hasData(legacy))
    }

    // MARK: 옮기기 일부 실패

    /// 정한 이름의 항목은 옮기기가 실패하는 FileManager(권한 없음처럼)
    final class FailingMoves: FileManager {
        var failing: Set<String> = []

        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if failing.contains(srcURL.lastPathComponent) {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: srcURL.path])
            }
            try super.moveItem(at: srcURL, to: dstURL)
        }
    }

    /// 일부 실패 → 완료 표식 없음(남은 항목 표식) → 다시 부르면 남은 것만 옮김 → 완료 표식. 지우는 것은 없다.
    func testPartialFailureIsRetriedThenMarkedComplete() throws {
        try seedLegacy()
        try write("new-ui", "term/ui.json", in: standard)
        try write("old-ui", "term/ui.json", in: legacy)
        let fm = FailingMoves()
        fm.failing = ["sessions", "layout.json"]

        let first = try DataLocation.migrate(from: legacy, to: standard, fileManager: fm)
        XCTAssertFalse(first.complete)
        XCTAssertEqual(Set(first.failed.map(\.path)), ["sessions", "term/layout.json"])
        XCTAssertEqual(first.kept, ["term/ui.json"], "겹침은 실패가 아니다")
        XCTAssertEqual(Set(first.moved), ["codex-sessions", "term/names.json"])
        XCTAssertNil(read(DataLocation.markerName, in: legacy), "실패가 있으면 완료 표식을 남기지 않는다")
        let pending = try XCTUnwrap(read(DataLocation.pendingMarkerName, in: legacy))
        XCTAssertTrue(pending.contains("sessions\n") && pending.contains("term/layout.json\n"))
        // 못 옮긴 것은 예전 폴더에 그대로
        XCTAssertEqual(read("sessions/s1.json", in: legacy), #"{"sessionId":"s1"}"#)
        XCTAssertEqual(read("term/layout.json", in: legacy), #"{"tabs":[]}"#)

        let facts = DataLocation.probe(env)
        XCTAssertTrue(facts.legacyPending)
        XCTAssertFalse(facts.legacyMigrated)
        XCTAssertEqual(DataLocation.appPlan(facts), .retry, "다음 실행 때 다시")
        XCTAssertFalse(DataLocation.helperUsesLegacy(facts), "이미 새 위치가 기준(hook 이 예전 폴더에 적지 않게)")
        XCTAssertTrue(first.summary.contains("실패 2개"))

        let second = try DataLocation.migrate(from: legacy, to: standard)
        XCTAssertTrue(second.complete)
        XCTAssertEqual(Set(second.moved), ["sessions", "term/layout.json"])
        XCTAssertEqual(second.kept, ["term/ui.json"])
        XCTAssertEqual(read("sessions/s1.json", in: standard), #"{"sessionId":"s1"}"#)
        XCTAssertEqual(read("term/layout.json", in: standard), #"{"tabs":[]}"#)
        XCTAssertEqual(read("term/ui.json", in: standard), "new-ui")
        XCTAssertEqual(read("term/ui.json", in: legacy), "old-ui")
        XCTAssertNotNil(read(DataLocation.markerName, in: legacy))
        XCTAssertNil(read(DataLocation.pendingMarkerName, in: legacy), "다 옮기면 남은 항목 표식을 지운다")
        XCTAssertEqual(DataLocation.appPlan(DataLocation.probe(env)), .standard)

        // 다시 불러도 그대로(겹친 것만 남김)
        let third = try DataLocation.migrate(from: legacy, to: standard)
        XCTAssertEqual(third.moved, [])
        XCTAssertTrue(third.complete)
    }

    /// 실제 권한: 읽기 전용 폴더에서는 꺼내지 못해 실패로 남고, 권한이 돌아오면 다음에 옮긴다
    func testReadOnlyFolderFailsThenRetries() throws {
        try seedLegacy()
        try write("{}", "sessions/other.json", in: standard) // 새 폴더에도 sessions 가 있어 안으로 들어가 합친다
        let locked = legacy.appendingPathComponent("sessions")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        let first = try DataLocation.migrate(from: legacy, to: standard)
        XCTAssertEqual(first.failed.map(\.path), ["sessions/s1.json"])
        XCTAssertNil(read(DataLocation.markerName, in: legacy))
        XCTAssertEqual(read("sessions/s1.json", in: legacy), #"{"sessionId":"s1"}"#)
        XCTAssertNil(read("sessions/s1.json", in: standard))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        let second = try DataLocation.migrate(from: legacy, to: standard)
        XCTAssertTrue(second.complete)
        XCTAssertEqual(second.moved, ["sessions/s1.json"])
        XCTAssertEqual(read("sessions/s1.json", in: standard), #"{"sessionId":"s1"}"#)
        XCTAssertNotNil(read(DataLocation.markerName, in: legacy))
    }

    /// 앱이 켤 때: 일부 실패면 새 위치를 쓰고 남은 항목을 알린다. 다음 번에 다 옮기면 알림이 없어진다.
    func testMigrateNowSurfacesPendingAndClearsOnRetry() throws {
        try seedLegacy()
        try write("new-ui", "term/ui.json", in: standard) // term 폴더가 있어 안으로 들어가 하나씩 옮긴다
        let fm = FailingMoves()
        fm.failing = ["names.json"]
        XCTAssertTrue(DataLocation.migrateNow(env, fileManager: fm))
        XCTAssertEqual(DataLocation.migrationPending.map(\.path), ["term/names.json"])
        XCTAssertNil(DataLocation.migrationError)
        let detail = DataLocation.pendingNoticeDetail(DataLocation.migrationPending, legacy: legacy, logPath: "/x/daemon.log")
        XCTAssertTrue(detail.contains("term/names.json") && detail.contains(legacy.path) && detail.contains("/x/daemon.log"))

        XCTAssertEqual(DataLocation.prepareForApp(env), .retry)
        XCTAssertEqual(DataLocation.migrationPending, [])
        XCTAssertEqual(read("term/names.json", in: standard), #"{"pane:a":{"title":"x"}}"#)
        XCTAssertEqual(DataLocation.appPlan(DataLocation.probe(env)), .standard)
    }

    /// 예전 폴더 자체가 읽기 전용 + 새 폴더가 이미 있음: 꺼내지도, 예전 폴더에 기록을 쓰지도 못한다.
    /// 기록은 새 위치(term/migration-pending.json)에 남아, 새 데몬이 떠 있는 다음 실행에도 다시 시도한다.
    func testReadOnlyLegacyRootKeepsPendingInStandardAcrossRelaunch() throws {
        try seedLegacy()
        try write("new-ui", "term/ui.json", in: standard)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: legacy.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacy.path) }

        let first = try DataLocation.migrate(from: legacy, to: standard)
        XCTAssertFalse(first.complete)
        XCTAssertTrue(first.failed.map(\.path).contains("sessions"), "\(first)")
        XCTAssertNil(first.pendingRecordError, "새 위치에는 썼다")
        XCTAssertNil(read(DataLocation.pendingMarkerName, in: legacy), "읽기 전용이라 예전 폴더엔 못 씀")
        XCTAssertNil(read(DataLocation.markerName, in: legacy))
        let record = try XCTUnwrap(read("term/\(DataLocation.pendingRecordName)", in: standard))
        XCTAssertTrue(record.contains("sessions") && record.contains(legacy.path))
        XCTAssertEqual(read("sessions/s1.json", in: legacy), #"{"sessionId":"s1"}"#, "지우지 않는다")

        // 다시 켬: 새 데몬이 떠 있어도 남은 것을 다시 옮긴다(hook 은 새 위치에)
        var facts = DataLocation.probe(env)
        XCTAssertTrue(facts.legacyPending)
        facts.standardDaemon = true
        XCTAssertEqual(DataLocation.appPlan(facts), .retry)
        XCTAssertFalse(DataLocation.helperUsesLegacy(facts))

        // 아직 읽기 전용이면 그대로 남는다
        let again = try DataLocation.migrate(from: legacy, to: standard)
        XCTAssertFalse(again.complete)
        XCTAssertTrue(DataLocation.probe(env).legacyPending)

        // 쓸 수 있게 되면 다 옮기고 완료 표식, 두 기록 모두 지움
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacy.path)
        let done = try DataLocation.migrate(from: legacy, to: standard)
        XCTAssertTrue(done.complete)
        XCTAssertEqual(read("sessions/s1.json", in: standard), #"{"sessionId":"s1"}"#)
        XCTAssertNotNil(read(DataLocation.markerName, in: legacy))
        XCTAssertNil(read("term/\(DataLocation.pendingRecordName)", in: standard))
        XCTAssertNil(read(DataLocation.pendingMarkerName, in: legacy))
        var after = DataLocation.probe(env)
        XCTAssertFalse(after.legacyPending)
        after.standardDaemon = true
        XCTAssertEqual(DataLocation.appPlan(after), .standard)
    }

    /// 기록을 어디에도 못 쓰면 결과에 남긴다(앱이 기록하고 이번 실행 동안 알림을 유지)
    func testPendingRecordWriteFailureIsReported() throws {
        try seedLegacy()
        try write("new-ui", "term/ui.json", in: standard)
        let fm = FileManager.default
        let term = DataLocation.termDir(of: standard)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: legacy.path)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: term.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacy.path)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: term.path)
        }
        let result = try DataLocation.migrate(from: legacy, to: standard)
        XCTAssertFalse(result.complete)
        XCTAssertNotNil(result.pendingRecordError)
    }
}
